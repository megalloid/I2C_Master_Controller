# SDC constraints for I2C EEPROM Test — AX301 board
# 50 MHz oscillator
create_clock -name clk -period 20.000 [get_ports {clk}]

# I2C is slow (100 kHz) — relax I/O timing
set_false_path -from [get_ports {i2c_sda i2c_scl key1 rst_n}]
set_false_path -to   [get_ports {i2c_sda i2c_scl led[*] seg_sel[*] seg_data[*]}]
