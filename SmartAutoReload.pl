#==========================================================
# SmartAutoReload.pl v1.2 — profile-aware control watcher + SmartCore
# - เฝ้าโฟลเดอร์ smart.txt ของโปรไฟล์ปัจจุบัน (SmartCore::smart_path() ถ้ามี)
# - ส่งฮุค: smart:file_changed / smart:file_created / smart:file_deleted
# - Bridge อัตโนมัติ: smart.txt / smart_skill_table.txt → Commands::run('smartreload')
# - ปรับโฟลเดอร์อัตโนมัติเมื่อสลับโปรไฟล์
#==========================================================
package SmartAutoReload;

use strict;
use warnings;
use Plugins;
use Globals qw(%config);
use Log qw(message debug warning);
use Commands;
use Time::HiRes qw(time);
use Settings;
use File::Basename qw(dirname);

my %S = (
  dir        => undef,
  interval   => 1.2,
  recursive  => 0,
  last_scan  => 0,
  seen       => {},  # path -> {mtime,size}
);

# Try SmartCore for smart.txt path
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

sub _effective_dir {
  return $config{smart_auto_dir} if defined $config{smart_auto_dir} && -d $config{smart_auto_dir};
  
  my $smart = _smart_core_path();
  unless (defined $smart && length $smart) {
    $smart = eval { Settings::getControlFilename('smart.txt') };
  }
  
  unless (defined $smart && length $smart) {
    return 'control';
  }
  
  my $dir = dirname($smart);
  return -d $dir ? $dir : 'control';
}

Plugins::register('SmartAutoReload', 'Watch per-profile control dir (+SmartCore)', \&onUnload);
my $hooks = Plugins::addHooks(
  ['start3', \&onStart, undef],
  ['AI_pre', \&onTick,  undef],
);

Commands::register(['smartwatch', 'Immediate rescan', sub {
  _scan_now(1);
  message "[SmartAutoReload] manual scan done.\n","system";
}]);

sub onUnload { Plugins::delHooks($hooks) if $hooks; }

sub onStart {
  $S{interval}  = ($config{smart_auto_interval}//1.2)+0;
  $S{recursive} = int($config{smart_auto_recursive}//0);
  _rebind_dir();
}

sub onTick {
  my $dir_now = _effective_dir();
  if (!defined $S{dir} || lc($dir_now) ne lc($S{dir})) {
    _rebind_dir();
    return;
  }
  my $now = time();
  return if ($now - $S{last_scan}) < $S{interval};
  _scan_now(0);
}

# ---------------- internals ----------------
sub _rebind_dir {
  $S{dir} = _effective_dir();
  if (!-d $S{dir}) { warning "[SmartAutoReload] dir not found: $S{dir}\n"; return; }
  $S{seen} = {};
  for my $p (_list_txt($S{dir}, $S{recursive})) {
    my ($mt,$sz) = _st($p);
    $S{seen}{$p} = {mtime=>$mt,size=>$sz} if defined $mt;
  }
  $S{last_scan} = time();
  message sprintf("[SmartAutoReload] watching '%s' every %.2fs %s\n",
    $S{dir}, $S{interval}, $S{recursive}?'(recursive)':''), "system";
}

sub _scan_now {
  my ($verbose)=@_;
  my %cur;
  for my $p (_list_txt($S{dir}, $S{recursive})) {
    my ($mt,$sz) = _st($p);
    $cur{$p} = {mtime=>$mt,size=>$sz} if defined $mt;
  }

  # created/changed
  for my $p (keys %cur) {
    if (!exists $S{seen}{$p}) {
      _emit('smart:file_created', $p, $cur{$p});
      _bridge($p);
      debug "[SmartAutoReload] + $p\n" if $verbose;
    } elsif (_diff($S{seen}{$p}, $cur{$p})) {
      _emit('smart:file_changed', $p, $cur{$p});
      _bridge($p);
      debug "[SmartAutoReload] * $p\n" if $verbose;
    }
  }
  # deleted
  for my $p (keys %{ $S{seen} }) {
    next if exists $cur{$p};
    _emit('smart:file_deleted', $p, $S{seen}{$p});
    debug "[SmartAutoReload] - $p\n" if $verbose;
  }

  $S{seen} = \%cur;
  $S{last_scan} = time();
}

sub _emit {
  my ($hook,$path,$meta)=@_;
  my ($name) = ($path =~ m{([^/\\]+)$});
  Plugins::callHook($hook, { path=>$path, name=>$name, ext=>($name=~m/(\.[^.]+)$/ ? $1 : ''), mtime=>$meta->{mtime}, size=>$meta->{size} });
}

sub _bridge {
  my ($p)=@_;
  my $lp = lc $p;
  return unless ($lp =~ /(?:^|[\/\\])smart\.txt$/ || $lp =~ /(?:^|[\/\\])smart\_skill\_table\.txt$/);
  Commands::run('smartreload'); # let SmartAttackSkill refresh itself
}

sub _list_txt {
  my ($root,$rec)=@_;
  my @out;
  _walk($root,$rec, sub {
    my ($p)=@_;
    return if $p =~ /(?:\.swp|\.swo|\.tmp|~)$/i;
    return unless $p =~ /\.txt$/i;
    push @out,$p;
  });
  return @out;
}
sub _walk {
  my ($dir,$rec,$cb)=@_;
  return unless -d $dir;
  opendir(my $dh,$dir) or return;
  while (defined(my $e=readdir($dh))) {
    next if $e eq '.' || $e eq '..';
    my $p = "$dir/$e";
    if (-d $p) { _walk($p,$rec,$cb) if $rec; }
    else { $cb->($p); }
  }
  closedir $dh;
}
sub _st   { my ($p)=@_; return undef unless -f $p; my @s=stat($p); return ($s[9],$s[7]); }
sub _diff { my ($a,$b)=@_; ($a->{mtime}!=$b->{mtime} || $a->{size}!=$b->{size}) }

1;
