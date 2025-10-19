#==========================================================
# SmartTeleportHunter.pl v2.2 - Hybrid Hunt (Patched)
# 
# Patches:
# - เพิ่ม: use AI qw(ai_useTeleport)
# - Fallback ปลอดภัยถ้าไม่มี SmartCore
#==========================================================
package SmartTeleportHunter;
use strict;
use warnings;
use Plugins;
use Globals qw(%config $field $char $monstersList);
use Log qw(message warning debug);
use Time::HiRes qw(time);
use AI qw(ai_useTeleport);  # ← เพิ่ม
use Utils qw(blockDistance);

# --------- SmartCore Integration (safe fallback) ---------
BEGIN {
    eval { 
        require SmartCore; 
        SmartCore->import(qw(smart_tele gate_init smart_is_idle_for mutex_peek)); 
        1 
    } or do {
        # Fallback ถ้าไม่มี SmartCore
        *smart_tele = sub { 
            my ($mode) = @_;
            $mode ||= 1;
            eval { 
                ai_useTeleport($mode); 
                1 
            } or do {
                warning "[TeleHunter] Teleport failed: $@\n";
                return 0;
            };
            return 1;
        };
        *gate_init = sub { 1 };
        *smart_is_idle_for = sub { 0 };
        *mutex_peek = sub { 0 };
    };
}

our $VERSION = '2.2-patched';

# ======================== CONFIG ========================
sub _cfg { my ($k,$d)=@_; exists $config{$k} ? $config{$k} : $d }
sub _toi { my ($v)=@_; $v//=0; $v=~s/\D+//g; $v+0 }
sub _tof { my ($v)=@_; $v//=0; $v=~s/[^0-9\.\-]+//g; 0.0+$v }

sub _enabled()           { _toi(_cfg('smartTeleHunter_enabled', 1)) }
sub _scanRadius()        { _toi(_cfg('smartTeleHunter_scanRadius', 12)) }
sub _minMonsters()       { _toi(_cfg('smartTeleHunter_minMonsters', 1)) }
sub _cooldown()          { _tof(_cfg('smartTeleHunter_cooldown', 0.9)) }
sub _checkInterval()     { _tof(_cfg('smartTeleHunter_checkInterval', 1.0)) }
sub _allowDuringRoute()  { _toi(_cfg('smartTeleHunter_allowDuringRoute', 1)) }
sub _routeMinSeconds()   { _tof(_cfg('smartTeleHunter_routeMinSeconds', 2.0)) }

# ======================== STATE ========================
my $hooks;
my %S = (
    last_tele_ts      => 0,
    last_check_ts     => 0,
    route_start_time  => 0,
);

# ======================== PLUGIN INIT ========================
Plugins::register('SmartTeleportHunter', "Teleport Hunting v$VERSION", \&onUnload);

$hooks = Plugins::addHooks(
    ['start3',         \&onStart,       undef],
    ['reloadFiles',    \&onStart,       undef],
    ['AI_pre',         \&onAI,          undef],
    ['AI::route_start',\&onRouteStart,  undef],
);

sub onUnload { 
    Plugins::delHooks($hooks) if $hooks;
}

sub onStart  { 
    gate_init();
    %S = (%S, last_tele_ts=>0, last_check_ts=>0, route_start_time=>0);
    message "[TeleHunter] v$VERSION loaded (Hybrid + Patched)\n","system";
}

# ======================== HELPERS ========================
sub _in_lockmap {
    my $lock = $config{lockMap} || '';
    my $m = $field ? ($field->can('baseName') ? $field->baseName : $field->name) : '';
    return ($lock && $m && lc($m) eq lc($lock)) ? 1 : 0;
}

sub _can_teleport {
    # Guard 1: SmartRouteAI
    if (eval { SmartRouteAI::isTraveling() }) {
        return 0;
    }
    
    # Guard 2: SmartAttackSkill
    if (eval { SmartAttackSkill::is_casting() }) {
        debug "[TeleHunter] Blocked: casting\n";
        return 0;
    }
    
    # Guard 3: SmartLootPriority
    if (eval { SmartLootPriority::is_looting() }) {
        debug "[TeleHunter] Blocked: looting\n";
        return 0;
    }
    
    my $action = AI::action() || '';
    
    #  ห้ามเทเล: โจมตี, สกิล
    return 0 if $action =~ /^(attack|skill_use)$/;
    
    #  ห้ามเทเล: เก็บของ
    return 0 if $action =~ /^(take|items_take)$/;
    
    #  ห้ามเทเล: NPC
    return 0 if $action =~ /^(npc|storage|shop|deal)$/;
    
    #  กรณีพิเศษ: กำลังเดิน
    if ($action =~ /^(route|move)$/) {
        return 0 unless _allowDuringRoute();
        
        my $now = time;
        my $route_duration = $now - $S{route_start_time};
        my $min_duration = _routeMinSeconds();
        
        if ($route_duration < $min_duration) {
            return 0;
        }
        
        debug "[TeleHunter] Route duration: ${route_duration}s >= ${min_duration}s - can teleport\n";
        return 1;
    }
    
    # เช็ค mutex จากปลั๊กอินอื่น
    return 0 if mutex_peek('smart/attack');
    
    return 1;
}

sub _count_nearby_monsters {
    my $list = $monstersList;
    return 0 unless $list && $list->size > 0;
    return 0 unless $char && $char->{pos_to};
    
    my ($cx, $cy) = ($char->{pos_to}{x}, $char->{pos_to}{y});
    my $radius = _scanRadius();
    my $r2 = $radius * $radius;
    
    my $count = 0;
    for (my $i=0; $i<$list->size; $i++) {
        my $m = $list->get($i) or next;
        next unless defined $m->{pos_to}{x} && defined $m->{pos_to}{y};
        next if $m->{dead} || $m->{ignore} || $m->{avoid};
        
        my $dx = $cx - $m->{pos_to}{x};
        my $dy = $cy - $m->{pos_to}{y};
        my $d2 = $dx*$dx + $dy*$dy;
        
        $count++ if $d2 <= $r2;
    }
    
    return $count;
}

# ======================== HOOKS ========================
sub onRouteStart {
    $S{route_start_time} = time;
    debug "[TeleHunter] Route started\n";
}

# ======================== MAIN AI ========================
sub onAI {
    return unless _enabled();
    return unless $char && $field;
    return unless _in_lockmap();
    
    my $now = time;
    
    # Throttle
    my $interval = _checkInterval();
    return if ($now - $S{last_check_ts}) < $interval;
    $S{last_check_ts} = $now;
    
    # เช็คว่าเทเลได้ไหม
    return unless _can_teleport();
    
    # Cooldown
    return if ($now - $S{last_tele_ts}) < _cooldown();
    
    # นับมอน
    my $monster_count = _count_nearby_monsters();
    my $min_monsters = _minMonsters();
    
    # มอนน้อย → เทเล
    if ($monster_count < $min_monsters) {
        my $action = AI::action() || 'idle';
        debug sprintf("[TeleHunter] Low monsters (%d<%d) during '%s' - teleporting\n",
            $monster_count, $min_monsters, $action);
        
        if (smart_tele(1)) {
            $S{last_tele_ts} = $now;
            $S{route_start_time} = 0;
            message "[TeleHunter] Teleported (hybrid hunt)\n", "info";
        }
    }
}

message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", "system";
message "[TeleHunter] v$VERSION - Hybrid Hunt (Patched)\n", "system";
message "Never interrupt: Combat, Looting\n", "system";
message "Can teleport: While walking (if > 2s)\n", "system";
message "Safe fallback: Works without SmartCore\n", "system";
message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", "system";

1;