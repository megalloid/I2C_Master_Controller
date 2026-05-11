# ---------------------------------------------------------------------------
# Vivado 2025.2  —  ZYNQ MINI Rev B (XC7Z020-CLG400, default)  —  PS+PL build script
#
# Создаёт проект, Block Design (Zynq PS7 + i2c_master_axi через AXI4-Lite),
# назначает констрейнты, прогоняет synthesis → implementation → bitstream
# и экспортирует .xsa для Vitis.
#
# Запуск (из корня репозитория):
#     source /opt/xilinx/2025.2/Vivado/settings64.sh
#     vivado -mode batch -source vivado/build.tcl
# ---------------------------------------------------------------------------

set repo_root  [file normalize [file join [file dirname [info script]] ..]]
set proj_dir   [file join $repo_root vivado/proj]
set proj_name  zynq_mini_oled
set top_module zynq_mini_oled_top
set bd_name    system

# ZYNQ MINI Rev B существует в двух исполнениях:
#   * XC7Z010CLG400  — урезанная (Artix-7-like PL, 28K LUT)
#   * XC7Z020CLG400  — полноразмерная (Artix-7, 53K LUT)   ← наша плата
# Speed-grade -1 / -2 / -3 (биннинг) роли в выборе не играет — IDCODE
# одинаков, bitstream совместим. См. doc/GUIDE_BUILDROOT.md FAQ.
#
# Часть выбирается переменной окружения VIVADO_PART, которую
# Makefile прокидывает из make-переменной PART:
#   make vivado-build                              # = xc7z020clg400-1 (default Makefile)
#   make vivado-build PART=xc7z020clg400-2         # биннинг -2
#   make vivado-build PART=xc7z010clg400-1         # для урезанной платы
#
# Default здесь синхронизирован с Makefile (xc7z020clg400-1) — чтобы
# `vivado -source build.tcl` без env тоже собирал правильно.
if {[info exists ::env(VIVADO_PART)] && $::env(VIVADO_PART) ne ""} {
    set part_id $::env(VIVADO_PART)
} else {
    set part_id xc7z020clg400-1
}
puts "INFO: target part = $part_id"

# I2C-мастер ожидает clk-домен = FCLK_CLK0.  Для f_SCL = 100 кГц при FCLK0=50 МГц:
#   PRESCALE = 50_000_000 / (4 * 100_000) - 1 = 124
set fclk0_mhz   50
set prescale    124

# ---------------------------------------------------------------
# 0. Чистый старт
# ---------------------------------------------------------------
file mkdir $proj_dir
if {[file exists [file join $proj_dir $proj_name.xpr]]} {
    puts "INFO: removing previous project at $proj_dir"
    file delete -force $proj_dir
    file mkdir $proj_dir
}

create_project $proj_name $proj_dir -part $part_id -force
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]

# ---------------------------------------------------------------
# 1. Добавляем RTL ядра I2C-мастера
# ---------------------------------------------------------------
add_files -norecurse [list \
    [file join $repo_root rtl/i2c_master_core.v] \
    [file join $repo_root rtl/i2c_master_axi.v] \
]
update_compile_order -fileset sources_1

# ---------------------------------------------------------------
# 2. Block Design: PS7 + i2c_master_axi (через Module Reference)
# ---------------------------------------------------------------
create_bd_design $bd_name
current_bd_design $bd_name

# ---- 2.1 Zynq PS7 ---------------------------------------------------------
# Конфигурация под ZYNQ MINI Rev B (см. datasheets/ZYNQ_MINI_REVB Schematic.pdf).
#
# СПЕЦИФИКАЦИЯ платы (подтверждено пользователем):
#   * U1 = MT41J256M16RE-125, single chip, 16-bit data, 512 MB DDR3
#   * X2 = 33.3333 MHz (PS_CLK_500)
#   * BANK 0 (500) = LVCMOS 3.3V (MIO0..15)
#   * BANK 1 (501) = LVCMOS 1.8V (MIO16..53)
#   * QSPI single-SS: MIO1..6 + MIO8 (feedback)
#   * SD0:   MIO40..45  (TF1 master, BOOT=11) — БЕЗ CD/WP/Power-enable
#            (TXS02612 level shifter: VCCA=1V8 ↔ VCCB=3V3, SEL=GND)
#   * ENET0: MIO16..27 + MDIO на MIO52..53 (RTL8211E PHY, U18)
#   * USB0:  MIO28..39, reset на MIO7 (USB3320C PHY, U19)
#   * UART1: TX=MIO48, RX=MIO49 (через CH340E на USB type-C)
#
# КРИТИЧНО: явных CONFIG.PCW_MIO_xx_IOTYPE НЕ задаём — Vivado сам
# подтянет уровни из PCW_PRESET_BANKn_VOLTAGE (Bank0=3.3V, Bank1=1.8V).
# Если задать явный IOTYPE = LVCMOS 3.3V для пина Bank 1, Vivado
# принудительно поставит input threshold для 3.3V (Vih ≈ 2.0V) —
# при реальном питании bank-а 1.8V high-уровень 1.8V будет читаться
# как low → периферия (SD, RGMII, ULPI) перестаёт получать ответ.
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config { \
        make_external "FIXED_IO, DDR" \
        Master Disable \
        Slave  Disable \
    } [get_bd_cells ps7]

# =====================================================================
# 2.1.A.  DDR + PLL + UART — берём ДОСЛОВНО из проверенного preset-а
# ~/devel/xilinx/configs/ZynqMini.tcl (XCM006/ZynqMini Rev B).
#
# Ранее у нас здесь были «свои» цифры: PCW_UIPARAM_DDR_FREQ_MHZ=525,
# отсутствовали timings (T_RCD/T_RP/T_RC/T_RAS_MIN/T_FAW/CL/CWL),
# не были заданы геометрия чипа (BANK/ROW/COL_ADDR_COUNT, DRAM_WIDTH,
# DEVICE_CAPACITY), SPEED_BIN, верхний адрес DDR, делители PLL.
# В результате ps7_init.tcl получался расходящийся с реальным железом,
# DDR не инициализировался → FSBL зависал ДО открытия UART, и в
# терминале была тишина. Этот блок один-в-один совпадает с заводским
# preset-ом и проверен в железе.
# =====================================================================
set_property -dict [list \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE          {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE          {LVCMOS 1.8V} \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ    {33.333333} \
    \
    \
    CONFIG.PCW_DDR_RAM_HIGHADDR              {0x1FFFFFFF} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO            {MT41J256M16 RE-125} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH         {16 Bit} \
    CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH        {16 Bits} \
    CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY   {4096 MBits} \
    CONFIG.PCW_UIPARAM_DDR_SPEED_BIN         {DDR3_1066F} \
    CONFIG.PCW_UIPARAM_DDR_ECC               {Disabled} \
    CONFIG.PCW_UIPARAM_DDR_USE_INTERNAL_VREF {0} \
    CONFIG.PCW_UIPARAM_DDR_BANK_ADDR_COUNT   {3} \
    CONFIG.PCW_UIPARAM_DDR_ROW_ADDR_COUNT    {15} \
    CONFIG.PCW_UIPARAM_DDR_COL_ADDR_COUNT    {10} \
    CONFIG.PCW_UIPARAM_DDR_CL                {7} \
    CONFIG.PCW_UIPARAM_DDR_CWL               {6} \
    CONFIG.PCW_UIPARAM_DDR_T_RCD             {7} \
    CONFIG.PCW_UIPARAM_DDR_T_RP              {7} \
    CONFIG.PCW_UIPARAM_DDR_T_RC              {48.91} \
    CONFIG.PCW_UIPARAM_DDR_T_RAS_MIN         {35.0} \
    CONFIG.PCW_UIPARAM_DDR_T_FAW             {40.0} \
    CONFIG.PCW_UIPARAM_ACT_DDR_FREQ_MHZ      {533.333374} \
    \
    \
    CONFIG.PCW_ARMPLL_CTRL_FBDIV             {40} \
    CONFIG.PCW_IOPLL_CTRL_FBDIV              {54} \
    CONFIG.PCW_DDRPLL_CTRL_FBDIV             {32} \
    CONFIG.PCW_CPU_CPU_PLL_FREQMHZ           {1333.333} \
    CONFIG.PCW_IO_IO_PLL_FREQMHZ             {1800.000} \
    CONFIG.PCW_DDR_DDR_PLL_FREQMHZ           {1066.667} \
    CONFIG.PCW_CPU_PERIPHERAL_DIVISOR0       {2} \
    CONFIG.PCW_DDR_PERIPHERAL_DIVISOR0       {2} \
    CONFIG.PCW_ACT_APU_PERIPHERAL_FREQMHZ    {666.666687} \
    \
    \
    CONFIG.PCW_UART_PERIPHERAL_VALID         {1} \
    CONFIG.PCW_UART_PERIPHERAL_FREQMHZ       {100} \
    CONFIG.PCW_UART_PERIPHERAL_DIVISOR0      {18} \
    CONFIG.PCW_ACT_UART_PERIPHERAL_FREQMHZ   {100.000000} \
    CONFIG.PCW_EN_UART1                      {1} \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE       {1} \
    CONFIG.PCW_UART1_UART1_IO                {MIO 48 .. 49} \
    CONFIG.PCW_UART1_BAUD_RATE               {115200} \
    CONFIG.PCW_UART1_GRP_FULL_ENABLE         {0} \
    \
    \
    \
    CONFIG.PCW_FPGA_FCLK0_ENABLE             {1} \
    CONFIG.PCW_FPGA_FCLK1_ENABLE             {0} \
    CONFIG.PCW_FPGA_FCLK2_ENABLE             {0} \
    CONFIG.PCW_FPGA_FCLK3_ENABLE             {0} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ      $fclk0_mhz \
    CONFIG.PCW_FCLK0_PERIPHERAL_DIVISOR0     {6} \
    CONFIG.PCW_FCLK0_PERIPHERAL_DIVISOR1     {6} \
    CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ  {50.000000} \
    \
    \
    CONFIG.PCW_USE_M_AXI_GP0                 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT          {1} \
    CONFIG.PCW_IRQ_F2P_INTR                  {1} \
    \
    CONFIG.PCW_QSPI_PERIPHERAL_ENABLE        {1} \
    CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE     {1} \
    CONFIG.PCW_QSPI_GRP_SINGLE_SS_IO         {MIO 1 .. 6} \
    CONFIG.PCW_QSPI_GRP_FBCLK_ENABLE         {1} \
    CONFIG.PCW_QSPI_GRP_FBCLK_IO             {MIO 8} \
    \
    CONFIG.PCW_SD0_PERIPHERAL_ENABLE         {1} \
    CONFIG.PCW_SD0_SD0_IO                    {MIO 40 .. 45} \
    \
    CONFIG.PCW_ENET0_PERIPHERAL_ENABLE       {1} \
    CONFIG.PCW_ENET0_ENET0_IO                {MIO 16 .. 27} \
    CONFIG.PCW_ENET0_PERIPHERAL_FREQMHZ      {1000 Mbps} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE         {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO             {MIO 52 .. 53} \
    CONFIG.PCW_ENET0_RESET_ENABLE            {0} \
    \
    CONFIG.PCW_USB0_PERIPHERAL_ENABLE        {1} \
    CONFIG.PCW_USB0_USB0_IO                  {MIO 28 .. 39} \
    CONFIG.PCW_USB0_RESET_ENABLE             {1} \
    CONFIG.PCW_USB0_RESET_IO                 {MIO 7} \
    \
    CONFIG.PCW_GPIO_MIO_GPIO_ENABLE          {1} \
    CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE         {0} \
] [get_bd_cells ps7]

# ---- 2.2 i2c_master_axi через Module Reference ----------------------------
# Vivado автоматически распознаёт интерфейс s_axi_* как AXI4-Lite slave.
create_bd_cell -type module -reference i2c_master_axi i2c
set_property CONFIG.DEFAULT_PRESCALE $prescale [get_bd_cells i2c]

# ---- 2.3 Tri-state buffers + внешние порты SDA/SCL ------------------------
# i2c_master_axi выдаёт *_pad_o (=0) и *_padoen_o (1=tristate, 0=drive low).
# Соберём IOBUF снаружи Block Design в RTL-обёртке (см. п. 3 ниже),
# а здесь просто выведем все четыре сигнала наружу как pin-port'ы.
make_bd_pins_external [get_bd_pins i2c/scl_pad_i]
make_bd_pins_external [get_bd_pins i2c/scl_pad_o]
make_bd_pins_external [get_bd_pins i2c/scl_padoen_o]
make_bd_pins_external [get_bd_pins i2c/sda_pad_i]
make_bd_pins_external [get_bd_pins i2c/sda_pad_o]
make_bd_pins_external [get_bd_pins i2c/sda_padoen_o]
make_bd_pins_external [get_bd_pins i2c/irq_o]

# Переименуем внешние порты в человекочитаемые имена
set_property name scl_i_ext      [get_bd_ports scl_pad_i_0]
set_property name scl_o_ext      [get_bd_ports scl_pad_o_0]
set_property name scl_oen_ext    [get_bd_ports scl_padoen_o_0]
set_property name sda_i_ext      [get_bd_ports sda_pad_i_0]
set_property name sda_o_ext      [get_bd_ports sda_pad_o_0]
set_property name sda_oen_ext    [get_bd_ports sda_padoen_o_0]
set_property name i2c_irq_ext    [get_bd_ports irq_o_0]

# ---- 2.4 AXI/Clock/Reset connection automation ----------------------------
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { \
        Master "/ps7/M_AXI_GP0" \
        Slave  "/i2c/s_axi" \
        Clk_master "Auto" \
        Clk_slave  "Auto" \
        Clk_xbar   "Auto" \
        intc_ip    "New AXI Interconnect" \
    } [get_bd_intf_pins i2c/s_axi]

# Подключаем прерывание I2C к IRQ_F2P
connect_bd_net [get_bd_pins i2c/irq_o] [get_bd_pins ps7/IRQ_F2P]

# ---- 2.5 Адресация AXI ----------------------------------------------------
assign_bd_address -target_address_space [get_bd_addr_spaces ps7/Data] \
    [get_bd_addr_segs i2c/s_axi/reg0] -force
set_property offset 0x43C00000 [get_bd_addr_segs ps7/Data/SEG_i2c_reg0]
set_property range  4K          [get_bd_addr_segs ps7/Data/SEG_i2c_reg0]

# Сохраняем BD и делаем wrapper
validate_bd_design
save_bd_design

set bd_file [get_files -filter "FILE_TYPE == \"Block Designs\""]
make_wrapper -files $bd_file -top -import

# ---------------------------------------------------------------
# 3. Top-RTL — IOBUF на SDA/SCL + LED + кнопки
#
# Block Design экспортирует *_pad_i / *_pad_o / *_padoen_o; здесь оборачиваем
# их в IOBUF для подключения к физическим выводам платы.
# ---------------------------------------------------------------
set top_v [file join $proj_dir $proj_name.srcs/sources_1/imports/${top_module}.v]
set top_dir [file dirname $top_v]
file mkdir $top_dir

set fh [open $top_v w]
puts $fh "\
\`timescale 1ns / 1ps
// Top-уровень: BD-обёртка + IOBUF + индикация состояния
module ${top_module} (
    inout  wire        oled_sda_io,
    inout  wire        oled_scl_io,
    output wire \[3:0\] led_o,
    input  wire        key1_n_i,
    input  wire        key2_n_i,
    inout  wire \[14:0\] DDR_addr,
    inout  wire \[2:0\]  DDR_ba,
    inout  wire        DDR_cas_n,
    inout  wire        DDR_ck_n,
    inout  wire        DDR_ck_p,
    inout  wire        DDR_cke,
    inout  wire        DDR_cs_n,
    inout  wire \[3:0\]  DDR_dm,
    inout  wire \[31:0\] DDR_dq,
    inout  wire \[3:0\]  DDR_dqs_n,
    inout  wire \[3:0\]  DDR_dqs_p,
    inout  wire        DDR_odt,
    inout  wire        DDR_ras_n,
    inout  wire        DDR_reset_n,
    inout  wire        DDR_we_n,
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,
    inout  wire \[53:0\] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_porb,
    inout  wire        FIXED_IO_ps_srstb
);

    wire scl_i, scl_o, scl_oen;
    wire sda_i, sda_o, sda_oen;
    wire i2c_irq;

    IOBUF iobuf_scl (.O(scl_i), .IO(oled_scl_io), .I(scl_o), .T(scl_oen));
    IOBUF iobuf_sda (.O(sda_i), .IO(oled_sda_io), .I(sda_o), .T(sda_oen));

    ${bd_name}_wrapper u_bd (
        .DDR_addr      (DDR_addr),
        .DDR_ba        (DDR_ba),
        .DDR_cas_n     (DDR_cas_n),
        .DDR_ck_n      (DDR_ck_n),
        .DDR_ck_p      (DDR_ck_p),
        .DDR_cke       (DDR_cke),
        .DDR_cs_n      (DDR_cs_n),
        .DDR_dm        (DDR_dm),
        .DDR_dq        (DDR_dq),
        .DDR_dqs_n     (DDR_dqs_n),
        .DDR_dqs_p     (DDR_dqs_p),
        .DDR_odt       (DDR_odt),
        .DDR_ras_n     (DDR_ras_n),
        .DDR_reset_n   (DDR_reset_n),
        .DDR_we_n      (DDR_we_n),
        .FIXED_IO_ddr_vrn  (FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp  (FIXED_IO_ddr_vrp),
        .FIXED_IO_mio      (FIXED_IO_mio),
        .FIXED_IO_ps_clk   (FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb  (FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb (FIXED_IO_ps_srstb),
        .scl_i_ext     (scl_i),
        .scl_o_ext     (scl_o),
        .scl_oen_ext   (scl_oen),
        .sda_i_ext     (sda_i),
        .sda_o_ext     (sda_o),
        .sda_oen_ext   (sda_oen),
        .i2c_irq_ext   (i2c_irq)
    );

    // LED-индикация: статически бьём low-биты IRQ + кнопки + статус-вектор
    assign led_o = {key2_n_i, key1_n_i, i2c_irq, ~i2c_irq};

endmodule
"
close $fh
add_files -norecurse $top_v
update_compile_order -fileset sources_1
set_property top ${top_module} [current_fileset]

# ---------------------------------------------------------------
# 4. Констрейнты
# ---------------------------------------------------------------
add_files -fileset constrs_1 -norecurse [file join $repo_root vivado/pins.xdc]

# ---------------------------------------------------------------
# 5. Synthesis → Implementation → Bitstream
# ---------------------------------------------------------------
set jobs 8
puts "INFO: launching synthesis..."
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed"
}

puts "INFO: launching implementation + bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation/bitstream failed"
}

# ---------------------------------------------------------------
# 6. Экспорт XSA для Vitis
# ---------------------------------------------------------------
open_run impl_1
set xsa_path [file join $repo_root vivado/${proj_name}.xsa]
write_hw_platform -fixed -include_bit -force -file $xsa_path
puts "INFO: hardware platform exported: $xsa_path"

puts "DONE: bitstream и XSA готовы."
puts "      bit:  [file join $proj_dir $proj_name.runs/impl_1/${top_module}.bit]"
puts "      xsa:  $xsa_path"
