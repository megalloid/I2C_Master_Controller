# ===========================================================================
# Timing Constraints — SSD1306 OLED Test — ALINX AX301
# ===========================================================================

# 50 MHz system clock
create_clock -name clk_50m -period 20.000 [get_ports clk_50m]

# I2C, LEDs, 7-seg — slow async I/O, no timing analysis needed
set_false_path -from [get_ports {rst_n key_start key_anim}]
set_false_path -to   [get_ports {led[*] seg_sel[*] seg_data[*]}]
set_false_path -from [get_ports {i2c_sda i2c_scl}]
set_false_path -to   [get_ports {i2c_sda i2c_scl}]
