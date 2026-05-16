# ---------------------------------------------------------------------------
# create_bd.tcl  —  standalone Block Design generator for ZYNQ MINI Rev B.
#
# Создаёт ТОЛЬКО Block Design (PS7 + i2c_master_axi через Module Reference,
# AXI4-Lite на 0x43C00000, FIXED_IO + DDR external, IRQ_F2P).  Ни проект,
# ни synthesis, ни bitstream, ни XSA здесь не создаются — это «чистый» BD,
# который можно подключить к существующему Vivado-проекту.
#
# Назначение: вы создали проект вручную (или из шаблона), добавили в него
# rtl/i2c_master_core.v + rtl/i2c_master_axi.v и хотите получить готовый BD
# без полной автоматизации build.tcl.
#
# Использование:
#
#   1. В Vivado создайте проект:
#        - Create Project → RTL Project → part = xc7z020clg400-1
#          (или xc7z010clg400-1 для урезанного варианта)
#        - Do not specify sources at this time
#
#   2. Добавьте RTL i2c-мастера в Sources:
#        Add Sources → Add or create design sources →
#          rtl/i2c_master_core.v, rtl/i2c_master_axi.v
#        (или в Tcl Console:  add_files -norecurse {...} )
#
#   3. В Tcl Console Vivado выполните:
#        source <repo>/vivado/create_bd.tcl
#
#   4. После завершения скрипта:
#        - в Sources появится system.bd
#        - правый клик по нему → Create HDL Wrapper (Let Vivado manage)
#        - добавьте top-RTL  zynq_mini_oled_top.v  (см. build.tcl 268–343
#          или Шаг 13 в doc/GUIDE_VIVADO_VITIS_FROM_SCRATCH.md)
#        - добавьте констрейнты vivado/pins.xdc
#        - запустите Run Synthesis → Run Implementation → Generate Bitstream
#
# Параметры (переопределяются через переменные ДО `source`):
#
#   set ::bd_name      "system"      ;# имя block design (default: system)
#   set ::fclk0_mhz    50            ;# частота FCLK_CLK0, МГц (default: 50)
#   set ::prescale     124           ;# DEFAULT_PRESCALE для i2c_master_axi
#                                    ;# (= fclk0_mhz*1e6 / (4*100kHz) - 1)
#
# Например, чтобы получить FCLK0=100 МГц с тем же I²C 100 кГц:
#   set ::fclk0_mhz 100
#   set ::prescale  249
#   source vivado/create_bd.tcl
# ---------------------------------------------------------------------------

# --- Параметры по умолчанию -------------------------------------------------
if {![info exists ::bd_name]}    { set ::bd_name      system }
if {![info exists ::fclk0_mhz]}  { set ::fclk0_mhz    50     }
if {![info exists ::prescale]}   { set ::prescale     124    }

set bd_name    $::bd_name
set fclk0_mhz  $::fclk0_mhz
set prescale   $::prescale

puts "INFO: create_bd: bd_name=$bd_name fclk0=${fclk0_mhz}MHz prescale=$prescale"

# --- Sanity checks ----------------------------------------------------------
if {[catch {current_project} cur_proj]} {
    error "create_bd.tcl: no project currently open. Use create_project or open_project first."
}
puts "INFO: working in project [get_property NAME [current_project]]"

# Убедимся, что i2c_master_axi.v добавлен в проект (для Module Reference)
set axi_file [get_files -quiet i2c_master_axi.v]
if {$axi_file eq ""} {
    error "create_bd.tcl: rtl/i2c_master_axi.v not in project sources. \n\
          Add it first:  add_files -norecurse <repo>/rtl/i2c_master_axi.v \n\
                         add_files -norecurse <repo>/rtl/i2c_master_core.v"
}

set core_file [get_files -quiet i2c_master_core.v]
if {$core_file eq ""} {
    puts "WARNING: i2c_master_core.v not in project sources. \n\
         i2c_master_axi will fail to elaborate without it. Add: \n\
         add_files -norecurse <repo>/rtl/i2c_master_core.v"
}

# Если BD с таким именем уже есть — выходим, чтобы случайно не затереть
set existing_bd [get_files -quiet "${bd_name}.bd"]
if {$existing_bd ne ""} {
    error "create_bd.tcl: block design '${bd_name}' уже существует ($existing_bd).\n\
          Удалите его или укажите другое имя:  set ::bd_name my_bd ; source ..."
}

update_compile_order -fileset sources_1

# ---------------------------------------------------------------
# 1. Создаём пустой Block Design
# ---------------------------------------------------------------
create_bd_design $bd_name
current_bd_design $bd_name
puts "INFO: empty BD '$bd_name' created"

# ---------------------------------------------------------------
# 2.1 Zynq PS7  +  Run Block Automation (FIXED_IO/DDR external)
# ---------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7

apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config { \
        make_external "FIXED_IO, DDR" \
        Master Disable \
        Slave  Disable \
    } [get_bd_cells ps7]

# ---------------------------------------------------------------
# 2.1.A Конфигурация PS7 под ZYNQ MINI Rev B (XC7Z020-CLG400, U1=MT41J256M16RE-125)
#
# Значения проверены в железе и совпадают с заводским preset'ом
# ~/devel/xilinx/configs/ZynqMini.tcl (см. build.tcl 116–203 — там
# то же самое в составе полного флоу).
# ---------------------------------------------------------------
set_property -dict [list \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE          {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE          {LVCMOS 1.8V} \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ    {33.333333} \
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
    CONFIG.PCW_FPGA_FCLK0_ENABLE             {1} \
    CONFIG.PCW_FPGA_FCLK1_ENABLE             {0} \
    CONFIG.PCW_FPGA_FCLK2_ENABLE             {0} \
    CONFIG.PCW_FPGA_FCLK3_ENABLE             {0} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ      $fclk0_mhz \
    CONFIG.PCW_FCLK0_PERIPHERAL_DIVISOR0     {6} \
    CONFIG.PCW_FCLK0_PERIPHERAL_DIVISOR1     {6} \
    CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ  {50.000000} \
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
puts "INFO: PS7 configured (bank0=3.3V, bank1=1.8V, xtal=33.3MHz, DDR3-1066, FCLK0=${fclk0_mhz}MHz)"

# ---------------------------------------------------------------
# 2.2 i2c_master_axi через Module Reference
# Vivado автоматически распознаёт s_axi_* как AXI4-Lite slave.
# ---------------------------------------------------------------
create_bd_cell -type module -reference i2c_master_axi i2c
set_property CONFIG.DEFAULT_PRESCALE $prescale [get_bd_cells i2c]
puts "INFO: i2c_master_axi added (DEFAULT_PRESCALE=$prescale)"

# ---------------------------------------------------------------
# 2.3 Make External: SDA/SCL pad i/o/oen + irq_o
# Tri-state IOBUF собирается в top-RTL снаружи BD.
# ---------------------------------------------------------------
make_bd_pins_external [get_bd_pins i2c/scl_pad_i]
make_bd_pins_external [get_bd_pins i2c/scl_pad_o]
make_bd_pins_external [get_bd_pins i2c/scl_padoen_o]
make_bd_pins_external [get_bd_pins i2c/sda_pad_i]
make_bd_pins_external [get_bd_pins i2c/sda_pad_o]
make_bd_pins_external [get_bd_pins i2c/sda_padoen_o]
make_bd_pins_external [get_bd_pins i2c/irq_o]

set_property name scl_i_ext      [get_bd_ports scl_pad_i_0]
set_property name scl_o_ext      [get_bd_ports scl_pad_o_0]
set_property name scl_oen_ext    [get_bd_ports scl_padoen_o_0]
set_property name sda_i_ext      [get_bd_ports sda_pad_i_0]
set_property name sda_o_ext      [get_bd_ports sda_pad_o_0]
set_property name sda_oen_ext    [get_bd_ports sda_padoen_o_0]
set_property name i2c_irq_ext    [get_bd_ports irq_o_0]
puts "INFO: external ports created: scl_{i,o,oen}_ext, sda_{i,o,oen}_ext, i2c_irq_ext"

# ---------------------------------------------------------------
# 2.4 AXI4 Connection Automation
# Vivado сам поставит AXI Interconnect и Processor System Reset.
# ---------------------------------------------------------------
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { \
        Master "/ps7/M_AXI_GP0" \
        Slave  "/i2c/s_axi" \
        Clk_master "Auto" \
        Clk_slave  "Auto" \
        Clk_xbar   "Auto" \
        intc_ip    "New AXI Interconnect" \
    } [get_bd_intf_pins i2c/s_axi]

# Прерывание I²C → IRQ_F2P[0]
connect_bd_net [get_bd_pins i2c/irq_o] [get_bd_pins ps7/IRQ_F2P]
puts "INFO: AXI4-Lite hooked up via auto-Interconnect, IRQ wired to IRQ_F2P[0]"

# ---------------------------------------------------------------
# 2.5 Address Editor: 0x43C00000, 4 KiB
# ---------------------------------------------------------------
assign_bd_address -target_address_space [get_bd_addr_spaces ps7/Data] \
    [get_bd_addr_segs i2c/s_axi/reg0] -force
set_property offset 0x43C00000 [get_bd_addr_segs ps7/Data/SEG_i2c_reg0]
set_property range  4K          [get_bd_addr_segs ps7/Data/SEG_i2c_reg0]
puts "INFO: i2c/s_axi mapped at 0x43C00000, range 4K"

# ---------------------------------------------------------------
# Validate + save
# ---------------------------------------------------------------
validate_bd_design
save_bd_design
puts "INFO: BD validated and saved"

# ---------------------------------------------------------------
# Подсказка пользователю о следующем шаге
# ---------------------------------------------------------------
set bd_file [lindex [get_files "${bd_name}.bd"] 0]
puts ""
puts "================================================================"
puts "DONE: Block Design '$bd_name' created."
puts "      File: $bd_file"
puts ""
puts "Next steps (вручную или см. vivado/build.tcl 251–352):"
puts "  1. In Sources, right-click ${bd_name}.bd  →  Create HDL Wrapper"
puts "     (выбрать 'Let Vivado manage wrapper and auto-update')"
puts "  2. Добавить top-RTL: zynq_mini_oled_top.v (он инстанцирует"
puts "     ${bd_name}_wrapper и вешает IOBUF на SDA/SCL). Шаблон"
puts "     см. в build.tcl 268–343 или Шаг 13 мануала"
puts "     doc/GUIDE_VIVADO_VITIS_FROM_SCRATCH.md"
puts "  3. Set this top as Top:  set_property top zynq_mini_oled_top \\\\"
puts "                                       \[current_fileset\]"
puts "  4. Добавить констрейнты vivado/pins.xdc:"
puts "     add_files -fileset constrs_1 -norecurse <repo>/vivado/pins.xdc"
puts "  5. Run Synthesis → Run Implementation → Generate Bitstream"
puts "================================================================"
