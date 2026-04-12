# ---------------------------------------------------------------------------
# Questa / ModelSim — compile all RTL + testbench sources
#
# Usage:
#   vsim -c -do "do compile.do"          (batch)
#   source compile.do                      (from Questa transcript)
# ---------------------------------------------------------------------------

# Detect project root relative to this script location
quietly set PROJ_ROOT "../../"

# Create work library if it does not exist
if {![file exists work]} {
    vlib work
}
vmap work work

# --- RTL (Verilog-2001) ---
vlog -work work -sv \
    ${PROJ_ROOT}/rtl/i2c_master_core.v \
    ${PROJ_ROOT}/rtl/i2c_master_axi.v \
    ${PROJ_ROOT}/rtl/i2c_master_top.v \
    ${PROJ_ROOT}/rtl/i2c_burst_writer.v

# --- Testbench (SystemVerilog) ---
vlog -work work -sv \
    ${PROJ_ROOT}/tb/i2c_slave_model.sv \
    ${PROJ_ROOT}/tb/axi_lite_master_bfm.sv \
    ${PROJ_ROOT}/tb/i2c_master_tb.sv

puts "=== Compilation complete ==="
