# ---------------------------------------------------------------------------
# Questa / ModelSim — waveform configuration
#
# Groups:
#   System          — clock, reset, IRQ
#   I2C Bus         — SDA, SCL (physical lines)
#   AXI Write       — AW, W, B channels
#   AXI Read        — AR, R channels
#   Core FSM        — internal state machine of i2c_master_core
#   Core I/O        — command interface signals
#   Burst Writer    — i2c_burst_writer FSM (if used in testbench)
#   Slave Model     — I2C slave model internals
# ---------------------------------------------------------------------------

onerror {resume}
quietly WaveActivateNextPane {} 0

# ===== System =====
add wave -noupdate -group {System} -label "clk"     /i2c_master_tb/clk
add wave -noupdate -group {System} -label "rst_n"   /i2c_master_tb/rst_n
add wave -noupdate -group {System} -label "irq"     /i2c_master_tb/irq

# ===== I2C Bus =====
add wave -noupdate -group {I2C Bus} -label "SDA"    /i2c_master_tb/sda
add wave -noupdate -group {I2C Bus} -label "SCL"    /i2c_master_tb/scl

# ===== AXI Write Channel =====
add wave -noupdate -group {AXI Write} -label "awaddr"   -radix hexadecimal /i2c_master_tb/axi_awaddr
add wave -noupdate -group {AXI Write} -label "awvalid"  /i2c_master_tb/axi_awvalid
add wave -noupdate -group {AXI Write} -label "awready"  /i2c_master_tb/axi_awready
add wave -noupdate -group {AXI Write} -label "wdata"    -radix hexadecimal /i2c_master_tb/axi_wdata
add wave -noupdate -group {AXI Write} -label "wstrb"    -radix binary      /i2c_master_tb/axi_wstrb
add wave -noupdate -group {AXI Write} -label "wvalid"   /i2c_master_tb/axi_wvalid
add wave -noupdate -group {AXI Write} -label "wready"   /i2c_master_tb/axi_wready
add wave -noupdate -group {AXI Write} -label "bresp"    -radix hexadecimal /i2c_master_tb/axi_bresp
add wave -noupdate -group {AXI Write} -label "bvalid"   /i2c_master_tb/axi_bvalid
add wave -noupdate -group {AXI Write} -label "bready"   /i2c_master_tb/axi_bready

# ===== AXI Read Channel =====
add wave -noupdate -group {AXI Read} -label "araddr"    -radix hexadecimal /i2c_master_tb/axi_araddr
add wave -noupdate -group {AXI Read} -label "arvalid"   /i2c_master_tb/axi_arvalid
add wave -noupdate -group {AXI Read} -label "arready"   /i2c_master_tb/axi_arready
add wave -noupdate -group {AXI Read} -label "rdata"     -radix hexadecimal /i2c_master_tb/axi_rdata
add wave -noupdate -group {AXI Read} -label "rresp"     -radix hexadecimal /i2c_master_tb/axi_rresp
add wave -noupdate -group {AXI Read} -label "rvalid"    /i2c_master_tb/axi_rvalid
add wave -noupdate -group {AXI Read} -label "rready"    /i2c_master_tb/axi_rready

# ===== I2C Core FSM =====
add wave -noupdate -group {Core FSM} -label "state"     -radix unsigned /i2c_master_tb/dut/u_axi/u_core/state_r
add wave -noupdate -group {Core FSM} -label "phase"     -radix unsigned /i2c_master_tb/dut/u_axi/u_core/phase_r
add wave -noupdate -group {Core FSM} -label "bit_cnt"   -radix unsigned /i2c_master_tb/dut/u_axi/u_core/bit_cnt_r
add wave -noupdate -group {Core FSM} -label "cmd_r"     -radix unsigned /i2c_master_tb/dut/u_axi/u_core/cmd_r
add wave -noupdate -group {Core FSM} -label "tx_shift"  -radix binary   /i2c_master_tb/dut/u_axi/u_core/tx_shift_r
add wave -noupdate -group {Core FSM} -label "rx_shift"  -radix binary   /i2c_master_tb/dut/u_axi/u_core/rx_shift_r

# ===== I2C Core I/O =====
add wave -noupdate -group {Core I/O} -label "cmd_valid" /i2c_master_tb/dut/u_axi/u_core/cmd_valid_i
add wave -noupdate -group {Core I/O} -label "cmd_i"     -radix unsigned /i2c_master_tb/dut/u_axi/u_core/cmd_i
add wave -noupdate -group {Core I/O} -label "din_i"     -radix hexadecimal /i2c_master_tb/dut/u_axi/u_core/din_i
add wave -noupdate -group {Core I/O} -label "dout_o"    -radix hexadecimal /i2c_master_tb/dut/u_axi/u_core/dout_o
add wave -noupdate -group {Core I/O} -label "ready_o"   /i2c_master_tb/dut/u_axi/u_core/ready_o
add wave -noupdate -group {Core I/O} -label "rx_ack_o"  /i2c_master_tb/dut/u_axi/u_core/rx_ack_o
add wave -noupdate -group {Core I/O} -label "arb_lost"  /i2c_master_tb/dut/u_axi/u_core/arb_lost_o
add wave -noupdate -group {Core I/O} -label "busy"      /i2c_master_tb/dut/u_axi/u_core/busy_o
add wave -noupdate -group {Core I/O} -label "scl_oen"   /i2c_master_tb/dut/u_axi/u_core/scl_oen_o
add wave -noupdate -group {Core I/O} -label "sda_oen"   /i2c_master_tb/dut/u_axi/u_core/sda_oen_o
add wave -noupdate -group {Core I/O} -label "scl_i"     /i2c_master_tb/dut/u_axi/u_core/scl_i
add wave -noupdate -group {Core I/O} -label "sda_i"     /i2c_master_tb/dut/u_axi/u_core/sda_i

# ===== Slave Model =====
add wave -noupdate -group {Slave} -label "state"        -radix unsigned    /i2c_master_tb/slave/state
add wave -noupdate -group {Slave} -label "sr"           -radix hexadecimal /i2c_master_tb/slave/sr
add wave -noupdate -group {Slave} -label "bcnt"         -radix unsigned    /i2c_master_tb/slave/bcnt
add wave -noupdate -group {Slave} -label "mem_ptr"      -radix hexadecimal /i2c_master_tb/slave/mem_ptr
add wave -noupdate -group {Slave} -label "rw_bit"       /i2c_master_tb/slave/rw_bit
add wave -noupdate -group {Slave} -label "sda_out_en"   /i2c_master_tb/slave/sda_out_en

# ===== AXI wrapper internals =====
add wave -noupdate -group {AXI Regs} -label "ctrl_en"   /i2c_master_tb/dut/u_axi/ctrl_en_r
add wave -noupdate -group {AXI Regs} -label "ctrl_ien"  /i2c_master_tb/dut/u_axi/ctrl_ien_r
add wave -noupdate -group {AXI Regs} -label "prescale"  -radix unsigned    /i2c_master_tb/dut/u_axi/prescale_r
add wave -noupdate -group {AXI Regs} -label "tx_data"   -radix hexadecimal /i2c_master_tb/dut/u_axi/tx_data_r
add wave -noupdate -group {AXI Regs} -label "tip"       /i2c_master_tb/dut/u_axi/tip_r
add wave -noupdate -group {AXI Regs} -label "isr_done"  /i2c_master_tb/dut/u_axi/isr_done_r
add wave -noupdate -group {AXI Regs} -label "isr_al"    /i2c_master_tb/dut/u_axi/isr_al_r

# ===== AXI Sequencer =====
add wave -noupdate -group {Sequencer} -label "seq_state"     -radix unsigned    /i2c_master_tb/dut/u_axi/seq_state_r
add wave -noupdate -group {Sequencer} -label "core_cmd_valid" /i2c_master_tb/dut/u_axi/core_cmd_valid_r
add wave -noupdate -group {Sequencer} -label "core_cmd"      -radix unsigned    /i2c_master_tb/dut/u_axi/core_cmd_r
add wave -noupdate -group {Sequencer} -label "core_din"      -radix hexadecimal /i2c_master_tb/dut/u_axi/core_din_r
add wave -noupdate -group {Sequencer} -label "sub_cmd_sent"  /i2c_master_tb/dut/u_axi/sub_cmd_sent_r

# ===== Configure view =====
TreeUpdate [SetDefaultTree]
configure wave -namecolwidth 200
configure wave -valuecolwidth 120
configure wave -signalnamewidth 1
configure wave -timelineunits ns
WaveRestoreZoom {0 ns} {500 us}
update
