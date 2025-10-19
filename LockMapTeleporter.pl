# LockMapTeleporter.pl
# Plugin to teleport randomly every 2 seconds inside the lockMap.

package LockMapTeleporter;

use strict;
use warnings;
use Plugins;
use Globals qw($char $field %config);
use Log qw(message);
use Time::HiRes qw(time); # ใช้สำหรับเวลาที่แม่นยำ

# --- State ---
my $hooks;
my $last_teleport_time = 0; # ตัวแปรสำหรับเก็บเวลาที่เทเลพอร์ตครั้งล่าสุด

# --- Registration ---
Plugins::register('LockMapTeleporter', 'Teleport every 2s in lockMap', \&onUnload);

# เราจะเกี่ยวเข้ากับ AI loop หลักของบอท
$hooks = Plugins::addHooks(
    ['AI_pre', \&onAI, undef]
);

# ฟังก์ชันสำหรับตอนปิดปลั๊กอิน เพื่อล้าง Hook ออกไป
sub onUnload {
    Plugins::delHooks($hooks);
}

# --- Core Logic ---
# ฟังก์ชันนี้จะถูกเรียกในทุกๆ รอบของ AI
sub onAI {
    # --- เงื่อนไขข้อที่ 1: ตรวจสอบว่าอยู่ใน lockMap หรือไม่ ---

    # ถ้ายังไม่พร้อม (ยังไม่เข้าเกม) หรือไม่ได้ตั้งค่า lockMap ให้หยุดทำงาน
    return unless ($field && $config{lockMap});

    # เปรียบเทียบชื่อแผนที่ปัจจุบันกับ lockMap (ใช้ lc เพื่อให้เป็นตัวพิมพ์เล็กทั้งหมด)
    my $current_map = $field->baseName;
    return if (lc($current_map) ne lc($config{lockMap}));


    # --- เงื่อนไขข้อที่ 2: ตรวจสอบว่าครบ 2 วินาทีหรือยัง ---
    my $now = time(); # ดึงเวลาปัจจุบัน
    return if ($now - $last_teleport_time < 2);


    # --- Action: ถ้าผ่านทุกเงื่อนไข ให้ทำการเทเลพอร์ต ---
    message "[LockMapTeleporter] Time to teleport!\n", "system";
    $char->useTeleport()


    # --- Update State: บันทึกเวลาที่เทเลพอร์ตครั้งนี้ไว้ ---
    $last_teleport_time = $now;
}

# Message on load
message "[LockMapTeleporter] Loaded. Will teleport every 2 seconds in your lockMap.\n", "success";

1;