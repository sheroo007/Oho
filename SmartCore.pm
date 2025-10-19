package SmartCore;
use strict;
use warnings;
use Exporter 'import';
use Settings;
use Plugins;
use Log qw(message warning debug);
use Time::HiRes qw(time);
use AI;
use Globals qw(%config $char $field);

our @EXPORT_OK = qw(
    smart_path broadcast_reload
    smart_tele smart_tele2
    mutex_acquire mutex_release mutex_peek
    gate_init smart_is_idle_for smart_busy_reason smart_can_telehunt gate_state gate_touch
);
our $VERSION = '2.1-activity-gate';

sub smart_path { Settings::getControlFilename('smart.txt') }
sub broadcast_reload {
    my ($reason) = @_;
    $reason ||= 'manual';
    Plugins::callHook('smart/config/reloaded', { reason => $reason, file => smart_path() });
    message "[SmartCore] Broadcast smart/config/reloaded ($reason)\n","info";
}

my %MUTEX;
sub mutex_acquire {
    my ($key, $ttl) = @_;
    $ttl ||= 2;
    my $now = time;
    my $ent = $MUTEX{$key};
    if ($ent && ($now - $ent->{ts} < $ttl)) { return 0; }
    $MUTEX{$key} = { ts => $now, ttl => $ttl };
    return 1;
}
sub mutex_peek {
    my ($key) = @_;
    my $ent = $MUTEX{$key} or return 0;
    return (time - $ent->{ts} < ($ent->{ttl}||2)) ? 1 : 0;
}
sub mutex_release { my ($key)=@_; delete $MUTEX{$key}; 1 }

sub _try_ai_useTeleport {
    my ($mode) = @_;
    no strict 'refs';
    if (defined &{"main::ai_useTeleport"}) {
        eval { &{"main::ai_useTeleport"}($mode); 1 } or return 0;
        return 1;
    }
    return 0;
}
sub _try_commands {
    my ($mode) = @_;
    eval { require Commands; Commands::run("tele $mode"); 1 } or return 0;
    return 1;
}
sub smart_tele {
    my ($mode, %opt) = @_;
    $mode = ($mode && $mode == 2) ? 2 : 1;
    return 1 if _try_ai_useTeleport($mode);
    return 1 if _try_commands($mode);
    warning "[SmartCore] teleport failed (mode=$mode)\n";
    return 0;
}
sub smart_tele2 { my (%opt)=@_; return smart_tele(2,%opt) }

my %G = (
    ts => {
        attack_start=>0, attack_end=>0,
        skill=>0, take_start=>0, take_end=>0,
        route_start=>0, route_end=>0,
        npc=>0, storage=>0, shop=>0, deal=>0,
        dmg_in=>0, dmg_out=>0, ai_pre=>0, ai_post=>0,
    },
    busy_reason => '',
);
my $gate_hooks;

sub gate_state { return \%G }
sub gate_touch {
    my ($key) = @_;
    $G{ts}{$key} = time if exists $G{ts}{$key};
}
sub _ai_action { AI::action() || '' }
sub _now      { time }

sub _update_busy_reason {
    my $a = _ai_action();
    my $r = '';
    if    ($a =~ /^(npc)$/)                          { $r='npc' }
    elsif ($a =~ /^(storage)$/)                      { $r='storage' }
    elsif ($a =~ /^(shop|deal)$/)                    { $r='shop' }
    elsif ($a =~ /^(attack|skill_use)$/)             { $r='attack' }
    elsif ($a =~ /^(take|items_take)$/)              { $r='take' }
    elsif ($a =~ /^(route)$/)                        { $r='route' }
    elsif ($a =~ /^(sit|stand)$/)                    { $r='pose' }
    else                                             { $r='' }
    $G{busy_reason} = $r;
}

sub gate_init {
    return if $gate_hooks;
    $gate_hooks = Plugins::addHooks(
        ['AI_pre', sub { $G{ts}{ai_pre}=_now(); _update_busy_reason(); }, undef],
        ['AI_post', sub { $G{ts}{ai_post}=_now(); }, undef],
        ['AI::attack_start', sub { $G{ts}{attack_start}=_now(); }, undef],
        ['AI::attack_end',   sub { $G{ts}{attack_end}=_now();   }, undef],
        ['AI::take_start',   sub { $G{ts}{take_start}=_now();   }, undef],
        ['AI::take_end',     sub { $G{ts}{take_end}=_now();     }, undef],
        ['AI::route_start',  sub { $G{ts}{route_start}=_now();  }, undef],
        ['AI::route_end',    sub { $G{ts}{route_end}=_now();    }, undef],
        ['AI::NPC::storage_start', sub { $G{ts}{storage}=_now(); }, undef],
        ['AI::NPC::storage_done',  sub { $G{ts}{storage}=_now(); }, undef],
        ['AI::NPC::sell_start',    sub { $G{ts}{shop}=_now();    }, undef],
        ['AI::NPC::sell_done',     sub { $G{ts}{shop}=_now();    }, undef],
    );
    message "[SmartCore] ActivityGate initialized\n","info";
}

sub smart_is_idle_for {
    my ($sec) = @_;
    $sec = 0+$sec;
    my $now = _now();
    my $max_busy = 0;
    foreach my $k (qw(attack_start take_start route_start npc storage shop deal ai_pre)) {
        my $t = $G{ts}{$k} || 0;
        $max_busy = $t if $t > $max_busy;
    }
    return ($now - $max_busy) >= $sec ? 1 : 0;
}
sub smart_busy_reason { return $G{busy_reason} || '' }

sub _map_name { return $field ? ($field->can('baseName') ? $field->baseName : $field->name) : '' }
sub _in_save  { my $save=$config{saveMap}//''; my $m=_map_name(); ($save && $m && lc($m) eq lc($save)) ? 1 : 0 }
sub _in_lock  { my $lock=$config{lockMap}//''; my $m=_map_name(); ($lock && $m && lc($m) eq lc($lock)) ? 1 : 0 }

sub smart_can_telehunt {
    my (%opt) = @_;
    gate_init();
    return 0 if _in_save();
    return 0 unless _in_lock();
    my $quiet = ($opt{quiet} // ($config{smartTeleHunter_activityQuietSeconds}//0.8))+0;
    return 0 unless smart_is_idle_for($quiet);
    if ($char) {
        my $hp = $char->{hpPercent} // 100;
        my $sp = $char->{spPercent} // 100;
        my $hpMin = ($opt{hpMin}//($config{smartTeleHunter_hpSafeMin}//0))+0;
        my $spMin = ($opt{spMin}//($config{smartTeleHunter_spMin}//0))+0;
        return 0 if $hp < $hpMin;
        return 0 if $sp < $spMin;
    }
    return 0 if mutex_peek('smart/attack');
    return 1;
}

1;
