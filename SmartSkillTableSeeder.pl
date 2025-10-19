#==========================================================
# SmartSkillTableSeeder.pl v1.5 – Profile-aware table seeder
# - Create smart_skill_table.txt in profiles/botX
# - Non-destructive append
# - Console commands
#==========================================================
package SmartSkillTableSeeder;

use strict;
use warnings;
use Plugins;
use Globals qw(%config);
use Log qw(message debug warning);
use Commands;
use Settings;
use File::Basename qw(dirname);
use File::Spec;
use File::Path qw(make_path);

my $hooks;

# ---------- Table template ----------
sub _table_template {
  return <<'TABLE_TXT';
# smart_skill_table.txt – Skill rotation for SmartAttackSkill
#
# FORMAT (CSV):
#   [skill],[enable 0|1],[factor],[mob>=N|0],[range<=R|0],[sp>=X|0]
#
# NOTES:
# - "skill" can be:
#     * Numeric ID (e.g. 2280)
#     * Internal handle (e.g. NC_AXETORNADO)
#     * Display name with quotes (e.g. "Axe Tornado")
# - factor: empty = adaptive auto, number = manual override
# - Use 0 to disable a condition
# - Rotation order: controlled by 'skill_tester_order' in smart.txt
# - Reload: smartreload
#
# EXAMPLES:
"Axe Tornado", 1, 1.25, >=3, <=2, 10
Bash, 0, 1.10, 0, 0, 10

TABLE_TXT
}

# ---------- Safe path resolution (profile-aware) ----------
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

sub _smart_txt_path {
  my $core = _smart_core_path();
  return $core if defined $core && length $core;
  
  my $profile = eval { $Globals::config{profile} } // $config{profile} // '';
  if ($profile && $profile ne '' && $profile ne 'default') {
    my $pdir = "profiles/$profile";
    return "$pdir/smart.txt" if -d $pdir;
    return "$pdir/smart.txt";
  }
  
  my $default = eval { Settings::getControlFilename('smart.txt') };
  return $default if defined $default && length $default;
  
  return 'control/smart.txt';
}

sub _table_path {
  my $smart = _smart_txt_path();
  
  unless (defined $smart && length $smart) {
    my $profile = eval { $Globals::config{profile} } // $config{profile} // '';
    if ($profile && $profile ne '' && $profile ne 'default') {
      return "profiles/$profile/smart_skill_table.txt";
    }
    return 'control/smart_skill_table.txt';
  }
  
  my $dir = dirname($smart);
  return File::Spec->catfile($dir, 'smart_skill_table.txt');
}

# ---------- IO helpers ----------
sub _write_new {
  my ($path, $content) = @_;
  my $dir = dirname($path);
  make_path($dir) unless -d $dir;
  
  open my $fh, ">:encoding(UTF-8)", $path or do { 
    warning "[SmartSkillTableSeeder] Cannot write: $path\n"; 
    return 0; 
  };
  print $fh $content; 
  close $fh; 
  return 1;
}

sub _append_line {
  my ($path, $line) = @_;
  my $dir = dirname($path);
  make_path($dir) unless -d $dir;
  
  open my $fh, ">>:encoding(UTF-8)", $path or do { 
    warning "[SmartSkillTableSeeder] Cannot append: $path\n"; 
    return 0; 
  };
  print $fh $line; 
  print $fh "\n" unless $line =~ /\n\z/;
  close $fh; 
  return 1;
}

sub _read_all { 
  my ($p) = @_;
  return '' unless -e $p; 
  open my $fh, "<:encoding(UTF-8)", $p or return ''; 
  local $/; 
  my $s = <$fh>; 
  close $fh; 
  return $s;
}

# ---------- CSV / skill resolution ----------
my (%_handle2id, %_id2handle, %_name2handle, %_handle2name);

sub _load_skill_tables {
  return if %_handle2id;
  
  my $f1 = Settings::getTableFilename("SKILL_id_handle.txt");
  if ($f1 && -e $f1 && open my $fh, "<:encoding(UTF-8)", $f1) {
    while (my $line = <$fh>) {
      next if $line =~ /^\s*#/ || $line !~ /\S/;
      chomp $line;
      my ($id, $handle) = split /\s+/, $line, 2;
      next unless defined $id && defined $handle;
      $_handle2id{ uc $handle } = int($id);
      $_id2handle{ int($id) }   = uc $handle;
    }
    close $fh;
  }
  
  my $f2 = Settings::getTableFilename("skillnametable.txt");
  if ($f2 && -e $f2 && open my $fh2, "<:encoding(UTF-8)", $f2) {
    while (my $line = <$fh2>) {
      next if $line =~ /^\s*#/ || $line !~ /\S/;
      chomp $line;
      my ($handle, $name) = split /#/, $line, 3;
      next unless $handle && $name;
      $name =~ s/^\s+|\s+$//g;
      $_name2handle{ lc $name } = uc $handle;
      $_handle2name{ uc $handle } = $name;
    }
    close $fh2;
  }
}

sub _sanitize_skill {
  my ($s) = @_;
  $s //= '';
  $s =~ s/^\s+|\s+$//g;
  $s =~ s/\\(["'])/$1/g;
  while ($s =~ /\A(["'])(.*)\1\z/s) { 
    $s = $2; 
    $s =~ s/^\s+|\s+$//g; 
  }
  $s =~ s/\s+/ /g;
  return $s;
}

sub _canonical_skill_key_and_display {
  my ($spec) = @_;
  my $t = _sanitize_skill($spec);
  return (undef, undef) if $t eq '';
  
  _load_skill_tables();

  if ($t =~ /^\d+$/) {
    my $id = int($t);
    my $disp = $_handle2name{ $_id2handle{$id} // '' } // $t;
    return ("ID:$id", $disp);
  }
  
  if ($t =~ /^\S+$/) {
    my $H = uc $t;
    if (exists $_handle2id{$H}) {
      my $id = $_handle2id{$H};
      my $disp = $_handle2name{$H} // $t;
      return ("ID:$id", $disp);
    }
  }
  
  my $H2 = $_name2handle{ lc $t };
  if ($H2 && exists $_handle2id{$H2}) {
    my $id = $_handle2id{$H2};
    my $disp = $_handle2name{$H2} // $t;
    return ("ID:$id", $disp);
  }
  
  return ("NAME:".lc $t, $t);
}

sub _first_csv_field {
  my ($line) = @_;
  return undef unless defined $line;
  if ($line =~ /^\s*"((?:[^"\\]|\\.)*)"\s*,/ ) {
    my $s = $1; 
    $s =~ s/\\"/"/g; 
    return $s;
  } elsif ($line =~ /^\s*([^,]+)\s*,/ ) {
    return $1;
  }
  return undef;
}

sub _existing_keys_in_table {
  my ($text) = @_;
  my %have;
  for my $ln (split /\n/, ($text // '')) {
    next if $ln =~ /^\s*#/ || $ln !~ /\S/;
    my $tok = _first_csv_field($ln);
    next unless defined $tok;
    my ($key, undef) = _canonical_skill_key_and_display($tok);
    $have{$key} = 1 if defined $key;
  }
  return \%have;
}

sub _build_csv_line_from_args {
  my (%arg) = @_;
  my $skill_raw = $arg{skill} // '';
  my ($key, $disp) = _canonical_skill_key_and_display($skill_raw);
  return (undef, undef, "Cannot resolve skill spec '$skill_raw'") unless $key;

  my $skill_field = $skill_raw;
  my $need_quote = ($skill_raw !~ /^\d+$/ && $skill_raw !~ /^\S+$/) ? 1 : 0;
  $skill_field = "\"$skill_raw\"" if $need_quote;

  my $enable = defined $arg{enable} ? int($arg{enable}) : 1;
  my $factor = defined $arg{factor} ? $arg{factor} : '';
  $factor =~ s/,/./g if defined $arg{factor};

  my $mob    = defined $arg{mob}    ? int($arg{mob})    : 0;
  my $range  = defined $arg{range}  ? int($arg{range})  : 0;
  my $sp     = defined $arg{sp}     ? int($arg{sp})     : 0;

  my $mob_col   = $mob   > 0 ? ">=".$mob   : 0;
  my $range_col = $range > 0 ? "<=".$range : 0;
  my $sp_col    = $sp    > 0 ? $sp         : 0;

  my $line = sprintf("%s, %d, %s, %s, %s, %s",
    $skill_field,
    $enable,
    ($factor ne '' ? $factor : ''),
    $mob_col, $range_col, $sp_col
  );
  return ($key, $line, undef);
}

# ---------- Actions ----------
sub _bridge_reload {
  no strict 'refs';
  if (scalar keys %{"SmartAttackSkill::"}) {
    Commands::run('smartreload');
  }
}

sub _create_if_missing {
  my ($quiet) = @_;
  my $tbl = _table_path();
  
  if (-e $tbl) {
    message "[SmartSkillTableSeeder] Exists: $tbl\n", "info" unless $quiet;
    return 0;
  }
  
  my $ok = _write_new($tbl, _table_template());
  if ($ok) {
    message "[SmartSkillTableSeeder] ✅ Created: $tbl\n", "success" unless $quiet;
    Plugins::callHook('smart/table/created', { path => $tbl });
    _bridge_reload();
    return 1;
  }
  return 0;
}

sub _force_write {
  my ($quiet) = @_;
  my $tbl = _table_path();
  my $ok  = _write_new($tbl, _table_template());
  
  if ($ok) {
    message "[SmartSkillTableSeeder] ✅ Force wrote: $tbl\n", "success" unless $quiet;
    Plugins::callHook('smart/table/created', { path => $tbl, force => 1 });
    _bridge_reload();
    return 1;
  }
  return 0;
}

sub _append_skill_row {
  my (%arg) = @_;
  my $tbl = _table_path();
  my $text = _read_all($tbl);
  
  if ($text eq '') {
    _create_if_missing(1);
    $text = _read_all($tbl);
  }

  my $have = _existing_keys_in_table($text);
  my ($key, $line, $err) = _build_csv_line_from_args(%arg);
  
  if ($err) { 
    warning "[SmartSkillTableSeeder] $err\n"; 
    return 0; 
  }

  if ($have->{$key}) {
    message "[SmartSkillTableSeeder] Skip: skill exists ($arg{skill})\n", "info";
    return 0;
  }

  my $ok = _append_line($tbl, $line);
  if ($ok) {
    message "[SmartSkillTableSeeder] ✅ Appended: $line\n", "success";
    Plugins::callHook('smart/table/appended', { 
      path => $tbl, 
      skill => $arg{skill}, 
      line => $line 
    });
    _bridge_reload();
    return 1;
  }
  return 0;
}

# ---------- CLI parsing ----------
sub _parse_add_args {
  my ($argstr) = @_;
  $argstr //= '';
  my %out;

  if ($argstr =~ /^\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*(.*)$/) {
    $out{skill} = $1; 
    $out{skill} =~ s/\\"/"/g;
    $argstr = $2;
  } elsif ($argstr =~ /^\s*([^\s=<>]+)\s*(.*)$/) {
    $out{skill} = $1;
    $argstr = $2;
  } else {
    return (undef, "Missing <skill> argument");
  }

  while ($argstr =~ /(\benable\s*=\s*(\d+))|(\bfactor\s*=\s*([0-9.,]+))|(\bmob\s*(?:>=|=)\s*(\d+))|(\brange\s*(?:<=|=)\s*(\d+))|(\bsp\s*(?:>=|=)\s*(\d+))/gi) {
    $out{enable} = $2 if defined $2;
    $out{factor} = $4 if defined $4;
    $out{mob}    = $6 if defined $6;
    $out{range}  = $8 if defined $8;
    $out{sp}     = $10 if defined $10;
  }

  return (\%out, undef);
}

# ---------- Commands ----------
Commands::register(['smarttable', 'Manage smart_skill_table.txt. Usage: smarttable [check|force|add ...]', sub {
  my (undef, $args) = @_;
  $args //= '';
  
  if ($args =~ /\bcheck\b/i) {
    my $tbl = _table_path();
    message "[SmartSkillTableSeeder] Path: $tbl\n", "system";
    message "[SmartSkillTableSeeder] Exists: " . (-e $tbl ? "YES" : "NO") . "\n", "system";
    
  } elsif ($args =~ /\bforce\b/i) {
    _force_write(0);
    
  } elsif ($args =~ /\badd\b/i) {
    $args =~ s/^\s*add\s+//i;
    my ($h, $err) = _parse_add_args($args);
    if ($err) { 
      warning "[SmartSkillTableSeeder] $err\n"; 
      return; 
    }
    _append_skill_row(%$h);
    
  } else {
    _create_if_missing(0);
  }
}]);

# ---------- Hooks ----------
Plugins::register('SmartSkillTableSeeder', 'Skill table seeder v1.5 (profile-aware)', \&onUnload);

$hooks = Plugins::addHooks(
  ['start3', sub { _create_if_missing(1); }, undef],
);

sub onUnload { 
  Plugins::delHooks($hooks) if $hooks; 
}

message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", "system";
message "[SmartSkillTableSeeder] v1.5 Profile-aware ✓\n", "system";
message "✅ Creates in: profiles/\$profile/smart_skill_table.txt\n", "system";
message "✅ Non-destructive append\n", "system";
message "✅ Console: smarttable [check|force|add ...]\n", "system";
message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", "system";

1;