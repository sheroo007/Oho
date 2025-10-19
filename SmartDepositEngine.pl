#==========================================================
# SmartDepositEngine.pl v1.7-final
# - Cart → Storage when storage opens (items_control: name + 6/7 tail ints)
# - Robust args parsing (quoted names like "Red Potion")
# - Hooks cover slash/underscore/old styles
# - SmartCore fallback (mutex) if SmartCore.pm is missing
#==========================================================
package SmartDepositEngine;

use strict;
use warnings;
use Plugins;
use Globals;
use Utils;
use Log qw(message warning error);
use Settings;
use Commands;
use Misc;
use AI;

use File::Basename ();
BEGIN {
    my $DIR = File::Basename::dirname(__FILE__);
    unshift @INC, $DIR if $DIR && -d $DIR;

    my $ok = eval { require SmartCore; SmartCore->import(qw(mutex_acquire mutex_release mutex_owner broadcast_reload smart_path)); 1 };
    if (!$ok) {
        our %_SMART_MUTEX; require Time::HiRes;
        *mutex_acquire = sub {
            my ($name,$owner,$ttl)=@_; $name||='unnamed'; $owner||='unknown'; $ttl||=30;
            my $now=Time::HiRes::time();
            if (my $h=$_SMART_MUTEX{$name}) {
                delete $_SMART_MUTEX{$name} if ($h->{until} && $h->{until} < $now);
                return 0 if ($h->{owner} && $h->{owner} ne $owner);
            }
            $_SMART_MUTEX{$name}={owner=>$owner, until=>$now+$ttl}; 1;
        };
        *mutex_release = sub { my ($name,$owner)=@_; delete $_SMART_MUTEX{$name} if $_SMART_MUTEX{$name}; 1; };
        *mutex_owner   = sub { my ($name)=@_; $_SMART_MUTEX{$name}{owner} };
        *broadcast_reload = sub {};
        *smart_path       = sub { Settings::getControlFilename('smart.txt') };
    }
}

our $VERSION = '1.7';

my $hooks;
my %rules_by_lcname = ();    # lc(name) => { name,min,store,sell,putCart,getCart,pullOnStorage }
my %state = (
    enabled      => 1,
    itemsFile    => undef,
    chunk        => 500,
    delay        => 0.2,     # seconds
    last_action  => 0,
    session      => 0,       # 1 while storage is open
);

Plugins::register('SmartDepositEngine', "Smart deposit engine $VERSION", \&onUnload);
$hooks = Plugins::addHooks(
    ['start3', \&onStart, undef],
    ['AI_pre', \&onAI, undef],

    # storage open/close hooks (cover multiple variants)
    ['packet/storage_open',   \&onStorageOpen,   undef],
    ['packet/storage_close',  \&onStorageClosed, undef],
    ['packet_storage_open',   \&onStorageOpen,   undef],
    ['packet_storage_close',  \&onStorageClosed, undef],
    ['packet_storage_opened', \&onStorageOpen,   undef],
    ['packet_storage_closed', \&onStorageClosed, undef],
    ['AI_storage_done',       \&onStorageClosed, undef],

    ['smart/config/reloaded', \&onSmartReloaded, undef],
);

sub onUnload { Plugins::delHooks($hooks); }
sub onStart { _load_config(); }
sub onSmartReloaded { message "[SmartDeposit] config reloaded\n","info"; _load_config(); }

sub _toi { my ($v)=@_; $v=0 unless defined $v; $v=~s/\D+//g; $v+0 }
sub _en  { $state{enabled} }

# ----------------------- config -----------------------
sub _load_config {
    $state{enabled}  = exists $config{smartDeposit_enabled} ? _toi($config{smartDeposit_enabled}) : 1;
    $state{chunk}    = exists $config{smartDeposit_chunk}   ? _toi($config{smartDeposit_chunk})   : 500;
    $state{delay}    = exists $config{smartDeposit_delay}   ? ($config{smartDeposit_delay}+0)     : 0.2;

    my $fn = exists $config{smartDeposit_itemsFile} ? $config{smartDeposit_itemsFile} : 'items_control.txt';
    $state{itemsFile} = Settings::getControlFilename($fn);
    _load_items_control();
}

# -------- getArgs-like argument splitter (supports quotes/escapes) --------
sub _split_args {
    my ($s)=@_;
    my @out; pos($s)=0;
    while ($s =~ /\G\s*(?:
            "((?:\\.|[^"\\])*)"   |   # double quoted
            '((?:\\.|[^'\\])*)'   |   # single quoted
            ([^\s"']+)                # bare
        )/gcx) {
        my $t = defined $1 ? $1 : (defined $2 ? $2 : $3);
        $t =~ s/\\([\\"'nrt])/
            $1 eq 'n' ? "\n" :
            $1 eq 'r' ? "\r" :
            $1 eq 't' ? "\t" : $1/eg;
        push @out, $t;
    }
    return @out;
}

# -------- parse one items_control line: name + 6/7 tail ints --------
sub _parse_items_line {
    my ($line)=@_;
    my @tok = _split_args($line);
    return unless @tok >= 6;

    for my $need (7,6) {
        next if @tok < $need;
        my @tail = @tok[-$need..-1];
        my $ok = 1; for (@tail) { $ok &&= /^\d+$/; }
        next unless $ok;

        my $name = join(' ', @tok[0..$#tok-$need]); $name =~ s/^\s+|\s+$//g;
        next unless length $name;

        my ($min,$store,$sell,$put,$get,$pull) =
            $need==7 ? @tail[0,1,2,3,4,5,6] : (@tail[0,1,2,3,4,5], undef);

        $pull = $store unless defined $pull;  # default if 7th col missing
        return ($name,$min,$store,$sell,$put,$get,$pull);
    }
    return;
}

sub _load_items_control {
    my $file = $state{itemsFile};
    unless (-e $file) { warning "[SmartDeposit] items_control file missing: $file\n"; return; }

    my %new;
    open my $fh, "<:encoding(UTF-8)", $file or do { warning "[SmartDeposit] cannot open $file: $!\n"; return; };
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/ || $line =~ /^\s*$/;

        my ($name,$min,$store,$sell,$put,$get,$pull) = _parse_items_line($line);
        next unless defined $name;

        $new{ _norm_name($name) } = {
            name=>$name, min=>_toi($min), store=>_toi($store), sell=>_toi($sell),
            putCart=>_toi($put), getCart=>_toi($get), pullOnStorage=>_toi($pull),
        };
    }
    close $fh;
    %rules_by_lcname = %new;
}

sub _norm_name { my ($s)=@_; $s=lc $s; $s =~ s/\s+/ /g; $s =~ s/^\s+|\s+$//g; $s }

# ------------------- storage open/close -------------------
sub onStorageOpen {
    return unless _en() && $char;

    unless (mutex_acquire("smart:storage","SmartDepositEngine", 120)) {
        warning "[SmartDeposit] Storage mutex busy by ".(mutex_owner("smart:storage")||"unknown")."\n";
        return;
    }
    my $st = $char->storage;
    unless ($st && $st->isReady) { warning "[SmartDeposit] storage not ready\n"; return; }

    $state{session}     = 1;
    $state{last_action} = 0;  # fire immediately
    _tick_storage();
}

sub onStorageClosed { _finish_session(); }

sub _finish_session {
    mutex_release("smart:storage","SmartDepositEngine");
    $state{session} = 0;
}

# ------------------------ AI loop -------------------------
sub onAI {
    return unless _en() && $char && $state{session};

    my $act = AI::action();
    return if $act && ($act eq 'npc' || $act eq 'shop' || $act eq 'deal');

    return if time - $state{last_action} < $state{delay};
    _tick_storage();
}

# ----------------------- core tick ------------------------
sub _tick_storage {
    $state{last_action} = time;

    # 1) cart -> storage (pullOnStorage=1)
    my $did = _pull_from_cart_and_store();
    return if $did;

    # 2) inventory -> storage (store=1, keep min)
    $did = _store_from_inventory();
    return if $did;
}

sub _store_from_inventory {
    my $inv = $char->inventory->getItems();
    for my $it (@$inv) {
        my $r = $rules_by_lcname{ _norm_name($it->{name}) } or next;
        next unless $r->{store};
        next if $it->{amount} <= ($r->{min} // 0);

        my $qty = $it->{amount} - ($r->{min} // 0);
        next unless $qty > 0;

        _dispatch(sprintf("storage add %d %d", $it->{binID}, $qty));
        return 1; # one command per tick
    }
    0;
}

# cart -> storage using: cart index > binID > quoted name
sub _pull_from_cart_and_store {
    my $cart = $char->cart->getItems();
    for my $it (@$cart) {
        my $r = $rules_by_lcname{ _norm_name($it->{name}) } or next;
        next unless $r->{pullOnStorage};
        next unless $it->{amount} > 0;

        my $batch = $it->{amount} > $state{chunk} ? $state{chunk} : $it->{amount};

        if (exists $it->{index}) {
            _dispatch(sprintf("storage addfromcart %d %d", $it->{index}, $batch));
        } elsif (exists $it->{binID}) {
            _dispatch(sprintf("storage addfromcart %d %d", $it->{binID}, $batch));
        } else {
            my $q = $it->{name}; $q =~ s/"/\\"/g;
            _dispatch(sprintf("storage addfromcart \"%s\" %d", $q, $batch));
        }
        return 1; # one command per tick
    }
    0;
}

sub _dispatch { my ($cmd)=@_; Commands::run($cmd); $state{last_action} = time; }

message "[SmartDeposit] Plugin loaded (v$VERSION) – cart-aware storage ready\n", "system";
1;
