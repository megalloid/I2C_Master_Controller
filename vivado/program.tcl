# ---------------------------------------------------------------------------
# Vivado 2025.2  —  Прошивка ZYNQ MINI через JTAG.
#
#   source /opt/xilinx/2025.2/Vivado/settings64.sh
#   vivado -mode batch -source vivado/program.tcl
# ---------------------------------------------------------------------------

set repo_root [file normalize [file join [file dirname [info script]] ..]]
set proj_name zynq_mini_oled
set top_module zynq_mini_oled_top
set bit [file join $repo_root vivado/proj/${proj_name}.runs/impl_1/${top_module}.bit]

if {![file exists $bit]} {
    error "Bitstream not found: $bit. Сначала: make vivado-build"
}

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target

# Поддерживаем оба чипа Zynq-7000 серии MINI: xc7z010 и xc7z020.
set hw_devs [get_hw_devices -filter {NAME =~ "xc7z010_*" || NAME =~ "xc7z020_*"}]
if {[llength $hw_devs] == 0} {
    error "No xc7z010_* / xc7z020_* device found on JTAG. Проверьте подключение."
}
set dev [lindex $hw_devs 0]
puts "INFO: programming device [get_property NAME $dev]"
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev

close_hw_target
close_hw_manager
puts "DONE: device programmed with $bit"
