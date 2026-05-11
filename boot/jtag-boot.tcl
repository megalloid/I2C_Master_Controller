# =============================================================================
#  xsct/xsdb script: загрузка Zynq Mini Rev B через JTAG (минуя SD/BOOT.BIN).
#
#  Запуск:
#     source /opt/xilinx/2025.2/Vitis/settings64.sh
#     xsct boot/jtag-boot.tcl
#
#  По умолчанию делает «full» путь:
#     1. connect → hw_server
#     2. system reset
#     3. ps7_init.tcl (DDR/PLL/MIO/UART)  — без FSBL
#     4. fpga -file ... .bit  (через PCAP)
#     5. dow u-boot                       — загрузка U-Boot в DDR
#     6. con                              — запуск U-Boot
#
#  Альтернативные режимы — через env-переменную JTAG_MODE:
#     JTAG_MODE=fsbl     — загрузить только FSBL и оставить плату в нём
#                          (полезно, чтобы увидеть `Xilinx ... First Stage
#                           Boot Loader Release 2025.2` в UART);
#     JTAG_MODE=ps7only  — только ps7_init, чтобы убедиться что DDR жив;
#     JTAG_MODE=full     — (default) ps7_init + bitstream + u-boot.
#
#  ВАЖНО: JP1 на плате должен быть выставлен в JTAG-режим (boot mode pins =
#  jtag). Иначе BootROM первым прочитает SD и xsct не сможет «перехватить»
#  цикл. После теста — JP1 обратно в SD-режим.
# =============================================================================

# --------------------------------- параметры ---------------------------------
set ::repo_root  [pwd]
set ::bit_file   "$::repo_root/vivado/proj/zynq_mini_oled.runs/impl_1/zynq_mini_oled_top.bit"
set ::fsbl_elf   "$::repo_root/vitis/workspace/zynq_mini_oled_platform/zynq_fsbl/build/fsbl.elf"
set ::uboot_elf  "$::repo_root/buildroot-build/images/u-boot"
# ps7_init.tcl ищем в нескольких местах: Vitis 2025.2 кладёт его в
# .../export/<platform>/hw/sdt/ps7_init.tcl, а классический FSBL — в
# самой папке FSBL.
set ::ps7_init ""
foreach ps7_candidate [list \
        "$::repo_root/vitis/workspace/zynq_mini_oled_platform/export/zynq_mini_oled_platform/hw/sdt/ps7_init.tcl" \
        "$::repo_root/vitis/workspace/zynq_mini_oled_platform/zynq_fsbl/ps7_init.tcl" \
        "$::repo_root/vitis/workspace/zynq_mini_oled_platform/ps7_cortexa9_0/standalone_ps7_cortexa9_0/bsp/hw_artifacts/ps7_init.tcl" \
        "$::repo_root/vitis/workspace/zynq_mini_oled_platform/export/zynq_mini_oled_platform/sw/standalone_ps7_cortexa9_0/hw_artifacts/ps7_init.tcl"] {
    if {[file exists $ps7_candidate]} {
        set ::ps7_init $ps7_candidate
        break
    }
}

# Адреса в DDR для прямой загрузки kernel+dtb (используется только если хотите
# обойти U-Boot и стартовать ядро напрямую — мы это пока не делаем).
set ::ker_addr   0x3000000
set ::dtb_addr   0x2A00000
set ::uimage     "$::repo_root/buildroot-build/images/uImage"
set ::dtb_file   "$::repo_root/buildroot-build/images/zynq-mini-revb.dtb"

# --- DTB для U-Boot --------------------------------------------------------
# xilinx_zynq_virt_defconfig имеет CONFIG_OF_BOARD=y — это значит U-Boot
# ожидает указатель на DTB в регистре R2 при старте (стандартный ARM
# boot-protocol: r0=0, r1=mach_id|0xffffffff, r2=dtb_ptr). На штатном
# SD-сценарии DTB передаёт SPL/FSBL. Через JTAG SPL мы не используем,
# поэтому грузим DTB сами на адрес 0x100000 и руками выставляем R2.
#
# В качестве DTB берём ZC706 (на нём stdout-path=&uart1 на MIO48/49
# и DDR=1GiB — совпадает с нашей платой). Этот DTB U-Boot пересобирает
# при каждом `make buildroot-build`.
set ::ub_dtb_addr  0x00100000
set ::ub_dtb       "$::repo_root/buildroot-build/build/uboot-2024.01/arch/arm/dts/zynq-zc706.dtb"

# Режим — по умолчанию full
if {[info exists ::env(JTAG_MODE)]} {
    set ::mode $::env(JTAG_MODE)
} else {
    set ::mode "full"
}
puts "=== JTAG_MODE = $::mode ==="

# ------------------------- helper-ы -----------------------------------------

proc check_file {label path} {
    if {![file exists $path]} {
        puts "ERROR: $label не найден: $path"
        exit 1
    }
    puts "OK:   $label = $path"
}

proc select_arm0 {} {
    # Имя у Cortex-A9 в xsct: "ARM Cortex-A9 MPCore #0" (Zynq-7000).
    targets -set -filter {name =~ "*Cortex-A9*#0*" || name =~ "ARM*Cortex-A9*0"}
}

# --------------------------- 1. валидация файлов ----------------------------
puts "\n>>> 1. проверка артефактов"
check_file "bitstream"  $::bit_file
switch $::mode {
    "fsbl" {
        # для FSBL-режима ps7_init.tcl не нужен — FSBL сам делает init
        check_file "fsbl.elf"  $::fsbl_elf
    }
    "full" - "ps7only" {
        if {$::ps7_init eq ""} {
            puts "ERROR: ps7_init.tcl не найден ни в одном из стандартных мест"
            puts "       (export/.../hw/sdt/, zynq_fsbl/, bsp/hw_artifacts/)."
            puts "       Пересоберите Vitis-platform:  make vitis-build"
            exit 1
        }
        check_file "ps7_init"   $::ps7_init
        if {$::mode eq "full"} {
            check_file "u-boot"    $::uboot_elf
            # DTB критически важен — без него CONFIG_OF_BOARD U-Boot падает
            # в hang() ещё до banner-а (молча, потому что DM-serial не успевает
            # стартовать). См. doc/GUIDE_BUILDROOT.md → FAQ «JTAG: UART молчит».
            if {![file exists $::ub_dtb]} {
                puts "ERROR: U-Boot DTB не найден: $::ub_dtb"
                puts "       Сначала прогоните 'make buildroot-build' — он соберёт"
                puts "       arch/arm/dts/zynq-zc706.dtb внутри U-Boot."
                exit 1
            }
            check_file "ub-dtb"    $::ub_dtb
        }
    }
}

# --------------------------- 2. подключение к JTAG --------------------------
puts "\n>>> 2. connect"
connect
puts "    targets:"
targets
puts "    jtag chain:"
jtag targets

# 2.A. Проверка соответствия PART-ID
#
# Если на плате стоит xc7z020, а bitstream/FSBL собраны под xc7z010
# (или наоборот) — FSBL отваливается на верификации заголовка bitstream-а
# либо вешает CPU в неопределённое состояние, и JTAG потом приходится
# восстанавливать через power-cycle. Лучше остановиться сразу.
set ::jtag_part ""
catch {
    set jt [jtag targets]
    foreach ln [split $jt "\n"] {
        if {[regexp {(xc7z\w+)} $ln -> m]} {
            set ::jtag_part $m
            break
        }
    }
}
puts "    detected silicon = '$::jtag_part'"
if {$::jtag_part eq ""} {
    puts "WARNING: не удалось определить part-id через JTAG."
    puts "         Убедитесь что плата включена, JP1 в JTAG-mode,"
    puts "         JTAG-кабель подключён."
} else {
    # Из .bit-файла читаем part-id (он в заголовке как ASCII строка
    # вроде '7z020clg400').
    set bit_id ""
    if {[file exists $::bit_file]} {
        set fh [open $::bit_file rb]
        set hdr [read $fh 200]
        close $fh
        if {[regexp {(7z0\d+clg\d+)} $hdr -> m]} {
            set bit_id $m
        }
    }
    if {$bit_id ne ""} {
        puts "    bitstream part = '$bit_id'"
        if {![string match "*$bit_id*" $::jtag_part] && ![string match "*[string range $::jtag_part 4 6]*" $bit_id]} {
            puts "ERROR: part-id mismatch!"
            puts "       железо = $::jtag_part,  bitstream = $bit_id"
            puts "       Пересоберите Vivado для нужного чипа:"
            puts "         make vivado-build PART=$::jtag_part""clg400-1"
            puts "         make vitis-build"
            puts "         make boot-bin && make sdcard-quick"
            disconnect
            exit 1
        }
        puts "    part-id OK ✓"
    }
}

# --------------------------- 3. системный сброс -----------------------------
puts "\n>>> 3. system reset"
select_arm0
rst -system
after 200

# --------------------------- 4. ps7_init / FSBL -----------------------------
puts "\n>>> 4. PS init"
switch $::mode {
    "fsbl" {
        puts "    режим: загрузим FSBL и оставим работать"
        select_arm0
        dow $::fsbl_elf
        con
        puts "    FSBL запущен. Смотрите UART. Скрипт завершается."
        disconnect
        exit 0
    }
    "ps7only" - "full" {
        puts "    режим: ps7_init из tcl (без FSBL)"
        select_arm0
        source $::ps7_init
        ps7_init
        ps7_post_config
    }
    default {
        puts "ERROR: неизвестный JTAG_MODE=$::mode"
        exit 1
    }
}

# --------------------------- 5. bitstream через PCAP -----------------------
puts "\n>>> 5. fpga -file (bitstream через PCAP)"
fpga -file $::bit_file
# DONE-LED должен загореться сразу после этой команды.
puts "    bitstream загружен. На плате DONE LED должен гореть."

if {$::mode eq "ps7only"} {
    puts "\nps7only: PS + bitstream подняты. Дальше — ничего."
    puts "         Можете напрямую писать/читать DDR через 'mrd 0x10000000' и т.п."
    disconnect
    exit 0
}

# --------------------------- 6. u-boot.elf в DDR ---------------------------
puts "\n>>> 6. dow u-boot"
select_arm0
dow $::uboot_elf

# --------------------------- 6.A. DTB для U-Boot --------------------------
puts "\n>>> 6.A. dow DTB → $::ub_dtb_addr"
dow -data $::ub_dtb $::ub_dtb_addr

# --------------------------- 6.B. ARM boot-protocol regs ------------------
# r0 = 0          (зарезервировано)
# r1 = mach_id    (для DT-only kernel/U-Boot ставим 0xffffffff)
# r2 = dtb_ptr    (адрес DTB в RAM)
# pc = entry      (CONFIG_TEXT_BASE U-Boot)
puts "\n>>> 6.B. ARM boot regs (r0=0, r1=0xffffffff, r2=$::ub_dtb_addr)"
rwr r0 0
rwr r1 0xffffffff
rwr r2 $::ub_dtb_addr
rwr pc 0x04000000

# --------------------------- 7. запуск -------------------------------------
puts "\n>>> 7. con — запуск U-Boot"
con
puts "    U-Boot запущен. Смотрите UART (115200 8N1 на /dev/ttyUSB1)."

disconnect
exit 0
