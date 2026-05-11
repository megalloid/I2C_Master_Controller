# read-bootmode.tcl — диагностика boot mode pins на Zynq-7000
puts ""
puts "=== read-bootmode.tcl: connect ==="
if {[catch {connect} err]} {
    puts "connect error: $err"
}

puts ""
puts "=== JTAG TAPs visible on the chain ==="
catch {jtag targets} jt
puts $jt

puts ""
puts "=== CPU/DAP targets ==="
catch {targets} ts
puts $ts

# попытаемся прочитать SLCR через любой доступный target
set candidates {}
foreach line [split $ts "\n"] {
    if {[regexp {^\s*([0-9]+)\s+(.+)$} $line _ id name]} {
        lappend candidates [list $id $name]
    }
}
puts ""
puts "available target ids: $candidates"

# берём первый ARM DAP, иначе Cortex-A9 #0, иначе любой
set chosen ""
foreach c $candidates {
    if {[string match "*DAP*" [lindex $c 1]]} { set chosen [lindex $c 0]; break }
}
if {$chosen eq ""} {
    foreach c $candidates {
        if {[string match "*Cortex-A9 MPCore #0*" [lindex $c 1]]} { set chosen [lindex $c 0]; break }
    }
}
if {$chosen eq "" && [llength $candidates] > 0} {
    set chosen [lindex [lindex $candidates 0] 0]
}
if {$chosen eq ""} {
    puts "!!! no targets visible — JTAG chain empty or TAP disabled !!!"
    puts "Возможные причины:"
    puts "  * плата без питания / JTAG-кабель отсоединён"
    puts "  * BootROM в lockdown loop (не нашёл BOOT.BIN, отключил JTAG TAP)"
    puts "  * boot mode pins сэмплированы как secure boot"
    disconnect
    exit 1
}

puts ""
puts "=== selecting target id=$chosen ==="
target $chosen

puts ""
puts "=== reading SLCR boot-mode group ==="
foreach {addr name} {
    0xF800025C boot_mode_reg
    0xF8000258 reboot_status_reg
    0xF8000254 ps_pll_status
    0xF8000900 lvl_shftr_en
} {
    if {[catch {mrd -force $addr 1} v]} {
        puts "  $name ($addr): READ FAILED ($v)"
    } else {
        puts "  $name ($addr): $v"
    }
}

puts ""
puts "=== MIO pin config (MIO3..MIO6) ==="
foreach {addr name} {
    0xF800070C MIO_PIN_03
    0xF8000710 MIO_PIN_04
    0xF8000714 MIO_PIN_05
    0xF8000718 MIO_PIN_06
} {
    if {[catch {mrd -force $addr 1} v]} {
        puts "  $name ($addr): READ FAILED ($v)"
    } else {
        puts "  $name ($addr): $v"
    }
}

disconnect
puts ""
puts "=== done ==="
