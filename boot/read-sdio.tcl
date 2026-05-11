# read-sdio.tcl — диагностика конфигурации SDIO0 и MIO для SD0 (Zynq-7000)
#
# Использует тот же xsct + JTAG. Читает:
#   MIO_PIN_40..45 (0xF80007A0..0xF80007B4) — pin function для SD0
#   APER_CLK_CTRL  (0xF800012C bit 10)      — clock gate SD0
#   SDIO_CLK_CTRL  (0xF8000150)             — SDIO0 PLL clock control
#   SD0 host:
#     0xE0100000+0x2C  CLOCK_CONTROL
#     0xE0100000+0x24  PRESENT_STATE  (CMD/DAT inhibit bits)
#     0xE0100000+0x30  ERROR_STATUS

puts ""
puts "=== read-sdio.tcl: connect ==="
if {[catch {connect} err]} { puts "connect error: $err"; exit 1 }

# выбираем ARM Cortex-A9 #0 (Running) для чтения через DAP
catch {targets} ts
set chosen ""
foreach line [split $ts "\n"] {
    if {[regexp {^\s*([0-9]+)\s+(.+)$} $line _ id name]} {
        if {[string match "*Cortex-A9 MPCore #0*" $name]} { set chosen $id; break }
    }
}
if {$chosen eq ""} {
    foreach line [split $ts "\n"] {
        if {[regexp {^\s*([0-9]+)\s+(.+)$} $line _ id name]} {
            if {[string match "*APU*" $name] || [string match "*DAP*" $name]} {
                set chosen $id; break
            }
        }
    }
}
if {$chosen eq ""} { puts "no JTAG target available"; disconnect; exit 1 }
target $chosen
puts "selected target id=$chosen"

puts ""
puts "=== MIO_PIN_40..45 (SD0 expected here) ==="
foreach offset {0 4 8 12 16 20} {
    set addr [expr {0xF80007A0 + $offset}]
    set name [format "MIO_PIN_%02d" [expr {40 + $offset/4}]]
    if {[catch {mrd -force $addr 1} v]} {
        puts "  $name (0x[format %X $addr]): READ FAILED"
    } else {
        # value | decode L3_SEL
        regexp {([0-9A-Fa-f]+):\s+([0-9A-Fa-f]+)} $v -> a val
        set valInt [expr "0x$val"]
        set l3 [expr {($valInt >> 5) & 0x7}]
        set tri [expr {$valInt & 0x1}]
        set pullup [expr {($valInt >> 12) & 0x1}]
        set speed [expr {($valInt >> 8) & 0x1}]
        set io_type [expr {($valInt >> 9) & 0x7}]
        set func ""
        switch -- $l3 {
            0 { set func "GPIO/MIO_default" }
            1 { set func "Reserved" }
            2 { set func "Reserved" }
            3 { set func "Reserved" }
            4 { set func "SDIO" }
            5 { set func "Reserved" }
            6 { set func "Reserved" }
            7 { set func "Reserved" }
        }
        puts [format "  %s = 0x%08X  L3_SEL=%d (%s) TRI=%d PullUp=%d Speed=%s IOtype=%d" \
              $name $valInt $l3 $func $tri $pullup [expr {$speed?"fast":"slow"}] $io_type]
    }
}

puts ""
puts "=== Clocks for SD0 ==="
foreach {addr name} {
    0xF800012C APER_CLK_CTRL
    0xF8000150 SDIO_CLK_CTRL
    0xF8000170 SDIO_CLK_CTRL_alt
    0xF8000164 SDIO_RST_CTRL
} {
    if {[catch {mrd -force $addr 1} v]} { puts "  $name: READ FAILED" } else { puts "  $name ($addr): $v" }
}

puts ""
puts "=== SDIO0 host controller (base 0xE0100000) ==="
foreach {off name} {
    0x24 PRESENT_STATE
    0x28 HOST_CONTROL
    0x2C CLOCK_CONTROL
    0x2E TIMEOUT_CONTROL
    0x30 NORM_ERR_STATUS
    0x34 NORM_ERR_INT_STATUS
    0x3C SLOT_INT_VERSION
    0x40 CAPABILITIES
} {
    set addr [expr {0xE0100000 + $off}]
    if {[catch {mrd -force $addr 1} v]} {
        puts "  $name (0x[format %08X $addr]): READ FAILED"
    } else {
        puts "  $name (0x[format %08X $addr]): $v"
    }
}

disconnect
puts ""
puts "=== done ==="
