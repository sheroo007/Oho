# SmartAISuite.pl
# "บริษัทรับจ้างสังหาร" อัจฉริยะ (เลขา + คนขับ + มือปืน + เก็บกวาด)
# v4.1 - (FIX) เอา 'use SmartWxAll' ออก
#
# - ใช้ SmartWxAll.pl v1.6+ เป็น "ดวงตา" และ "สมอง"
# - ทำงานเฉพาะใน lockMap
# - "เลขา": เปิด/ปิด AI อัตโนมัติ (รวมถึง route_randomWalk)
# - "คนขับรถ": เทเลพอร์ต, สร้างอาณาเขตสังหาร, สั่งงาน
# - "มือปืน": ล็อคเป้าหมายเดียวจนตาย, ใช้สกิล/AoE
# - "คนเก็บกวาด": ใช้ Greed เมื่อปลอดภัย
package SmartAISuite;

use strict;
use warnings;

use Globals;
use Plugins;
use Log qw(message warning error);
use AI;         # <--- ตัวสั่งการ (Attack, pickup, teleport, useSkill, greed)
# *** ลบ 'use SmartWxAll;' ออกแล้ว ***
use Utils qw(distance calcPosition);
use Scalar::Util qw(blessed);
# *** ไม่ต้องใช้ Field.pm "หัวหน้า" จัดการให้ ***

my $hooks;

# --- สถานะของ "บริษัท" ---

# 1. "เลขา" จะเก็บค่า AI เดิมไว้ที่นี่
my ($orig_attackAuto, $orig_pickupAuto, $orig_sitAuto_idle);
my $orig_route_randomWalk; # <--- เพิ่มตัวแปรจำค่า randomWalk
my $settings_saved = 0;

# 2. "คนขับรถ" จะเก็บ "อาณาเขตสังหาร" ไว้ที่นี่
my %ZONE = (
    active    => 0, # 1 = สร้างโซนแล้ว, 0 = ยัง (ต้องสร้างใหม่)
    center_x  => undef,
    center_y  => undef,
);

# 3. "มือปืน" จะจำเป้าหมาย "รักเดียวใจเดียว" ไว้ที่นี่
my $CURRENT_TARGET_ID = undef; # <--- ตัวแปร "ล็อคเป้า"

Plugins::register('SmartAISuite', 'Smart AI Suite (Driver+Hitman+Cleaner) v4.1', \&unload);
$hooks = Plugins::addHooks(
    ['start3',            \&save_initial_settings],
    ['packet/map_loaded', \&hook_map_loaded],       # "เลขา" + "ล้างสมอง"
    ['AI_pre',            \&hook_ai_pre, undef, 40] # "คนขับรถ" (priority 40)
);

sub unload {
    Plugins::delHooks($hooks) if $hooks;
    restore_ai_settings() if $settings_saved;
    message "[SmartAISuite] Unloaded. Default AI restored.\n";
}

# --- ส่วนของ "เลขา" (จัดการเปิด/ปิด AI) ---

sub save_initial_settings {
    return if $settings_saved;
    $orig_attackAuto = $config{attackAuto};
    $orig_pickupAuto = $config{pickupAuto};
    $orig_sitAuto_idle = $config{sitAuto_idle};
    $orig_route_randomWalk = $config{route_randomWalk}; # <--- "เลขา" จำค่า route_randomWalk
    $settings_saved = 1;
    message "[SmartAISuite] Original AI settings saved.\n";
}

sub hook_map_loaded {
    return unless $settings_saved;
    my $current_map = $field ? $field->name : "";
    my $lock_map = $config{lockMap};

    if ($current_map eq $lock_map) {
        message "[SmartAISuite] 'เลขา': เข้าสู่ lockMap ($lock_map). สั่งปิด AI หลัก!\n";
        $config{attackAuto} = 0;  
        $config{pickupAuto} = 0;  
        $config{sitAuto_idle} = 0;
        $config{route_randomWalk} = 0; # <--- "เลขา" สั่งปิดการเดินมั่ว
        
        # "ล้างสมอง" (ความจำสั้น)
        $ZONE{active} = 0; 
        $CURRENT_TARGET_ID = undef; # <--- "เลขา" สั่งล้างเป้าหมายที่ล็อคไว้
        message "[SmartAISuite] 'เลขา': ล้างสมอง! (ล้างอาณาเขต + ล้างเป้าหมายล็อค)\n";
    } else {
        restore_ai_settings();
    }
}

sub restore_ai_settings {
    if ($config{attackAuto} == 0 && $config{pickupAuto} == 0) {
        message "[SmartAISuite] 'เลขา': อยู่นอก lockMap. คืนค่า AI หลัก.\n";
        $config{attackAuto} = $orig_attackAuto;
        $config{pickupAuto} = $orig_pickupAuto;
        $config{sitAuto_idle} = $orig_sitAuto_idle;
        $config{route_randomWalk} = $orig_route_randomWalk; # <--- คืนค่าการเดินมั่ว
    }
    $ZONE{active} = 0;
    $CURRENT_TARGET_ID = undef;
}

# --- ส่วนของ "คนขับรถ" (ตัวตัดสินใจหลัก) ---

sub hook_ai_pre {
    return if @Globals::ai_seq; # AI กำลังทำงานอื่นอยู่

    my $current_map = $field ? $field->name : "";
    return if ($current_map ne $config{lockMap}); # "คนขับรถ" เช็ค: อยู่ใน lockMap?
    
    my $you = calcPosition($char);
    unless ($ZONE{active}) {
        # "ปักหมุด" สร้างอาณาเขต
        message "[SmartAISuite] 'คนขับรถ': สร้างอาณาเขตสังหาร รอบจุด ($you->{x}, $you->{y})\n";
        $ZONE{center_x} = $you->{x};
        $ZONE{center_y} = $you->{y};
        $ZONE{active} = 1;
    }

    # *** เราเรียก 'SmartWxAll::get_snapshot' ตรงๆ เลย ***
    my $snap = SmartWxAll::get_snapshot(); # ถาม "หัวหน้า"
    return unless $snap;

    # --- 5.5. "รักเดียวใจเดียว" ---
    if (defined $CURRENT_TARGET_ID) {
        my $target_obj = $Globals::monsters{$CURRENT_TARGET_ID};
        
        if ($target_obj && blessed($target_obj) && $target_obj->isa('Actor::Monster') && !$target_obj->{dead}) {
            message "[SmartAISuite] 'มือปืน': ล็อคเป้าเดิม! " . $target_obj->name . "\n";
            
            # (ต้องนับมอนในโซน เพื่อตัดสินใจ AoE)
            my $mob_count = 0;
            if ($snap->{truth}{monsters_nonempty}) {
                my $r = $config{'smartwx.radius_mon'} // 10;
                for (@{$snap->{monsters}}) {
                    # หัวหน้ากรองทางเดินมาแล้ว เรากรองแค่รัศมีโซน
                    next if (distance({ x => $ZONE{center_x}, y => $ZONE{center_y} }, {x => $_->{x}, y => $_->{y}}) > $r);
                    $mob_count++;
                }
            }
            
            # (logic การยิงจาก v2)
            my $aoe_skill = $config{smart_aoe_skill};
            my $aoe_lvl   = $config{smart_aoe_skill_lvl} // 1;
            my $aoe_min   = $config{smart_aoe_min_mobs} // 3;
            my $target_skill = $config{smart_attack_skill_target};
            my $target_lvl   = $config{smart_attack_skill_target_lvl} // 1;

            if ($aoe_skill && $mob_count >= $aoe_min) {
                AI::useSkill($aoe_skill, $aoe_lvl, $target_obj);
            } elsif ($target_skill) {
                AI::useSkill($target_skill, $target_lvl, $target_obj);
            } else {
                AI::Attack($target_obj);
            }
            return; # สั่งยิงเป้าเดิมแล้ว, จบ
            
        } else {
            message "[SmartAISuite] 'มือปืน': เป้าหมายเก่า ($CURRENT_TARGET_ID) ตาย/หาย. ค้นหาเป้าหมายใหม่.\n";
            $CURRENT_TARGET_ID = undef; # ล้างเป้าหมาย
        }
    }

    # (ถ้ามาถึงนี่ = ไม่มีเป้าหมายเก่าที่ล็อคไว้)

    # กรองข้อมูลเฉพาะใน "อาณาเขตสังหาร"
    my $zone_center = { x => $ZONE{center_x}, y => $ZONE{center_y} };
    my $radius_mon  = $config{'smartwx.radius_mon'} // 10; 
    my $radius_item = $config{'smartwx.radius_item'} // 10;

    my @monsters_in_zone;
    if ($snap->{truth}{monsters_nonempty}) {
        for my $mon_data (@{$snap->{monsters}}) {
            # หัวหน้ากรองทางเดินมาแล้ว
            next if (distance($zone_center, {x => $mon_data->{x}, y => $mon_data->{y}}) > $radius_mon);
            push @monsters_in_zone, $mon_data;
        }
    }
    
    my @items_in_zone;
    if ($snap->{truth}{items_nonempty}) {
        for my $item_data (@{$snap->{items}}) {
            # หัวหน้ากรองทางเดินมาแล้ว
            next if (distance($zone_center, {x => $item_data->{x}, y => $item_data->{y}}) > $radius_item);
            push @items_in_zone, $item_data;
        }
    }

    # --- 6. "คนขับรถ" สั่งงาน "มือปืน" (Person 2) ---
    my $target_obj = find_target_in_zone(\@monsters_in_zone); # <--- ไม่ต้องส่ง $you
    if ($target_obj) {
        
        $CURRENT_TARGET_ID = $target_obj->{ID}; # <--- ล็อคเป้าหมายใหม่!
        message "[SmartAISuite] 'มือปืน': ล็อคเป้าหมายใหม่! " . $target_obj->name . " (ID: $CURRENT_TARGET_ID)\n";

        my $mob_count = scalar(@monsters_in_zone);
        my $aoe_skill = $config{smart_aoe_skill};
        my $aoe_lvl   = $config{smart_aoe_skill_lvl} // 1;
        my $aoe_min   = $config{smart_aoe_min_mobs} // 3;
        
        my $target_skill = $config{smart_attack_skill_target};
        my $target_lvl   = $config{smart_attack_skill_target_lvl} // 1;

        if ($aoe_skill && $mob_count >= $aoe_min) {
            message "[SmartAISuite] 'มือปืน': มอนรุม ($mob_count ตัว)! สั่งยิง AoE ($aoe_skill) ใส่ " . $target_obj->name . "!\n";
            AI::useSkill($aoe_skill, $aoe_lvl, $target_obj);
        
        } elsif ($target_skill) {
            message "[SmartAISuite] 'มือปืน': สั่งยิงสกิล ($target_skill) ใส่ " . $target_obj->name . "!\n";
            AI::useSkill($target_skill, $target_lvl, $target_obj);
        
        } else {
            message "[SmartAISuite] 'มือปืน': สั่งโจมตี " . $target_obj->name . "!\n";
            AI::Attack($target_obj);
        }
        return; # สั่งงานแล้ว, จบ
    }

    # --- 7. "คนขับรถ" สั่งงาน "คนเก็บกวาด" (Person 3) ---
    my $can_greed = find_item_in_zone(\@items_in_zone, scalar(@monsters_in_zone)); # <--- ไม่ต้องส่ง $you
    if ($can_greed) {
        message "[SmartAISuite] 'เก็บกวาด': ปลอดภัย... สั่งใช้ Greed!\n";
        AI::greed();
        return; # สั่งงานแล้ว, จบ
    }

    # --- 8. "คนขับรถ" เช็คว่า "งานเสร็จ" หรือยัง ---
    if ($snap->{self}{action} eq '-') {
        message "[SmartAISuite] 'คนขับรถ': งานเสร็จ! (Mob=F, Item=F, Action='-'). ออกเดินทาง!\n";
        AI::teleport();
        return; # สั่งงานแล้ว, จบ
    }
}


# --- ส่วนของ "มือปืน" (Person 2) ---
sub find_target_in_zone {
    my ($monsters_list) = @_; # <--- เอา $you_pos ออก
    
    my $attack_mode = $config{smart_attack_mode} // 0;
    my $attack_all  = ($attack_mode == 0);

    my %attack_list;
    unless ($attack_all) {
        %attack_list = map { lc($_) => 1 } split /,/, lc($config{smart_attack_list} // '');
    }
    my %ignore_list;
    if (defined $config{smart_attack_ignore_list}) {
        %ignore_list = map { lc($_) => 1 } split /,/, lc($config{smart_attack_ignore_list});
    }

    # WxAll เรียงระยะทางมาให้แล้ว (ใกล้สุดก่อน)
    for my $mon_data (@{$monsters_list}) {
        
        next unless $mon_data->{ks_ok};
        
        my $mon_name = lc($mon_data->{name} || '');
        my $mon_cid  = $mon_data->{classid} || '';

        if (%ignore_list) {
            next if (exists $ignore_list{$mon_name} || 
                     exists $ignore_list{$mon_cid});
        }
        unless ($attack_all) {
            next unless (exists $attack_list{$mon_name} || 
                         exists $attack_list{$mon_cid});
        }
        
        my $obj = $Globals::monsters{$mon_data->{id}};
        
        # *** ลบที่เช็ค Field::isReachable ตรงนี้ออก (ที่ error) ***
        
        if ($obj && blessed($obj) && $obj->isa('Actor::Monster') && !$obj->{dead}) {
            return $obj; # เจอเป้าหมาย! (ที่หัวหน้า กรองมาแล้วว่าเดินถึง)
        }
    }
    return undef; # ไม่เจอเป้าหมายในโซน
}

# --- ส่วนของ "คนเก็บกวาด" (Person 3) ---
sub find_item_in_zone {
    my ($items_list, $mob_count_in_zone) = @_; # <--- เอา $you_pos ออก
    
    my $safe_mob_count = $config{smart_pickup_safe_mobs} // 3;
    
    if ($mob_count_in_zone > $safe_mob_count) {
        return undef; # ไม่ปลอดภัย!
    }

    # *** โค้ดคลีนขึ้นเยอะ! ***
    # "หัวหน้า" (WxAll) กรองมาแล้วว่าของทุกชิ้นเดินไปถึง
    # แค่เช็คว่ามีของตก (และปลอดภัย) ก็พอ
    if (@{$items_list}) {
        # (อย่าลืมตั้งค่า items_control.txt ด้วยนะ!)
        return 1; # ปลอดภัย + มีของ = อนุญาตให้ Greed
    }
    
    return undef; # ไม่มีของให้เก็บ
}

1;