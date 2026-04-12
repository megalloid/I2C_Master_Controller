# ---------------------------------------------------------------------------
# Questa / ModelSim — GUI simulation with waveform viewer
#
# Usage:
#   cd sim/questa
#   vsim -do "do run_gui.do"
# ---------------------------------------------------------------------------

do compile.do

vsim work.i2c_master_tb \
     -voptargs="+acc" \
     -t 1ps \
     -suppress 3839

# Load waveform configuration
do wave.do

# Run simulation
run -all
