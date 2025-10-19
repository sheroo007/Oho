# ==========================================================
# SmartGroundGuard.pl v1.2.1 (smart.txt, RAM-cached, compat)
# - FIX: ไม่ import $spellsList จาก Globals (บางบิลด์ไม่ export)
# - ใช้ _iter_spells() รองรับทั้ง $spellsList และ $spells
# ==========================================================

package SmartGroundGuard;
use strict;
use Plugins;
use Log qw(message debug warning);
use Globals qw(%config $char $field $monstersList $itemsList);  # <- removed $spellsList
use AI;
use Commands;
use Utils qw(blockDistance);
use Time::HiRes qw(time);

# บางฟอร์กไม่ได้ export ตัวแปรสเปล ให้ประกาศ our ไว้เพื่อ strict และอ้างถึงของระบบ
our ($spellsList, $spells);

my $HAS_SMARTCORE = eval { require SmartCore; 1 } || 0;

my $PLUGIN = 'SmartGroundGuard';
my $hooks;

# ----------------------- Defaults -----------------------
my %defaults = (
  'smart.avoid.enable'               => 1,
  'smart.avoid.skills'               => 'Firewall, Storm Gust, Meteor Storm, Quagmire, Land Protector, Sanctuary, Safety Wall, Magnus Exorcismus, Ice Wall',
  'smart.avoid.radius.default'       => 3,
  'smart.avoid.radius.Firewall'      => 1,
  'smart.avoid.radius.Ice Wall'      => 1,
  'smart.avoid.noAttackThrough'      => 'Firewall, Ice Wall',
  'smart.avoid.sampleStep'           => 1,
  'smart.avoid.loot.block'           => 1,
  'smart.avoid.loot.defer_ms'        => 5500,
  'smart.avoid.loot.restoreGather'   => 1,
  'smart.avoid.stepBackTiles'        => 3,
  'smart.avoid.repos.maxTry'         => 3,
  'smart.avoid.attack.suppress_ms'   => 500,
  'smart.avoid.grid.cell'            => 4,
  'smart.avoid.cooldown.recheck_ms'  => 120,
  'smart.avoid.debug'                => 0,
);

# ----------------------- Runtime config ------------------
my %cfg = ();
my %AVOID_SET; my %NO_THRU_SET; my %RADIUS_BY_NAME;

# Hazard RAM cache
my %HZ = (); my %GRID = ();
my $GRID_CELL = 4;
my $SPELLS_SIG = '';
my $HZ_VER = 0;

# Runtime states
my $last_tick_ms = 0;
my $defer_loot_until = 0;
my $saved_itemsGatherAuto;
my $items_gather_suppressed = 0;
my $suppress_attack_until = 0;

# ----------------------- Utils ---------------------------
sub _now_ms { int(time*1000) }
sub _norm   { my $s = lc($_[0] // ''); $s =~ s/^\s+|\s+$//g; $s }
sub _logd   { debug "[$PLUGIN] $_[0]\n", 'smartavoid' if $cfg{'smart.avoid.debug'} }
sub _get    { my ($k)=@_; exists $config{$k} ? $config{$k} : $defaults{$k} }

sub _load_config {
  %cfg = ();
  for my $k (keys %defaults) { $cfg{$k} = _get($k) }

  %AVOID_SET=(); %NO_THRU_SET=();
  for my $n (split /,/, ($cfg{'smart.avoid.skills'} // '')) {
    $n =~ s/^\s+|\s+$//g; next unless length $n; $AVOID_SET{ _norm($n) } = 1;
  }
  for my $n (split /,/, ($cfg{'smart.avoid.noAttackThrough'} // '')) {
    $n =~ s/^\s+|\s+$//g; next unless length $n; $NO_THRU_SET{ _norm($n) } = 1;
  }

  %RADIUS_BY_NAME = ();
  $RADIUS_BY_NAME{'*default'} = $cfg{'smart.avoid.radius.default'} || 3;
  while (my ($k,$v) = each %config) {
    if ($k =~ /^smart\.avoid\.radius\.(.+)$/) { $RADIUS_BY_NAME{ _norm($1) } = $v+0; }
  }

  $GRID_CELL = $cfg{'smart.avoid.grid.cell'} || 4;
  _logd("config loaded: grid=$GRID_CELL skills=".scalar(keys %AVOID_SET)." walls=".scalar(keys %NO_THRU_SET));
}

sub _radius_for { my ($name_norm)=@_; $RADIUS_BY_NAME{$name_norm} // $RADIUS_BY_NAME{'*default'} // 3 }

# ---- spell iterator (compat) ----
sub _iter_spells {
  my @out;
  if (defined $spellsList && eval { $spellsList->can('getItems') }) {
    @out = $spellsList->getItems();
  } elsif (defined $spells && eval { $spells->can('getItems') }) {
    @out = $spells->getItems();
  } else {
    @out = (); # ไม่มีระบบสเปลในบิลด์นี้
  }
  return @out;
}

# ----------------------- Hazard cache --------------------
sub _spells_signature {
  my @sig;
  foreach my $sp (_iter_spells()) {
    my $name = eval { $sp->name } // $sp->{name} // '';
    my $pos  = eval { $sp->position } // $sp->{pos} // $sp->{position};
    next unless $name && $pos && defined $pos->{x} && defined $pos->{y};
    my $en   = $sp->{endTime} // $sp->{timeout} // 0;
    push @sig, join('|', _norm($name), $pos->{x}, $pos->{y}, int($en||0));
  }
  return join(';', sort @sig);
}

sub _clear_hazard_cache { %HZ=(); %GRID=(); }

sub _grid_span {
  my ($x,$y,$r) = @_;
  my $gx1 = int( ($x-$r) / $GRID_CELL );
  my $gy1 = int( ($y-$r) / $GRID_CELL );
  my $gx2 = int( ($x+$r) / $GRID_CELL );
  my $gy2 = int( ($y+$r) / $GRID_CELL );
  ($gx1,$gy1,$gx2,$gy2)
}

sub _grid_insert {
  my ($key,$gx1,$gy1,$gx2,$gy2) = @_;
  for (my $gx=$gx1; $gx <= $gx2; $gx++) {
    for (my $gy=$gy1; $gy <= $gy2; $gy++) { $GRID{"$gx,$gy"}{$key} = 1; }
  }
}

sub _rebuild_hazard_if_changed {
  my $sig = _spells_signature();
  return if $sig eq $SPELLS_SIG;

  $SPELLS_SIG = $sig;
  _clear_hazard_cache();

  foreach my $sp (_iter_spells()) {
    my $name = eval { $sp->name } // $sp->{name} // '';
    my $pos  = eval { $sp->position } // $sp->{pos} // $sp->{position};
    next unless $name && $pos && defined $pos->{x} && defined $pos->{y};

    my $name_norm = _norm($name);
    next unless $AVOID_SET{$name_norm};

    my $x = $pos->{x}+0; my $y = $pos->{y}+0;
    my $r = _radius_for($name_norm); my $r2 = $r*$r;
    my $end = $sp->{endTime} // $sp->{timeout} // 0;
    my $exp_ms = $end && $end>time ? int(1000*($end-time)) : 0;

    my ($gx1,$gy1,$gx2,$gy2) = _grid_span($x,$y,$r);
    my $key = join('#', $name_norm,$x,$y,$r,$exp_ms);
    $HZ{$key} = { name_norm=>$name_norm, x=>$x, y=>$y, r=>$r, r2=>$r2,
                  exp_ms=>$exp_ms, gx1=>$gx1, gy1=>$gy1, gx2=>$gx2, gy2=>$gy2 };
    _grid_insert($key,$gx1,$gy1,$gx2,$gy2);
  }

  $HZ_VER++;
  _logd("hazard rebuilt: n=".scalar(keys %HZ)." ver=$HZ_VER");
}

# ----------------------- Queries (RAM) --------------------
sub _is_in_hazard_q {
  my ($x,$y) = @_;
  my $gx = int($x / $GRID_CELL);
  my $gy = int($y / $GRID_CELL);

  for my $ix (-1..1) {
    for my $iy (-1..1) {
      my $bk = $GRID{ ($gx+$ix).",".($gy+$iy) } or next;
      while (my ($key,undef) = each %$bk) {
        my $h = $HZ{$key} or next;
        my $dx = $x - $h->{x}; my $dy = $y - $h->{y};
        next if ($dx*$dx + $dy*$dy) > $h->{r2};
        return (1, $h);
      }
    }
  }
  return (0, undef);
}

sub _segment_cross_hazard_q {
  my ($sx,$sy,$tx,$ty) = @_;
  my $step = $cfg{'smart.avoid.sampleStep'} || 1;
  my $dx = $tx - $sx; my $dy = $ty - $sy;
  my $len = abs($dx) + abs($dy);
  my $n = ($len / $step); $n = 1 if $n < 1;

  for (my $i=0; $i <= $n; $i++) {
    my $t = $i / $n;
    my $x = int($sx + $dx*$t);
    my $y = int($sy + $dy*$t);
    my ($hit,$h) = _is_in_hazard_q($x,$y);
    return (1,$h) if $hit && $NO_THRU_SET{ $h->{name_norm} };
  }
  return (0, undef);
}

# ----------------------- Items gather ctrl ----------------
sub _suppress_items_gather {
  return if $items_gather_suppressed;
  $saved_itemsGatherAuto = exists $config{'itemsGatherAuto'} ? $config{'itemsGatherAuto'} : 1;
  Commands::run('conf itemsGatherAuto 0');
  $items_gather_suppressed = 1;
  _logd("itemsGatherAuto -> 0");
}

sub _restore_items_gather {
  return unless $items_gather_suppressed;
  if ($cfg{'smart.avoid.loot.restoreGather'}) {
    Commands::run(sprintf('conf %s %s', 'itemsGatherAuto', $saved_itemsGatherAuto));
  }
  $items_gather_suppressed = 0;
  _logd("itemsGatherAuto restored -> $saved_itemsGatherAuto");
}

# ----------------------- Movement helpers ----------------
sub _step_back_from_center {
  my ($hx,$hy) = @_;
  my $me = $char->position or return;
  my ($sx,$sy) = ($me->{x}, $me->{y});
  my $dx = $sx - $hx; my $dy = $sy - $hy;
  $dx = ($dx==0 ? 0.0001 : $dx); $dy = ($dy==0 ? 0.0001 : $dy);
  my $len = sqrt($dx*$dx + $dy*$dy);
  my $ux = $dx/$len; my $uy = $dy/$len;
  my $step = $cfg{'smart.avoid.stepBackTiles'} || 3;
  my $tx = int($sx + $ux*$step); my $ty = int($sy + $uy*$step);
  Commands::run("move $tx $ty");
}

sub _reposition_around {
  my ($targetPos) = @_;
  my ($tx,$ty) = ($targetPos->{x}, $targetPos->{y});
  my $try = $cfg{'smart.avoid.repos.maxTry'} || 3;
  for (1..$try) {
    my $nx = $tx + (-1 + int(rand(3))) * 2;
    my $ny = $ty + (-1 + int(rand(3))) * 2;
    my ($hit,undef) = _is_in_hazard_q($nx,$ny);
    next if $hit;
    Commands::run("move $nx $ny");
    last;
  }
}

# ----------------------- Hooks ---------------------------
Plugins::register($PLUGIN, 'Avoid ground skills (smart.txt, RAM cache, compat)', \&on_unload, \&on_reload);
$hooks = Plugins::addHooks(
  ['initialized',            \&on_init,       undef],
  ['AI_pre',                 \&on_ai_pre,     undef],
  ['AI_post',                \&on_ai_post,    undef],
  ['packet_mapChange',       \&on_map_change, undef],
  ['smart/config/reloaded',  \&on_cfg_reload, undef],
);

sub on_reload { on_unload(); }
sub on_unload {
  _restore_items_gather();
  Plugins::delHooks($hooks) if $hooks;
  %HZ=(); %GRID=();
  message "[$PLUGIN] unloaded.\n";
}

sub on_init {
  _load_config();
  $SPELLS_SIG = '';
  _rebuild_hazard_if_changed();
  message "[$PLUGIN] initialized (compat mode).\n";
}

sub on_cfg_reload {
  _load_config();
  $SPELLS_SIG = '';
  _rebuild_hazard_if_changed();
  message "[$PLUGIN] smart config reloaded.\n";
}

sub on_map_change {
  $defer_loot_until = 0;
  $suppress_attack_until = 0;
  _restore_items_gather();
  %HZ=(); %GRID=();
  $SPELLS_SIG = '';
}

sub on_ai_pre {
  return unless $cfg{'smart.avoid.enable'};

  my $now = _now_ms();
  my $cd  = $cfg{'smart.avoid.cooldown.recheck_ms'} || 120;
  return if ($now - $last_tick_ms < $cd);
  $last_tick_ms = $now;

  _rebuild_hazard_if_changed();

  my $me = $char->position or return;
  my ($mx,$my) = ($me->{x}, $me->{y});

  my ($hit,$h) = _is_in_hazard_q($mx,$my);
  if ($hit) {
    _logd("standing on hazard[$h->{name_norm}] -> step back");
    _step_back_from_center($h->{x},$h->{y});
    SmartCore::enter_mutex('avoid', 300) if $HAS_SMARTCORE;
  }

  if ($cfg{'smart.avoid.loot.block'} && AI::is('items_take')) {
    my $item = AI::args->{item};
    if ($item && $item->can('position')) {
      my $pos = $item->position;
      my ($phit,$ph) = _is_in_hazard_q($pos->{x},$pos->{y});
      if ($phit) {
        my $wait = $ph->{exp_ms} && $ph->{exp_ms} > 0 ? $ph->{exp_ms} : $cfg{'smart.avoid.loot.defer_ms'};
        $defer_loot_until = _now_ms() + $wait;
        _logd("cancel loot (hazard $ph->{name_norm}), defer ${wait}ms");
        Commands::run('ai clear items_take'); # ถ้าเวอร์ชันไม่รองรับ ใช้ 'ai clear'
        _suppress_items_gather();
        _step_back_from_center($ph->{x},$ph->{y});
      }
    }
  }

  if ($defer_loot_until && $now < $defer_loot_until) {
    _suppress_items_gather();
  } elsif ($items_gather_suppressed && (!$defer_loot_until || $now >= $defer_loot_until)) {
    _restore_items_gather();
    $defer_loot_until = 0;
  }

  if ($suppress_attack_until && $now < $suppress_attack_until) {
    if (AI::is('attack')) { Commands::run('ai clear attack'); }
    return;
  }

  if (AI::is('attack')) {
    my $args = AI::args();
    my $target = $args->{monster} || ($args->{ID} && $monstersList->getByID($args->{ID}));
    if ($target && $target->can('position')) {
      my $tp = $target->position; my $cp = $char->position;
      my ($cross,$wh) = _segment_cross_hazard_q($cp->{x},$cp->{y}, $tp->{x},$tp->{y});
      if ($cross) {
        _logd("path crosses [$wh->{name_norm}] -> reposition");
        _reposition_around($tp);
        $suppress_attack_until = _now_ms() + ($cfg{'smart.avoid.attack.suppress_ms'} || 500);
        SmartCore::enter_mutex('avoid', 300) if $HAS_SMARTCORE;
      }
    }
  }
}

sub on_ai_post {
  my $now = _now_ms();
  if ($items_gather_suppressed && (!$defer_loot_until || $now >= $defer_loot_until)) {
    _restore_items_gather();
  }
}

1;
