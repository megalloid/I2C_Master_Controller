# ---------------------------------------------------------------------------
# ZYNQ MINI Rev B  —  Pin / IOSTANDARD constraints  (PS+PL build)
#
# Источник: datasheets/ZYNQ_MINI_REVB Schematic.pdf  (листы 5 и 12).
# Все указанные ниже выводы относятся к BANK 35 (3.3 V) или BANK 34 (3.3 V).
# ---------------------------------------------------------------------------

# ----- I2C линии к внешнему SSD1306-модулю (через 40-pin GPIO-разъём CAM1) --
# SDA → T20  (FPGA_GPIO_15P_34), SCL → P20 (FPGA_GPIO_14N_34); BANK 34, 3.3 V
# (внутренний OLED-разъём J4 на пинах E18/E19 в этом проекте НЕ используется)
set_property PACKAGE_PIN T20 [get_ports oled_sda_io]
set_property PACKAGE_PIN P20 [get_ports oled_scl_io]
set_property IOSTANDARD LVCMOS33 [get_ports oled_sda_io]
set_property IOSTANDARD LVCMOS33 [get_ports oled_scl_io]
set_property PULLUP TRUE         [get_ports oled_sda_io]
set_property PULLUP TRUE         [get_ports oled_scl_io]

# ----- Пользовательские LED (FPGA_PL_LED1..4, BANK 34) ----------------------
set_property PACKAGE_PIN T12 [get_ports {led_o[0]}]
set_property PACKAGE_PIN U12 [get_ports {led_o[1]}]
set_property PACKAGE_PIN V12 [get_ports {led_o[2]}]
set_property PACKAGE_PIN W13 [get_ports {led_o[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[*]}]

# ----- Пользовательские кнопки (FPGA_PL_KEY1/2, BANK 35) --------------------
# Активный уровень — низкий (нажата = 0).
set_property PACKAGE_PIN M20 [get_ports key1_n_i]
set_property PACKAGE_PIN M19 [get_ports key2_n_i]
set_property IOSTANDARD LVCMOS33 [get_ports {key1_n_i key2_n_i}]
set_property PULLUP TRUE [get_ports {key1_n_i key2_n_i}]

# ---------------------------------------------------------------------------
# Системный 50 МГц для PL — НЕ используется в PS+PL варианте: тактирование
# логики идёт от FCLK_CLK0 процессорной системы. Если захотите подать
# внешний 50 МГц в обход PS — раскомментируйте:
# ---------------------------------------------------------------------------
# set_property PACKAGE_PIN K17 [get_ports clk_50m_i]
# set_property IOSTANDARD LVCMOS33 [get_ports clk_50m_i]
# create_clock -name clk_50m -period 20.000 [get_ports clk_50m_i]
