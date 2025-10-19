package SmartLootPriority;
use strict;
use warnings;
use Plugins;
use Globals qw(%config $char $monstersList $itemsList);
use Log qw(message warning debug);
use AI;
use Time::HiRes qw(time);
use File::Basename ();
use Settings;
use Skill;
use Commands;

our $VERSION = '1.2.2-nearby-items-check';

BEGIN {
    my $DIR = File::Basename::dirname(__FILE__);
    unshift @INC, $DIR if $DIR && -d $DIR;
    eval { require SmartCore; SmartCore->import(qw(gate_init smart_is_idle_for)); 1 } or do {
        *smart_is_idle_for = sub { 0 };
        *gate_init = sub { 1 };
    };
}

my $hooks;
my %S = (
    suppressed      => 0,
    saved_pickup    => undef,
    last_seen_dense => 0,
    last_urgent_ts  => 0,
    rare_map        => {},
    urgent_re       => undef,
);

Plugins::register('SmartLootPriority', "Smart Loot Priority $VERSION", \&onUnload);
$hooks = Plugins::addHooks(
    ['start3',      \&onStart, undef],
    ['reloadFiles', \&onStart, undef],
    ['AI_pre',      \&onAI,    undef],
);

sub onUnload {
    Plugins::delHooks($hooks) if $hooks;
    # restore pickup flag if we suppressed it
    if ($S{suppressed}) {
        if (defined $AI::pickupItems && defined $S{saved_pickup}) {
            $AI::pickupItems = $S{saved_pickup};
        }
        $S{suppressed}   = 0;
        $S{saved_pickup} = undef;
    }
}

# ---------------- Public API ----------------
sub is_looting {
    return 1 if $S{suppressed};
    
    my $action = AI::action() || '';
    return 1 if $action =~ /^(take|items_take)$/;
    
    # เช็ค Greed cooldown
    return 1 if (time() - $S{last_urgent_ts}) < 2.0;
    
    # เพิ่ม: มีของใกล้ๆ (5 blocks)
    if ($itemsList && $char && $char->{pos_to}) {
        my $cx = $char->{pos_to}{x};
        my $cy = $char->{pos_to}{y};
        my $n = $itemsList->size || 0;
        for (my $i = 0; $i < $n; $i++) {
            my $item = $itemsList->get($i) or next;
            next unless defined $item->{pos}{x} && defined $item->{pos}{y};
            my $dx = $cx - $item->{pos}{x};
            my $dy = $cy - $item->{pos}{y};
            return 1 if ($dx*$dx + $dy*$dy) <= 25;  # 5x5
        }
    }
    
    return 0;
}

# ---- config helpers ----
sub _cfg { my ($k,$d)=@_; return exists $config{$k} ? $config{$k} : $d }
sub _toi { my ($v)=@_; $v//=0; $v=~s/\D+//g; $v+0 }
sub _tof { my ($v)=@_; $v//=0; $v=~s/[^0-9\.\-]+//g; 0.0+$v }

sub _enabled   () { _toi(_cfg('smartLootPriority_enabled', 1)) }
sub _minMon    () { _toi(_cfg('smartLootPriority_minMonsters', 2)) }
sub _radius    () { _toi(_cfg('smartLootPriority_scanRadius', 10)) }
sub _quietSec  () { _tof(_cfg('smartLootPriority_quietSeconds', 0.8)) }
sub _debugFlag () { _toi(_cfg('smartLootPriority_debug', 0)) }

# urgent
sub _trigGreed   () { _toi(_cfg('smartLootPriority_triggerGreed', 1)) }
sub _minDropsG   () { _toi(_cfg('smartLootPriority_minDropsForGreed', 3)) }
sub _greedR      () { _toi(_cfg('smartLootPriority_greedRadius', 6)) }
sub _minSP       () { _toi(_cfg('smartLootPriority_minSP', 30)) }
sub _hpSafeMin   () { _toi(_cfg('smartLootPriority_hpSafeMin', 50)) }
sub _urgCD       () { _tof(_cfg('smartLootPriority_cooldown', 1.0)) }
sub _urgTakeOn   () { _toi(_cfg('smartLootPriority_urgentTakeIfNoGreed', 1)) }
sub _urgTakeMaxD () { _toi(_cfg('smartLootPriority_urgentTakeMaxDist', 3)) }
sub _usePuf2     () { _toi(_cfg('smartLootPriority_usePickupFlag2', 1)) }
sub _urgRegex    () { _cfg('smartLootPriority_urgentRegex', 'Card$|Card Album|Old (Blue|Purple) Box') }

sub onStart {
    gate_init();
    %S = (%S, suppressed=>0, saved_pickup=>undef, last_seen_dense=>0, last_urgent_ts=>0);
    _load_rare_from_pickupitems() if _usePuf2();
    my $pat = _urgRegex();
    eval { $S{urgent_re} = qr/$pat/i; 1 } or do { warning "[SmartLootPriority] bad urgentRegex: $@"; $S{urgent_re}=undef; };
}

sub _load_rare_from_pickupitems {
    my $p = eval { Settings::getControlFilename('pickupitems.txt') } || '';
    my %rare;
    if ($p && -e $p) {
        if (open my $fh, '<:encoding(UTF-8)', $p) {
            while (my $ln = <$fh>) {
                next if $ln =~ /^\s*#/;
                chomp $ln; $ln =~ s/\r//g;
                next unless $ln =~ /\S/;
                my ($name, $flag) = split /\s+/, $ln, 2;
                next unless defined $name;
                $flag = defined $flag ? $flag : '';
                if ($flag =~ /\b2\b/) {
                    $rare{lc $name} = 1;
                }
            }
            close $fh;
        }
    }
    $S{rare_map} = \%rare;
    debug "[SmartLootPriority] rare-from-pickupitems loaded: ".scalar(keys %rare)."\n" if _debugFlag();
}

sub _count_nearby_monsters {
    return 0 unless $monstersList && $char;
    my $cx = $char->{pos_to}{x}; my $cy = $char->{pos_to}{y};
    my $r  = _radius(); my $r2 = $r*$r;
    my $n = $monstersList->size || 0;
    my $c = 0;
    for (my $i=0; $i<$n; $i++) {
        my $m = $monstersList->get($i) or next;
        next unless $m->{hp} > 0;
        next unless defined $m->{pos_to}{x} and defined $m->{pos_to}{y};
        my $dx = $cx - $m->{pos_to}{x}; my $dy = $cy - $m->{pos_to}{y};
        my $d2 = $dx*$dx + $dy*$dy;
        $c++ if $d2 <= $r2;
    }
    return $c;
}

sub _suppress_pickup {
    return if $S{suppressed};
    $S{saved_pickup} = $AI::pickupItems if defined $AI::pickupItems;
    $AI::pickupItems = 0 if defined $AI::pickupItems;
    $S{suppressed} = 1;
    debug "[SmartLootPriority] defer loot (dense fight)\n" if _debugFlag();
}
sub _restore_pickup {
    return unless $S{suppressed};
    if (defined $AI::pickupItems && defined $S{saved_pickup}) {
        $AI::pickupItems = $S{saved_pickup};
    }
    $S{saved_pickup} = undef;
    $S{suppressed} = 0;
    debug "[SmartLootPriority] resume loot (fight calmed)\n" if _debugFlag();
}

sub _have_skill_greed {
    my $sk = Skill->new(name=>'Greed') or return 0;
    my $hdl = $sk->getHandle() or return 0;
    return ($char && $char->getSkillLevel($hdl) > 0) ? 1 : 0;
}

sub _count_drops_in_radius {
    my ($rad) = @_;
    return 0 unless $itemsList && $char;
    my $cx = $char->{pos_to}{x}; my $cy = $char->{pos_to}{y};
    my $r2 = $rad*$rad;
    my $n = $itemsList->size || 0;
    my $c = 0;
    for (my $i=0; $i<$n; $i++) {
        my $it = $itemsList->get($i) or next;
        next unless defined $it->{pos}{x} and defined $it->{pos}{y};
        my $dx = $cx - $it->{pos}{x}; my $dy = $cy - $it->{pos}{y};
        my $d2 = $dx*$dx + $dy*$dy;
        $c++ if $d2 <= $r2;
    }
    return $c;
}

sub _exists_urgent_drop_nearby {
    return 0 unless $itemsList && $char;
    my $cx = $char->{pos_to}{x}; my $cy = $char->{pos_to}{y};
    my $re = $S{urgent_re};
    my $n = $itemsList->size || 0;
    for (my $i=0; $i<$n; $i++) {
        my $it = $itemsList->get($i) or next;
        next unless defined $it->{pos}{x} and defined $it->{pos}{y};
        my $name = $it->{name} // '';
        my $isRare = ($re && $name =~ $re) ? 1 : 0;
        $isRare ||= $S{rare_map}->{lc $name} ? 1 : 0;
        if ($isRare) {
            my $dx = $cx - $it->{pos}{x}; my $dy = $cy - $it->{pos}{y};
            my $d = sqrt($dx*$dx + $dy*$dy);
            return { id=>$it->{ID}, name=>$name, dist=>$d };
        }
    }
    return 0;
}

sub _urgent_greed_or_take {
    my $now = time;
    return if ($now - $S{last_urgent_ts}) < _urgCD();
    return unless $char;
    my $hp = $char->{hpPercent} // 100;
    return if $hp < _hpSafeMin();

    my $urgent = _exists_urgent_drop_nearby() or return;
    my $dense  = _count_nearby_monsters();
    return if $dense >= _minMon() + 1;

    # Prefer Greed
    if (_trigGreed() && _have_skill_greed()) {
        my $sp = $char->{sp} // 0;
        if ($sp >= _minSP()) {
            my $drops = _count_drops_in_radius(_greedR());
            if ($drops >= _minDropsG() || $urgent->{dist} <= _greedR()) {
                debug "[SmartLootPriority] URGENT: Greed for rare '$urgent->{name}'\n" if _debugFlag();
                eval { Commands::run("ss greed"); };
                $S{last_urgent_ts} = $now;
                return;
            }
        }
    }

    # Fallback: quick take if very close
    if (_urgTakeOn() && $urgent->{dist} <= _urgTakeMaxD()) {
        debug "[SmartLootPriority] URGENT: take '$urgent->{name}' (d≈$urgent->{dist})\n" if _debugFlag();
        eval { Commands::run(sprintf("take %s", $urgent->{id})); };
        $S{last_urgent_ts} = $now;
        return;
    }
}

sub onAI {
    return unless _enabled();
    return unless $char;

    # 1) ชิงของหายากถ้าปลอดภัย
    _urgent_greed_or_take();

    # 2) หนาแน่น -> ชะลอเก็บ
    my $dense = _count_nearby_monsters();
    if ($dense >= _minMon()) {
        $S{last_seen_dense} = time;
        _suppress_pickup();
        return;
    }

    # 3) เงียบพอ -> คืนสิทธิ์เก็บ
    my $quiet = _quietSec();
    my $now   = time;
    if (($now - $S{last_seen_dense}) >= $quiet && smart_is_idle_for($quiet)) {
        _restore_pickup();
    }
}

1;