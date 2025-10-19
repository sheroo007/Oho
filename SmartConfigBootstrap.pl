#==========================================================
# SmartConfigBootstrap.pl v3.3 (Profile-aware + Updated)
# รองรับ: ปลั๊กอินทั้งหมด 10 ตัว + SmartRouteAI backup
#==========================================================
package SmartConfigBootstrap;

use strict;
use warnings;
use Plugins;
use Globals qw(%config);
use Settings;
use Log qw(message warning error);
use IO::File;
use File::Basename ();
use File::Spec;
use Encode ();
use Time::HiRes ();

BEGIN {
    eval { require SmartCore; SmartCore->import(qw(broadcast_reload smart_path)); 1 } or do {
        *smart_path = sub {
            # ✅ Check profile from selector
            my $profile = $Globals::config{profile} // $config{profile} // '';
            if ($profile && $profile ne '' && $profile ne 'default') {
                my $pdir = "profiles/$profile";
                return "$pdir/smart.txt" if -d $pdir;
                return "$pdir/smart.txt";
            }
            return Settings::getControlFilename('smart.txt');
        };
        *broadcast_reload = sub {
            my ($reason) = @_;
            $reason ||= 'bootstrap';
            Plugins::callHook('smart/config/reloaded', { 
                reason => $reason, 
                file => _smart_path_safe() 
            });
            message "[SmartBootstrap] Broadcast smart/config/reloaded ($reason)\n";
        };
    };
}

my $hooks;
Plugins::register('SmartConfigBootstrap', 'Smart.txt bootstrap v3.3 (Updated)', \&onUnload);
$hooks = Plugins::addHooks(
    ['start3', \&onStart, undef],
);
sub onUnload { Plugins::delHooks($hooks) if $hooks; }

# ----------------------- COMPLETE SPEC v3.3 -----------------------
my %SPEC = (
  'SmartCore' => {
    # Core settings - no config needed
  },

  'SmartComboSimple' => {
    smartSimple_enabled         => 1,
    smartSimple_save_enabled    => 1,
    smartSimple_lock_enabled    => 1,
    smartSimple_autosell_cmd    => 'autosell',
    smartSimple_player_over_pct => 85,
    smartSimple_cart_over_pct   => 90,
    smartSimple_autosell_delay_ms => 300,
    smartSimple_over_check_ms   => 500,
    smartSimple_teleport_cool_ms => 1200,
  },

  'SmartDepositEngine' => {
    smartDeposit_enabled        => 1,
    smartDeposit_chunk          => 500,
    smartDeposit_delay          => '0.15',
    smartDeposit_watchdog       => 10,
    smartDeposit_logLevel       => 'info',
    smartDeposit_itemsFile      => 'items_control.txt',
    smartDeposit_direct         => 1,
    smartDeposit_blockRoute     => 1,
    smartDeposit_opCooldown     => '0.3',
    smartDeposit_stepBurst      => 5,
    smartDeposit_maxPullRounds  => 50,
  },

  'SmartAttackSkill' => {
    skill_tester_enabled        => 1,
    skill_tester_use_in_savemap => 0,
    skill_tester_use_in_lockmap => 1,
    skill_tester_attack         => 1,
    skill_tester_lv             => 5,
    skill_tester_factor         => '1.20',
    skill_tester_order          => 'alpha',
    skill_tester_scope          => 'any',
  },

  'SmartLootPriority' => {
    smartLootPriority_enabled            => 1,
    smartLootPriority_minMonsters        => 2,
    smartLootPriority_scanRadius         => 10,
    smartLootPriority_quietSeconds       => '0.8',
    smartLootPriority_debug              => 0,
    smartLootPriority_triggerGreed       => 1,
    smartLootPriority_minDropsForGreed   => 3,
    smartLootPriority_greedRadius        => 6,
    smartLootPriority_minSP              => 30,
    smartLootPriority_hpSafeMin          => 50,
    smartLootPriority_cooldown           => '1.0',
    smartLootPriority_urgentTakeIfNoGreed => 1,
    smartLootPriority_urgentTakeMaxDist  => 3,
    smartLootPriority_usePickupFlag2     => 1,
    'smartLootPriority_urgentRegex'      => 'Card$|Card Album|Old (Blue|Purple) Box',
  },

  'SmartNearestTarget' => {
    smartNearest_enabled            => 1,
    smartNearest_idleOnly           => 1,
    smartNearest_scanRadius         => 12,
    smartNearest_skipPassive        => 1,
    smartNearest_minHPpct           => 0,
    smartNearest_attackLockDelay    => 2,
  },

  'SmartRouteAI' => {
    smartRoute_enabled                 => 1,
    smartRoute_checkInterval           => '0.3',
    smartRoute_dangerRadius            => 7,
    smartRoute_dangerCount             => 3,
    smartRoute_teleMinDistance         => 100,
    smartRoute_teleCooldown            => '0.5',
    smartRoute_teleMinSP               => 12,
    smartRoute_teleWaitSP              => 1,
    smartRoute_teleWaitSPTimeout       => 5,
    smartRoute_stuckTimeout            => 8,
    smartRoute_emergencyHpPercent      => 50,
    smartRoute_walkIfNoWings           => 1,
    smartRoute_quitIfNoWings           => 0,
    smartRoute_attackWhileWalking      => 1,
    smartRoute_clearPathTimeout        => '3.0',
    smartRoute_idleTime                => '0.3',
    smartRoute_pathWidth               => 2,
    smartRoute_emergencyThreshold      => 3,
    smartRoute_emergencyNoWaitSP       => 1,
    smartRoute_returnWaitTimeout       => 3,
    smartRoute_outsideOnly             => 1,
    smartRoute_maxPlans                => 3,
    # Backup values
    smartRoute_attackAuto              => 1,
    smartRoute_attackAuto_party        => 1,
    smartRoute_randomWalk              => 0,
    smartRoute_randomWalk_inTown       => 0,
    smartRoute_randomWalk_maxRouteTime => 75,
    smartRoute_sitAuto_idle            => 1,
    smartRoute_sitAuto_hp_lower        => 0,
    smartRoute_sitAuto_sp_lower        => 0,
    smartRoute_follow                  => 0,
    smartRoute_followTarget            => '',
  },

  'SmartGroundAvoidance' => {
    smartAvoid_enabled          => 1,
    smartAvoid_method           => 1,
    smartAvoid_step             => 6,
    smartAvoid_scanInterval     => '0.5',
    smartAvoid_debug            => 0,
    # Skill toggles
    smartAvoid_firewall         => 1,
    smartAvoid_icewall          => 1,
    smartAvoid_meteorstorm      => 1,
    smartAvoid_stormgust        => 1,
    smartAvoid_lordofvermilion  => 1,
    smartAvoid_quagmire         => 1,
    smartAvoid_firepillar       => 1,
  },

  'SmartTeleportHunter' => {
    smartTeleHunter_enabled           => 1,
    smartTeleHunter_scanRadius        => 12,
    smartTeleHunter_minMonsters       => 1,
    smartTeleHunter_cooldown          => '0.9',
    smartTeleHunter_checkInterval     => '1.0',
    smartTeleHunter_allowDuringRoute  => 1,
    smartTeleHunter_routeMinSeconds   => '2.0',
  },

  'SmartAutoReload' => {
    smart_auto_interval  => '1.2',
    smart_auto_recursive => 0,
  },
);

# ----------------------- SAFE PATH HELPERS -----------------------
sub _smart_path_safe {
    my $p = eval { smart_path() } // '';
    $p =~ s/^\s+|\s+$//g if defined $p;
    return $p if $p;

    # ✅ Check profile
    my $profile = eval { $Globals::config{profile} } // $config{profile} // '';
    if ($profile && $profile ne '' && $profile ne 'default') {
        my $pdir = "profiles/$profile";
        return "$pdir/smart.txt" if -d $pdir;
        return "$pdir/smart.txt";
    }

    my $cfg = eval { Settings::getControlFilename('config.txt') } // '';
    my $dir = eval { File::Basename::dirname($cfg) } // '';
    if (!$dir || $dir eq '.') { $dir = 'control'; }
    return File::Spec->catfile($dir, 'smart.txt');
}

sub _ensure_parent_dir {
    my ($filepath) = @_;
    if (!defined $filepath || $filepath eq '') {
        my $profile = eval { $Globals::config{profile} } // $config{profile} // '';
        my $dir = ($profile && $profile ne '' && $profile ne 'default') 
                  ? "profiles/$profile" 
                  : 'control';
        eval { 
            require File::Path;
            File::Path::make_path($dir) unless -d $dir;
        };
        warning "[SmartBootstrap] mkdir (fallback) failed for $dir : $@\n" if $@;
        return;
    }
    my $dir = eval { File::Basename::dirname($filepath) } // '';
    if (!$dir || $dir eq '.') { $dir = 'control'; }
    eval { 
        require File::Path;
        File::Path::make_path($dir) unless -d $dir;
    };
    warning "[SmartBootstrap] mkdir failed for $dir : $@\n" if $@;
}

# ----------------------- START HOOK -----------------------
sub onStart {
    my $path = _smart_path_safe();

    my $created = 0;
    my $updated = 0;
    my $aliased = 0;

    unless (-e $path) {
        _ensure_parent_dir($path);
        _write_fresh($path, \%SPEC);
        $created = 1;
        message "[SmartBootstrap] ✅ Created: $path\n", "success";
    } else {
        $updated = _append_missing($path, \%SPEC);
        $aliased = _append_aliases_if_needed($path);
        if ($updated || $aliased) {
            message "[SmartBootstrap] ✅ Updated: $path\n", "success";
        } else {
            message "[SmartBootstrap] ℹ️  Up-to-date: $path\n", "info";
        }
    }

    my $reason = $created ? 'bootstrap-create'
               : $updated ? 'bootstrap-append'
               : $aliased ? 'bootstrap-alias'
               :            'bootstrap-nochange';
    broadcast_reload($reason);
}

# ----------------------- RENDER/APPEND (UTF-8 & BOM safe) -----------------------
sub _write_fresh {
    my ($path, $spec) = @_;
    my $text = _render_template($spec);

    my $fh;
    if ($^O =~ /MSWin32/i) {
        open($fh, '>:raw', $path) or do { error "[SmartBootstrap] Cannot write $path : $!\n"; return; };
        print $fh "\x{EF}\x{BB}\x{BF}";
        print $fh Encode::encode('UTF-8', $text);
    } else {
        open($fh, '>:encoding(UTF-8)', $path) or do { error "[SmartBootstrap] Cannot write $path : $!\n"; return; };
        print $fh $text;
    }
    close $fh;
}

sub _append_missing {
    my ($path, $spec) = @_;

    my $text = _slurp($path);
    my $had_change = 0;
    my $have = _scan_existing($text);

    my $append = '';
    foreach my $section ( _ordered_sections($spec) ) {
        my $kv = $spec->{$section};
        my $section_has = $have->{$section};

        if (!$section_has) {
            $append .= _render_section($section, $kv);
            $had_change = 1;
            $have->{$section} = { map { $_ => 1 } keys %$kv };
            next;
        }

        my $buf = '';
        foreach my $k ( _ordered_keys($section, $kv) ) {
            next if $have->{$section}{$k};
            $buf .= sprintf("%s = %s\n", $k, $kv->{$k});
        }
        if ($buf ne '') {
            $append .= "\n[$section]\n$buf\n";
            $had_change = 1;
        }
    }

    if ($had_change) {
        my $fh;
        if ($^O =~ /MSWin32/i) {
            open($fh, '>>:raw', $path) or do { error "[SmartBootstrap] Cannot append $path : $!\n"; return 0; };
            print $fh Encode::encode('UTF-8', $append);
        } else {
            open($fh, '>>:encoding(UTF-8)', $path) or do { error "[SmartBootstrap] Cannot append $path : $!\n"; return 0; };
            print $fh $append;
        }
        close $fh;
    }
    return $had_change ? 1 : 0;
}

sub _append_aliases_if_needed {
    my ($path) = @_;
    my $text = _slurp($path);
    my $have = _scan_existing($text);
    my $changed = 0;
    my $append = '';

    if (($have->{'SmartComboSimple'} && $have->{'SmartComboSimple'}{'perlsmartSimple_enabled'})
        && (! $have->{'SmartComboSimple'}{'smartSimple_enabled'})) {
        $append .= "\n[SmartComboSimple]\nsmartSimple_enabled = 1\n";
        $changed = 1;
    }

    if (($have->{'SmartDepositEngine'} && $have->{'SmartDepositEngine'}{'perlsmartDeposit_enabled'})
        && (! $have->{'SmartDepositEngine'}{'smartDeposit_enabled'})) {
        $append .= "\n[SmartDepositEngine]\nsmartDeposit_enabled = 1\n";
        $changed = 1;
    }

    if ($changed) {
        my $fh;
        if ($^O =~ /MSWin32/i) {
            open($fh, '>>:raw', $path) or do { error "[SmartBootstrap] Cannot append aliases to $path : $!\n"; return 0; };
            print $fh Encode::encode('UTF-8', $append);
        } else {
            open($fh, '>>:encoding(UTF-8)', $path) or do { error "[SmartBootstrap] Cannot append aliases to $path : $!\n"; return 0; };
            print $fh $append;
        }
        close $fh;
    }
    return $changed ? 1 : 0;
}

# ----------------------- UTIL/RENDER -----------------------
sub _slurp {
    my ($path) = @_;
    my $fh;
    if ($^O =~ /MSWin32/i) {
        open($fh, '<:raw', $path) or return '';
        local $/; my $raw = <$fh>; close $fh;
        $raw =~ s/^\x{EF}\x{BB}\x{BF}//;
        return Encode::decode('UTF-8', $raw);
    } else {
        $fh = IO::File->new($path, '<:encoding(UTF-8)') or return '';
        local $/; my $t = <$fh>; $fh->close; return $t // '';
    }
}

sub _scan_existing {
    my ($txt) = @_;
    my %have; my $cur;
    foreach my $line (split /\r?\n/, $txt) {
        if ($line =~ /^\s*\[(.+?)\]\s*$/) { $cur = $1; $have{$cur} ||= {}; next; }
        next unless defined $cur;
        if ($line =~ /^\s*([A-Za-z0-9_]+)\s*=/) { $have{$cur}{$1} = 1; }
        if ($line =~ /^\s*([A-Za-z0-9_]+)\s*$/) { $have{$cur}{$1} = 1; }
    }
    return \%have;
}

sub _render_template {
    my ($spec) = @_;
    my $out = '';
    foreach my $section ( _ordered_sections($spec) ) {
        $out .= _render_section($section, $spec->{$section});
    }
    return $out;
}

sub _render_section {
    my ($section, $kv) = @_;
    my $out = "[$section]\n";
    foreach my $k ( _ordered_keys($section, $kv) ) {
        $out .= sprintf("%s = %s\n", $k, $kv->{$k});
    }
    return $out . "\n";
}

sub _ordered_sections {
    my ($spec) = @_;
    my @order = qw(
        SmartCore
        SmartComboSimple
        SmartDepositEngine
        SmartAttackSkill
        SmartLootPriority
        SmartNearestTarget
        SmartRouteAI
        SmartGroundAvoidance
        SmartTeleportHunter
        SmartAutoReload
    );
    my %seen; @seen{@order} = (1) x @order;
    return (@order, grep { !$seen{$_} } sort keys %$spec);
}

sub _ordered_keys {
    my ($section, $kv) = @_;
    my @keys = sort keys %$kv;
    my %prio = map { $_ => 1 } qw(
        smartSimple_enabled smartDeposit_enabled skill_tester_enabled
        smartLootPriority_enabled smartNearest_enabled smartRoute_enabled
        smartAvoid_enabled smartTeleHunter_enabled
    );
    return (sort { ($prio{$b}||0) <=> ($prio{$a}||0) || $a cmp $b } @keys);
}

message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", "system";
message "[SmartBootstrap] v3.3 Updated \n", "system";
message "Creates in: profiles/\$profile/smart.txt\n", "system";
message "10 Plugins + SmartRouteAI backup\n", "system";
message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", "system";

1;