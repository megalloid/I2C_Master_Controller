# ---------------------------------------------------------------------------
# xsdb script: program PL bitstream + load ELF + run on Cortex-A9 #0.
#
# Канонический порядок шагов для Zynq-7000 без FSBL (UG1400, AR74463):
#   1) подключение к hw_server и остановка APU
#   2) прошивка PL bitstream (PS не трогаем)
#   3) rst -system  — гарантирует чистое состояние PS перед ps7_init
#   4) ps7_init / ps7_post_config — настраиваем DDR controller, MIO, clocks
#   5) загрузка ELF в DDR и старт ядра
#
# Запуск:
#   source /opt/xilinx/2025.2/Vitis/settings64.sh
#   xsdb vitis/run.tcl
# или через Makefile:
#   make vitis-run
# ---------------------------------------------------------------------------

if {![info exists REPO]} {
    set REPO [file normalize [file join [file dirname [info script]] ..]]
}

set BIT [file join $REPO vivado/proj/zynq_mini_oled.runs/impl_1/zynq_mini_oled_top.bit]
set ELF [file join $REPO vitis/workspace/oled_demo/build/oled_demo.elf]

# В Vitis 2025.2 IDE-шный ps7_init.tcl для приложения лежит в _ide/psinit;
# fallback — общий из platform/hw/sdt.
set PS7_CANDIDATES [list \
    [file join $REPO vitis/workspace/oled_demo/_ide/psinit/ps7_init.tcl] \
    [file join $REPO vitis/workspace/zynq_mini_oled_platform/hw/sdt/ps7_init.tcl] \
]
set PS7_INIT_TCL ""
foreach c $PS7_CANDIDATES {
    if {[file exists $c]} { set PS7_INIT_TCL $c; break }
}
if {$PS7_INIT_TCL eq ""} { error "ps7_init.tcl не найден; пересоберите Vitis: make vitis-build" }

foreach f [list $BIT $ELF] {
    if {![file exists $f]} { error "missing artefact: $f" }
}

puts "INFO: connecting to hw_server..."
connect

# ---------------------------------------------------------------
# 0. Диагностика и попытка реанимации PS (если он завис)
# ---------------------------------------------------------------
proc has_apu {} {
    return [expr {![catch {targets -filter {name =~ "APU*"}} r] && [llength $r] > 0}]
}

puts "INFO: detected JTAG targets:"
puts [targets]

set chip_z010 [llength [targets -filter {name =~ "xc7z010*"}]]
set chip_z020 [llength [targets -filter {name =~ "xc7z020*"}]]
if {$chip_z010 == 0 && $chip_z020 == 0} {
    error "На JTAG не найден ни xc7z010, ни xc7z020.  Проверьте кабель и питание платы."
}
if {$chip_z020 > 0 && $chip_z010 > 0} {
    puts "WARN: видны оба xc7z010 и xc7z020 — мульти-плата?"
} elseif {$chip_z020 > 0} {
    puts "INFO: на плате xc7z020"
} else {
    puts "INFO: на плате xc7z010"
}

# Если APU не появился — почти всегда это означает, что PS повис на FSBL
# (boot-mode установлен в QSPI/SD, а валидной прошивки там нет).  Пробуем:
#   1) JTAG SRST
#   2) SLCR soft-reset через DAP (если DAP жив)
if {![has_apu]} {
    puts "WARN: APU не виден на JTAG.  PS либо висит, либо DAP заблокирован."
    puts "      Пробую системный сброс через JTAG (rst -srst)..."
    catch {
        targets -set -filter {name =~ "xc7z*"}
        rst -srst
    }
    after 1500
    puts "INFO: targets after rst -srst:"
    puts [targets]

    if {![has_apu]} {
        puts "WARN: APU всё ещё не виден.  Пробую SLCR soft-reset через DAP..."
        catch {
            targets -set -filter {name =~ "DAP*"}
            mwr -force 0xF8000008 0xDF0D    ;# SLCR_UNLOCK
            mwr -force 0xF8000200 0x00000001 ;# PSS_RST_CTRL: PSS_RST = 1
            after 500
        }
        after 1000
        puts "INFO: targets after SLCR soft-reset:"
        puts [targets]
    }

    if {![has_apu]} {
        error "APU так и не появился на JTAG.  Требуется физическое вмешательство:\n
\n
  1) Проверьте BOOT-переключатель SW1 на плате — установите его в режим JTAG\n
     (на ZYNQ MINI это положение, при котором MIO\[5:2\] = 0).\n
\n
  2) Сделайте power-cycle: отсоедините и снова подключите питание/USB.\n
\n
  3) Если на плате есть кнопка PS_POR (на этой плате — K4 ARM_nPOR) —\n
     нажмите её один раз СРАЗУ перед запуском make vitis-run.\n
\n
  4) Если на JTAG висит несколько устройств (например, рядом стоит другая плата) —\n
     отключите лишнее.  Список выше:\n
[targets]"
    }
}

# ---------------------------------------------------------------
# 1. Останавливаем APU
# ---------------------------------------------------------------
puts "INFO: APU обнаружена, продолжаю штатный flow"
puts "INFO: stopping APU"
targets -set -filter {name =~ "APU*"}
catch { stop }

# ---------------------------------------------------------------
# 2. Прошиваем PL bitstream
# ---------------------------------------------------------------
puts "INFO: programming PL with $BIT"
fpga -file $BIT

# ---------------------------------------------------------------
# 3. Полный системный сброс PS — чистое состояние перед ps7_init
# ---------------------------------------------------------------
puts "INFO: system reset"
targets -set -filter {name =~ "APU*"}
rst -system

# После rst -system ядро автоматически в halt. Переходим на core #0.
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}

# ---------------------------------------------------------------
# 4. Инициализация PS7 (DDR, MIO, clocks)
# ---------------------------------------------------------------
puts "INFO: sourcing $PS7_INIT_TCL"
source $PS7_INIT_TCL
puts "INFO: ps7_init"
ps7_init
puts "INFO: ps7_post_config"
ps7_post_config

# ---------------------------------------------------------------
# 5. Загрузка ELF в DDR и старт
# ---------------------------------------------------------------
puts "INFO: downloading $ELF"
dow $ELF
puts "INFO: starting Cortex-A9 #0"
con

puts "DONE: ELF запущен. Откройте UART (115200 8N1) на CH340."
exit
