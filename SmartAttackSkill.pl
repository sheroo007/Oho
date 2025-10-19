#==========================================================
# SmartAttackSkill.pl v3.8 – Complete Edition
# 
# New in v3.8:
# - Min SP guard (skill_tester_min_sp)
# - During route mode (skill_tester_during_route)
# - Level per skill (column 7 in table)
# - smartdiag skill command
# - Target guard (prevent casting without target)
# 
# Features:
# - Profile-aware path detection
# - SmartCore integration
# - Attack Override mode
# - Hybrid mode with table conditions
# - Precise cooldown from packet/self_skill_used
# - Works with SmartNearestTarget
# - Auto-reloads on config changes
# - Antiflood protection
#==========================================================
package SmartAttackSkill;

use strict;
use warnings;
use Plugins;
use Globals qw($char $field %config $monstersList);
use Log qw(message debug warning);
use AI;
use Commands;
use Time::HiRes qw(time);
use Settings;
use Utils qw(distance calcPosition);
use Actor;
use File::Basename qw(dirname);
use File::Spec ();

# ---------------- constants ----------------
use constant {
  FUDGE_MS         => 80,
  TICK_MS          => 50,
  DEFAULT_MS       => 650,
  FAIL_ADD_MS      => 60,
  FAIL_DEC_MS      => 30,
  INFLIGHT_TMO_MS  => 1200,
  MIN_GAP_MS       => 30,
  MIN_SP           => 1,

  MOB_NEAR_RADIUS  => 6,

  ANTIFLOOD_ON            => 1,
  MIN_CMD_GAP_MS          => 220,
  MAX_CMD_PER_10S         => 22,
  COOLDOWN_AFTER_LIMIT_MS => 1200,
  JITTER_MAX_MS           => 40,
};


# ---------------- helpers: path safe + profile-aware ----------------
sub _safe_dir {
  my ($p) = @_;
  return 'control' unless defined $p && length $p;
  my $d = eval { dirname($p) };
  return (defined $d && length $d) ? $d : 'control';
}

sub _under_control {
  my ($fname) = @_;
  my $cfg = eval { Settings::getControlFilename('config.txt') } // '';
  my $base = _safe_dir($cfg);
  return File::Spec->catfile($base, $fname);
}

# SmartCore support (optional)
sub _smart_core_path {
  my $p;
  eval { 
    require SmartCore; 
    SmartCore->import(qw(smart_path)); 
    $p = smart_path(); 
    1; 
  } or do { $p = undef };
  return $p;
}

# Profile-aware smart.txt detection
sub _default_smart_file {
  # 1) Try SmartCore first
  my $core = _smart_core_path();
  return $core if defined $core && length $core;
  
  # 2) Try profile detection
  my $profile = eval { $Globals::config{profile} } // $config{profile} // '';
  if ($profile && $profile ne '' && $profile ne 'default') {
    my $pdir = "profiles/$profile";
    if (-d $pdir) {
      my $smart = "$pdir/smart.txt";
      return $smart if -e $smart;
      return $smart;
    }
  }
  
  # 3) Fallback: standard OpenKore path
  my $p = eval { Settings::getControlFilename('smart.txt') } // '';
  return length($p) ? $p : _under_control('smart.txt');
}

sub _default_table_file {
  my $smart = _default_smart_file();
  my $dir   = _safe_dir($smart);
  return File::Spec->catfile($dir, 'smart_skill_table.txt');
}

# ---------------- plugin-scope config loaded from smart.txt ----------------
my %P;  # ✅ ต้องอยู่ที่นี่!

sub _smart_cfg_file { $P{smart_config_file} // _default_smart_file() }
sub CFG_TABLEFILE   { $P{skill_tester_table_file} // _default_table_file() }

# getters (smart.txt -> %config -> defaults)
sub _num { my ($v,$d)=@_; defined $v && $v ne '' ? 0+$v : $d }
sub _str { my ($v,$d)=@_; defined $v && $v ne '' ? $v    : $d }

sub CFG_ENABLED () { _num($P{skill_tester_enabled},  _num($config{skill_tester_enabled}, 1)) }
sub CFG_FACTOR  () { my $r=_str($P{skill_tester_factor}, _str($config{skill_tester_factor}, '1.2')); $r=~s/,/./g; my $f=0+$r; $f>0?$f:1.0 }
sub CFG_LV      () { _num($P{skill_tester_lv},       _num($config{skill_tester_lv}, 5)) }
sub CFG_ORDER   () { lc _str($P{skill_tester_order}, _str($config{skill_tester_order}, 'alpha')) }

# scope flags
sub CFG_USE_SAVE () { exists $P{skill_tester_use_in_savemap} ? _num($P{skill_tester_use_in_savemap}, 0) : undef }
sub CFG_USE_LOCK () { exists $P{skill_tester_use_in_lockmap} ? _num($P{skill_tester_use_in_lockmap}, 0) : undef }
sub CFG_SCOPE    () { lc _str($P{skill_tester_scope}, lc _str($config{skill_tester_scope}, 'any')) }

# attack override flag
sub CFG_ATTACK  () { _num($P{skill_tester_attack}, _num($config{skill_tester_attack}, 0)) }

# v3.8: new config
sub CFG_MIN_SP  () { _num($P{skill_tester_min_sp}, _num($config{skill_tester_min_sp}, 1)) }
sub CFG_DURING_ROUTE () { _num($P{skill_tester_during_route}, _num($config{skill_tester_during_route}, 0)) }

# ---------------- state ----------------
my $hooks;
my %S = (
  active_scope      => 0,

  inflight          => 0,
  inflight_deadline => 0.0,
  inflight_skill_id => undef,

  last_cmd_at       => 0.0,
  recent_cmd_ts     => [],

  handle2id         => {},
  name2handle       => {},
  handle2name       => {},
  id2handle         => {},

  SK_ORDER          => [],
  SK                => {},
  ROT_INDEX         => 0,

  snt_detected      => 0,
  override_hold_until => 0,
);

# ---------------- register & commands ----------------
Plugins::register('SmartAttackSkill', 'Table-driven multi-skill v3.8', \&onUnload);
$hooks = Plugins::addHooks(
  ['start3',                   \&onStartup,          undef],
  ['map_loaded',               \&onMapChange,        undef],
  ['packet_mapChange',         \&onMapChange,        undef],
  ['packet/self_skill_used',   \&onSelfSkillUsed,    undef],
  ['packet/skill_use_failed',  \&onSkillUseFailed,   undef],
  ['packet/skill_failed',      \&onSkillUseFailed,   undef],
  ['AI_pre',                   \&onAI,               undef],

  ['smart:file_changed',       \&onSmartFileEvent,   undef],
  ['smart:file_created',       \&onSmartFileEvent,   undef],
  ['smart:file_deleted',       \&onSmartFileEvent,   undef],
  ['smart/config/reloaded',    \&onSmartConfigReload,undef],
);

Commands::register(['smartreload', 'Reload smart.txt and smart_skill_table', sub {
  _load_plugin_config();
  _build_rotation();
  message "[SmartAttackSkill] reloaded smart.txt and table.\n", "system";
}]);

Commands::register(['smartdiag', 'Dump SmartAttackSkill state', sub {
  my (undef, $args) = @_;
  
  if ($args && $args =~ /skill/i) {
    _diag_skills();
    return;
  }
  
  my $smart = eval { _smart_cfg_file() } // '(undef)';
  my $table = eval { CFG_TABLEFILE() }   // '(undef)';
  my $dir   = _safe_dir($smart);
  my $where = $field ? ($field->name // '(unknown)') : '(no map)';
  my $atkAuto = int($config{attackAuto} // 0);
  my $atkMode = CFG_ATTACK() ? ($atkAuto==0 ? 'RESPECT-NO-ATTACK' : 'OVERRIDE') : 'HYBRID';

  message "----- SmartAttackSkill :: DIAG -----\n","system";
  message "Map: $where | scope=". ( _in_scope() ? 'ACTIVE' : 'INACTIVE') ."\n","system";
  message "smart.txt: $smart\n","system";
  message "table   : $table\n","system";
  message "control : $dir\n","system";
  message "order   : ".CFG_ORDER()." | default lv=".CFG_LV()." | factor=".sprintf('%.2f',CFG_FACTOR())."\n","system";
  message "attack  : $atkMode (attackAuto=$atkAuto)\n","system";
  message "min_sp  : ".CFG_MIN_SP()." | during_route: ".CFG_DURING_ROUTE()."\n","system";

  if (@{ $S{SK_ORDER} // [] }) {
    my @summ = map {
      my $e = $S{SK}->{$_};
      sprintf("%s(id=%d) lv=%d @%.2f %s%s%s",
        $e->{name}, $e->{id}, $e->{lv}, $e->{factor},
        (exists $e->{conds}->{mob_ge}   ? "[mob>=".$e->{conds}->{mob_ge}."]": ""),
        (exists $e->{conds}->{range_le} ? "[range<=".$e->{conds}->{range_le}."]": ""),
        (exists $e->{conds}->{sp_ge}    ? "[sp>=".$e->{conds}->{sp_ge}."]" : ""))
    } @{ $S{SK_ORDER} };
    message "rotation: ".join(" , ", @summ)."\n","system";
  } else {
    message "rotation: (empty)\n","system";
  }
  message "------------------------------------\n","system";
}]);

sub _diag_skills {
  my $now = time();
  message "===== SmartAttackSkill :: Skill Details =====\n","system";
  
  unless (@{ $S{SK_ORDER} // [] }) {
    message "  (no skills loaded)\n","info";
    message "=============================================\n","system";
    return;
  }
  
  for my $i (0..$#{$S{SK_ORDER}}) {
    my $id = $S{SK_ORDER}->[$i];
    my $sk = $S{SK}->{$id};
    
    my $ready = ($now >= ($sk->{next_ready}//0)) ? 'READY' : 'WAIT';
    my $wait_time = ($sk->{next_ready}//0) - $now;
    $wait_time = 0 if $wait_time < 0;
    
    my $conds = '';
    $conds .= sprintf("[mob>=%d]", $sk->{conds}{mob_ge}) if $sk->{conds}{mob_ge};
    $conds .= sprintf("[range<=%d]", $sk->{conds}{range_le}) if $sk->{conds}{range_le};
    $conds .= sprintf("[sp>=%d]", $sk->{conds}{sp_ge}) if $sk->{conds}{sp_ge};
    
    message sprintf("  #%d %s (id=%d) lv=%d \@%.2f %s [%s %.1fs]\n",
        $i+1, $sk->{name}, $id, $sk->{lv}, $sk->{factor},
        $conds, $ready, $wait_time), "info";
  }
  
  message "=============================================\n","system";
}

sub onUnload { Plugins::delHooks($hooks) if $hooks; message "[SmartAttackSkill] Unloaded.\n", "system" }

sub is_casting {
    return 1 if $S{inflight};
    return 1 if (time() < $S{override_hold_until});
    return 0;
}
# ---------------- startup / scope ----------------
sub onStartup {
  $P{smart_config_file} = $config{smart_config_file} if defined $config{smart_config_file};
  _load_plugin_config();
  onMapChange();
}

sub _detect_SNT {
  no strict 'refs';
  return scalar keys %{"SmartNearestTarget::"} ? 1 : 0;
}

sub _in_scope {
  my $cur  = $field ? ($field->name // '') : '';
  my $save = $config{saveMap} // '';
  my $lock = $config{lockMap} // '';

  my $use_save = CFG_USE_SAVE();
  my $use_lock = CFG_USE_LOCK();
  if (defined $use_save || defined $use_lock) {
    return 1 if $use_save && $save && lc($cur) eq lc($save);
    return 1 if $use_lock && $lock && lc($cur) eq lc($lock);
    return 0;
  }

  my $mode = CFG_SCOPE();
  return 1 if $mode eq 'any';
  return lc($cur) eq lc($save) if $mode eq 'save';
  return lc($cur) eq lc($lock) if $mode eq 'lock';
  return 0;
}

sub onMapChange {
  $S{active_scope} = _in_scope() ? 1 : 0;
  $S{snt_detected} = _detect_SNT();

  _build_rotation();

  $S{inflight}            = 0;
  $S{inflight_skill_id}   = undef;
  $S{inflight_deadline}   = 0.0;
  $S{last_cmd_at}         = 0.0;
  $S{recent_cmd_ts}       = [];
  $S{override_hold_until} = 0;

  my $where   = $field ? $field->name : '(unknown)';
  my $atkAuto = int($config{attackAuto} // 0);
  my $atkMode = CFG_ATTACK() ? ($atkAuto==0 ? 'RESPECT-NO-ATTACK' : 'OVERRIDE') : 'HYBRID';

  message sprintf("[SmartAttackSkill] Map: %s | scope=%s -> %s | smart=%s | table=%s | order=%s | lv=%d factor=%.2f | attack=%s (attackAuto=%d) | minSP=%d | SNT=%s\n",
    $where,
    (defined CFG_USE_SAVE() || defined CFG_USE_LOCK()) ? 'flags' : CFG_SCOPE(),
    $S{active_scope}?'ACTIVE':'INACTIVE', _smart_cfg_file(), CFG_TABLEFILE(), CFG_ORDER(), CFG_LV(), CFG_FACTOR(),
    $atkMode, $atkAuto, CFG_MIN_SP(), ($S{snt_detected}?'YES':'NO')),
    $S{active_scope} ? "success" : "info";
}

# ---------------- config & tables ----------------
sub _sanitize {
  my ($s) = @_;
  return '' unless defined $s;
  $s =~ s/^\s+|\s+$//g;
  $s =~ s/\\(["'])/$1/g;
  while ($s =~ /\A(["'])(.*)\1\z/s) { $s=$2; $s=~s/^\s+|\s+$//g; }
  $s =~ s/[\x{2018}\x{2019}\x{201C}\x{201D}\x{00AB}\x{00BB}\x{2039}\x{203A}]//g;
  $s =~ s/\s+/ /g;
  return $s;
}

sub _load_plugin_config {
  my $file = _smart_cfg_file();
  unless (-e $file) { warning "[SmartAttackSkill] plugin config not found: $file (using defaults)\n"; return; }
  open my $fh, "<:encoding(UTF-8)", $file or do { warning "[SmartAttackSkill] cannot open: $file\n"; return; };
  my $ln=0;
  while (my $line = <$fh>) {
    $ln++;
    $line =~ s/^\x{FEFF}//;
    next if $line =~ /^\s*#/ || $line =~ /^\s*$/ || $line =~ /^\s*\[.*?\]\s*$/;
    chomp $line;
    if ($line =~ /^\s*([A-Za-z0-9_.]+)\s+(.*?)\s*$/) {
      $P{$1} = $2;
    }
  }
  close $fh;
}

sub _load_skill_tables {
  return if (keys %{ $S{handle2id} } || keys %{ $S{name2handle} } || keys %{ $S{handle2name} } || keys %{ $S{id2handle} });

  my $f1 = Settings::getTableFilename("SKILL_id_handle.txt");
  if ($f1 && -e $f1 && open my $fh, "<:encoding(UTF-8)", $f1) {
    while (my $line = <$fh>) {
      next if $line =~ /^\s*#/ || $line !~ /\S/;
      chomp $line;
      my ($id, $handle) = split /\s+/, $line, 2;
      next unless defined $id && defined $handle;
      $handle =~ s/\s+$//;
      my $ID = int($id);
      my $H  = uc $handle;
      $S{handle2id}->{$H} = $ID;
      $S{id2handle}->{$ID} = $H;
    }
    close $fh;
  } else { warning "[SmartAttackSkill] SKILL_id_handle.txt not found.\n" }

  my $f2 = Settings::getTableFilename("skillnametable.txt");
  if ($f2 && -e $f2 && open my $fh2, "<:encoding(UTF-8)", $f2) {
    while (my $line = <$fh2>) {
      next if $line =~ /^\s*#/ || $line !~ /\S/;
      chomp $line;
      my ($handle, $name) = split /#/, $line, 3;
      next unless $handle && $name;
      $name =~ s/^\s+|\s+$//g;
      my $H = uc $handle;
      my $N = $name;
      $S{name2handle}->{ lc $N } = $H;
      $S{handle2name}->{$H} = $N;
    }
    close $fh2;
  } else { warning "[SmartAttackSkill] skillnametable.txt not found.\n" }
}

sub _resolve_one {
  my ($spec_raw) = @_;
  my $spec = _sanitize($spec_raw);
  return () unless length $spec;

  if ($spec =~ /^\d+$/) {
    my $id = int($spec);
    my $handle = $S{id2handle}->{$id} // '';
    my $name   = $S{handle2name}->{$handle} // $spec;
    return ($id,$handle,$name);
  }

  _load_skill_tables();

  if ($spec =~ /^\S+$/) {
    my $H = uc $spec;
    if (my $ID = $S{handle2id}->{$H}) {
      return ($ID,$H,($S{handle2name}->{$H}//$spec));
    }
  }
  my $H2 = $S{name2handle}->{ lc $spec };
  if ($H2) {
    if (my $ID2 = $S{handle2id}->{$H2}) {
      return ($ID2,$H2,($S{handle2name}->{$H2}//$spec));
    }
  }
  return ();
}

sub _split_csv {
  my ($line) = @_;
  my @out;
  while ($line =~ /\G\s*(?:"([^"\\]*(?:\\.[^"\\]*)*)"|([^,]+)|())\s*(?:,|$)/xg) {
    my $v = defined $1 ? $1 : defined $2 ? $2 : '';
    $v =~ s/\\"/"/g;
    push @out, $v;
  }
  return @out;
}

sub _parse_cond_num {
  my ($txt) = @_;
  return undef unless defined $txt;
  my $t = _sanitize($txt);
  return undef unless length $t;
  return 0 if $t eq '0';
  $t =~ s/^[<>=\s]+//;
  return ($t =~ /^\d+$/) ? int($t) : undef;
}

sub _load_table_rows {
  my $file = CFG_TABLEFILE();
  unless (-e $file) { warning "[SmartAttackSkill] table file not found: $file\n"; return (); }
  open my $fh, "<:encoding(UTF-8)", $file or do { warning "[SmartAttackSkill] cannot open table: $file\n"; return (); };

  my @rows; my $line_no=0;
  while (my $line = <$fh>) {
    $line_no++;
    $line =~ s/^\x{FEFF}//;
    next if $line =~ /^\s*#/ || $line =~ /^\s*$/;
    chomp $line;

    my @c = _split_csv($line);
    @c = map { _sanitize($_) } @c;
    if (@c < 2) { warning "[SmartAttackSkill] bad row $line_no: $line\n"; next; }

    my $skill  = $c[0];
    my $enable = $c[1] ne '' ? int($c[1]) : 1;
    my $factor = (defined $c[2] && $c[2] ne '') ? 0+$c[2] : CFG_FACTOR();

    my $mob_ge   = _parse_cond_num($c[3] // '');
    my $range_le = _parse_cond_num($c[4] // '');
    my $sp_ge    = _parse_cond_num($c[5] // '');
    my $lv       = _parse_cond_num($c[6] // '');

    push @rows, {
      skill=>$skill, enable=>$enable, factor=>$factor,
      mob_ge=>$mob_ge, range_le=>$range_le, sp_ge=>$sp_ge,
      lv=>$lv,
      order_idx=>$line_no,
    };
  }
  close $fh;
  return @rows;
}

sub _build_rotation {
  $S{SK_ORDER} = [];
  $S{SK}       = {};
  $S{ROT_INDEX}= 0;

  my @rows = _load_table_rows();
  if (!@rows) { warning "[SmartAttackSkill] table empty/missing.\n"; return; }

  my @entries;
  for my $r (@rows) {
    next unless $r->{enable};
    my ($id,$handle,$name) = _resolve_one($r->{skill});
    if (!$id) { warning sprintf("[SmartAttackSkill] cannot resolve: '%s' -> skip\n", $r->{skill}); next; }
    next if exists $S{SK}->{$id};

    my %conds;
    $conds{mob_ge}   = $r->{mob_ge}   if defined $r->{mob_ge}   && $r->{mob_ge}   > 0;
    $conds{range_le} = $r->{range_le} if defined $r->{range_le} && $r->{range_le} > 0;
    $conds{sp_ge}    = $r->{sp_ge}    if defined $r->{sp_ge}    && $r->{sp_ge}    > 0;

    my $skill_lv = (defined $r->{lv} && $r->{lv} > 0) ? $r->{lv} : CFG_LV();

    my $e = {
      id=>$id, name=>($name//$r->{skill}), handle=>($handle//''),
      lv=>$skill_lv,
      factor=>($r->{factor}//CFG_FACTOR()), 
      conds=>\%conds,
      next_ready=>0.0, last_ms=>0, ema_ms=>undef, last_ack=>0.0,
      fail_streak=>0, fail_bias_ms=>0,
      order_idx=>$r->{order_idx},
    };
    $S{SK}->{$id} = $e;
    push @entries, $e;
  }

  if (CFG_ORDER() eq 'alpha') {
    @entries = sort { lc($a->{name}) cmp lc($b->{name}) } @entries;
  } else {
    @entries = sort { $a->{order_idx} <=> $b->{order_idx} } @entries;
  }

  my @order = map { $_->{id} } @entries;
  $S{SK_ORDER} = \@order;

  my @summ = map { sprintf("%s(@%.2f)lv%d%s%s%s->%d",
    $_->{name}, $_->{factor}, $_->{lv},
    (exists $_->{conds}->{mob_ge}   ? "[mob>=".$_->{conds}->{mob_ge}."]"   : ""),
    (exists $_->{conds}->{range_le} ? "[range<=".$_->{conds}->{range_le}."]": ""),
    (exists $_->{conds}->{sp_ge}    ? "[sp>=".$_->{conds}->{sp_ge}."]"     : ""),
    $_->{id}) } @entries;
  message "[SmartAttackSkill] Rotation: ".(@summ?join(", ",@summ):"(empty)")."\n", @summ?"success":"warning";
}

# ---------------- conditions ----------------
sub _count_near_mobs {
  my $count = 0; return 0 unless $monstersList && $char;
  my $me = calcPosition($char);
  for my $m (@{ $monstersList->getItems() }) {
    next if $m->{dead};
    my $mp = calcPosition($m);
    my $d  = distance($me, $mp);
    $count++ if defined $d && $d <= MOB_NEAR_RADIUS;
  }
  return $count;
}

sub _nearest_mob_range {
  my $best; return undef unless $monstersList && $char;
  my $me = calcPosition($char);
  for my $m (@{ $monstersList->getItems() }) {
    next if $m->{dead};
    my $mp = calcPosition($m);
    my $d  = distance($me, $mp);
    next unless defined $d;
    $best = $d if !defined($best) || $d < $best;
  }
  return $best;
}

sub _current_target_or_nearest_range {
  return undef unless $char;
  if ($S{snt_detected} && $char->{target}) {
    my $t = Actor::get($char->{target});
    if ($t && !$t->{dead}) {
      my $d = distance(calcPosition($char), calcPosition($t));
      return $d if defined $d;
    }
  }
  return _nearest_mob_range();
}

sub _conds_ok {
  my ($sk) = @_;
  my $c = $sk->{conds} || {};
  return 1 unless %$c;
  if (exists $c->{sp_ge})    { return 0 if ($char->{sp}//0) < $c->{sp_ge} }
  if (exists $c->{mob_ge})   { my $n=_count_near_mobs(); return 0 if $n < $c->{mob_ge} }
  if (exists $c->{range_le}) {
    my $r=_current_target_or_nearest_range();
    return 0 if !defined($r) || $r > $c->{range_le};
  }
  return 1;
}

sub _has_valid_target {
  return 0 unless $char && $char->{target};
  
  my $target = Actor::get($char->{target});
  return 0 unless $target;
  return 0 if $target->{dead};
  
  return 1;
}

# ---------------- packets ----------------
sub onSelfSkillUsed {
  my (undef, $args) = @_;
  return unless CFG_ENABLED() && $S{active_scope} && $args;

  my $skill_id = $args->{skillID};
  my $delay_ms = $args->{delay};
  my $sk = $S{SK}->{$skill_id} or return;

  if (defined $delay_ms) {
    $sk->{last_ms} = $delay_ms;
    my $a = 0.5;
    $sk->{ema_ms} = defined $sk->{ema_ms} ? int($a*$delay_ms + (1-$a)*$sk->{ema_ms}) : $delay_ms;
  }

  my $now = time();
  $sk->{last_ack} = $now;

  if ($sk->{fail_bias_ms} > 0) {
    $sk->{fail_bias_ms} = ($sk->{fail_bias_ms} > FAIL_DEC_MS()) ? $sk->{fail_bias_ms} - FAIL_DEC_MS() : 0;
  }
  $sk->{fail_streak} = 0;

  my $pred_ms = _predicted_ms_for($sk);
  $sk->{next_ready} = $now + ($pred_ms / 1000.0);

  $S{inflight}          = 0;
  $S{inflight_skill_id} = undef;
}

sub onSkillUseFailed {
  return unless CFG_ENABLED() && $S{active_scope};

  my $sid = $S{inflight_skill_id};
  my $sk  = defined $sid ? $S{SK}->{$sid} : undef;
  my $now = time();

  if (!$sk) {
    $S{inflight} = 0; $S{inflight_skill_id} = undef;
    for my $id (@{ $S{SK_ORDER} }) { $S{SK}->{$id}->{next_ready} = $now + 0.30 }
    debug "[SmartAttackSkill] FAIL (unknown) -> global 300ms\n";
    return;
  }

  my $pred_ms = _predicted_ms_for($sk);
  my $since_ack_ms = $sk->{last_ack} ? int( ($now - $sk->{last_ack}) * 1000 ) : 999999;
  my $mid_delay_guess = ($since_ack_ms < $pred_ms + 1);

  if ($mid_delay_guess) {
    $sk->{fail_streak}++;
    my $add = FAIL_ADD_MS() + (20 * ($sk->{fail_streak}-1));
    $add = 200 if $add > 200;
    $sk->{fail_bias_ms} += $add;
    $sk->{fail_bias_ms} = 500 if $sk->{fail_bias_ms} > 500;

    my $retry_ms = _predicted_ms_for($sk);
    $sk->{next_ready} = $now + ($retry_ms / 1000.0);
    debug sprintf("[SmartAttackSkill] FAIL Mid-Delay %s -> bias+=%d (bias=%d) retry %dms\n",
      $sk->{name}, $add, $sk->{fail_bias_ms}, $retry_ms);
  } else {
    $sk->{next_ready} = $now + 0.30;
    debug sprintf("[SmartAttackSkill] FAIL %s -> wait 300ms\n", $sk->{name});
  }

  $S{inflight}          = 0;
  $S{inflight_skill_id} = undef;
}

# ---------------- antiflood ----------------
sub _prune_cmd_log {
  my $now = time();
  my $cut = $now - 10.0;
  my @keep = grep { $_ >= $cut } @{ $S{recent_cmd_ts} };
  $S{recent_cmd_ts} = \@keep;
  return scalar @keep;
}

sub _antiflood_ok_or_delay {
  return 1 unless ANTIFLOOD_ON();
  my $now = time();

  if ($S{last_cmd_at} > 0) {
    my $gap_ms = int( ($now - $S{last_cmd_at}) * 1000 );
    if ($gap_ms < MIN_CMD_GAP_MS()) {
      my $need = (MIN_CMD_GAP_MS() - $gap_ms) / 1000.0;
      for my $id (@{ $S{SK_ORDER} }) {
        my $nr = $S{SK}->{$id}->{next_ready};
        $S{SK}->{$id}->{next_ready} = ($now + $need) if $nr < $now + $need;
      }
      return 0;
    }
  }

  my $cnt = _prune_cmd_log();
  if ($cnt >= MAX_CMD_PER_10S()) {
    for my $id (@{ $S{SK_ORDER} }) {
      my $cool = $now + (COOLDOWN_AFTER_LIMIT_MS() / 1000.0);
      $S{SK}->{$id}->{next_ready} = $cool if $S{SK}->{$id}->{next_ready} < $cool;
    }
    debug sprintf("[SmartAttackSkill] AntiFlood: hit %d/10s -> cooldown %dms\n", $cnt, COOLDOWN_AFTER_LIMIT_MS());
    return 0;
  }
  return 1;
}

# ---------------- timing ----------------
sub _predicted_ms_for {
  my ($sk) = @_;
  my $base = defined $sk->{ema_ms} ? int($sk->{ema_ms})
           : $sk->{last_ms}        ? int($sk->{last_ms})
           : DEFAULT_MS;

  my $ms = int($base * ($sk->{factor}//CFG_FACTOR()) + 0.5) + FUDGE_MS + $sk->{fail_bias_ms};
  my $tick = TICK_MS;
  $ms = int(($ms + $tick - 1) / $tick) * $tick;
  my $jit = (JITTER_MAX_MS() > 0) ? int(rand(JITTER_MAX_MS()+1)) : 0;
  return $ms + $jit;
}

# ---------------- override melee ----------------
sub _maybe_take_over_melee {
  if (eval { SmartRouteAI::isTraveling() }) {
      return 0;
  }
  
  return 0 unless CFG_ATTACK();
  my $atkAuto = int($config{attackAuto} // 0);
  return 0 unless $atkAuto > 0;
  return 0 unless $S{active_scope};
  return 0 if $S{inflight};
  return 0 unless @{$S{SK_ORDER} // []};

  if ($S{override_hold_until} && time() < $S{override_hold_until}) {
    if (AI::action eq 'attack') { AI::dequeue(); }
    return 1;
  }

  if (AI::action eq 'attack') {
    AI::dequeue();
    $S{override_hold_until} = time() + 1.0;
    debug "[SmartAttackSkill] override: drop Core 'attack' state, taking over.\n";
    return 1;
  }
  return 0;
}

# ---------------- AI loop ----------------
sub onAI {
  if (eval { SmartRouteAI::isTraveling() }) {
      return unless CFG_DURING_ROUTE();
  }
  
  return unless CFG_ENABLED() && $S{active_scope} && $char;
  return if $char->{dead} || $char->{sit};
  
  my $min_sp = CFG_MIN_SP();
  return if ($char->{sp}//0) < $min_sp;
  
  return unless @{ $S{SK_ORDER} };

  _maybe_take_over_melee();

  my $now     = time();
  my $atkAuto = int($config{attackAuto} // 0);

  return if (CFG_ATTACK() && $atkAuto == 0);

  if ($S{inflight} && $now > $S{inflight_deadline}) {
    debug "[SmartAttackSkill] inflight timeout -> reset\n";
    $S{inflight} = 0; $S{inflight_skill_id} = undef;
  }
  return if $S{inflight};

  my $force_attack = (CFG_ATTACK() && $atkAuto > 0) ? 1 : 0;

  my $start = $S{ROT_INDEX};
  my $chosen;
  for (my $i=0; $i<@{ $S{SK_ORDER} }; $i++) {
    my $idx = ($start + $i) % @{ $S{SK_ORDER} };
    my $id  = $S{SK_ORDER}->[$idx];
    my $sk  = $S{SK}->{$id};
    next unless $now >= ($sk->{next_ready}//0);
    next unless ($force_attack || _conds_ok($sk));
    $chosen = $id;
    $S{ROT_INDEX} = ($idx + 1) % @{ $S{SK_ORDER} };
    last;
  }
  return unless $chosen;

  return unless _antiflood_ok_or_delay();

  _useSkill($chosen);
}

# ---------------- action ----------------
sub _useSkill {
  my ($id) = @_;
  my $sk = $S{SK}->{$id} or return;

  return unless _has_valid_target();

  $S{inflight}          = 1;
  $S{inflight_skill_id} = $id;
  $S{inflight_deadline} = time() + (INFLIGHT_TMO_MS() / 1000.0);

  my $pred_ms = _predicted_ms_for($sk);
  $sk->{next_ready} = time() + ($pred_ms / 1000.0);

  my $now = time();
  $S{last_cmd_at} = $now;
  push @{ $S{recent_cmd_ts} }, $now;

  message sprintf("[SmartAttackSkill] ss %d %d  # %s\n", $id, $sk->{lv}, $sk->{name}), "skill";
  Commands::run("ss $id $sk->{lv}");
}

# ---------------- file events ----------------
sub onSmartFileEvent {
  my (undef, $args) = @_;
  my $p = lc($args->{path} // '');
  return unless ($p eq lc(_smart_cfg_file()) || $p eq lc(CFG_TABLEFILE()));
  _load_plugin_config();
  _build_rotation();
  message "[SmartAttackSkill] auto-reloaded due to file event: $args->{name}\n", "system";
}

sub onSmartConfigReload {
  my (undef, $args) = @_;
  my $p = lc($args->{file} // '');
  my $mine = lc(_smart_cfg_file());
  return if ($p && $p ne $mine);
  _load_plugin_config();
  _build_rotation();
  message "[SmartAttackSkill] smart.txt reloaded via bootstrap ($args->{reason})\n", "system";
}

# ---------------- banner ----------------
message "==========================================================\n","system";
message "[SmartAttackSkill] v3.8 Loaded - Complete Edition\n","system";
message "New: Min SP guard | During route | Level per skill\n","system";
message "     Target guard | smartdiag skill command\n","system";
message "==========================================================\n","system";

1;
