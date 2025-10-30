##
# SimpleTeleHunter v4.4.3 - Fast Start Edition
# Smart teleport hunter with instant action on spawn
#
# Author: sheroo007
# Created: 2025-10-28
# Last Modified: 2025-10-29 21:17:36 UTC
# Version: 4.4.3 (Fast Start + Edge Detection Fixed)
#
# CHANGES in v4.4.3:
#   - Fixed slow start after spawn/death
#   - Instant danger detection on map load
#   - Better edge detection (works immediately)
#   - No more waiting when spawning in danger
#   - Fast recovery after death
#
# Core Features:
#   - Teleport to find monsters instead of walking
#   - Attack closest monsters first
#   - Pure static farming (no walking)
#   - INSTANT ACTION after spawn/death
##
package SimpleTeleHunter;

use strict;
use warnings;
use Time::HiRes qw(time);
use File::Spec;

use Plugins;
use Settings;
use FileParsers qw(parseDataFile);
use Globals qw($char $field %config $monstersList $net $accountID);
use Log qw(message warning error debug);
use AI;
use Misc;
use Network;
use Network::Send;
use Utils qw(timeOut distance blockDistance);
use Actor;
use Commands;

Plugins::register(
    'SimpleTeleHunter',
    'Smart teleport hunter v4.4.3 Fast Start',
    \&on_unload
);

my $VERSION = '4.4.3';
my $hooks;
my $smart_handle;
my %smart_config;
my $profile_loaded = 0;
my $current_profile = '';

###############################################################################
# Plugin State Management
###############################################################################

my %state = (
    mode => 'farm',
    teleport_pending => 0,
    in_danger => 0,
    
    # Timers
    last_teleport => 0,
    last_attack => 0,
    last_kill => 0,
    last_death => 0,
    idle_start => 0,
    countdown_start => 0,
    spot_start => 0,
    last_tick => 0,
    walk_start => 0,
    last_take => 0,
    last_target_check => 0,
    map_load_time => 0,
    
    # Tracking
    countdown_active => 0,
    countdown_by_kill => 0,
    map_loaded => 0,
    config_reloaded => 0,
    forced_closest => 0,
    spawn_danger => 0,
    fast_mode => 0,
    
    # เพิ่มใหม่สำหรับ instant teleport
    just_teleported => 0,
    teleport_time => 0,
    
    # RandomWalk
    randomwalk_original => undef,
    randomwalk_timeout => 0,
);

my %stats = (
    total_teleports => 0,
    teleports_by_idle => 0,
    teleports_by_few_monsters => 0,
    teleports_by_spawn => 0,
    teleports_by_edge => 0,
    failed_teleports => 0,
    target_switches => 0,
    deaths => 0,
    session_start => time,
);

# Cache for performance
my %cache = (
    monster_count => 0,
    monster_count_time => 0,
    closest_monster => undef,
    closest_monster_time => 0,
);

###############################################################################
# Debug System
###############################################################################

sub DEBUG {
    my ($msg, $level) = @_;
    $level ||= 1;
    
    my $debug_level = get_config('simpleTeleHunter_debug', 0);
    return unless $debug_level >= $level;
    
    message "[DEBUG] $msg\n", "debug";
}

# Register Debug Command
Commands::register(
    ["sthdebug", "SimpleTeleHunter Debug", \&cmd_debug]
);

sub cmd_debug {
    my (undef, $args) = @_;
    
    if (!defined $args || $args eq '') {
        my $current = get_config('simpleTeleHunter_debug', 0);
        message "[SimpleTeleHunter] Debug level: $current (0=off, 1=basic, 2=verbose)\n";
        return;
    }
    
    my $level = int($args);
    $level = 0 if $level < 0;
    $level = 2 if $level > 2;
    
    $smart_config{simpleTeleHunter_debug} = $level;
    
    my $status = $level == 0 ? 'OFF' : 
                 $level == 1 ? 'BASIC' : 'VERBOSE';
    
    message "[SimpleTeleHunter] Debug mode: $status\n", "success";
}

###############################################################################
# Profile-aware Configuration Loading
###############################################################################

sub get_profile_name {
    # Try to detect current profile
    if ($profiles::profile) {
        return $profiles::profile;
    }
    
    # Check control folders for profile hint
    foreach my $dir (@Settings::controlFolders) {
        if ($dir =~ /profiles[\/\\]([^\/\\]+)/) {
            return $1;
        }
    }
    
    return '';
}

sub load_smart_config {
    my ($file) = @_;
    
    # Clear old config
    %smart_config = ();
    
    # Check file exists
    return 0 unless $file && -f $file;
    
    # Parse file (Settings API compatible)
    open my $fh, '<', $file or return 0;
    while (<$fh>) {
        chomp;
        s/^\s+|\s+$//g;  # Trim spaces
        next if /^#/ || /^$/;  # Skip comments and empty lines
        
        # Parse: key value
        if (/^(\S+)\s+(.+)$/) {
            $smart_config{$1} = $2;
        }
    }
    close $fh;
    
    # Show result
    my $count = scalar keys %smart_config;
    if ($count > 0) {
        message "[SimpleTeleHunter] Loaded $count settings from smart.txt\n", "success";
        
        # Show key values for verification
        my $idle = $smart_config{simpleTeleHunter_idleTime} || 'default';
        my $monsters = $smart_config{simpleTeleHunter_minNearbyMonsters} || 'default';
        message "[SimpleTeleHunter] Verified: idle=$idle, monsters=$monsters\n", "system";
    }
    
    return 1;
}

sub validate_config {
    my $idle = get_config('simpleTeleHunter_idleTime', 5);
    my $cooldown = get_config('simpleTeleHunter_cooldown', 1);
    
    # Force minimum idle time
    if ($idle < 1) {
        warning "[SimpleTeleHunter] idleTime too low ($idle), using 3s\n";
        $smart_config{simpleTeleHunter_idleTime} = 3;
    }
    
    # Check for conflicting values
    if ($idle < $cooldown) {
        warning "[SimpleTeleHunter] idleTime ($idle) should be > cooldown ($cooldown)\n";
    }
    
    # Validate radius for static farm
    my $radius = get_config('simpleTeleHunter_monsterRadius', 15);
    if ($radius < 1 || $radius > 30) {
        warning "[SimpleTeleHunter] monsterRadius ($radius) seems unusual, using 5\n";
        $smart_config{simpleTeleHunter_monsterRadius} = 5;
    }
}

sub get_config {
    my ($key, $default) = @_;
    
    # Check smart.txt first
    if (exists $smart_config{$key} && defined $smart_config{$key}) {
        return $smart_config{$key};
    }
    
    # Then check config.txt
    if (exists $config{$key} && defined $config{$key}) {
        return $config{$key};
    }
    
    return $default;
}

sub is_enabled {
    return get_config('simpleTeleHunter', 0);
}

sub load_and_show_config {
    # Get current values
    my $idle_time = get_config('simpleTeleHunter_idleTime', 5);
    my $min_monsters = get_config('simpleTeleHunter_minNearbyMonsters', 3);
    my $debug_level = get_config('simpleTeleHunter_debug', 0);
    my $farming_mode = $config{route_randomWalk} ? 'Walk Mode' : 'Static Mode';
    my $profile = get_profile_name();
    my $force_closest = get_config('simpleTeleHunter_forceClosest', 1);
    my $edge_dist = get_config('simpleTeleHunter_edgeDistance', 10);
    
    # Show configuration banner
    message "=" x 50 . "\n";
    message "[SimpleTeleHunter] Configuration Loaded\n", "success";
    
    # Show profile info
    if ($profile) {
        message "[SimpleTeleHunter] Profile: $profile\n", "plugins";
    } else {
        message "[SimpleTeleHunter] Profile: default (no profile detected)\n", "plugins";
    }
    
    # Show mode
    message "[SimpleTeleHunter] Mode: $farming_mode\n", "plugins";
    
    # Show core settings
    message "[SimpleTeleHunter] Config: idle=${idle_time}s, minMonsters=$min_monsters\n", "plugins";
    
    # Show edge settings
    message "[SimpleTeleHunter] Safety: edge=${edge_dist} blocks\n", "plugins";
    
    # Show attack priority
    if ($force_closest) {
        message "[SimpleTeleHunter] Target: Always attack closest monster first\n", "success";
    }
    
    # Show debug level with hint
    my $debug_status = $debug_level == 0 ? "OFF" : 
                       $debug_level == 1 ? "BASIC" : "VERBOSE";
    message "[SimpleTeleHunter] Debug: $debug_level ($debug_status) (use 'sthdebug' to change)\n", "plugins";
    
    # Show additional settings if debug enabled
    if ($debug_level >= 1) {
        my $radius = get_config('simpleTeleHunter_monsterRadius', 15);
        my $max_time = get_config('simpleTeleHunter_maxTimePerSpot', 300);
        my $walk_timeout = get_config('simpleTeleHunter_walkTimeout', 30);
        my $close_range = get_config('simpleTeleHunter_closeRange', 5);
        
        message "[SimpleTeleHunter] Advanced: radius=${radius}, closeRange=${close_range}, maxTime=${max_time}s\n", "plugins";
        
        # Show emergency settings
        if (get_config('simpleTeleHunter_emergencyMode', 0)) {
            my $emergency_hp = get_config('simpleTeleHunter_emergency_hp', 30);
            message "[SimpleTeleHunter] Emergency: ON (HP < ${emergency_hp}%)\n", "plugins";
        }
    }
    
    # Check lockMap
    my $lockmap = get_config('lockMap', '');
    if ($lockmap) {
        message "[SimpleTeleHunter] Target: $lockmap\n", "success";
    } else {
        warning "[SimpleTeleHunter] WARNING: No lockMap set! Plugin may not work.\n";
    }
    
    # Show configuration source
    if (%smart_config) {
        my $count = scalar keys %smart_config;
        message "[SimpleTeleHunter] Source: smart.txt ($count settings)\n", "plugins";
    } else {
        message "[SimpleTeleHunter] Source: config.txt (defaults)\n", "plugins";
    }
    
    message "=" x 50 . "\n";
}

###############################################################################
# Smart Target Selection (FIXED BUG)
###############################################################################

sub get_current_target {
    # Check if we're attacking - FIXED
    return undef unless defined AI::action && AI::action eq 'attack';
    
    my $args = AI::args;
    return undef unless $args && $args->{ID};
    
    # Get the monster object
    my $target = Actor::get($args->{ID});
    return undef unless $target && $target->isa('Actor::Monster');
    
    return $target;
}

sub get_closest_monster {
    my ($max_dist) = @_;
    $max_dist //= get_config('simpleTeleHunter_closeRange', 5);
    
    return undef unless $char && $monstersList;
    return undef unless defined $accountID;  # Check accountID exists
    
    # Use cache if recent (but not in fast mode)
    if (!$state{fast_mode} && time - $cache{closest_monster_time} < 0.2) {
        return $cache{closest_monster};
    }
    
    my $closest_monster = undef;
    my $min_distance = 999;
    
    for (my $i = 0; $i < $monstersList->size; $i++) {
        my $monster = $monstersList->get($i);
        next unless $monster && !$monster->{dead};
        
        # Skip if being attacked by others (anti-KS) - FIXED
        if ($monster->{dmgFromPlayer} && defined $accountID) {
            if (exists $monster->{dmgFromPlayer}{$accountID}) {
                my $our_dmg = $monster->{dmgFromPlayer}{$accountID} || 0;
                my $total_dmg = 0;
                foreach my $pid (keys %{$monster->{dmgFromPlayer}}) {
                    next unless defined $monster->{dmgFromPlayer}{$pid};
                    $total_dmg += $monster->{dmgFromPlayer}{$pid};
                }
                next if $our_dmg == 0 && $total_dmg > 0;
            }
        }
        
        my $dist = $char->distance($monster);
        next unless defined $dist && $dist <= $max_dist;
        
        # Prioritize aggressive monsters
        my $priority_bonus = 0;
        if ($monster->{dmgToYou} && $monster->{dmgToYou} > 0) {
            $priority_bonus = -2;
        }
        
        my $effective_dist = $dist + $priority_bonus;
        
        if ($effective_dist < $min_distance) {
            $min_distance = $effective_dist;
            $closest_monster = $monster;
        }
    }
    
    # Update cache
    $cache{closest_monster} = $closest_monster;
    $cache{closest_monster_time} = time;
    
    return $closest_monster;
}
sub force_attack_closest {
    my $close_range = get_config('simpleTeleHunter_closeRange', 5);
    my $target = get_closest_monster($close_range);
    
    if ($target && defined $target->{ID}) {
        # Check if we need to switch target
        my $current_target = get_current_target();
        
        if ($current_target && defined $current_target->{ID} && 
            $current_target->{ID} ne $target->{ID}) {
            
            my $current_dist = $char->distance($current_target);
            my $new_dist = $char->distance($target);
            
            # Only switch if new target is significantly closer
            if (defined $current_dist && defined $new_dist && 
                $new_dist < $current_dist - 2) {
                
                AI::clear('attack');
                $char->attack($target->{ID});
                
                $stats{target_switches}++;
                
                message sprintf("[SimpleTeleHunter] Switching to closer target: %s (%.1f -> %.1f blocks)\n",
                    $target->{name} || 'Unknown', 
                    $current_dist || 0, 
                    $new_dist || 0), "teleport";
                    
                DEBUG("Force attacking closest: " . ($target->{name} || 'Unknown') . 
                      " (dist: " . sprintf("%.1f", $new_dist || 0) . ")", 1);
                
                $state{forced_closest} = 1;
                return 1;
            }
        } elsif (!$current_target) {
            # No current target, attack the closest
            $char->attack($target->{ID});
            
            DEBUG("Attacking closest: " . ($target->{name} || 'Unknown') . 
                  " (dist: " . sprintf("%.1f", $char->distance($target) || 0) . ")", 1);
            
            $state{forced_closest} = 1;
            return 1;
        }
    }
    
    return 0;
}
# Fix for check_current_target_distance
sub check_current_target_distance {
    return unless defined AI::action && AI::action eq 'attack';  # FIXED
    
    my $target = get_current_target();
    return unless $target && defined $target->{ID};
    
    my $max_attack_dist = get_config('simpleTeleHunter_maxAttackDistance', 7);
    my $dist = $char->distance($target);
    
    if (defined $dist && $dist > $max_attack_dist) {
        message "[SimpleTeleHunter] Target too far ($dist blocks), looking for closer monster\n", "teleport";
        
        AI::clear('attack');
        force_attack_closest();
        
        return 1;
    }
    
    return 0;
}

# Fix on_attack_start
sub on_attack_start {
    my (undef, $args) = @_;
    
    # Check if we should switch to closer target - FIXED
    if (get_config('simpleTeleHunter_forceClosest', 1) && 
        timeOut($state{last_target_check}, 1)) {
        
        $state{last_target_check} = time;
        
        # Only check if AI is in attack mode
        if (defined AI::action && AI::action eq 'attack') {
            check_current_target_distance();
        }
    }
}

###############################################################################
# Optimized Monster Detection
###############################################################################

sub count_nearby_monsters {
    my ($radius) = @_;
    $radius //= get_config('simpleTeleHunter_monsterRadius', 15);
    
    return 0 unless $char && $monstersList;
    
    my $count = 0;
    for (my $i = 0; $i < $monstersList->size; $i++) {
        my $monster = $monstersList->get($i);
        next unless $monster && !$monster->{dead};
        
        my $dist = $char->distance($monster);
        $count++ if defined $dist && $dist <= $radius;
    }
    
    DEBUG("Monsters nearby: $count (radius: $radius)", 2);
    
    return $count;
}

# Cached version for performance (but not in fast mode)
sub count_nearby_monsters_cached {
    my ($radius) = @_;
    
    # No cache in fast mode
    if ($state{fast_mode}) {
        return count_nearby_monsters($radius);
    }
    
    # Cache for 0.5 seconds normally
    if (time - $cache{monster_count_time} > 0.5) {
        $cache{monster_count} = count_nearby_monsters($radius);
        $cache{monster_count_time} = time;
        
        # Clear closest monster cache too
        $cache{closest_monster_time} = 0;
    }
    
    return $cache{monster_count};
}

###############################################################################
# AI State Check
###############################################################################

sub is_ai_busy {
    return 0 unless $char;
    
    # Check casting
    return 1 if $char->{casting};
    
    # Check skill delay
    return 1 if $char->{skills_status} && $char->{skills_status}{'Axe Tornado Delay'};
    
    # Check attack
    my $current_target = get_current_target();
    return 1 if $current_target;
    
    # Use AI::inQueue for combat states
    return AI::inQueue('attack', 'skill', 'skill_use') ? 1 : 0;
}

sub is_truly_idle {
    return 0 if is_ai_busy();
    
    # Static Mode: always idle when not in combat
    if (!$config{route_randomWalk}) {
        return 1;
    }
    
    # Walk Mode: check if walking too long
    if (AI::inQueue('route', 'move')) {
        my $walk_timeout = get_config('simpleTeleHunter_walkTimeout', 30);
        
        if (!$state{walk_start}) {
            $state{walk_start} = time;
        }
        
        if (timeOut($state{walk_start}, $walk_timeout)) {
            return 1 if count_nearby_monsters_cached() == 0;
        }
        return 0;
    } else {
        $state{walk_start} = 0;
    }
    
    return 1;
}

###############################################################################
# Enhanced Danger Detection (FIXED)
###############################################################################

sub is_in_danger {
    return 0 unless $char && $field && $char->{pos_to};
    
    my $pos = $char->{pos_to};
    my ($x, $y) = ($pos->{x}, $pos->{y});
    
    # Get edge distance from config
    my $edge_dist = get_config('simpleTeleHunter_edgeDistance', 10);
    my ($width, $height) = ($field->{width}, $field->{height});
    
    # Check if at map edge
    if ($x <= $edge_dist || $x >= ($width - $edge_dist) ||
        $y <= $edge_dist || $y >= ($height - $edge_dist)) {
        
        DEBUG("Edge danger at ($x,$y) - edge_dist=$edge_dist, map=${width}x${height}", 1);
        return 'edge';
    }
    
    # Check if in corner (double danger)
    if (($x <= $edge_dist || $x >= ($width - $edge_dist)) &&
        ($y <= $edge_dist || $y >= ($height - $edge_dist))) {
        
        DEBUG("Corner danger at ($x,$y)", 1);
        return 'corner';
    }
    
    # Check walkable cells around
    my $min_walkable = get_config('simpleTeleHunter_minWalkable', 4);
    my $walkable = 0;
    
    for my $dx (-1..1) {
        for my $dy (-1..1) {
            next if $dx == 0 && $dy == 0;
            $walkable++ if $field->isWalkable($x + $dx, $y + $dy);
        }
    }
    
    if ($walkable < $min_walkable) {
        DEBUG("Not enough walkable cells: $walkable < $min_walkable", 1);
        return 'trapped';
    }
    
    return 0;
}

###############################################################################
# RandomWalk Management
###############################################################################

sub enable_randomwalk {
    my ($duration) = @_;
    
    if (!defined $state{randomwalk_original}) {
        $state{randomwalk_original} = $config{route_randomWalk} || 0;
    }
    
    $config{route_randomWalk} = 1;
    $state{randomwalk_timeout} = $duration ? time + $duration : 0;
    
    DEBUG("RandomWalk enabled for ${duration}s", 2) if $duration;
}

sub disable_randomwalk {
    return unless defined $state{randomwalk_original};
    
    $config{route_randomWalk} = $state{randomwalk_original};
    $state{randomwalk_original} = undef;
    $state{randomwalk_timeout} = 0;
    
    DEBUG("RandomWalk restored", 2);
}

###############################################################################
# Emergency Detection
###############################################################################

sub check_emergency {
    return 0 unless get_config('simpleTeleHunter_emergencyMode', 0);
    return 0 unless $char && $char->{hp_max};
    
    my $hp_pct = ($char->{hp} / $char->{hp_max}) * 100;
    my $emergency_hp = get_config('simpleTeleHunter_emergency_hp', 30);
    
    return 'hp_critical' if $hp_pct < $emergency_hp;
    return 0;
}

###############################################################################
# Teleport Functions (Enhanced)
###############################################################################

sub do_teleport {
    my ($reason) = @_;
    return unless $char;
    
    $reason ||= 'unknown';
    
    # Check if can teleport
    if (!Misc::canUseTeleport(1)) {
        error "[SimpleTeleHunter] Cannot teleport - no skill/item!\n";
        $stats{failed_teleports}++;
        return;
    }
    
    # Check SP (but skip in emergency/spawn danger/instant)
    unless ($reason =~ /spawn|emergency|edge|corner|instant/) {
        my $min_sp = get_config('simpleTeleHunter_minSp', 10);
        if ($char->{sp} < $min_sp) {
            warning "[SimpleTeleHunter] Not enough SP ($char->{sp} < $min_sp)\n";
            return;
        }
    }
    
    # Check cooldown (but skip in danger/instant)
    unless ($reason =~ /spawn|danger|edge|corner|emergency|instant/) {
        my $cooldown = get_config('simpleTeleHunter_cooldown', 1);
        if (!timeOut($state{last_teleport}, $cooldown)) {
            DEBUG("Teleport cooldown active", 2);
            return;
        }
    }
    
    # Check if already teleporting
    if ($state{teleport_pending}) {
        DEBUG("Already teleporting", 2);
        return;
    }
    
    # Show teleport message
    message "[SimpleTeleHunter] Teleporting: $reason\n", "teleport";
    DEBUG("Teleport reason: $reason, monsters: " . count_nearby_monsters_cached(), 1);
    
    # Reset timers
    $state{idle_start} = 0;
    $state{countdown_active} = 0;
    $state{countdown_by_kill} = 0;
    $state{countdown_start} = 0;
    $state{spot_start} = time;
    $state{forced_closest} = 0;
    $state{spawn_danger} = 0;
    $state{just_teleported} = 0;  # Reset before new teleport
    
    $state{teleport_pending} = 1;
    $state{last_teleport} = time;
    
    # Clear attack AI
    AI::clear('attack', 'skill', 'move');
    
    # Use teleport with error handling
    eval {
        main::ai_useTeleport(1);
    };
    
    if ($@) {
        error "[SimpleTeleHunter] Teleport failed: $@\n";
        $state{teleport_pending} = 0;
        $stats{failed_teleports}++;
        return;
    }
    
    # Stats
    $stats{total_teleports}++;
    $stats{"teleports_by_$reason"}++ if exists $stats{"teleports_by_$reason"};
}

###############################################################################
# Countdown System
###############################################################################

sub start_countdown {
    my ($reason) = @_;
    
    return if $state{countdown_active};
    
    # Get idleTime from config
    my $idle_time = get_config('simpleTeleHunter_idleTime', 5);
    
    # Force minimum 1 second
    $idle_time = 1 if $idle_time < 1;
    
    DEBUG("Starting countdown: $reason, time: ${idle_time}s", 1);
    
    # Debounce check
    my $debounce = get_config('simpleTeleHunter_debounce', 0.2);
    if (!timeOut($state{countdown_start}, $debounce)) {
        DEBUG("Countdown debounce active", 2);
        return;
    }
    
    $state{idle_start} = time;
    $state{countdown_active} = 1;
    $state{countdown_start} = time;
    $state{countdown_by_kill} = ($reason eq 'Kill') ? 1 : 0;
    
    # Show countdown message
    message "[SimpleTeleHunter] $reason → Countdown: ${idle_time}s\n", "teleport";
}

sub check_countdown {
    return 0 unless $state{countdown_active};
    
    my $idle_time = get_config('simpleTeleHunter_idleTime', 5);
    $idle_time = 1 if $idle_time < 1;
    
    # Reduce idle time in fast mode
    if ($state{fast_mode}) {
        $idle_time = 1;
    }
    
    if (timeOut($state{idle_start}, $idle_time)) {
        return 1;
    }
    
    # Debug countdown progress
    if (get_config('simpleTeleHunter_debug', 0) >= 2) {
        my $elapsed = time - $state{idle_start};
        DEBUG(sprintf("Countdown progress: %.1f/%ds", $elapsed, $idle_time), 2);
    }
    
    return 0;
}

sub reset_countdown {
    $state{idle_start} = 0;
    $state{countdown_active} = 0;
    $state{countdown_by_kill} = 0;
    $state{countdown_start} = 0;
    
    DEBUG("Countdown reset", 2);
}

###############################################################################
# Should Teleport Logic
###############################################################################

sub should_teleport {
    my $nearby = count_nearby_monsters_cached();
    my $min_monsters = get_config('simpleTeleHunter_minNearbyMonsters', 3);
    
    # Check if instant teleport is enabled
    my $instant_enabled = get_config('simpleTeleHunter_instantTeleport', 1);
    my $grace_period = get_config('simpleTeleHunter_instantGracePeriod', 1.5);
    
    # Priority 0: Just teleported and no monsters = instant teleport
    if ($instant_enabled && $state{just_teleported}) {
        if (time - $state{teleport_time} <= $grace_period) {
            if ($nearby == 0) {
                $state{just_teleported} = 0;
                message "[SimpleTeleHunter] No monsters after teleport → Instant teleport!\n", "teleport";
                return 'instant_no_monsters';
            }
        } else {
            $state{just_teleported} = 0;
        }
    }
  
   
    # Priority 1: Enough monsters
    if ($nearby >= $min_monsters) {
        reset_countdown() if $state{countdown_active};
        $state{spot_start} = time if !$state{spot_start};
        return 0;
    }
    
    # Priority 2: No monsters + Idle
    if ($nearby == 0) {
        # Start countdown if not started
        if (!$state{countdown_active}) {
            # Static Mode: immediate countdown
            if (!$config{route_randomWalk}) {
                start_countdown("No monsters");
            }
            # Walk Mode: check if truly idle
            elsif (is_truly_idle()) {
                start_countdown("No monsters");
            }
        }
        
        # Check countdown
        if (check_countdown()) {
            my $elapsed = time - $state{idle_start};
            message sprintf("[SimpleTeleHunter] No monsters + Idle %.1fs → Teleport\n", $elapsed), "teleport";
            return 'idle';
        }
    }
    # Priority 3: Few monsters
    elsif ($nearby > 0 && $nearby < $min_monsters) {
        # Give countdown a chance (stable period)
        if ($state{countdown_active}) {
            my $stable = get_config('simpleTeleHunter_stablePeriod', 0.5);
            
            if (!timeOut($state{countdown_start}, $stable)) {
                # Continue countdown
                if (check_countdown()) {
                    return 'idle';
                }
            } else {
                reset_countdown();
            }
        }
        
        # Check max time per spot
        if ($state{spot_start}) {
            my $max_time = get_config('simpleTeleHunter_maxTimePerSpot', 300);
            
            if ($max_time > 0 && timeOut($state{spot_start}, $max_time)) {
                my $elapsed = int(time - $state{spot_start});
                message "[SimpleTeleHunter] Few monsters + Timeout (${elapsed}s) → Teleport\n", "teleport";
                return 'few_monsters';
            }
        }
    }
    
    return 0;
}

###############################################################################
# Event Handlers (Enhanced for Fast Start)
###############################################################################

sub on_monster_died {
    my (undef, $args) = @_;
    
    $state{last_attack} = time;
    $state{last_kill} = time;
    
    # Clear monster count cache
    $cache{monster_count_time} = 0;
    $cache{closest_monster_time} = 0;
    
    DEBUG("Monster died", 2);
    
    # Auto-start countdown after kill if idle
    if (!is_ai_busy() && !$state{countdown_active}) {
        start_countdown("Kill");
    }
    
    # Check for new closest target after kill
    if (get_config('simpleTeleHunter_forceClosest', 1)) {
        force_attack_closest();
    }
}

sub on_player_died {
    my (undef, $args) = @_;
    
    $state{last_death} = time;
    $state{spawn_danger} = 0;
    $state{fast_mode} = 1;  # Enable fast mode
    $stats{deaths}++;
    
    message "[SimpleTeleHunter] Player died - preparing fast recovery\n", "warning";
    
    # Reset all timers
    $state{last_teleport} = 0;
    $state{last_tick} = 0;
    reset_countdown();
}

sub on_skill_use {
    my (undef, $args) = @_;
    
    return unless $args && defined $args->{skillID};
    
    # BS_GREED = 1013
    if ($args->{skillID} == 1013) {
        $state{last_take} = time;
        DEBUG("Greed used", 2);
    }
}

sub on_map_changed {
    DEBUG("Map changed", 1);
    
    reset_countdown();
    $state{last_attack} = 0;
    $state{last_kill} = 0;
    $state{spot_start} = time;
    $state{map_loaded} = 0;
    $state{map_load_time} = 0;
    
    # Clear cache
    $cache{monster_count_time} = 0;
    $cache{closest_monster_time} = 0;
}

sub on_map_loaded {
    $state{map_loaded} = 1;
    $state{map_load_time} = time;
    
    # Enable fast mode for 5 seconds after spawn
    if (time - $state{last_death} < 10) {
        $state{fast_mode} = 1;
        DEBUG("Fast mode enabled (recent death)", 1);
    }
    
    # Check if profile changed
    my $profile = get_profile_name();
    if ($profile && $profile ne $current_profile) {
        $current_profile = $profile;
        
        # Reload config with Settings API
        Settings::loadByHandle($smart_handle) if $smart_handle;
        load_and_show_config();
        $state{config_reloaded} = 1;
    }
    
    # Fast start - reset tick timer to work immediately
    $state{last_tick} = 0;
    
    # เพิ่ม: Mark as just teleported
    if ($state{teleport_pending}) {
        message "[SimpleTeleHunter] Teleport completed\n", "teleport";
        $state{teleport_pending} = 0;
        $state{just_teleported} = 1;
        $state{teleport_time} = time;
    }
    
    # Immediate danger check after spawn
    if ($char && $field && $char->{pos_to}) {
        my $pos = $char->{pos_to};
        my ($x, $y) = ($pos->{x}, $pos->{y});
        
        DEBUG("Spawned at ($x, $y)", 1);
        
        # Check if spawned in danger zone
        if (my $danger = is_in_danger()) {
            message "[SimpleTeleHunter] ⚠️ Spawned in $danger zone! Teleporting immediately!\n", "warning";
            
            # Force immediate teleport
            $state{spawn_danger} = 1;
            $stats{teleports_by_spawn}++;
            
            # Don't wait for anything, just teleport
            do_teleport("spawn_$danger");
            return;
        }
        
        # เพิ่ม: Check monsters immediately after teleport
        if ($state{just_teleported}) {
            my $nearby = count_nearby_monsters();
            my $min_monsters = get_config('simpleTeleHunter_minNearbyMonsters', 3);
            
            if ($nearby == 0) {
                message "[SimpleTeleHunter] No monsters after teleport! Teleporting again...\n", "teleport";
                $state{just_teleported} = 0;
                do_teleport('no_monsters_instant');
                return;
            } elsif ($nearby < $min_monsters) {
                message "[SimpleTeleHunter] Few monsters ($nearby) after teleport, checking...\n", "teleport";
            }
        }
        
        # Check monsters immediately at spawn
        my $nearby = count_nearby_monsters(5);
        if ($nearby >= 3) {
            message "[SimpleTeleHunter] ⚠️ Many monsters at spawn ($nearby)! Teleporting!\n", "warning";
            $stats{teleports_by_spawn}++;
            do_teleport('spawn_crowded');
            return;
        }
        
        # If safe, attack closest immediately
        if ($nearby > 0 && get_config('simpleTeleHunter_forceClosest', 1)) {
            # Small delay to let monsters load
            $state{forced_closest} = 0;
        }
    }
    
    DEBUG("Map loaded - Fast start ready", 1);
}

sub on_attack_start {
    my (undef, $args) = @_;
    
    # Check if we should switch to closer target
    if (get_config('simpleTeleHunter_forceClosest', 1) && 
        timeOut($state{last_target_check}, 1)) {
        
        $state{last_target_check} = time;
        check_current_target_distance();
    }
}

sub on_configModify {
    my (undef, $args) = @_;
    
    # Reload if SimpleTeleHunter config changed
    if ($args->{key} =~ /^simpleTeleHunter/) {
        DEBUG("Config modified: $args->{key} = $args->{val}", 1);
        
        # Show updated value
        if ($args->{key} eq 'simpleTeleHunter_idleTime') {
            message "[SimpleTeleHunter] Idle time changed to: $args->{val}s\n", "plugins";
        } elsif ($args->{key} eq 'simpleTeleHunter_minNearbyMonsters') {
            message "[SimpleTeleHunter] Min monsters changed to: $args->{val}\n", "plugins";
        }
        
        # Validate after change
        validate_config();
    }
}

sub on_reload_config {
    Settings::loadByHandle($smart_handle) if $smart_handle;
    message "[SimpleTeleHunter] Config reloaded\n", "success";
    validate_config();
}

sub on_initializeAddTasks {
    # Called after profile is loaded
    if (!$state{config_reloaded}) {
        load_and_show_config();
        $state{config_reloaded} = 1;
    }
}

###############################################################################
# Main AI Tick (Fast Response Version)
###############################################################################

sub on_ai_tick {
    return unless is_enabled();
    return unless $char && $field;
    
    # Fast mode check - no delay after spawn/death
    my $fast_response = 0;
    if ($state{fast_mode} || 
        $state{spawn_danger} || 
        (time - $state{last_death} < 10) ||
        (time - $state{map_load_time} < 3)) {
        $fast_response = 1;
    }
    
    # Disable fast mode after 5 seconds
    if ($state{fast_mode} && time - $state{map_load_time} > 5) {
        $state{fast_mode} = 0;
        DEBUG("Fast mode disabled", 1);
    }
    
    # Tick interval check - faster in fast mode
    my $tick_interval = $fast_response ? 0.1 : 
                        get_config('simpleTeleHunter_tickInterval', 0.5);
    
    return unless timeOut($state{last_tick}, $tick_interval);
    $state{last_tick} = time;
    
    # Debug Level 2 (Verbose)
    if (get_config('simpleTeleHunter_debug', 0) >= 2) {
        my $nearby = count_nearby_monsters_cached();
        my $is_busy = is_ai_busy() ? 'yes' : 'no';
        my $countdown = $state{countdown_active} ? 'active' : 'inactive';
        
        DEBUG(sprintf(
            "Tick: monsters=%d, busy=%s, countdown=%s, mode=%s, fast=%s",
            $nearby, $is_busy, $countdown, $state{mode}, 
            $fast_response ? 'yes' : 'no'
        ), 2);
    }
    
    # Basic checks - skip lockMap check in fast mode
    if (!$fast_response) {
        return unless Misc::inLockMap();
    }
    return unless $state{map_loaded};
    
    # Skip if teleporting
    if ($state{teleport_pending}) {
        reset_countdown() if $state{countdown_active};
        return;
    }
    
    # Force attack closest after teleport (with delay)
    if (get_config('simpleTeleHunter_forceClosest', 1)) {
        if (!$state{forced_closest} && 
            timeOut($state{last_teleport}, 0.5) && 
            !timeOut($state{last_teleport}, 2)) {
            force_attack_closest();
        }
        
        # Regular target distance check
        if (defined AI::action && AI::action eq 'attack' && timeOut($state{last_target_check}, 2)) {
            $state{last_target_check} = time;
            check_current_target_distance();
        }
    }
    
    # Check randomwalk timeout
    if ($state{randomwalk_timeout} > 0 && time >= $state{randomwalk_timeout}) {
        disable_randomwalk();
    }
    
    # Priority 1: Emergency
    if (my $emergency = check_emergency()) {
        message "[SimpleTeleHunter] EMERGENCY: $emergency\n", "warning";
        do_teleport($emergency);
        return;
    }
    
    # Priority 2: Danger Zone (Enhanced)
    if (my $danger = is_in_danger()) {
        if (!$state{in_danger}) {
            message "[SimpleTeleHunter] ⚠️ Danger: $danger zone!\n", "teleport";
            $state{in_danger} = 1;
            AI::clear('attack', 'skill', 'route', 'move');
            
            # Immediate teleport from danger
            $stats{teleports_by_edge}++;
            do_teleport($danger);
            return;
        }
        # Don't enable randomwalk in static mode
        if ($config{route_randomWalk}) {
            enable_randomwalk(3);
        }
        return;
    } elsif ($state{in_danger}) {
        message "[SimpleTeleHunter] ✓ Safe zone\n", "success";
        $state{in_danger} = 0;
        disable_randomwalk();
    }
    
    # Priority 3: Farm Mode
    return unless $state{mode} eq 'farm';
    
    # Update action times from AI
    if (AI::inQueue('take', 'items_take')) {
        if (timeOut($state{last_take}, 1)) {
            $state{last_take} = time;
        }
    }
    
    # Auto-start countdown after kill (with grace period)
    if (!$state{countdown_active} && 
        $state{last_kill} > 0 &&
        !is_ai_busy()) {
        
        my $grace = $fast_response ? 0.2 : 0.5;  # Shorter grace in fast mode
        if (timeOut($state{last_kill}, $grace) && !timeOut($state{last_kill}, 2)) {
            if (count_nearby_monsters_cached() == 0) {
                start_countdown("Delayed after kill");
            }
        }
    }
    
    # Main teleport decision
    if (my $reason = should_teleport()) {
        if (is_ai_busy()) {
            DEBUG("Should teleport but busy", 2);
            return;
        }
        
        do_teleport($reason);
    }
}

###############################################################################
# Plugin Initialization
###############################################################################

sub on_load {
    message "=" x 50 . "\n";
    message "[SimpleTeleHunter] v$VERSION Fast Start Edition\n", "success";
    message "[SimpleTeleHunter] Author: sheroo007\n", "plugins";
    message "=" x 50 . "\n";
    
    # Check if profiles plugin is loaded
    my $profile = get_profile_name();
    if ($profile) {
        message "[SimpleTeleHunter] Profile detected: $profile\n", "plugins";
        $current_profile = $profile;
    }
    
    # Register control file with Settings API (proper way)
    $smart_handle = Settings::addControlFile(
        'smart.txt',
        loader => [\&load_smart_config],
        autoSearch => 1,  # Search in @controlFolders automatically
        mustExist => 0,   # Don't require file to exist
    );
    
    # Initial load
    if ($smart_handle) {
        Settings::loadByHandle($smart_handle);
        message "[SimpleTeleHunter] Registered smart.txt with Settings API\n", "success";
    } else {
        warning "[SimpleTeleHunter] Failed to register smart.txt - using defaults\n";
    }
    
    load_and_show_config();
    
    # Register hooks
    $hooks = Plugins::addHooks(
        ['packet_mapChange', \&on_map_changed],
        ['packet/map_change', \&on_map_changed],
        ['map_loaded', \&on_map_loaded],
        ['target_died', \&on_monster_died],
        ['packet_skilluse', \&on_skill_use],
        ['attack_start', \&on_attack_start],
        ['AI_pre', \&on_ai_tick],
        ['configModify', \&on_configModify],
        ['reloadConfig', \&on_reload_config],
        ['initialized', \&on_initializeAddTasks],
        ['player_died', \&on_player_died],
    );
    
    message "=" x 50 . "\n";
}

###############################################################################
# Plugin Cleanup
###############################################################################

sub on_unload {
    disable_randomwalk();
    
    # Proper cleanup with Settings API
    if ($smart_handle) {
        Settings::delControlFile($smart_handle);
        $smart_handle = undef;
        message "[SimpleTeleHunter] Unregistered smart.txt from Settings API\n", "plugins";
    }
    
    Plugins::delHooks($hooks) if $hooks;
    Commands::unregister('sthdebug');
    
    # Show session statistics
    my $runtime = int((time - $stats{session_start}) / 60);
    
    message "=" x 50 . "\n";
    message "[SimpleTeleHunter] Session: ${runtime} minutes\n", "plugins";
    message "[SimpleTeleHunter] Teleports: $stats{total_teleports}\n", "plugins";
    message "[SimpleTeleHunter]   - By spawn: $stats{teleports_by_spawn}\n", "plugins" if $stats{teleports_by_spawn};
    message "[SimpleTeleHunter]   - By edge: $stats{teleports_by_edge}\n", "plugins" if $stats{teleports_by_edge};
    message "[SimpleTeleHunter] Target switches: $stats{target_switches}\n", "plugins" if $stats{target_switches};
    message "[SimpleTeleHunter] Deaths: $stats{deaths}\n", "plugins" if $stats{deaths};
    
    if ($stats{failed_teleports} > 0) {
        warning "[SimpleTeleHunter] Failed teleports: $stats{failed_teleports}\n";
    }
    
    message "[SimpleTeleHunter] Profile used: " . ($current_profile || 'default') . "\n", "plugins" if $current_profile;
    message "[SimpleTeleHunter] v$VERSION unloaded successfully\n", "plugins";
    message "=" x 50 . "\n";
}

on_load();

1;

__END__

=pod

=head1 SimpleTeleHunter v4.4.3 - Fast Start Edition

Smart teleport hunter with instant action on spawn - No more waiting!

=head2 What's New in v4.4.3

=over 4

=item * B<Fixed slow start> - Instant action after spawn/death

=item * B<Fixed edge detection> - Teleports immediately when spawning at map edge

=item * B<Fast mode> - Super responsive for 5 seconds after death

=item * B<No delays> - Works immediately, no waiting period

=item * B<Better safety> - Detects edge, corner, and trapped positions

=back

=head2 Configuration

Place in profiles/<profile>/smart.txt or control/smart.txt:

    # SimpleTeleHunter v4.4.3
    simpleTeleHunter 1
    
    # Basic Settings
    simpleTeleHunter_idleTime 3
    simpleTeleHunter_minNearbyMonsters 2
    simpleTeleHunter_monsterRadius 10
    
    # Safety Settings (Important!)
    simpleTeleHunter_edgeDistance 10
    simpleTeleHunter_minWalkable 4
    simpleTeleHunter_emergencyMode 1
    simpleTeleHunter_emergency_hp 50
    
    # Target Selection
    simpleTeleHunter_forceClosest 1
    simpleTeleHunter_closeRange 5
    simpleTeleHunter_maxAttackDistance 7
    
    # Performance
    simpleTeleHunter_cooldown 1
    simpleTeleHunter_tickInterval 0.5
    simpleTeleHunter_maxTimePerSpot 60
    
    # Debug (optional)
    simpleTeleHunter_debug 0

Also set in config.txt:

    # Disable walking
    route_randomWalk 0
    attackAuto_followTarget 0
    
    # Teleport settings
    teleportAuto_hp 30
    teleportAuto_deadly 1
    teleportAuto_unstuck 1
    teleportAuto_useSkill 1
    
    # Use Greed for items
    itemsTakeGreed 1
    itemsTakeAuto 0

=head2 Commands

    sthdebug        # Show current debug level
    sthdebug 0      # Disable debug
    sthdebug 1      # Basic debug
    sthdebug 2      # Verbose debug

=head2 How It Works

1. B<Spawns> → Checks position immediately
2. B<Edge detected> → Teleports instantly (no delay)
3. B<Safe position> → Attacks closest monster
4. B<No monsters> → Countdown then teleport
5. B<After death> → Fast mode for 5 seconds

=head2 Edge Distance Explained

    edgeDistance 10 = Danger zone within 10 blocks of map edge
    edgeDistance 5  = Only very edge is dangerous
    edgeDistance 15 = Large safety margin

=head2 AUTHOR

sheroo007

=head2 VERSION

4.4.3 (2025-10-29 21:17:36 UTC) - Fast Start Edition

=cut