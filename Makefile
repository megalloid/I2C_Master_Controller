IVERILOG   ?= iverilog
VVP        ?= vvp
VERILATOR  ?= verilator
VSIM       ?= vsim

RTL_DIR    := rtl
TB_DIR     := tb
SIM_DIR    := sim
QUESTA_DIR := $(SIM_DIR)/questa

RTL_SRC    := $(RTL_DIR)/i2c_master_core.v \
              $(RTL_DIR)/i2c_master_axi.v \
              $(RTL_DIR)/i2c_master_top.v

TB_SRC     := $(TB_DIR)/i2c_slave_model.sv \
              $(TB_DIR)/axi_lite_master_bfm.sv \
              $(TB_DIR)/i2c_master_tb.sv

# Core-only testbench (no AXI wrapper)
CORE_RTL   := $(RTL_DIR)/i2c_master_core.v
CORE_TB    := $(TB_DIR)/i2c_slave_model.sv \
              $(TB_DIR)/i2c_core_tb.sv

SIM_OUT    := $(SIM_DIR)/i2c_master_tb.vvp
WAVEFORM   := $(SIM_DIR)/i2c_master_tb.vcd
CORE_OUT   := $(SIM_DIR)/i2c_core_tb.vvp
CORE_WAVE  := $(SIM_DIR)/i2c_core_tb.vcd

.PHONY: all sim wave sim-core wave-core lint lint-core clean questa questa-gui questa-clean

all: sim

# ---------------------------------------------------------------
# Icarus Verilog
# ---------------------------------------------------------------
sim:
	@mkdir -p $(SIM_DIR)
	$(IVERILOG) -g2012 -Wall -o $(SIM_OUT) $(RTL_SRC) $(TB_SRC)
	$(VVP) $(SIM_OUT) -vcd
	@echo "--- Simulation complete ---"

wave: sim
	@echo "Open $(WAVEFORM) in GTKWave or other waveform viewer."

# ---------------------------------------------------------------
# Icarus Verilog — core-only testbench
# ---------------------------------------------------------------
sim-core:
	@mkdir -p $(SIM_DIR)
	$(IVERILOG) -g2012 -Wall -o $(CORE_OUT) $(CORE_RTL) $(CORE_TB)
	cd $(SIM_DIR) && $(VVP) ../$(CORE_OUT)
	@echo "--- Core simulation complete ---"

wave-core: sim-core
	@echo "Open $(CORE_WAVE) in GTKWave or other waveform viewer."

# ---------------------------------------------------------------
# Verilator lint
# ---------------------------------------------------------------
lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module i2c_master_top $(RTL_SRC)
	@echo "--- Lint passed ---"

lint-core:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module i2c_master_core $(CORE_RTL)
	@echo "--- Core lint passed ---"

# ---------------------------------------------------------------
# Questa / ModelSim
# ---------------------------------------------------------------
questa:
	@mkdir -p $(QUESTA_DIR)
	cd $(QUESTA_DIR) && $(VSIM) -c -do "do run_batch.do"

questa-gui:
	@mkdir -p $(QUESTA_DIR)
	cd $(QUESTA_DIR) && $(VSIM) -do "do run_gui.do"

questa-clean:
	rm -rf $(QUESTA_DIR)/work $(QUESTA_DIR)/transcript $(QUESTA_DIR)/vsim.wlf \
	       $(QUESTA_DIR)/modelsim.ini $(QUESTA_DIR)/*.vcd $(QUESTA_DIR)/*.wlf

# ---------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------
clean: questa-clean
	rm -rf $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd $(SIM_DIR)/*.fst obj_dir
