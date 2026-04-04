IVERILOG   ?= iverilog
VVP        ?= vvp
VERILATOR  ?= verilator

RTL_DIR    := rtl
TB_DIR     := tb
SIM_DIR    := sim

RTL_SRC    := $(RTL_DIR)/i2c_master_core.v \
              $(RTL_DIR)/i2c_master_axi.v \
              $(RTL_DIR)/i2c_master_top.v

TB_SRC     := $(TB_DIR)/i2c_slave_model.sv \
              $(TB_DIR)/axi_lite_master_bfm.sv \
              $(TB_DIR)/i2c_master_tb.sv

SIM_OUT    := $(SIM_DIR)/i2c_master_tb.vvp
WAVEFORM   := $(SIM_DIR)/i2c_master_tb.vcd

.PHONY: all sim wave lint clean

all: sim

sim:
	@mkdir -p $(SIM_DIR)
	$(IVERILOG) -g2012 -Wall -o $(SIM_OUT) $(RTL_SRC) $(TB_SRC)
	$(VVP) $(SIM_OUT) -vcd
	@echo "--- Simulation complete ---"

wave: sim
	@echo "Open $(WAVEFORM) in GTKWave or other waveform viewer."

lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module i2c_master_top $(RTL_SRC)
	@echo "--- Lint passed ---"

clean:
	rm -rf $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd $(SIM_DIR)/*.fst obj_dir
