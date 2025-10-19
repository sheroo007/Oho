#==========================================================
# SmartRouteAI.pl v10.0 "The Sentinel"
# 
# ✅ 2-Layer Cache (World Map + Route Cache)
# ✅ Non-Blocking State Machine
# ✅ Surgical AI Clear
# ✅ SmartCore Integration
# ✅ Zero Lag, Zero Freeze
#
# Requires: SmartCore.pm
# Config: control/smart.txt
#==========================================================
package SmartRouteAI;
use strict;
use warnings;
use Plugins;
use Globals qw($char $field %config %portals @portalsID $monstersList);
use Log qw(message debug warning error);
use AI;
use Utils qw(blockDistance);
use Time::HiRes qw(time);
use Settings;
use File::Spec;
use Task::Route;
use SmartCore qw(smart_tele smart_is_idle_for gate_init);

my $VERSION = '10.0';
my $hooks;

# ---------------------------
# 2-Layer Cache System
# ---------------------------
my %WORLD_MAP = (
  conn   => {},  # map => [connected_maps]
  portal => {},  # "map->dest" => {x, y}
  loaded => 0,
);

my %ROUTE_CACHE = ();  # "from->to" => { route => [...], timestamp => ... }
my $ROUTE_CACHE_TTL = 1800;  # 30 minutes

my $LAST_MAP = '';

# ---------------------------
# Internal State
# ---------------------------
my %OV = (
  auto_override_active => 0,
  keys => [qw(
    attackAuto
    attackAuto_party
    route_randomWalk
    route_randomWalk_inTown
    route_randomWalk_maxRouteTime
    sitAuto_idle
    sitAuto_hp_lower
    sitAuto_sp_lower
    follow
    followTarget
  )],
  snap => {},
);

my %PORT = (
  map          => undef,
  candidates   => [],
  locked_idx   => undef,
  locked_xy    => undef,
  locked_dst   => undef,
  tried        => {},
  plans        => [],
  excluded_maps => {},
  failed_count => 0,
);

my %ROUTE = (
  target_xy               => undef,
  target_map              => undef,
  signature               => undef,
  last_distance           => undef,
  last_improve_at         => 0,
);

my %SYS = (
  work_id                 => 0,
  last_tick               => 0,
  tele_cd_until           => 0,
  clear_path_until        => 0,
  is_working              => 0,
  teleport_mode           => 0,
  sp_wait_start           => 0,
  emergency_count         => 0,
  return_state            => 'idle',     # idle, waiting, failed
  return_wait_start       => 0,
);

# ---------------------------
# Config Accessors
# ---------------------------
sub _cfg { my ($k,$d)=@_; return exists $config{$k} ? $config{$k} : $d }
sub _toi { my ($v)=@_; $v//=0; $v=~s/\D+//g; return 0+$v }
sub _tof { my ($v)=@_; $v//=0; $v=~s/[^0-9.\-]//g; return 0.0+$v }

sub enabled()      { _toi(_cfg('smartRoute_enabled', 1)) }
sub outsideOnly()  { _toi(_cfg('smartRoute_outsideOnly', 1)) }
sub tickSec()      { _tof(_cfg('smartRoute_checkInterval', 0.3)) }
sub dRadius()      { _toi(_cfg('smartRoute_dangerRadius', 7)) }
sub dCount()       { _toi(_cfg('smartRoute_dangerCount', 3)) }
sub pathWidth()    { _toi(_cfg('smartRoute_pathWidth', 2)) }

sub teleMinDist()  { _toi(_cfg('smartRoute_teleMinDistance', 100)) }
sub teleCD()       { _tof(_cfg('smartRoute_teleCooldown', 0.5)) }
sub teleMinSP()    { _toi(_cfg('smartRoute_teleMinSP', 12)) }
sub teleWaitSP()   { _toi(_cfg('smartRoute_teleWaitSP', 1)) }
sub teleWaitSPTimeout() { _tof(_cfg('smartRoute_teleWaitSPTimeout', 5)) }
sub emergencyNoWaitSP() { _toi(_cfg('smartRoute_emergencyNoWaitSP', 1)) }

sub stuckTO()      { _tof(_cfg('smartRoute_stuckTimeout', 8)) }
sub maxPlans()     { _toi(_cfg('smartRoute_maxPlans', 3)) }
sub emergencyHp()  { _tof(_cfg('smartRoute_emergencyHpPercent', 50)) }
sub emergencyThreshold() { _toi(_cfg('smartRoute_emergencyThreshold', 3)) }

sub walkIfNoWings() { _toi(_cfg('smartRoute_walkIfNoWings', 1)) }
sub quitIfNoWings() { _toi(_cfg('smartRoute_quitIfNoWings', 0)) }
sub attackWhileWalking() { _toi(_cfg('smartRoute_attackWhileWalking', 1)) }
sub clearPathTO()  { _tof(_cfg('smartRoute_clearPathTimeout', 3.0)) }
sub idleTime()     { _tof(_cfg('smartRoute_idleTime', 0.3)) }
sub returnWaitTimeout() { _tof(_cfg('smartRoute_returnWaitTimeout', 3)) }

# ---------------------------
# Register Hooks
# ---------------------------
Plugins::register('SmartRouteAI', "SmartRouteAI $VERSION", \&onUnload);
$hooks = Plugins::addHooks(
  ['start3',           \&onStart,       undef],
  ['reloadFiles',      \&onReload,      undef],
  ['packet_mapChange', \&onMapChange,   undef],
  ['AI_pre',           \&onAI,          undef],
);

sub onUnload {
  eval { 
    _restore_autos_if_needed('unload'); 
    1 
  };
  Plugins::delHooks($hooks) if $hooks;
  message "[SmartRouteAI] unloaded\n";
}
sub isTraveling { 
    return $SYS{is_working} ? 1 : 0; 
}
sub onStart  { 
  _banner('start'); 
  gate_init();
  _load_world_map();
}

sub onReload { 
  _banner('reload'); 
  gate_init();
  _load_world_map();
}

sub _banner {
  my ($why) = @_;
  message sprintf("[SmartRouteAI] v%s \"The Sentinel\" loaded (%s)\n", $VERSION, $why||'-');
  message "[SmartRouteAI] 2-Layer Cache | Non-Blocking | Surgical AI\n";
}

# ---------------------------
# Layer 1: World Map Cache (Load Once!)
# ---------------------------
sub _load_world_map {
  return if $WORLD_MAP{loaded};
  
  my $pt = _locate_portals_file();
  unless ($pt && -e $pt) {
    warning "[SmartRouteAI] portals.txt not found\n";
    return;
  }
  
  open my $fh, '<', $pt or return;
  
  my $count = 0;
  while (my $line = <$fh>) {
    $line =~ s/\r?\n$//;
    $line =~ s/^\s+|\s+$//g;
    next if $line eq '' || $line =~ /^#/;
    
    my @t = split /\s+/, $line;
    for my $i (0..$#t) { $t[$i] =~ s/\.(gat|rsw)$//i; }
    next unless @t >= 6;
    
    my ($smap, $sx, $sy, $dmap) = @t[0,1,2,3];
    
    # Store connections
    push @{$WORLD_MAP{conn}{$smap}}, $dmap;
    
    # Store portal coordinates
    my $key = "$smap->$dmap";
    $WORLD_MAP{portal}{$key} = { x => $sx, y => $sy };
    
    $count++;
  }
  close $fh;
  
  $WORLD_MAP{loaded} = 1;
  message "[SmartRouteAI] World Map loaded ($count portals)\n";
}

sub _locate_portals_file {
  my @candidates;
  
  if (defined $Settings::tablesFolder && $Settings::tablesFolder ne '') {
    push @candidates, File::Spec->catfile($Settings::tablesFolder, 'portals.txt');
  }
  
  if (@Settings::tablesFolders) {
    for my $dir (@Settings::tablesFolders) {
      next unless defined $dir && $dir ne '';
      push @candidates, File::Spec->catfile($dir, 'portals.txt');
    }
  }
  
  push @candidates, File::Spec->catfile(File::Spec->curdir(), 'tables', 'portals.txt');
  
  for my $p (@candidates) {
    return $p if defined $p && -e $p;
  }
  
  return undef;
}

# ---------------------------
# Layer 2: Route Cache (Remember Calculated Routes)
# ---------------------------
sub _get_cached_routes {
  my ($from, $to) = @_;
  
  my $key = "$from->$to";
  my $cached = $ROUTE_CACHE{$key};
  
  if ($cached) {
    my $age = time - $cached->{timestamp};
    if ($age < $ROUTE_CACHE_TTL) {
      debug "[SmartRouteAI] Using cached route: $key (age: ${age}s)\n";
      return @{$cached->{plans}};
    } else {
      delete $ROUTE_CACHE{$key};
    }
  }
  
  return ();
}

sub _cache_routes {
  my ($from, $to, @plans) = @_;
  
  my $key = "$from->$to";
  $ROUTE_CACHE{$key} = {
    plans => \@plans,
    timestamp => time,
  };
  
  debug "[SmartRouteAI] Cached route: $key (" . scalar(@plans) . " plans)\n";
}

# ---------------------------
# Map Guards
# ---------------------------
sub _current_map {
  return eval { $field->baseName } || eval { $field->{name} } || '';
}

sub _is_save {
  my $m = lc _current_map();
  my $save = lc($config{saveMap}||'');
  return ($save && $m eq $save) ? 1 : 0;
}

sub _is_lock {
  my $m = lc _current_map();
  my $lock = lc($config{lockMap}||'');
  return ($lock && $m eq $lock) ? 1 : 0;
}

# ---------------------------
# SP Management
# ---------------------------
sub _check_sp {
  my $current_sp = $char->{sp} || 0;
  my $min_sp = teleMinSP();
  return $current_sp >= $min_sp;
}

sub _get_sp_percent {
  my $sp = $char->{sp} || 0;
  my $sp_max = $char->{sp_max} || 1;
  return ($sp / $sp_max) * 100;
}

# ---------------------------
# Map Change (Optimized!)
# ---------------------------
sub onMapChange {
  my $map = _current_map();
  
  # Guard: not ready
  return unless $char && $field;
  return if $map eq '';
  
  # Guard: same map (tele in same map)
  if ($LAST_MAP eq $map && $SYS{is_working}) {
    debug "[SmartRouteAI] Same map ($map) - skip recalculate\n";
    return;
  }
  
  $LAST_MAP = $map;
  
  # Reset route state
  %ROUTE = (
    target_xy => undef,
    target_map => undef,
    signature => undef,
    last_distance => undef,
    last_improve_at => 0,
  );
  
  $PORT{map} = $map;
  $PORT{candidates} = [];
  $PORT{locked_idx} = undef;
  $PORT{locked_xy}  = undef;
  $PORT{locked_dst} = undef;
  $PORT{tried}      = {};
  $SYS{work_id}++;
  
  # Reset modes
  $SYS{teleport_mode} = 1;
  $SYS{sp_wait_start} = 0;
  $SYS{emergency_count} = 0;
  $SYS{return_state} = 'idle';

  if (_is_lock()) {
    message "[SmartRouteAI] Arrived lockMap ($map)\n";
    _restore_autos_if_needed('lockMap');
    $SYS{is_working} = 0;
    $SYS{teleport_mode} = 0;
    $PORT{excluded_maps} = {};
    $PORT{failed_count} = 0;
    $LAST_MAP = '';
    $config{smartRoute_enabled} = 0;
    return;
  }

  if (outsideOnly() && _is_save()) {
    if ($SYS{is_working}) {
      debug "[SmartRouteAI] In saveMap ($map) transit\n";
    }
    $SYS{teleport_mode} = 0;
    return;
  }

  if (enabled()) {
    message "[SmartRouteAI] ===== Map Change: $map =====\n";
    message "[SmartRouteAI] Teleport-Only Mode: ON\n";
    _recalculate_and_execute();
  }
}

# ---------------------------
# Recalculate Routes (With Cache!)
# ---------------------------
sub _recalculate_and_execute {
  return if _is_lock();
  return if outsideOnly() && _is_save();

  my $current_map = _current_map();
  my $lockMap = $config{lockMap} || '';
  
  unless ($lockMap) {
    warning "[SmartRouteAI] No lockMap configured\n";
    return;
  }

  message "[SmartRouteAI] Calculating routes: $current_map → $lockMap\n";
  
  if (%{$PORT{excluded_maps}}) {
    my @excluded = keys %{$PORT{excluded_maps}};
    message "[SmartRouteAI] Excluded maps: " . join(', ', @excluded) . "\n";
  }
  
  # Try cache first!
  my @plans = _get_cached_routes($current_map, $lockMap);
  
  # Cache miss - calculate new routes
  if (!@plans) {
    @plans = _get_multiple_routes($current_map, $lockMap, maxPlans());
    
    if (!@plans) {
      warning "[SmartRouteAI] No routes found!\n";
      $PORT{failed_count}++;
      
      if ($PORT{failed_count} >= 3) {
        error "[SmartRouteAI] Failed 3 times - Give up!\n";
        _restore_autos_if_needed('giveup');
        $config{smartRoute_enabled} = 0;
      }
      return;
    }
    
    # Cache the result
    _cache_routes($current_map, $lockMap, @plans);
  }
  
  $PORT{failed_count} = 0;
  
  for my $plan (@plans) {
    my @maps = map { $_->{map} } @{$plan->{route}};
    message sprintf("[SmartRouteAI] Plan %s (%d hops): %s\n",
                    $plan->{plan}, $plan->{hops}, join(' → ', @maps));
  }
  
  my @portals = _scan_portals($current_map);
  
  if (!@portals) {
    warning "[SmartRouteAI] No portals found in $current_map\n";
    return;
  }
  
  my %grouped = _group_portals_by_plan(\@portals, \@plans);
  
  my @cand;
  
  for my $plan_name (qw(A B C D E)) {
    next unless $grouped{$plan_name};
    
    for my $p (@{$grouped{$plan_name}}) {
      push @cand, {
        %$p,
        plan => $plan_name,
        priority => ord($plan_name) - ord('A'),
      };
    }
  }
  
  if ($grouped{other}) {
    for my $p (@{$grouped{other}}) {
      push @cand, {
        %$p,
        plan => 'other',
        priority => 99,
      };
    }
  }
  
  @cand = sort { 
    $a->{priority} <=> $b->{priority} || 
    $a->{dist} <=> $b->{dist} 
  } @cand;
  
  for my $i (0..$#cand) {
    $cand[$i]{idx} = $i + 1;
  }
  
  $PORT{candidates} = \@cand;
  $PORT{plans} = \@plans;
  
  message "[SmartRouteAI] Found " . scalar(@cand) . " portals:\n";
  for my $c (@cand[0..($#cand < 4 ? $#cand : 4)]) {
    message sprintf("   #%d: (%d,%d)->%s [Plan %s] d=%d\n",
                    $c->{idx}, $c->{x}, $c->{y}, 
                    $c->{dst_map}, $c->{plan}, $c->{dist});
  }
  
  if (!@cand) {
    warning "[SmartRouteAI] No valid portals\n";
    return;
  }
  
  _choose_best_portal();
  
  _snapshot_autos();
  _apply_override_autos();
  
  $SYS{is_working} = 1;
}

# ---------------------------
# Get Multiple Routes (Use World Map)
# ---------------------------
sub _get_multiple_routes {
  my ($from, $to, $max_routes) = @_;
  $max_routes ||= 3;
  
  my @routes;
  my %temp_excluded = %{$PORT{excluded_maps}};
  
  for my $i (1..$max_routes) {
    my $route = _bfs_route($from, $to, \%temp_excluded);
    
    last unless $route && @$route > 1;
    
    push @routes, {
      plan => chr(64 + $i),
      route => $route,
      hops => scalar(@$route) - 1,
    };
    
    if (@$route > 1) {
      my $next_map = $route->[1]{map};
      $temp_excluded{$next_map} = 1;
    }
  }
  
  return @routes;
}

# ---------------------------
# BFS Route (Use World Map Cache)
# ---------------------------
sub _bfs_route {
  my ($from, $to, $excluded) = @_;
  $excluded ||= {};
  
  return [] if lc($from) eq lc($to);
  return [] if $excluded->{$from} || $excluded->{$to};
  
  my %visited;
  my @queue = ({ map => $from, path => [$from] });
  
  while (@queue) {
    my $current = shift @queue;
    my $map = $current->{map};
    
    next if $visited{$map}++;
    
    my @neighbors = @{$WORLD_MAP{conn}{$map} || []};
    
    for my $neighbor (@neighbors) {
      next if $excluded->{$neighbor};
      next if $visited{$neighbor};
      
      my @new_path = (@{$current->{path}}, $neighbor);
      
      if (lc($neighbor) eq lc($to)) {
        return _build_route_from_path(\@new_path);
      }
      
      push @queue, { 
        map => $neighbor, 
        path => \@new_path 
      };
    }
  }
  
  return [];
}

# ---------------------------
# Build Route from Path (Use World Map)
# ---------------------------
sub _build_route_from_path {
  my ($path) = @_;
  my @route;
  
  for my $i (0..$#$path - 1) {
    my $from = $path->[$i];
    my $to = $path->[$i + 1];
    
    my $key = "$from->$to";
    my $portal = $WORLD_MAP{portal}{$key};
    
    if ($portal) {
      push @route, {
        map => $from,
        x => $portal->{x},
        y => $portal->{y},
        dest => { map => $to },
      };
    }
  }
  
  push @route, { map => $path->[-1] };
  
  return \@route;
}

# ---------------------------
# Scan Portals (Hybrid: Visible + World Map)
# ---------------------------
sub _scan_portals {
  my ($map) = @_;
  my @portals;
  my %seen;
  my $me = $char->{pos_to};
  
  # Visible portals
  for my $id (@portalsID) {
    my $p = $portals{$id};
    next unless $p && $p->{pos} && defined $p->{pos}{x} && defined $p->{pos}{y};
    my ($px,$py) = ($p->{pos}{x}, $p->{pos}{y});
    my $key = "$px,$py";
    next if $seen{$key}++;
    
    my $d = eval { blockDistance($me, $p->{pos}) } // 9999;
    
    my $dst_map = 'unknown';
    if ($p->{dest} && ref($p->{dest}) eq 'HASH' && $p->{dest}{map}) {
      $dst_map = $p->{dest}{map};
    }
    
    push @portals, { 
      x => $px, 
      y => $py, 
      dist => $d, 
      dst_map => $dst_map,
      status => 'visible',
    };
  }
  
  # World Map portals
  for my $conn_key (keys %{$WORLD_MAP{portal}}) {
    if ($conn_key =~ /^(\w+)->(\w+)$/) {
      my ($smap, $dmap) = ($1, $2);
      next unless lc($smap) eq lc($map);
      
      my $portal = $WORLD_MAP{portal}{$conn_key};
      my $key = "$portal->{x},$portal->{y}";
      next if $seen{$key}++;
      
      my $d = eval { blockDistance($me, {x=>$portal->{x}, y=>$portal->{y}}) } // 9999;
      
      push @portals, { 
        x => $portal->{x}, 
        y => $portal->{y}, 
        dist => $d,
        dst_map => $dmap,
        status => 'cached',
      };
    }
  }
  
  return @portals;
}

# ---------------------------
# Group Portals by Plan
# ---------------------------
sub _group_portals_by_plan {
  my ($portals, $plans) = @_;
  my %grouped;
  
  PORTAL: for my $p (@$portals) {
    my $dst = $p->{dst_map};
    
    for my $plan (@$plans) {
      my $next_step = $plan->{route}[1];
      next unless $next_step;
      
      if (lc($next_step->{map}) eq lc($dst)) {
        push @{$grouped{$plan->{plan}}}, $p;
        next PORTAL;
      }
    }
    
    push @{$grouped{other}}, $p;
  }
  
  return %grouped;
}

# ---------------------------
# Choose Portal
# ---------------------------
sub _choose_best_portal {
  return unless $PORT{candidates} && @{$PORT{candidates}};
  
  my $best = $PORT{candidates}[0];
  my $best_i = 0;
  
  $PORT{locked_idx} = $best_i;
  $PORT{locked_xy}  = [$best->{x}, $best->{y}];
  $PORT{locked_dst} = $best->{dst_map};
  $PORT{tried}{$best_i} = 1;
  
  $ROUTE{target_xy}  = [$best->{x}, $best->{y}];
  $ROUTE{target_map} = _current_map();
  $ROUTE{signature}  = _make_signature($best->{x}, $best->{y});
  $ROUTE{last_distance}   = eval { blockDistance($char->{pos_to}, {x=>$best->{x}, y=>$best->{y}}) };
  $ROUTE{last_improve_at} = time;
  
  message sprintf("[SmartRouteAI] Lock #%d (%d,%d->%s) [Plan %s]\n", 
                  $best->{idx}, $best->{x}, $best->{y}, 
                  $best->{dst_map}, $best->{plan});
}

sub _switch_portal {
  return unless $PORT{candidates} && @{$PORT{candidates}};
  
  for my $i (0..$#{$PORT{candidates}}) {
    next if $PORT{tried}{$i};
    
    my $c = $PORT{candidates}[$i];
    $PORT{locked_idx} = $i;
    $PORT{locked_xy}  = [$c->{x}, $c->{y}];
    $PORT{locked_dst} = $c->{dst_map};
    $PORT{tried}{$i}  = 1;
    
    $ROUTE{target_xy}  = [$c->{x}, $c->{y}];
    $ROUTE{target_map} = _current_map();
    $ROUTE{signature}  = _make_signature($c->{x}, $c->{y});
    $ROUTE{last_distance}   = eval { blockDistance($char->{pos_to}, {x=>$c->{x}, y=>$c->{y}}) };
    $ROUTE{last_improve_at} = time;
    
    message sprintf("[SmartRouteAI] Switch #%d (%d,%d->%s) [Plan %s]\n", 
                    $c->{idx}, $c->{x}, $c->{y}, $c->{dst_map}, $c->{plan});
    
    $SYS{teleport_mode} = 1;
    $SYS{sp_wait_start} = 0;
    
    return 1;
  }
  
  my $current_map = _current_map();
  warning "[SmartRouteAI] All portals tried in $current_map\n";
  
  $PORT{excluded_maps}{$current_map} = 1;
  message "[SmartRouteAI] Excluded map: $current_map\n";
  
  message "[SmartRouteAI] Recalculating routes...\n";
  _recalculate_and_execute();
  
  return 1;
}

sub _make_signature { my ($x,$y)=@_; return sprintf('%d,%d@%s', $x,$y,_current_map()); }

# ---------------------------
# Runtime Autos
# ---------------------------
sub _snapshot_autos {
  for my $k (@{$OV{keys}}) {
    $OV{snap}{$k} = exists $config{$k} ? $config{$k} : '';
  }
}

sub _apply_override_autos {
  return if $OV{auto_override_active};
  
  for my $k (@{$OV{keys}}) { 
    my $val = $config{$k} || 0;
    $config{$k} = 0 if $val;
  }
  
  $OV{auto_override_active} = 1;
  message "[SmartRouteAI] Auto disabled\n";
}

sub _restore_autos_if_needed {
  my ($why) = @_;
  return unless $OV{auto_override_active};
  
  for my $k (@{$OV{keys}}) {
    my $v = $OV{snap}{$k};
    $v = '' unless defined $v;
    $config{$k} = $v;
  }
  
  $OV{auto_override_active} = 0;
  message "[SmartRouteAI] Auto restored ($why)\n";
}

# ---------------------------
# Walk to Portal (when close)
# ---------------------------
sub _walk_to_locked_if_close {
  return unless $ROUTE{target_xy};
  my ($x,$y) = @{$ROUTE{target_xy}};
  my $d = eval { blockDistance($char->{pos_to}, {x=>$x,y=>$y}) } // 9999;
  
  if ($d <= teleMinDist()) {
    $SYS{teleport_mode} = 0;
    
    my $task = Task::Route->new(x => $x, y => $y);
    AI::queue($task);
    
    message "[SmartRouteAI] Close enough (d=$d) → walk to portal ($x,$y)\n";
    return 1;
  }
  return 0;
}

# ---------------------------
# Monster Detection (continued)
# ---------------------------
sub _count_nearby_monsters {
  return 0 unless $char && $char->{pos_to} && $monstersList;
  my $me = $char->{pos_to};
  my $r  = dRadius();
  my $cnt = 0;
  my $arr = eval { $monstersList->getItems() };
  if ($arr) {
    for my $m (@$arr) {
      next unless $m && $m->{pos_to};
      my $d = eval { blockDistance($me, $m->{pos_to}) };
      $cnt++ if defined $d && $d <= $r;
    }
  }
  return $cnt;
}
sub _corridor_blockers_count {
  return 0 unless $char && $char->{pos_to} && $PORT{locked_xy} && $monstersList;
  my ($x2,$y2) = @{$PORT{locked_xy}};
  my $x1 = $char->{pos_to}{x};
  my $y1 = $char->{pos_to}{y};
  my $W  = pathWidth();
  my $cnt = 0;
  my $arr = eval { $monstersList->getItems() };
  return 0 unless $arr;

  my $dx = $x2 - $x1; 
  my $dy = $y2 - $y1;
  my $L2 = $dx*$dx + $dy*$dy; 
  $L2 = 1 if $L2 <= 0;

  for my $m (@$arr) {
    next unless $m && $m->{pos_to};
    my ($mx,$my) = ($m->{pos_to}{x}, $m->{pos_to}{y});
    my $t = (($mx-$x1)*$dx + ($my-$y1)*$dy) / $L2; 
    next if $t < 0 || $t > 1;
    my $dd = abs(($dy)*($mx-$x1) - ($dx)*($my-$y1)) / sqrt($L2);
    $cnt++ if $dd <= $W + 0.5;
  }
  return $cnt;
}

sub _is_emergency_situation {
  my $monster_count = _count_nearby_monsters();
  my $has_sp = _check_sp();
  
  if ($monster_count >= dCount()) {
    if (!$has_sp && emergencyNoWaitSP()) {
      return 1;
    }
  }
  
  return 0;
}

# ---------------------------
# Emergency Teleport
# ---------------------------
sub _emergency_teleport {
  return 0 unless $char && $char->{pos_to};
  return 0 unless $PORT{locked_xy};
  
  my $nearby = _count_nearby_monsters();
  my $hp_percent = eval { ($char->{hp} / $char->{hp_max}) * 100 } || 100;
  
  if ($nearby >= dCount() || $hp_percent < emergencyHp()) {
    my $now = time;
    return 0 if $now < $SYS{tele_cd_until};
    
    $SYS{emergency_count}++;
    
    message sprintf("[SmartRouteAI] EMERGENCY! (%d/%d) mon=%d HP=%.0f%%\n", 
                    $SYS{emergency_count}, emergencyThreshold(),
                    $nearby, $hp_percent);
    
    # Too many emergencies → tele 2
    if ($SYS{emergency_count} >= emergencyThreshold()) {
      warning "[SmartRouteAI] Too many emergencies → tele 2\n";
      
      my $current_map = _current_map();
      $PORT{excluded_maps}{$current_map} = 1;
      
      smart_tele(2);
      
      # Set state to waiting
      $SYS{return_state} = 'waiting';
      $SYS{return_wait_start} = time;
      $SYS{emergency_count} = 0;
      
      return 1;
    }
    
    # Normal emergency → tele 1
    smart_tele(1);
    
    $SYS{tele_cd_until} = $now + teleCD();
    
    AI::clear('route', 'move');
    
    return 1;
  }
  
  return 0;
}

# ---------------------------
# Clear Path
# ---------------------------
sub _clear_corridor_monsters {
  return if $SYS{clear_path_until} > 0;
  
  $config{attackAuto} = 1;
  $SYS{clear_path_until} = time + clearPathTO();
  
  message sprintf("[SmartRouteAI] Clear (%.1fs)\n", clearPathTO());
}

sub _check_clear_path_timeout {
  my $now = time;
  if ($SYS{clear_path_until} > 0 && $now >= $SYS{clear_path_until}) {
    $config{attackAuto} = 0;
    $SYS{clear_path_until} = 0;
    message "[SmartRouteAI] Clear done\n";
  }
}

# ---------------------------
# Teleport Phase
# ---------------------------
sub _maybe_teleport {
  return 0 unless $PORT{locked_xy};
  
  my $now = time;
  my $dist = eval { blockDistance($char->{pos_to}, 
                    {x=>$PORT{locked_xy}[0], y=>$PORT{locked_xy}[1]}) };
  
  if (!$SYS{teleport_mode}) {
    return 0;
  }
  
  if (!defined $dist) {
    return 0;
  }
  
  # Close enough → walk
  if ($dist <= teleMinDist()) {
    message "[SmartRouteAI] Close enough (d=$dist) - START WALKING\n";
    $SYS{teleport_mode} = 0;
    
    my ($x,$y) = @{$PORT{locked_xy}};
    my $task = Task::Route->new(x => $x, y => $y);
    AI::queue($task);
    
    return 1;
  }
  
  # Check Emergency
  if (_is_emergency_situation()) {
    warning "[SmartRouteAI] Emergency + Low SP → Try tele 2\n";
    return _handle_return_or_quit($dist, 'emergency');
  }
  
  # Check SP
  if (!_check_sp()) {
    if (!teleWaitSP()) {
      message "[SmartRouteAI] Low SP + No wait → Try tele 2\n";
      return _handle_return_or_quit($dist, 'low-sp');
    }
    
    # Wait for SP
    if ($SYS{sp_wait_start} == 0) {
      $SYS{sp_wait_start} = $now;
      my $sp_pct = _get_sp_percent();
      message sprintf("[SmartRouteAI] Low SP (%.0f%%) - waiting...\n", $sp_pct);
    }
    
    my $wait_time = $now - $SYS{sp_wait_start};
    
    if ($wait_time >= teleWaitSPTimeout()) {
      warning "[SmartRouteAI] SP wait timeout → Try tele 2\n";
      $SYS{sp_wait_start} = 0;
      return _handle_return_or_quit($dist, 'sp-timeout');
    }
    
    return 0;
  }
  
  # SP OK → tele 1
  $SYS{sp_wait_start} = 0;
  
  return 0 if $now < $SYS{tele_cd_until};
  
  # Use tele 1
  message sprintf('[SmartRouteAI] tele 1 (d=%d SP=%.0f%%)\n', 
                  $dist, _get_sp_percent());
  
  smart_tele(1);
  
  $SYS{tele_cd_until} = $now + teleCD();
  
  return 1;
}

# ---------------------------
# Return Phase (Non-Blocking State Machine!)
# ---------------------------
sub _handle_return_or_quit {
  my ($dist, $reason) = @_;
  
  message "[SmartRouteAI] Attempting tele 2 (reason: $reason)\n";
  
  smart_tele(2);
  
  AI::clear('route', 'move');  # ← เพิ่มบรรทัดนี้
  
  $SYS{return_state} = 'waiting';
  $SYS{return_wait_start} = time;
  $SYS{teleport_mode} = 0;
  
  return 1;
}

sub _check_return_state {
  return if $SYS{return_state} eq 'idle';
  
  my $now = time;
  
  if ($SYS{return_state} eq 'waiting') {
    # Check if returned to save map
    if (_is_save()) {
      message "[SmartRouteAI] tele 2 success - Returned to town\n";
      
      my $current_map = _current_map();
      $PORT{excluded_maps}{$current_map} = 1;
      debug "[SmartRouteAI] State: waiting → idle\n";  # ← เพิ่ม
      $SYS{return_state} = 'idle';
      return;
    }
    
    # Check timeout
    my $wait_time = $now - $SYS{return_wait_start};
    if ($wait_time >= returnWaitTimeout()) {
      warning "[SmartRouteAI] tele 2 timeout - no wings\n";
	  debug "[SmartRouteAI] State: waiting → failed\n";  # ← เพิ่ม
      $SYS{return_state} = 'failed';
    }
  }
  
  if ($SYS{return_state} eq 'failed') {
    # Handle failure
    if (quitIfNoWings()) {
      error "[SmartRouteAI] No teleport available - QUITTING\n";
      require Commands;
      Commands::run('quit');
	  debug "[SmartRouteAI] State: failed → idle (quit)\n";  # ← เพิ่ม
      $SYS{return_state} = 'idle';
      return;
    }
    
    if (walkIfNoWings()) {
      warning "[SmartRouteAI] No teleport - WALK\n";
      
      if (attackWhileWalking()) {
        $config{attackAuto} = 1;
        message "[SmartRouteAI] attackAuto: ON (for safety)\n";
      }
      
      if ($PORT{locked_xy}) {
        my ($x,$y) = @{$PORT{locked_xy}};
        my $task = Task::Route->new(x => $x, y => $y);
        AI::queue($task);
      }
      debug "[SmartRouteAI] State: failed → idle (walk)\n";  # ← เพิ่ม
      $SYS{return_state} = 'idle';
      return;
    }
    
    # Switch portal
    warning "[SmartRouteAI] Switch portal\n";
	debug "[SmartRouteAI] State: failed → idle (switch)\n";  # ← เพิ่ม
    _switch_portal();
    $SYS{return_state} = 'idle';
  }
}

# ---------------------------
# Stuck Detection & Blocker Detour
# ---------------------------
sub _check_progress_or_switch {
  return unless $PORT{locked_xy};
  my $now = time;
  my $d = eval { blockDistance($char->{pos_to}, 
                {x=>$PORT{locked_xy}[0], y=>$PORT{locked_xy}[1]}) };
  return unless defined $d;

  if (!defined $ROUTE{last_distance} || $d < $ROUTE{last_distance}) {
    $ROUTE{last_distance}   = $d;
    $ROUTE{last_improve_at} = $now;
    return;
  }

  # Check corridor blockers
  my $blockers = _corridor_blockers_count();
  if (defined $blockers && $blockers >= dCount()) {
    warning "[SmartRouteAI] Corridor blocked (blockers=$blockers)\n";
    
    if ($PORT{locked_dst}) {
      $PORT{excluded_maps}{$PORT{locked_dst}} = 1;
      message "[SmartRouteAI] Excluded next map: $PORT{locked_dst}\n";
    }
    
    message "[SmartRouteAI] Rerouting...\n";
    _recalculate_and_execute();
    return;
  }

  # Stuck timeout
  if (($now - $ROUTE{last_improve_at}) >= stuckTO()) {
    message sprintf('[SmartRouteAI] Stuck (no progress)\n');
    _switch_portal();
  }
}

# ---------------------------
# AI Loop
# ---------------------------
sub onAI {
    _load_world_map() unless $WORLD_MAP{loaded};
    if (!$config{smartRoute_enabled}) {
        _restore_autos_if_needed() if $OV{auto_override_active};
        return;
    }
    if (!$OV{auto_override_active}) {
    _apply_override_autos();
	}

  return unless enabled();
  
  my $now = time;
  return if ($now - $SYS{last_tick}) < tickSec();
  $SYS{last_tick} = $now;

  return if outsideOnly() && (_is_save() || _is_lock());

  if (!$OV{auto_override_active} && (!$PORT{locked_xy})) {
    return;
  }

  # SmartCore busy guard
  unless (smart_is_idle_for(idleTime())) {
    return;
  }

  # Check return state (non-blocking!)
  _check_return_state();

  # Emergency teleport
  if (_emergency_teleport()) {
    return;
  }

  # Teleport Mode
  if ($SYS{teleport_mode}) {
    # Try walk if close
    return if _walk_to_locked_if_close();
    
    # Try teleport
    _maybe_teleport();
    return;
  }

  # Walk Mode
  _check_clear_path_timeout();

  my $blockers = _corridor_blockers_count();
  if (defined $blockers && $blockers > 0) {
    if ($blockers >= dCount()) {
      # Already handled in _check_progress_or_switch
      return;
    }
    
    if ($blockers < dCount() && $SYS{clear_path_until} == 0) {
      message sprintf('[SmartRouteAI] Block=%d -> clear\n', $blockers);
      _clear_corridor_monsters();
      return;
    }
  }

  _check_progress_or_switch();
}

1;