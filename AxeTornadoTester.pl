#==========================================================
# SkillSpamTester.pl v3.0 — Multi-Skill Rotation (SimpleFactor)
#
# - รองรับหลายสกิลจาก config เดียว: skill_tester_skill Axe Tornado, Bash, NC_AXETORNADO, 2280
#   * ใส่ได้ทั้ง "ชื่อ" / handle / เลข ID (คั่นด้วย comma)
#   * ระบบจะ map → เลขสกิลทั้งหมดอัตโนมัติ
# - เรียงลำดับใช้งานตาม "ชื่อแสดงผล" (A→Z) แล้ววนลูป
# - ต่อสกิลแต่ละตัวมี state แยก: EMA delay, bias/backoff, next_ready
# - ใช้ in-flight gate, tick rounding, anti-flood, jitter เบา ๆ
# - factor เดียวทั้งชุด: skill_tester_factor (เช่น 1.2 / 1.5 / 2 / 3 ...)
#==========================================================
package SkillSpamTester;

use strict;
use warnings;
use Plugins;
use Globals qw($char $field %config);
use Log qw(message debug warning);
use AI;
use Commands;
use Time::HiRes qw(time);
use Settings;

# ---------------- Constants ----------------
use constant {
  FUDGE_MS         => 80,     # กัน jitter พื้นฐาน
  TICK_MS          => 50,     # ปัดขึ้นตาม server tick
  DEFAULT_MS       => 650,    # ใช้ก่อนรู้ค่าจริง
  FAIL_ADD_MS      => 60,     # เพิ่ม bias เมื่อ Mid-Delay
  FAIL_DEC_MS      => 30,     # ลด bias ทีละน้อยเมื่อสำเร็จ
  INFLIGHT_TMO_MS  => 2000,   # กันรอ ACK ค้าง
  MIN_GAP_MS       => 30,     # กัน double-hit ภายในเฟรมเดียว
  MIN_SP           => 1,      # ขั้นต่ำ SP

  # AntiFlood
  ANTIFLOOD_ON            => 1,
  MIN_CMD_GAP_MS          => 220,
  MAX_CMD_PER_10S         => 22,
  COOLDOWN_AFTER_LIMIT_MS => 1200,
  JITTER_MAX_MS           => 40,
};

# ---------------- Config ----------------
sub CFG_ENABLED   () { int($config{skill_tester_enabled} // 1) }
sub CFG_SCOPE     () { lc($config{skill_tester_scope}    // 'save') }   # save|lock|any
sub CFG_FACTOR    () {
  my $raw = $config{skill_tester_factor}; $raw = '1.2' unless defined $raw && $raw ne '';
  $raw =~ s/,/./g; my $f = $raw + 0; $f = 1.0 if $f <= 0; return $f;
}
# ใช้เลเวลเดียวกับทุกสกิลเพื่อความเรียบง่าย
sub CFG_LV        () { int($config{skill_tester_lv}      // 5) }
# รายการสกิลแบบ CSV (ชื่อ/handle/ID)
sub CFG_SKILLS_RAW() { $config{skill_tester_skill} // 'NC_AXETORNADO' }

# ---------------- State ----------------
my $hooks;
my %S = (
  active_scope      => 0,
  inflight          => 0,
  inflight_deadline => 0.0,
  inflight_skill_id => undef,      # สกิลที่สั่งยิงล่าสุด (ไว้แม็ปกับ fail)

  # anti-flood
  last_cmd_at       => 0.0,
  recent_cmd_ts     => [],

  # ตารางแม็ป
  handle2id         => {},
  name2handle       => {},
  handle2name       => {},
  id2handle         => {},

  # รายการสกิลที่ใช้งาน (เรียงแล้ว)
  # @SK_ORDER   = (id1,id2,...)
  # $SK{id} = {
  #   name, handle, id,
  #   next_ready, last_ms, ema_ms, last_ack,
  #   fail_streak, fail_bias_ms
  # }
  SK_ORDER          => [],
  SK                => {},
  ROT_INDEX         => 0,          # pointer หมุนวนตามลำดับชื่อ
);

#==========================================================
# Register hooks
#==========================================================
Plugins::register('SkillSpamTester', 'Multi-Skill Spam (rotation + SimpleFactor)', \&onUnload);
$hooks = Plugins::addHooks(
  ['start3',                   \&onMapChange,      undef],
  ['map_loaded',               \&onMapChange,      undef],
  ['packet_mapChange',         \&onMapChange,      undef],
  ['packet/self_skill_used',   \&onSelfSkillUsed,  undef],
  ['packet/skill_use_failed',  \&onSkillUseFailed, undef],
  ['packet/skill_failed',      \&onSkillUseFailed, undef],
  ['AI_pre',                   \&onAI,             undef],
);
sub onUnload { Plugins::delHooks($hooks) if $hooks; message "[SkillSpamTester] Unloaded.\n", "system" }

#==========================================================
# Utils: sanitize, tables, resolve
#==========================================================
sub _sanitize {
  my ($s) = @_;
  return '' unless defined $s;
  $s =~ s/^\s+|\s+$//g;
  $s =~ s/\\(["'])/$1/g; # unescape \" / \'
  $s =~ s/[\x{2018}\x{2019}\x{201A}\x{201B}\x{201C}\x{201D}\x{201E}\x{201F}\x{275D}\x{275E}\x{00AB}\x{00BB}\x{2039}\x{203A}]//g;
  while ( $s =~ /\A(["'])(.*)\1\z/s ) { $s = $2; $s =~ s/^\s+|\s+$//g; }
  $s =~ s/\s+/ /g;
  return $s;
}

sub _load_skill_tables {
  return if (keys %{ $S{handle2id} } || keys %{ $S{name2handle} } || keys %{ $S{handle2name} } || keys %{ $S{id2handle} });

  my $f1 = Settings::getTableFilename("SKILL_id_handle.txt");
  if ($f1 && -e $f1 && open my $fh, "<:encoding(UTF-8)", $f1) {
    while (my $line = <$fh>) {
      next if $line =~ /^\s*#/ || $line !~ /\S/;
      chomp $line;
      my ($id, $handle) = split /\s+/, $line, 2;
      next unless defined $id && defined $handle;
      $handle =~ s/\s+$//;
      my $ID = int($id);
      my $H  = uc $handle;
      $S{handle2id}->{$H} = $ID;
      $S{id2handle}->{$ID} = $H;
    }
    close $fh;
  } else {
    warning "[SkillSpamTester] SKILL_id_handle.txt not found via Settings.\n";
  }

  my $f2 = Settings::getTableFilename("skillnametable.txt");
  if ($f2 && -e $f2 && open my $fh2, "<:encoding(UTF-8)", $f2) {
    while (my $line = <$fh2>) {
      next if $line =~ /^\s*#/ || $line !~ /\S/;
      chomp $line;
      my ($handle, $name) = split /#/, $line, 3;
      next unless $handle && $name;
      $name =~ s/^\s+|\s+$//g;
      my $H = uc $handle;
      my $N = $name;
      $S{name2handle}->{ lc $N } = $H;
      $S{handle2name}->{$H} = $N;
    }
    close $fh2;
  } else {
    warning "[SkillSpamTester] skillnametable.txt not found via Settings.\n";
  }
}

# คืน (id, handle, displayName) จากสเปก (เลข/handle/ชื่อ) — ไม่เจอคืน undef
sub _resolve_one {
  my ($spec_raw) = @_;
  my $spec = _sanitize($spec_raw);
  return (int($spec), $S{id2handle}->{int($spec)} // undef, $S{handle2name}->{ $S{id2handle}->{int($spec)} // '' } // $spec)
         if $spec =~ /^\d+$/;

  _load_skill_tables();

  # handle (ไม่มีช่องว่าง)
  if ($spec =~ /^\S+$/) {
    my $H = uc $spec;
    if (my $ID = $S{handle2id}->{$H}) {
      my $N = $S{handle2name}->{$H} // $spec;
      return ($ID, $H, $N);
    }
  }

  # ชื่อ (มีเว้นวรรคได้)
  my $H2 = $S{name2handle}->{ lc $spec };
  if ($H2) {
    if (my $ID2 = $S{handle2id}->{ $H2 }) {
      my $N2 = $S{handle2name}->{ $H2 } // $spec;
      return ($ID2, $H2, $N2);
    }
  }
  return ();
}

#==========================================================
# Scope / Build rotation
#==========================================================
sub _in_scope {
  my $mode = CFG_SCOPE();
  return 1 if $mode eq 'any';
  my $cur = $field ? ($field->name // '') : '';
  return lc($cur) eq lc($config{saveMap} // '') if $mode eq 'save';
  return lc($cur) eq lc($config{lockMap} // '') if $mode eq 'lock';
  return 0;
}

sub _parse_skill_list {
  my $raw = CFG_SKILLS_RAW();
  my @parts = split /,/, $raw;
  my @out;
  for my $p (@parts) {
    my $t = _sanitize($p);
    push @out, $t if length $t;
  }
  return @out;
}

sub _build_rotation {
  $S{SK_ORDER} = [];
  $S{SK}       = {};
  $S{ROT_INDEX}= 0;

  my @specs = _parse_skill_list();
  my @entries;

  for my $spec (@specs) {
    my ($id, $handle, $name) = _resolve_one($spec);
    if (!$id) {
      warning sprintf("[SkillSpamTester] Cannot resolve skill '%s' → skip\n", $spec);
      next;
    }
    # ถ้า id ซ้ำในลิสต์ ให้คงรายการเดียว
    next if exists $S{SK}->{$id};
    my $entry = {
      id => $id,
      handle => ($handle // ''),
      name => ($name // $spec),
      next_ready   => 0.0,
      last_ms      => 0,
      ema_ms       => undef,
      last_ack     => 0.0,
      fail_streak  => 0,
      fail_bias_ms => 0,
    };
    $S{SK}->{$id} = $entry;
    push @entries, $entry;
  }

  # เรียงตามชื่อแสดงผล (A→Z)
  @entries = sort { lc($a->{name}) cmp lc($b->{name}) } @entries;

  # บันทึกลำดับ id
  my @order = map { $_->{id} } @entries;
  $S{SK_ORDER} = \@order;

  # สรุป
  my @summ = map { sprintf("%s->%d", $_->{name}, $_->{id}) } @entries;
  message "[SkillSpamTester] Rotation: " . ( @summ ? join(", ", @summ) : "(empty)" ) . "\n", @summ ? "success":"warning";
}

sub onMapChange {
  $S{active_scope} = _in_scope() ? 1 : 0;

  _build_rotation();

  $S{inflight}          = 0;
  $S{inflight_skill_id} = undef;
  $S{inflight_deadline} = 0.0;
  $S{last_cmd_at}       = 0.0;
  $S{recent_cmd_ts}     = [];

  my $where = $field ? $field->name : '(unknown)';
  message sprintf("[SkillSpamTester] Map: %s | scope=%s -> %s | factor=%.2f | lv=%d\n",
    $where, CFG_SCOPE(), $S{active_scope} ? 'ACTIVE' : 'INACTIVE', CFG_FACTOR(), CFG_LV()),
    $S{active_scope} ? "success" : "info";
}

#==========================================================
# Timing
#==========================================================
sub _predicted_ms_for {
  my ($sk) = @_;
  my $base = defined $sk->{ema_ms} ? int($sk->{ema_ms})
           : $sk->{last_ms}        ? int($sk->{last_ms})
           : DEFAULT_MS;

  my $ms = int($base * CFG_FACTOR() + 0.5) + FUDGE_MS + $sk->{fail_bias_ms};
  my $tick = TICK_MS;
  $ms = int(($ms + $tick - 1) / $tick) * $tick;

  my $jit = (JITTER_MAX_MS() > 0) ? int(rand(JITTER_MAX_MS()+1)) : 0;
  return $ms + $jit;
}

#==========================================================
# Packet handlers
#==========================================================
sub onSelfSkillUsed {
  my (undef, $args) = @_;
  return unless CFG_ENABLED() && $S{active_scope} && $args;

  my $skill_id = $args->{skillID};
  my $delay_ms = $args->{delay};
  my $sk = $S{SK}->{$skill_id} or return; # สนใจเฉพาะสกิลใน rotation

  if (defined $delay_ms) {
    $sk->{last_ms} = $delay_ms;
    my $a = 0.35;
    $sk->{ema_ms} = defined $sk->{ema_ms} ? int($a*$delay_ms + (1-$a)*$sk->{ema_ms}) : $delay_ms;
  }

  my $now = time();
  $sk->{last_ack} = $now;

  # ลด bias ของสกิลนั้น ๆ
  if ($sk->{fail_bias_ms} > 0) {
    $sk->{fail_bias_ms} = ($sk->{fail_bias_ms} > FAIL_DEC_MS()) ? $sk->{fail_bias_ms} - FAIL_DEC_MS() : 0;
  }
  $sk->{fail_streak} = 0;

  my $pred_ms = _predicted_ms_for($sk);
  $sk->{next_ready} = $now + ($pred_ms / 1000.0);

  # ปลด inflight
  $S{inflight}          = 0;
  $S{inflight_skill_id} = undef;

  debug sprintf("[SkillSpamTester] ACK %s(id=%d) delay=%s ema=%s pred=%dms\n",
    $sk->{name}, $sk->{id},
    (defined $sk->{last_ms} ? $sk->{last_ms}.'ms' : 'n/a'),
    (defined $sk->{ema_ms}  ? $sk->{ema_ms}.'ms'  : 'n/a'),
    $pred_ms);
}

sub onSkillUseFailed {
  return unless CFG_ENABLED() && $S{active_scope};

  my $sid = $S{inflight_skill_id};
  my $sk  = defined $sid ? $S{SK}->{$sid} : undef;
  my $now = time();

  # ถ้าเราไม่รู้ว่าที่ fail คือสกิลไหน (edge case) ให้คูลดาวน์สั้น ๆ ทั้งระบบ
  if (!$sk) {
    debug "[SkillSpamTester] FAIL (unknown skill) → cooldown 300ms\n";
    $S{inflight} = 0; $S{inflight_skill_id} = undef;
    # ขยับทุกสกิลให้มีเวลาพักสั้น ๆ กันวนเร็วเกิน
    for my $id (@{ $S{SK_ORDER} }) { $S{SK}->{$id}->{next_ready} = $now + 0.30 }
    return;
  }

  # ประเมิน Mid-Delay เทียบกับสกิลตัวนั้น
  my $pred_ms = _predicted_ms_for($sk);
  my $since_ack_ms = $sk->{last_ack} ? int( ($now - $sk->{last_ack}) * 1000 ) : 999999;
  my $mid_delay_guess = ($since_ack_ms < $pred_ms + 1);

  if ($mid_delay_guess) {
    $sk->{fail_streak}++;
    my $add = FAIL_ADD_MS() + (20 * ($sk->{fail_streak}-1));
    $add = 200 if $add > 200;
    $sk->{fail_bias_ms} += $add;

    my $retry_ms = _predicted_ms_for($sk);
    $sk->{next_ready} = $now + ($retry_ms / 1000.0);
    debug sprintf("[SkillSpamTester] FAIL Mid-Delay %s → bias+=%d (bias=%d) retry %dms\n",
      $sk->{name}, $add, $sk->{fail_bias_ms}, $retry_ms);
  } else {
    # fail แบบอื่น: พักสั้น ๆ
    $sk->{next_ready} = $now + 0.30;
    debug sprintf("[SkillSpamTester] FAIL %s → wait 300ms\n", $sk->{name});
  }

  $S{inflight}          = 0;
  $S{inflight_skill_id} = undef;
}

#==========================================================
# AntiFlood
#==========================================================
sub _prune_cmd_log {
  my $now = time();
  my $cut = $now - 10.0;
  my @keep = grep { $_ >= $cut } @{ $S{recent_cmd_ts} };
  $S{recent_cmd_ts} = \@keep;
  return scalar @keep;
}

sub _antiflood_ok_or_delay {
  return 1 unless ANTIFLOOD_ON();

  my $now = time();
  if ($S{last_cmd_at} > 0) {
    my $gap_ms = int( ($now - $S{last_cmd_at}) * 1000 );
    if ($gap_ms < MIN_CMD_GAP_MS()) {
      my $need = (MIN_CMD_GAP_MS() - $gap_ms) / 1000.0;
      # ขยับ "สกิลถัดไปที่กำลังจะยิง" ออกเล็กน้อย (ทำทั่วระบบโดยรวม)
      for my $id (@{ $S{SK_ORDER} }) {
        my $nr = $S{SK}->{$id}->{next_ready};
        $S{SK}->{$id}->{next_ready} = ($now + $need) if $nr < $now + $need;
      }
      return 0;
    }
  }

  my $cnt = _prune_cmd_log();
  if ($cnt >= MAX_CMD_PER_10S()) {
    for my $id (@{ $S{SK_ORDER} }) {
      my $nr = $S{SK}->{$id}->{next_ready};
      my $cool = $now + (COOLDOWN_AFTER_LIMIT_MS() / 1000.0);
      $S{SK}->{$id}->{next_ready} = $cool if $nr < $cool;
    }
    debug sprintf("[SkillSpamTester] AntiFlood: hit %d/10s → cooldown %dms\n", $cnt, COOLDOWN_AFTER_LIMIT_MS());
    return 0;
  }
  return 1;
}

#==========================================================
# AI Loop (เลือกสกิลตามลำดับชื่อ -> อันที่พร้อมก่อน)
#==========================================================
sub onAI {
  return unless CFG_ENABLED() && $S{active_scope} && $char;
  return if $char->{dead} || $char->{sit} || ($char->{sp} // 0) < MIN_SP();
  return if !@{ $S{SK_ORDER} };

  my $now = time();

  # ปลดถ้าค้างเกินเวลา
  if ($S{inflight} && $now > $S{inflight_deadline}) {
    debug "[SkillSpamTester] inflight timeout → reset\n";
    $S{inflight} = 0; $S{inflight_skill_id} = undef;
  }
  return if $S{inflight};

  # หา "สกิลที่พร้อม" ตัวแรกตามลำดับชื่อ
  my $start = $S{ROT_INDEX};
  my $chosen;
  for (my $i = 0; $i < @{ $S{SK_ORDER} }; $i++) {
    my $idx = ($start + $i) % @{ $S{SK_ORDER} };
    my $id  = $S{SK_ORDER}->[$idx];
    my $sk  = $S{SK}->{$id};
    if ($now >= ($sk->{next_ready} // 0)) {
      $chosen = $id;
      $S{ROT_INDEX} = ($idx + 1) % @{ $S{SK_ORDER} }; # เตรียมชี้ตัวถัดไปรอบหน้า
      last;
    }
  }

  # ถ้ายังไม่พร้อมเลย -> รอจนถึงอันที่ใกล้สุด
  if (!$chosen) {
    my $soonest = undef;
    for my $id (@{ $S{SK_ORDER} }) {
      my $nr = $S{SK}->{$id}->{next_ready} // 0;
      $soonest = $nr if !defined($soonest) || $nr < $soonest;
    }
    # ไม่มีค่า -> ไม่ทำอะไร
    return unless defined $soonest && $soonest > $now;
    # รอจนถึงเวลาที่เร็วที่สุด
    return;
  }

  # AntiFlood ตรวจก่อนยิง
  return unless _antiflood_ok_or_delay();

  _useSkill($chosen);
}

#==========================================================
# Action
#==========================================================
sub _useSkill {
  my ($id) = @_;
  my $sk = $S{SK}->{$id} or return;
  my $lv = CFG_LV();

  $S{inflight}          = 1;
  $S{inflight_skill_id} = $id;
  $S{inflight_deadline} = time() + (INFLIGHT_TMO_MS() / 1000.0);

  my $pred_ms = _predicted_ms_for($sk);
  $sk->{next_ready} = time() + ($pred_ms / 1000.0);

  # anti-flood bookkeeping
  my $now = time();
  $S{last_cmd_at} = $now;
  push @{ $S{recent_cmd_ts} }, $now;

  message sprintf("[SkillSpamTester] ss %d %d  # %s\n", $id, $lv, $sk->{name}), "skill";
  Commands::run("ss $id $lv");
}

#==========================================================
# Banner
#==========================================================
BEGIN {
  message "==========================================================\n", "system";
  message "[SkillSpamTester] v3.0 Loaded — Multi-Skill Rotation (SimpleFactor)\n", "system";
  message "==========================================================\n", "system";
}

1;
