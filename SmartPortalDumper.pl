#==========================================================
# SmartPortalDumper.pl  v1.1  (no getTableFile dependency)
# - ดึง "จุดวาปทั้งแผนที่" ของแมพปัจจุบันจาก tables/portals.txt
# - ไม่เรียก Settings::getTableFile (รองรับบิลด์ที่ไม่มีเมธอดนี้)
# - สแกนหาไฟล์จาก @Settings::tablesFolders และ $Settings::tablesFolder
# - คำสั่ง: portal.dump [live|<dest_substr>]
#==========================================================
package SmartPortalDumper;
use strict;
use warnings;

use Plugins;
use Globals qw($field %portals @portalsID $char);
use Log qw(message warning error);
use Commands;
use Settings;
use File::Spec;

my ($hooks, $cmd);

Plugins::register(
    'SmartPortalDumper',
    'Dump ALL portals of current map (from tables)',
    \&onUnload
);

$hooks = Plugins::addHooks(
    ['start3',     \&onStart3],
    ['map_loaded', \&onMapLoaded],
);

$cmd = Commands::register([
    'portal.dump',
    'Dump portals of current map. Usage: portal.dump [live|<dest_map_substr>]',
    \&cmd_dump
]);

sub onUnload {
    Plugins::delHooks($hooks) if $hooks;
    Commands::unregister($cmd) if $cmd;
    message "[PortalDumper] Plugin unloaded.\n";
}

sub onStart3    { _dump_from_tables(); }
sub onMapLoaded { _dump_from_tables(); }

sub cmd_dump {
    my (undef, $args) = @_;
    $args ||= '';
    if ($args =~ /\blive\b/i) {
        _dump_live();
    } else {
        _dump_from_tables($args);
    }
}

#--------------------- locate portals.txt safely ---------------------
sub _locate_portals_file {
    my @candidates;

    # 1) โฟลเดอร์ tables หลัก (ตัวแปรเก่า)
    if (defined $Settings::tablesFolder && $Settings::tablesFolder ne '') {
        push @candidates, File::Spec->catfile($Settings::tablesFolder, 'portals.txt');
    }

    # 2) รายการ tablesFolders (ตัวแปรใหม่/หลาย region)
    #   อย่าใช้ defined(@array) -> ใช้ @array แทน
    if (@Settings::tablesFolders) {
        for my $dir (@Settings::tablesFolders) {
            next unless defined $dir && $dir ne '';
            push @candidates, File::Spec->catfile($dir, 'portals.txt');
        }
    }

    # 3) fallback: ./tables/portals.txt (โฟลเดอร์ที่รันอยู่)
    push @candidates, File::Spec->catfile(File::Spec->curdir(), 'tables', 'portals.txt');

    # คืนไฟล์แรกที่เจอ
    for my $p (@candidates) {
        return $p if defined $p && -e $p;
    }

    # log ไว้ช่วยดีบัก
    warning "[PortalDumper] portals.txt not found. Checked paths:\n";
    for my $p (@candidates) { message "  - $p\n" if defined $p; }
    return undef;
}

#--------------------- TABLE-BASED (ทั้งแผนที่) ---------------------
sub _dump_from_tables {
    my ($dest_filter) = @_;

    unless ($field) {
        warning "[PortalDumper] Field not ready yet.\n";
        return;
    }

    my $map = eval { $field->baseName } // eval { $field->name } // '(unknown)';
    message "========== [PortalDumper] Current map (TABLE): $map ==========\n";

    my $pt_path = _locate_portals_file();
    unless ($pt_path) {
        error "[PortalDumper] Could not locate portals.txt\n";
        return;
    }
    message "[PortalDumper] Using portals file: $pt_path\n";

    open my $fh, '<', $pt_path or do {
        error "[PortalDumper] Failed to open $pt_path : $!\n";
        return;
    };

    my ($cx, $cy);
    if (defined $char && $char->position) {
        $cx = $char->position->{x};
        $cy = $char->position->{y};
    }

    my $n = 0;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n$//;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;

        # รูปแบบพื้นฐาน: srcMap srcX srcY destMap destX destY [อื่นๆ...]
        my @t = split /\s+/, $line;
        for my $i (0..$#t) { $t[$i] =~ s/\.(gat|rsw)$//i; }
        next unless @t >= 6;

        my ($smap, $sx, $sy, $dmap, $dx, $dy) = @t[0,1,2,3,4,5];
        next unless defined $smap && lc($smap) eq lc($map);
        next unless defined $sx && $sx =~ /^\d+$/ && defined $sy && $sy =~ /^\d+$/;

        if (defined $dest_filter && $dest_filter ne '') {
            next unless defined $dmap && $dmap ne '' && $dmap =~ /$dest_filter/i;
        }

        my $dest_str = '';
        if (defined $dmap && $dmap ne '') {
            $dest_str = " -> $dmap";
            $dest_str .= " ($dx,$dy)" if (defined $dx && $dx =~ /^\d+$/ && defined $dy && $dy =~ /^\d+$/);
        }

        my $dist = '';
        if (defined $cx && defined $cy) {
            my $d = int( sqrt(($sx-$cx)**2 + ($sy-$cy)**2) + 0.5 );
            $dist = " [~$d cells]";
        }

        $n++;
        message sprintf("[PortalDumper:T] #%02d at (%d,%d)%s%s\n", $n, $sx, $sy, $dest_str, $dist);
    }
    close $fh;

    message "========== [PortalDumper] (TABLE) Found $n portal(s) ==========\n";
}

#--------------------- LIVE (เฉพาะที่เห็นรอบตัว) -------------------
sub _dump_live {
    unless ($field) {
        warning "[PortalDumper] Field not ready yet.\n";
        return;
    }
    my $map = eval { $field->baseName } // eval { $field->name } // '(unknown)';
    message "========== [PortalDumper] Current map (LIVE): $map ==========\n";

    if (!@portalsID) {
        message "[PortalDumper] No live portals visible on this map.\n";
        return;
    }
    my $n = 0;
    foreach my $id (@portalsID) {
        my $p = $portals{$id};
        next unless $p;
        my ($sx, $sy) = ('?', '?');
        if ($p->{pos}) {
            $sx = defined $p->{pos}{x} ? $p->{pos}{x} : $sx;
            $sy = defined $p->{pos}{y} ? $p->{pos}{y} : $sy;
        }
        my $dest_info = '';
        if ($p->{dest}) {
            my $dm = $p->{dest}{map} // '';
            my $dx = ($p->{dest}{pos} && defined $p->{dest}{pos}{x}) ? $p->{dest}{pos}{x} : '';
            my $dy = ($p->{dest}{pos} && defined $p->{dest}{pos}{y}) ? $p->{dest}{pos}{y} : '';
            if ($dm ne '') {
                $dest_info = " -> $dm";
                $dest_info .= " ($dx,$dy)" if ($dx ne '' && $dy ne '');
            }
        }
        $n++;
        message sprintf("[PortalDumper:L] #%02d at (%s,%s)%s\n", $n, $sx, $sy, $dest_info);
    }
    message "========== [PortalDumper] (LIVE) Found $n portal(s) ==========\n";
}

1;
# End of file
