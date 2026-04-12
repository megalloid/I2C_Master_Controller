# ---------------------------------------------------------------------------
# Questa / ModelSim — batch simulation (no GUI)
#
# Usage:
#   cd sim/questa
#   vsim -c -do "do run_batch.do"
#
# Generates VCD waveform: sim/questa/i2c_master_tb.vcd
# ---------------------------------------------------------------------------

do compile.do

vsim -c work.i2c_master_tb \
     -voptargs="+acc" \
     -t 1ps \
     -suppress 3839

run -all
quit -f
