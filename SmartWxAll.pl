# SmartWxAll.pl
# Core Wx realtime monitor (Monsters + Items + Self/Statuses + Truth) — v1.4
# - Tabs: Monsters, Items, Self+Truth
# - Exposes API:   my $snap = SmartWxAll::get_snapshot();
#   Structure:
#     $snap->{monsters} = [ { id=>UID, classid=>ClassID, name, x,y, dist, hp_pct, ks_ok }... ]
#     $snap->{items}    = [ { id=>UID, itemid=>NameID,   name, x,y, dist, qty }... ]
#     $snap->{self}     = { map, x,y, action, statuses => [ {handle, name, id}... ] }
#     $snap->{truth}    = { monsters_nonempty, items_nonempty, self_action_nonempty }
# - Broadcasts hook on every repaint or data change:
#     Plugins::callHook('smartwx/snapshot', { snapshot => \%SNAP });
# - Config (config.txt or control/smart.txt):
#     smartwx.enabled       1
#     smartwx.update_ms     1        # min 1ms (if OS allows)
#     smartwx.radius_mon    10
#     smartwx.radius_item   10
#     smartwx.max_rows      60
#     smartwx.start_hidden  0
package SmartWxAll;
use strict;
use warnings;
use Plugins;
use Log qw(message warning error);
use Globals;
use Utils qw(calcPosition distance);
use Field qw(isReachable); # <--- เพิ่มตัวเช็คทางเดิน
use Scalar::Util qw(blessed);
use Time::HiRes qw(time);
use constant HAVE_WX => eval { require Wx; Wx->import(qw(:everything)); 1 } || 0;

my ($hooks, $frame, $tabs, $lv_mon, $lv_item, $lvTruth, $lvStatus, $timer);
my ($txtMap, $txtPos, $txtAct);
my $READY   = 0;
my $VISIBLE = 1;
my $last_sig = '';
my %SNAP = (monsters=>[], items=>[], self=>{map=>'-',x=>undef,y=>undef,action=>'-',statuses=>[]}, truth=>{monsters_nonempty=>0,items_nonempty=>0,self_action_nonempty=>0});

Plugins::register('SmartWxAll', 'Core Wx monitor + snapshot API', \&unload);
$hooks = Plugins::addHooks(
  ['AI_pre',             \&ensure_ui],
  ['packet/map_loaded',  \&refresh_now],
  ['Commands::run/post', \&on_command],
);

sub unload {
  Plugins::delHooks($hooks) if $hooks;
  if ($timer) { $timer->Stop; undef $timer; }
  if ($frame) { eval { $frame->Destroy }; undef $frame; }
  message "[SmartWxAll] unloaded.\n";
}

sub get_snapshot { return \%SNAP }

sub on_command {
  my (undef, $args) = @_;
  return unless $args && $args->{switch} && $args->{switch} eq 'swx';
  my $arg = $args->{args} // '';
  if ($arg =~ /^(?:on|show)$/i)      { _show(1); }
  elsif ($arg =~ /^(?:off|hide)$/i)  { _show(0); }
  else                               { _show(!$VISIBLE); }
  $args->{return} = 1;
}

sub _cfg_num  { my ($k,$d)=@_; my $v=$Globals::config{$k}; return (defined $v && $v=~/^-?\d+(?:\.\d+)?$/)?0+$v:$d; }
sub _cfg_bool { my ($k,$d)=@_; my $v=$Globals::config{$k}; return defined($v)?($v?1:0):($d?1:0); }
sub _you_pos { return $Globals::char ? calcPosition($Globals::char) : undef }

sub _is_my_id {
  my ($id) = @_; return 0 unless $id;
  return 1 if ($Globals::char && $Globals::char->{ID} && $id eq $Globals::char->{ID});
  if ($Globals::char && $Globals::char->{party} && $Globals::char->{party}{users}) {
    return 1 if exists $Globals::char->{party}{users}{$id};
  }
  no strict 'refs';
  if (defined &Misc::isMySlaveID) { return 1 if Misc::isMySlaveID($id); }
  use strict 'refs';
  return 0;
}

sub _monster_ks_ok {
  my ($m) = @_; return 0 unless $m;
  my $target = $m->{target};
  if ($target) { return _is_my_id($target) ? 1 : 0; }
  if ($m->{dmgFromPlayer} && ref $m->{dmgFromPlayer} eq 'HASH') {
    for my $pid (keys %{$m->{dmgFromPlayer}}) {
      next if _is_my_id($pid);
      return 0;
    }
  }
  return 1;
}

sub _show { my ($want)=@_; $VISIBLE=$want?1:0; return unless $frame; $frame->Show($VISIBLE?1:0); $frame->Raise if $VISIBLE; }

sub _parent_frame {
  return unless HAVE_WX;
  my $iface = $Globals::interface;
  return unless $iface && Scalar::Util::blessed($iface) && $iface->isa('Interface::Wx');
  return $iface->{frame} || $iface->{mainWin};
}

sub ensure_ui {
  return if $READY;
  return unless HAVE_WX;
  return unless _cfg_bool('smartwx.enabled', 1);
  my $parent = _parent_frame() or return;

  $frame = Wx::Frame->new($parent, -1, 'Smart Wx All', [-1,-1], [760, 420], Wx::wxDEFAULT_FRAME_STYLE() | Wx::wxFRAME_FLOAT_ON_PARENT());
  my $root = Wx::BoxSizer->new(Wx::wxVERTICAL());
  $tabs = Wx::Notebook->new($frame, -1, [-1,-1], [-1,-1]);

  my $p_mon = Wx::Panel->new($tabs, -1);
  my $s_mon = Wx::BoxSizer->new(Wx::wxVERTICAL());
  $lv_mon = Wx::ListView->new($p_mon, -1, [-1,-1], [-1,-1], Wx::wxLC_REPORT()|Wx::wxLC_SINGLE_SEL()|Wx::wxLC_HRULES()|Wx::wxLC_VRULES());
  $lv_mon->InsertColumn(0, 'ClassID', Wx::wxLIST_FORMAT_LEFT(), 90);
  $lv_mon->InsertColumn(1, 'Name',    Wx::wxLIST_FORMAT_LEFT(), 240);
  $lv_mon->InsertColumn(2, 'X',       Wx::wxLIST_FORMAT_RIGHT(), 50);
  $lv_mon->InsertColumn(3, 'Y',       Wx::wxLIST_FORMAT_RIGHT(), 50);
  $lv_mon->InsertColumn(4, 'Dist',    Wx::wxLIST_FORMAT_RIGHT(), 60);
  $lv_mon->InsertColumn(5, 'HP%',     Wx::wxLIST_FORMAT_RIGHT(), 60);
  $lv_mon->InsertColumn(6, 'KS OK',   Wx::wxLIST_FORMAT_LEFT(),  60);
  $s_mon->Add($lv_mon, 1, Wx::wxALL()|Wx::wxEXPAND(), 6);
  $p_mon->SetSizer($s_mon);
  $tabs->AddPage($p_mon, 'Monsters', 1);

  my $p_item = Wx::Panel->new($tabs, -1);
  my $s_item = Wx::BoxSizer->new(Wx::wxVERTICAL());
  $lv_item = Wx::ListView->new($p_item, -1, [-1,-1], [-1,-1], Wx::wxLC_REPORT()|Wx::wxLC_SINGLE_SEL()|Wx::wxLC_HRULES()|Wx::wxLC_VRULES());
  $lv_item->InsertColumn(0, 'ItemID', Wx::wxLIST_FORMAT_LEFT(), 90);
  $lv_item->InsertColumn(1, 'Name',   Wx::wxLIST_FORMAT_LEFT(), 320);
  $lv_item->InsertColumn(2, 'X',      Wx::wxLIST_FORMAT_RIGHT(), 50);
  $lv_item->InsertColumn(3, 'Y',      Wx::wxLIST_FORMAT_RIGHT(), 50);
  $lv_item->InsertColumn(4, 'Dist',   Wx::wxLIST_FORMAT_RIGHT(), 60);
  $lv_item->InsertColumn(5, 'Qty',    Wx::wxLIST_FORMAT_RIGHT(), 60);
  $s_item->Add($lv_item, 1, Wx::wxALL()|Wx::wxEXPAND(), 6);
  $p_item->SetSizer($s_item);
  $tabs->AddPage($p_item, 'Items', 0);

  my $p_truth = Wx::Panel->new($tabs, -1);
  my $s_truth = Wx::BoxSizer->new(Wx::wxVERTICAL());
  my $grid = Wx::FlexGridSizer->new(3, 2, 5, 6);
  $grid->AddGrowableCol(1, 1);
  $grid->Add(Wx::StaticText->new($p_truth, -1, 'Map:'), 0, Wx::wxALIGN_CENTER_VERTICAL(), 0);
  $txtMap = Wx::StaticText->new($p_truth, -1, '-'); $grid->Add($txtMap, 0, Wx::wxEXPAND(), 0);
  $grid->Add(Wx::StaticText->new($p_truth, -1, 'Position:'), 0, Wx::wxALIGN_CENTER_VERTICAL(), 0);
  $txtPos = Wx::StaticText->new($p_truth, -1, '-'); $grid->Add($txtPos, 0, Wx::wxEXPAND(), 0);
  $grid->Add(Wx::StaticText->new($p_truth, -1, 'Action:'), 0, Wx::wxALIGN_CENTER_VERTICAL(), 0);
  $txtAct = Wx::StaticText->new($p_truth, -1, '-'); $grid->Add($txtAct, 0, Wx::wxEXPAND(), 0);
  $s_truth->Add($grid, 0, Wx::wxALL()|Wx::wxEXPAND(), 6);
  $lvStatus = Wx::ListView->new($p_truth, -1, [-1,-1], [-1,-1], Wx::wxLC_REPORT()|Wx::wxLC_SINGLE_SEL()|Wx::wxLC_HRULES()|Wx::wxLC_VRULES());
  
  $lvStatus->InsertColumn(0, 'Handle', Wx::wxLIST_FORMAT_LEFT(), 220);
  $lvStatus->InsertColumn(1, 'Name',   Wx::wxLIST_FORMAT_LEFT(), 220);
  $lvStatus->InsertColumn(2, 'ID',     Wx::wxLIST_FORMAT_RIGHT(), 80);
  $s_truth->Add($lvStatus, 1, Wx::wxALL()|Wx::wxEXPAND(), 6); # 1 = ขยายเต็มพื้นที่

  $lvTruth = Wx::ListView->new($p_truth, -1, [-1,-1], [-1,-1], Wx::wxLC_REPORT()|Wx::wxLC_SINGLE_SEL()|Wx::wxLC_HRULES()|Wx::wxLC_VRULES());
  $lvTruth->InsertColumn(0, 'Key',   Wx::wxLIST_FORMAT_LEFT(), 260);
  $lvTruth->InsertColumn(1, 'Value', Wx::wxLIST_FORMAT_LEFT(), 200);
  $s_truth->Add($lvTruth, 0, Wx::wxALL()|Wx::wxEXPAND(), 6); # 0 = ขนาดคงที่
  $p_truth->SetSizer($s_truth);
  $tabs->AddPage($p_truth, 'Self + Truth', 0);

  $root->Add($tabs, 1, Wx::wxALL()|Wx::wxEXPAND(), 6);
  $frame->SetSizer($root);

  $VISIBLE = !_cfg_bool('smartwx.start_hidden', 0);
  _show($VISIBLE);

  my $period = int(_cfg_num('smartwx.update_ms', 1)); $period = 1 if $period < 1;
  $timer = Wx::Timer->new($frame);
  Wx::Event::EVT_TIMER($frame, $timer, \&_refresh);
  $timer->Start($period);

  $READY = 1;
  message "[SmartWxAll] ready (${period}ms).\n";
}

sub _gather_monsters {
  my @mons;
  if ($Globals::monstersList && Scalar::Util::blessed($Globals::monstersList) && $Globals::monstersList->can('getItems')) {
    my $items = $Globals::monstersList->getItems; @mons = @$items if $items;
  } elsif ($Globals::monsters && ref $Globals::monsters eq 'HASH') {
    @mons = values %{$Globals::monsters};
  }
  return @mons;
}

sub _gather_items {
  my @its;
  if ($Globals::itemsList && Scalar::Util::blessed($Globals::itemsList) && $Globals::itemsList->can('getItems')) {
    my $items = $Globals::itemsList->getItems; @its = @$items if $items;
  } elsif ($Globals::items && ref $Globals::items eq 'HASH') {
    @its = values %{$Globals::items};
  }
  return @its;
}

sub _status_numeric_id {
  my ($handle) = @_;
  no strict 'refs';
  if (%Globals::ailmentHandle) {
    for my $id (keys %Globals::ailmentHandle) {
      return $id if defined $Globals::ailmentHandle{$id} && $Globals::ailmentHandle{$id} eq $handle;
    }
  }
  if (%Globals::statusHandle) {
    for my $id (keys %Globals::statusHandle) {
      return $id if defined $Globals::statusHandle{$id} && $Globals::statusHandle{$id} eq $handle;
    }
  }
  use strict 'refs';
  return undef;
}

sub refresh_now { _refresh() }

sub _refresh {
  return unless $frame && $frame->IsShown;

  my $you = _you_pos();
  my $r_mon = _cfg_num('smartwx.radius_mon', 10);
  my $r_itm = _cfg_num('smartwx.radius_item', 10);
  my $cap   = _cfg_num('smartwx.max_rows', 60);

  my (@rows_mon, @rows_item);
  my @snap_mon; my @snap_item;

  for my $m (_gather_monsters()) {
    next unless $m && Scalar::Util::blessed($m) && $m->isa('Actor::Monster');
    my $p = calcPosition($m) or next;
    my $dist = defined $you ? distance($you, $p) : undef;
    next if defined($dist) && $dist > $r_mon;
	next unless (Field::isReachable($field, $you, $p));
	
    my $classid = $m->{nameID} // $m->{type} // $m->{class} // '-';
    my $name = $m->name || 'Monster';
    my $hp   = (defined $m->{hp} && defined $m->{hp_max} && $m->{hp_max}>0)
               ? sprintf('%.0f', 100*$m->{hp}/$m->{hp_max})
               : (defined $m->{hp_percent} ? $m->{hp_percent} : '-');
    my $ok   = _monster_ks_ok($m) ? 'OK' : 'FALSE';

    push @rows_mon, [$classid, $name, $p->{x}||0, $p->{y}||0, (defined $dist? sprintf('%.1f',$dist):'-'), $hp, $ok];
    push @snap_mon, { id => ($m->{ID}//''), classid => $classid, name => $name, x=>$p->{x}||0, y=>$p->{y}||0, dist=>($dist//undef), hp_pct=>$hp, ks_ok=>($ok eq 'OK'?1:0) };
  }
  @rows_mon = sort { ($a->[4]=~/^\d/ ? $a->[4] : 9e9) <=> ($b->[4]=~/^\d/ ? $b->[4] : 9e9) } @rows_mon;
  splice @rows_mon, $cap if @rows_mon > $cap;

  for my $it (_gather_items()) {
    next unless $it;
    my $p = calcPosition($it) or next;
    my $dist = defined $you ? distance($you, $p) : undef;
    next if defined($dist) && $dist > $r_itm;
	next unless (Field::isReachable($field, $you, $p));

    my $itemid = defined $it->{nameID} ? $it->{nameID} : (defined $it->{id} ? $it->{id} : '-');
    my $name   = $it->can('name') ? ($it->name || 'Item') : ($it->{name} || 'Item');
    my $qty    = $it->{amount} // $it->{stack} // '-';
    push @rows_item, [$itemid, $name, $p->{x}||0, $p->{y}||0, (defined $dist? sprintf('%.1f',$dist):'-'), $qty];
    push @snap_item, { id => ($it->{ID}//''), itemid => $itemid, name => $name, x=>$p->{x}||0, y=>$p->{y}||0, dist=>($dist//undef), qty=>$qty };
  }
  @rows_item = sort { ($a->[4]=~/^\d/ ? $a->[4] : 9e9) <=> ($b->[4]=~/^\d/ ? $b->[4] : 9e9) } @rows_item;
  splice @rows_item, $cap if @rows_item > $cap;

  my $mapName = ($Globals::field && $Globals::field->name) ? $Globals::field->name : ($Globals::field ? $Globals::field->baseName : '-');
  my ($sx,$sy) = ('-','-');
  if ($Globals::char) { my $p = calcPosition($Globals::char); ($sx,$sy) = (defined $p ? ($p->{x}||0, $p->{y}||0) : ('-','-')); }
  my $act = '-';
  if (@Globals::ai_seq) { $act = $Globals::ai_seq[0]; }
  if ($Globals::char) {
    my $c = $Globals::char;
    $act = "dead"    if $c->{dead};
    $act = "sitting" if $c->{sitting};
    $act = "casting" if $c->{casting};
    $act = "moving"  if $c->{moving};
  }

  my @st_rows;
  if ($Globals::char && $Globals::char->{statuses} && %{$Globals::char->{statuses}}) {
    for my $handle (sort keys %{$Globals::char->{statuses}}) {
      my $name = defined $Globals::statusName{$handle} ? $Globals::statusName{$handle} : $handle;
      my $idnum = _status_numeric_id($handle);
      push @st_rows, { handle => $handle, name => $name, id => $idnum };
    }
  }

  $SNAP{monsters} = \@snap_mon;
  $SNAP{items}    = \@snap_item;
  $SNAP{self}     = { map => $mapName, x => ($sx eq '-'?undef:$sx), y => ($sy eq '-'?undef:$sy), action => $act, statuses => \@st_rows };
  $SNAP{truth}    = {
    monsters_nonempty    => scalar(@rows_mon) ? 1 : 0,
    items_nonempty       => scalar(@rows_item) ? 1 : 0,
    self_action_nonempty => ($act && $act ne '-') ? 1 : 0,
  };

  my $sig = join('|',
    $mapName, $sx, $sy, $act,
    (map { join(',', @{$_}) } @rows_mon), '||', (map { join(',', @{$_}) } @rows_item),
    '||', (map { $_->{handle}.($_->{id}//'') } @st_rows)
  );
  my $changed = ($sig ne $last_sig);
  $last_sig = $sig;

  Plugins::callHook('smartwx/snapshot', { snapshot => \%SNAP }) if $changed;

  return unless $changed;

  $txtMap->SetLabel($mapName // '-');
  $txtPos->SetLabel(($sx eq '-' || $sy eq '-') ? '-' : "($sx,$sy)");
  $txtAct->SetLabel($act);

  if ($lv_mon && $lv_mon->IsShownOnScreen) {
    $lv_mon->DeleteAllItems;
    for my $r (@rows_mon) { my $i=$lv_mon->InsertStringItem($lv_mon->GetItemCount, $r->[0]); for my $c (1..6){ $lv_mon->SetItem($i,$c,"$r->[$c]"); } }
  }
  if ($lv_item && $lv_item->IsShownOnScreen) {
    $lv_item->DeleteAllItems;
    for my $r (@rows_item) { my $i=$lv_item->InsertStringItem($lv_item->GetItemCount, $r->[0]); for my $c (1..5){ $lv_item->SetItem($i,$c,"$r->[$c]"); } }
  }
  if ($lvStatus && $lvStatus->IsShownOnScreen) {
    $lvStatus->DeleteAllItems;
    # @st_rows มีข้อมูลอยู่แล้วจากบรรทัด 262
    my @rows_sorted = sort { lc($a->{name}) cmp lc($b->{name}) } @st_rows;
    for my $r (@rows_sorted) {
      my $i = $lvStatus->InsertStringItem($lvStatus->GetItemCount, $r->{handle});
      $lvStatus->SetItem($i, 1, $r->{name});
      $lvStatus->SetItem($i, 2, (defined $r->{id} ? $r->{id} : '-'));
    }
  }
  if ($lvTruth && $lvTruth->IsShownOnScreen) {
    $lvTruth->DeleteAllItems;
    my @pairs = (
      ['monsters_nonempty',    $SNAP{truth}{monsters_nonempty} ? 'true' : 'false'],
      ['items_nonempty',       $SNAP{truth}{items_nonempty} ? 'true' : 'false'],
      ['self_action_nonempty', $SNAP{truth}{self_action_nonempty} ? 'true' : 'false'],
      ['statuses_count',       scalar(@st_rows)],
    );
    for my $kv (@pairs) { my $i=$lvTruth->InsertStringItem($lvTruth->GetItemCount, $kv->[0]); $lvTruth->SetItem($i,1,$kv->[1]); }
  }
}
1;
