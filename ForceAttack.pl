package ForceAttack;

use strict;
use Plugins;
use Globals;
use Log qw(message);

# ลงทะเบียนปลั๊กอิน
Plugins::register('ForceAttack', 'A profile-aware plugin to force-use a skill on attack', \&on_unload);

# สร้าง Hook: เหมือนเดิม
my $hook = Plugins::addHook('ai_attack_pre', \&on_ai_attack_pre);

# แสดงข้อความเมื่อปลั๊กอินโหลดสำเร็จ
message "[ForceAttack] Profile-aware plugin loaded.\n", "success";


# ========== นี่คือหัวใจของปลั๊กอิน (เวอร์ชันอัปเดต) ==========
sub on_ai_attack_pre {
    my ($hook, $args) = @_;
    my $target = $args->{monster};

    # ★★★ เปลี่ยนตรงนี้ ★★★
    # ดึงค่าคอนฟิกจาก %config ที่ OpenKore โหลดให้โปรไฟล์นี้โดยตรง
    my $skill_name = $config{forceAttack_skill};
    my $skill_level = $config{forceAttack_level};
    
    # ถ้าโปรไฟล์นี้ไม่ได้ตั้งค่าสกิลไว้ ก็หยุดทำงาน
    return 1 unless ($skill_name && $skill_level);
    
    # ดึงคอนฟิกของมอนสเตอร์เป้าหมาย (เหมือนเดิม)
    my $monster_config = $mon_control{$target->name};

    # ตรวจสอบ "สวิตช์" ของเรา (เหมือนเดิม)
    if ($monster_config && $monster_config->{loot} == 2) {
        
        my $skill_obj = Skills->get($skill_name);

        if ($skill_obj && $char->sp >= $skill_obj->sp_cost($skill_level)) {
            message "[ForceAttack] Intercepted attack on ".$target->name.". Using ".$skill_name."!\n", "success";
            AI::useSkill($skill_name, $skill_level, $target->id);
            return 0; # ตัดจบการทำงานของ AI หลัก
        }
    }
    
    # ถ้าเงื่อนไขไม่ตรง ให้ AI ทำงานตามปกติ
    return 1;
}

# --- ฟังก์ชันเมื่อปลั๊กอินถูกปิด ---
sub on_unload {
    message "[ForceAttack] Plugin unloaded.\n", "success";
}

1;