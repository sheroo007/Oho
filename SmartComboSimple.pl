#==========================================================
# SmartComboSimple.pl v1.4.1 (safe autosell)
# - Adds delay and AI clear before autosell
#==========================================================
package SmartComboSimple;
use strict;
use warnings;
use Plugins;
use Globals qw(%config $field $char);
use Log qw(message warning debug);
use Time::HiRes qw(time);
use AI;
use Commands;

# Import SmartCore teleport helpers (with safe fallback)
use File::Basename ();
BEGIN {
    my $DIR = File::Basename::dirname(__FILE__);
    unshift @INC, $DIR if $DIR && -d $DIR;
    eval { require SmartCore; SmartCore->import(qw(smart_tele smart_tele2)); 1 } or do {
        *smart_tele  = sub { my ($m,%o)=@_; eval { ai_useTeleport($m); 1 } ? 1 : 0 };
        *smart_tele2 = sub { my (%o)=@_; smart_tele(2,%o) };
    };
}

our $VERSION = '1.4.1';

#------------------------- config helpers -------------------------
sub _cfg { my ($k,$d)=@_; return exists $config{$k} ? $config{$k} : $d }
sub _toi { my ($v)=@_; $v//=0; $v=~s/\D+//g; $v+0 }

sub _enabled   () { _toi(_cfg('smartSimple_enabled',        1)) }
sub _save_en   () { _toi(_cfg('smartSimple_save_enabled',   1)) }
sub _lock_en   () { _toi(_cfg('smartSimple_lock_enabled',   1)) }
sub _cmd       () {       _cfg('smartSimple_autosell_cmd',  'autosell') }
sub _pPct      () { _toi(_cfg('smartSimple_player_over_pct',85)) }
sub _cPct      () { _toi(_cfg('smartSimple_cart_over_pct',  90)) }
sub _autoDelay () {      (_cfg('smartSimple_autosell_delay_ms',600)+0) / 1000.0 }
sub _chkGap    () {      (_cfg('smartSimple_over_check_ms', 500)+0) / 1000.0 }
sub _tpCD      () {      (_cfg('smartSimple_teleport_cool_ms',1200)+0) / 1000.0 }

#------------------------- state -------------------------
my $hooks;
my %S = (
    last_check_ts   => 0,
    last_tele_ts    => 0,
    arrived_ts      => 0,
    autosell_done   => 0,
);

Plugins::register('SmartComboSimple', "SmartComboSimple $VERSION", \&onUnload);
$hooks = Plugins::addHooks(
    ['start3',                \&onStart,  undef],
    ['reloadFiles',           \&onStart,  undef],
    ['packet/map_loaded',     \&onMap,    undef],
    ['packet/map_change',     \&onMap,    undef],
    ['AI_pre',                \&onAI,     undef],
    ['smart/config/reloaded', \&onSmart,  undef],
);

sub onUnload { Plugins::delHooks($hooks) if $hooks; }
sub onStart  { %S = (%S, last_check_ts=>0, last_tele_ts=>0); }
sub onSmart  { message "[SmartComboSimple] Config reloaded\n","info"; }

sub _map_name { return $field ? ($field->can('baseName') ? $field->baseName : $field->name) : '' }
sub _in_savemap  { my $save=$config{saveMap}//''; my $m=_map_name(); ($save && $m && lc($m) eq lc($save)) ? 1 : 0 }
sub _in_lockmap  { my $lock=$config{lockMap}//''; my $m=_map_name(); ($lock && $m && lc($m) eq lc($lock)) ? 1 : 0 }

sub onMap {
    $S{arrived_ts}    = time;
    $S{autosell_done} = 0;
}
#------------------------- busy/weight helpers -------------------------
sub _busy_now {
    my $a = AI::action() || '';
    return 1 if $a =~ /^(attack|skill_use|take|npc|storage|shop|deal|route)$/;
    return 0;
}
sub _player_pct {
    return 0 unless $char && $char->{weight_max};
    my $pct = int( ( ($char->{weight}||0) * 100 ) / ($char->{weight_max}||1) );
    return $pct;
}
sub _cart_pct {
    return 0 unless $char && $char->{cart} && $char->{cart}{weight_max};
    my $pct = int( ( ($char->{cart}{weight}||0) * 100 ) / ($char->{cart}{weight_max}||1) );
    return $pct;
}

sub _use_central_teleport_to_save {
    return SmartCore::smart_tele2();
}

#------------------------- main AI loop -------------------------
sub onAI {
    return unless _enabled() && $char && $field;
    my $now = time;

    # 1) SaveMap: autosell once per arrival
    if (_save_en() && _in_savemap()) {
        if (!$S{autosell_done} && ($now - $S{arrived_ts} >= _autoDelay()) && !_busy_now()) {
            my $cmd = _cmd();
            message "[SmartComboSimple] autosell at saveMap via '$cmd'\n","system";
            AI::clear('all');                      # เคลียร์ AI ก่อน
            Commands::run("pause 1");              # รอ 1 วินาทีเพื่อความปลอดภัย
            eval { Commands::run($cmd); 1 } or do { warning "[SmartComboSimple] autosell failed: $@\n" };
            $S{autosell_done} = 1;
        }
    }

    # 2) LockMap: overweight return
    return if _busy_now();
    return if $now - $S{last_check_ts} < _chkGap();
    $S{last_check_ts} = $now;

    return unless _lock_en() && _in_lockmap();
    return if $now - $S{last_tele_ts} < _tpCD();

    my $pp = _player_pct();
    my $cp = _cart_pct();
    if ($cp >= _cPct()) {
        message "[SmartComboSimple] Overweight cart=$cp% -> return\n","info";
        if (_use_central_teleport_to_save()) { $S{last_tele_ts} = $now; }
    } elsif ($pp >= _pPct()) {
        message "[SmartComboSimple] Overweight player=$pp% -> return\n","info";
        if (_use_central_teleport_to_save()) { $S{last_tele_ts} = $now; }
    }
}

message "[SmartComboSimple] Loaded v$VERSION\n","system";
1;
