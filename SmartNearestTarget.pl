#==========================================================
# SmartNearestTarget.pl v1.3 - Complete Fixed
# - เล็งเป้า "ใกล้สุด" แบบไม่สแปม และไม่แทรกคิวระบบ
# - เพิ่ม: Commands import, เช็ค ignore/avoid/dead
# - ใช้ $char->attack() แทน Commands::run
# - เพิ่ม: SmartRouteAI guard
#==========================================================
package SmartNearestTarget;
use strict;
use warnings;
use Plugins;
use Globals qw(%config $char $monstersList $field);
use Commands;
use Actor;
use Log qw(debug message);
use AI;
use Utils qw(blockDistance);
use Time::HiRes qw(time);

# ---------- throttle (no 'state') ----------
our %_throttle_cache;
sub _throttle_ok {
    my ($name,$sec)=@_; $sec ||= 0.25;
    my $now = time;
    return 0 if exists $_throttle_cache{$name} && $now - $_throttle_cache{$name} < $sec;
    $_throttle_cache{$name} = $now;
    return 1;
}

# ---------- config ----------
sub _en()       { $config{smartNearest_enabled}     // 1 }
sub _idleOnly() { $config{smartNearest_idleOnly}    // 1 }
sub _scanR()    { $config{smartNearest_scanRadius}  // 12 }
sub _skipPas()  { $config{smartNearest_skipPassive} // 1 }
sub _minHPpct() { $config{smartNearest_minHPpct}    // 0 }

# ---------- helpers ----------
sub _busy() {
    # Guard SmartRouteAI (มีอยู่แล้ว)
    if (eval { SmartRouteAI::isTraveling() }) {
        return 1;
    }
    
    # ← เพิ่ม: Guard SmartAttackSkill
    if (eval { SmartAttackSkill::is_casting() }) {
        return 1;
    }
    
    my $a = AI::action;
    return 1 if $a && ($a eq 'storage' || $a eq 'npc' || $a eq 'shop' || 
                       $a eq 'deal' || $a eq 'route' || $a eq 'move');
    
    if (_idleOnly() && $a && ($a eq 'attack' || $a eq 'skill_use')) {
        return 1;
    }
    
    return 0;
}

sub _me_pos { 
    return ($char && $char->{pos_to}) ? $char->{pos_to} : undef 
}

sub _hp_pct_m {
    my ($m) = @_;
    return 100 unless $m && $m->{hp_max};
    return int( (($m->{hp}||0) * 100) / ($m->{hp_max}||1) );
}

sub _is_passive_guess {
    my ($m) = @_;
    return 0 unless $m;
    # ถ้ามอนไม่เคยทำดาเมจให้เรา แต่เราทำดาเมจมอน = passive
    return 1 if defined $m->{dmgToYou} && $m->{dmgToYou} == 0 && 
                defined $m->{dmgFromYou} && $m->{dmgFromYou} > 0;
    return 0;
}

# ---------- main ----------
Plugins::register('SmartNearestTarget', 'Pick nearest target safely v1.3', \&onUnload);

my $hooks = Plugins::addHooks(
    ['AI_pre', \&on_ai_pre, undef],
);

sub onUnload { 
    Plugins::delHooks($hooks) if $hooks;
}

sub on_ai_pre {
    # lockMap guard
    my $lockMap = $config{lockMap} || '';
    return if ($config{attackAuto_inLockOnly} && $lockMap && lc($field->name) ne lc($lockMap));
    
    return unless _en() && $char && $field && $monstersList;
    return unless _throttle_ok('SmartNearestTarget.tick', 0.20);
    return if _busy();
    
    my $me = _me_pos() or return;
    my $items = $monstersList->getItems || [];
    
    my @candidates;
    for my $m (@$items) {
        next unless $m && $m->{pos_to};
        
        # เช็คสถานะมอน
        next if $m->{ignore};
        next if $m->{avoid};
        next if $m->{dead};
        next if $m->{hp} && $m->{hp} <= 0;
        
        my $d = blockDistance($me, $m->{pos_to});
        next if $d > _scanR();
        
        # เช็ค passive
        if (_skipPas() && _is_passive_guess($m)) { 
            next 
        }
        
        # เช็ค HP%
        my $hpp = _minHPpct();
        if ($hpp > 0) {
            my $mhp = _hp_pct_m($m);
            next if $mhp < $hpp;
        }
        
        push @candidates, [$m, $d];
    }
    
    return unless @candidates;
    
    # เรียงตามระยะใกล้สุด
    @candidates = sort { $a->[1] <=> $b->[1] } @candidates;
    my $target = $candidates[0]->[0];
    my $dist   = $candidates[0]->[1];
    
    # ไม่ไปซ้ำเป้าปัจจุบัน (เลี่ยงสแปม)
    if ($char->{target} && $char->{target} eq $target->{ID}) {
        return;
    }
    
    debug sprintf("[SmartNearestTarget] attack id=%s name=%s dist=%d\n",
        $target->{ID}, ($target->{name}||'?'), $dist);
    
    # ใช้ $char->attack() แทน Commands::run
    $char->attack($target->{ID});
}

message "[SmartNearestTarget] v1.3 loaded (Fixed & SmartRouteAI aware)\n", "system";
1;