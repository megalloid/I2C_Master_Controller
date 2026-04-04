IVERILOG   ?= iverilog
VVP        ?= vvp
VERILATOR  ?= verilator

RTL_DIR    := rtl
TB_DIR     := tb
SIM_DIR    := sim

# Shared core
CORE_SRC   := $(RTL_DIR)/i2c_master_core.v

# AXI variant (Zynq)
AXI_SRC    := $(CORE_SRC) \
              $(RTL_DIR)/i2c_master_axi.v \
              $(RTL_DIR)/i2c_master_top.v

AXI_TB     := $(TB_DIR)/i2c_slave_model.sv \
              $(TB_DIR)/axi_lite_master_bfm.sv \
              $(TB_DIR)/i2c_master_tb.sv

# Avalon variant (Cyclone IV)
AVL_SRC    := $(CORE_SRC) \
              $(RTL_DIR)/i2c_master_avalon.v \
              $(RTL_DIR)/i2c_master_top_c4.v

AVL_TB     := $(TB_DIR)/i2c_slave_model.sv \
              $(TB_DIR)/avalon_mm_master_bfm.sv \
              $(TB_DIR)/i2c_master_c4_tb.sv

.PHONY: all sim sim-axi sim-c4 lint lint-axi lint-c4 wave clean

all: sim

# ---- AXI (Zynq) ----

sim-axi:
	@mkdir -p $(SIM_DIR)
	$(IVERILOG) -g2012 -Wall -o $(SIM_DIR)/i2c_master_tb.vvp $(AXI_SRC) $(AXI_TB)
	cd $(SIM_DIR) && $(VVP) i2c_master_tb.vvp -vcd
	@echo "--- AXI simulation complete ---"

lint-axi:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module i2c_master_top $(AXI_SRC)
	@echo "--- AXI lint passed ---"

# ---- Avalon (Cyclone IV) ----

sim-c4:
	@mkdir -p $(SIM_DIR)
	$(IVERILOG) -g2012 -Wall -o $(SIM_DIR)/i2c_master_c4_tb.vvp $(AVL_SRC) $(AVL_TB)
	cd $(SIM_DIR) && $(VVP) i2c_master_c4_tb.vvp -vcd
	@echo "--- Cyclone IV simulation complete ---"

lint-c4:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module i2c_master_top_c4 $(AVL_SRC)
	@echo "--- Cyclone IV lint passed ---"

# ---- Combined ----

sim: sim-axi sim-c4

lint: lint-axi lint-c4

wave:
	@echo "Open $(SIM_DIR)/*.vcd in GTKWave"

clean:
	rm -rf $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd $(SIM_DIR)/*.fst obj_dir
