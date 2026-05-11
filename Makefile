IVERILOG   ?= iverilog
VVP        ?= vvp
VERILATOR  ?= verilator
VSIM       ?= vsim

RTL_DIR    := rtl
TB_DIR     := tb
SIM_DIR    := sim
QUESTA_DIR := $(SIM_DIR)/questa

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

# Core-only testbench (no AXI wrapper)
CORE_RTL   := $(RTL_DIR)/i2c_master_core.v
CORE_TB    := $(TB_DIR)/i2c_slave_model.sv \
              $(TB_DIR)/i2c_core_tb.sv

CORE_OUT   := $(SIM_DIR)/i2c_core_tb.vvp
CORE_WAVE  := $(SIM_DIR)/i2c_core_tb.vcd

# Hardware test (EEPROM test shell — all submodules)
HW_DIR     := quartus/src
HW_RTL     := $(RTL_DIR)/i2c_master_core.v \
              $(HW_DIR)/i2c_test_ctrl.v \
              $(HW_DIR)/seg_scan.v \
              $(HW_DIR)/ax_debounce.v
HW_TB      := $(TB_DIR)/i2c_slave_model.sv \
              $(TB_DIR)/i2c_test_top_tb.sv
HW_OUT     := $(SIM_DIR)/i2c_test_top_tb.vvp
HW_WAVE    := $(SIM_DIR)/i2c_test_top_tb.vcd

.PHONY: all sim sim-axi sim-c4 sim-core sim-hw wave wave-core wave-hw lint lint-axi lint-c4 lint-core lint-ssd1306 clean questa questa-gui questa-clean \
        vivado-build vivado-program vivado-clean vitis-build vitis-run vitis-clean \
        boot-bin boot-bin-clean buildroot-init buildroot-build buildroot-menuconfig buildroot-clean buildroot-rebuild \
        uboot-rebuild linux-rebuild sdcard-rebuild sdcard-quick \
        jtag-boot jtag-fsbl jtag-ps7

all: sim

# ---------------------------------------------------------------
# AXI (Zynq)
# ---------------------------------------------------------------
sim-axi:
	@mkdir -p $(SIM_DIR)
	$(IVERILOG) -g2012 -Wall -o $(SIM_DIR)/i2c_master_tb.vvp $(AXI_SRC) $(AXI_TB)
	cd $(SIM_DIR) && $(VVP) i2c_master_tb.vvp -vcd
	@echo "--- AXI simulation complete ---"

lint-axi:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module i2c_master_top $(AXI_SRC)
	@echo "--- AXI lint passed ---"

# ---------------------------------------------------------------
# Avalon (Cyclone IV)
# ---------------------------------------------------------------
sim-c4:
	@mkdir -p $(SIM_DIR)
	$(IVERILOG) -g2012 -Wall -o $(SIM_DIR)/i2c_master_c4_tb.vvp $(AVL_SRC) $(AVL_TB)
	cd $(SIM_DIR) && $(VVP) i2c_master_c4_tb.vvp -vcd
	@echo "--- Cyclone IV simulation complete ---"

lint-c4:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module i2c_master_top_c4 $(AVL_SRC)
	@echo "--- Cyclone IV lint passed ---"

# ---------------------------------------------------------------
# Core-only testbench
# ---------------------------------------------------------------
sim-core:
	@mkdir -p $(SIM_DIR)
	$(IVERILOG) -g2012 -Wall -o $(CORE_OUT) $(CORE_RTL) $(CORE_TB)
	cd $(SIM_DIR) && $(VVP) ../$(CORE_OUT)
	@echo "--- Core simulation complete ---"

wave-core: sim-core
	@echo "Open $(CORE_WAVE) in GTKWave or other waveform viewer."

# ---------------------------------------------------------------
# Hardware test (EEPROM test shell)
# ---------------------------------------------------------------
sim-hw:
	@mkdir -p $(SIM_DIR)
	$(IVERILOG) -g2012 -Wall -o $(HW_OUT) $(HW_RTL) $(HW_TB)
	cd $(SIM_DIR) && $(VVP) ../$(HW_OUT)
	@echo "--- Hardware test simulation complete ---"

wave-hw: sim-hw
	@echo "Open $(HW_WAVE) in GTKWave or other waveform viewer."

# ---------------------------------------------------------------
# Combined
# ---------------------------------------------------------------
sim: sim-axi sim-c4

lint: lint-axi lint-c4

wave:
	@echo "Open $(SIM_DIR)/*.vcd in GTKWave"

lint-core:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module i2c_master_core $(CORE_RTL)
	@echo "--- Core lint passed ---"

# ---------------------------------------------------------------
# SSD1306 OLED project (Cyclone IV, AX301) — lint only
# ---------------------------------------------------------------
SSD_DIR := quartus_ssd1306/src
SSD_RTL := $(CORE_SRC) \
           $(RTL_DIR)/i2c_burst_writer.v \
           $(SSD_DIR)/scene_renderer.v \
           $(SSD_DIR)/ssd1306_ctrl.v \
           $(SSD_DIR)/seg_scan.v \
           $(SSD_DIR)/ax_debounce.v \
           $(SSD_DIR)/ssd1306_test_top.v

lint-ssd1306:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
	    -Wno-DECLFILENAME --top-module ssd1306_test_top $(SSD_RTL)
	@echo "--- SSD1306 project lint passed ---"

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
# Vivado / Vitis (PS+PL build для ZYNQ MINI Rev B, XC7Z010)
# ---------------------------------------------------------------
XILINX_ROOT  ?= /opt/xilinx/2025.2
VIVADO_ENV   := source $(XILINX_ROOT)/Vivado/settings64.sh
VITIS_ENV    := source $(XILINX_ROOT)/Vitis/settings64.sh
VIVADO_LOG   := vivado/build.log
VIVADO_JNL   := vivado/build.jou

# ZYNQ MINI Rev B: XC7Z010 (по умолчанию) или XC7Z020.
#   make vivado-build PART=xc7z020clg400-1   (default — он же на ZYNQ MINI Rev B)
#   make vivado-build PART=xc7z010clg400-1   (для урезанной версии платы)
PART         ?= xc7z020clg400-1

vivado-build:
	@mkdir -p vivado
	@echo ">>> Vivado: synth + impl + bitstream + XSA  (part = $(PART))"
	bash -c "$(VIVADO_ENV) && cd vivado && \
	    VIVADO_PART=$(PART) vivado -mode batch -nojournal -nolog -source build.tcl 2>&1 | tee build.log"

vivado-program:
	@echo ">>> Vivado: программирование платы по JTAG"
	bash -c "$(VIVADO_ENV) && cd vivado && \
	    vivado -mode batch -nojournal -nolog -source program.tcl"

vivado-clean:
	rm -rf vivado/proj vivado/*.xsa vivado/*.log vivado/*.jou \
	       vivado/.Xil vivado/webtalk*

vitis-build:
	@mkdir -p vitis/workspace
	@echo ">>> Vitis: создаём platform + app, собираем ELF"
	bash -c "$(VITIS_ENV) && vitis -s vitis/build.py"

vitis-run:
	@# Чистим зомби-серверы предыдущих неудачных запусков (если есть).
	@pids=$$(pgrep -x hw_server 2>/dev/null; pgrep -x xsdb 2>/dev/null); \
	    if [ -n "$$pids" ]; then echo "killing stale: $$pids"; kill $$pids 2>/dev/null; sleep 1; fi; true
	bash -c "$(VITIS_ENV) && xsdb vitis/run.tcl"

vitis-clean:
	rm -rf vitis/workspace vitis/.Xil

# ---------------------------------------------------------------
# BOOT.BIN  (FSBL + bitstream + U-Boot ELF)  →  boot/BOOT.BIN
# ---------------------------------------------------------------
# Подразумевается, что:
#   * vivado-build уже отработал → есть vivado/zynq_mini_oled.xsa и .bit
#   * Vitis сгенерировал FSBL ELF в vitis/workspace/.../fsbl/...
#   * Buildroot собрал u-boot.elf в buildroot-build/output/images/
# Если чего-то нет — цель честно расскажет, что именно.
BUILDROOT_OUT ?= $(CURDIR)/buildroot-build
# Buildroot при O=$(BUILDROOT_OUT) кладёт images в $(BUILDROOT_OUT)/images/
# (а не в output/images/, как было до 2018.x).
BR_IMAGES     := $(BUILDROOT_OUT)/images
# FSBL_ELF ищем автоматически в vitis/workspace (Vitis FSBL App
# обычно зовётся zynq_fsbl/fsbl/<name>_fsbl и т.п.). Если ничего
# не нашли — оставляем "пустую" подсказку: пользователь увидит
# вменяемое сообщение об ошибке.
FSBL_ELF      ?= $(or                                                           \
                   $(firstword $(wildcard                                       \
                       $(CURDIR)/vitis/workspace/*/zynq_fsbl/build/fsbl.elf     \
                       $(CURDIR)/vitis/workspace/*/fsbl/build/fsbl.elf          \
                       $(CURDIR)/vitis/workspace/*_fsbl/build/*fsbl*.elf        \
                       $(CURDIR)/vitis/workspace/zynq_fsbl/build/*fsbl*.elf)),  \
                   $(CURDIR)/vitis/workspace/zynq_mini_oled_platform/zynq_fsbl/build/fsbl.elf)
BIT_FILE      ?= $(CURDIR)/vivado/proj/zynq_mini_oled.runs/impl_1/zynq_mini_oled_top.bit
# Внимание: при BR2_TARGET_UBOOT_FORMAT_ELF=y Buildroot копирует ELF
# под именем "u-boot" БЕЗ расширения (так его именует main U-Boot
# Makefile). Расширение .elf появляется только при FORMAT_REMAKE_ELF=y.
UBOOT_ELF     ?= $(BR_IMAGES)/u-boot

boot-bin:
	@if [ ! -f "$(BIT_FILE)" ]; then \
	    echo "ERROR: bitstream not found: $(BIT_FILE)"; \
	    echo "       run  'make vivado-build'  first."; exit 1; fi
	@if [ ! -f "$(UBOOT_ELF)" ]; then \
	    echo "ERROR: U-Boot ELF not found: $(UBOOT_ELF)"; \
	    echo "       run  'make buildroot-build'  first."; exit 1; fi
	@if [ ! -f "$(FSBL_ELF)" ]; then \
	    echo "WARNING: FSBL ELF not found ($(FSBL_ELF))."; \
	    echo "         Falling back to Buildroot's u-boot-spl.bin if present."; \
	    if [ ! -f "$(BR_IMAGES)/u-boot-spl.bin" ]; then \
	        echo "ERROR: no FSBL/SPL binary available."; \
	        echo "       Build the Zynq FSBL in Vitis (template 'Zynq FSBL'),"; \
	        echo "       e.g. into vitis/workspace/<platform>/zynq_fsbl/,"; \
	        echo "       or override:  make boot-bin FSBL_ELF=/path/to/fsbl.elf"; \
	        exit 1; fi; \
	    FSBL_BIN=$(BR_IMAGES)/u-boot-spl.bin; \
	else \
	    FSBL_BIN=$(FSBL_ELF); \
	fi; \
	echo ">>> bootgen: BOOT.BIN ← $$FSBL_BIN + bitstream + u-boot.elf"; \
	rm -f boot/boot.bif.tmp; \
	sed -e "s|@FSBL_ELF@|$$FSBL_BIN|" \
	    -e "s|@BITSTREAM@|$(BIT_FILE)|" \
	    -e "s|@UBOOT_ELF@|$(UBOOT_ELF)|" \
	    boot/boot.bif > boot/boot.bif.tmp; \
	bash -c "$(VITIS_ENV) && bootgen -arch zynq -image boot/boot.bif.tmp -o i boot/BOOT.BIN -w on"; \
	rm -f boot/boot.bif.tmp
	@echo "DONE: $(CURDIR)/boot/BOOT.BIN"

boot-bin-clean:
	rm -f boot/BOOT.BIN boot/boot.bif.tmp

# ---------------------------------------------------------------
# JTAG boot через xsct (диагностика без SD-карты)
#
# Полезно когда:
#   * UART/DONE молчат и непонятно где зависание (SD/FSBL/PS init);
#   * хочется быстро попробовать новый bitstream без перезаписи SD.
#
# Перед запуском:
#   * подключить USB-JTAG к плате (через FT2232 + JTAG-разъём);
#   * выставить JP1 в JTAG-mode (boot mode pins = JTAG);
#   * в ОТДЕЛЬНОМ терминале запустить мониторинг UART:
#       picocom -b 115200 /dev/ttyUSB1
#     (или /dev/ttyACM0 — выбрать тот, что соответствует CH340E
#     на USB-Type-C, а не FT2232 на JTAG);
#   * после теста — JP1 обратно в SD-mode.
#
# Режимы (через JTAG_MODE=...):
#   full     — ps7_init + bitstream + U-Boot (default)
#   fsbl     — только FSBL.elf (поверка что FSBL стартует и пишет в UART)
#   ps7only  — только ps7_init + bitstream (без U-Boot)
# ---------------------------------------------------------------
JTAG_MODE ?= full

jtag-boot:
	@if [ ! -f "$(BIT_FILE)" ]; then \
	    echo "ERROR: bitstream not found: $(BIT_FILE)"; \
	    echo "       run  'make vivado-build'  first."; exit 1; fi
	@if [ "$(JTAG_MODE)" = "fsbl" ] && [ ! -f "$(FSBL_ELF)" ]; then \
	    echo "ERROR: FSBL ELF not found: $(FSBL_ELF)"; \
	    echo "       run  'make vitis-build'  first."; exit 1; fi
	@if [ "$(JTAG_MODE)" = "full" ] && [ ! -f "$(UBOOT_ELF)" ]; then \
	    echo "ERROR: U-Boot ELF not found: $(UBOOT_ELF)"; \
	    echo "       run  'make buildroot-build'  first."; exit 1; fi
	@echo ">>> xsct: JTAG boot (mode=$(JTAG_MODE))"
	@bash -c "$(VITIS_ENV) && JTAG_MODE=$(JTAG_MODE) xsct $(CURDIR)/boot/jtag-boot.tcl"

jtag-fsbl:
	@$(MAKE) --no-print-directory jtag-boot JTAG_MODE=fsbl

# ---------------------------------------------------------------
# Диагностика boot-mode pins через JTAG.
# Читает SLCR.boot_mode_reg (0xF800025C) и расшифровывает MIO[5:3]+MIO6.
# Полезно когда плата подаёт питание, но UART молчит — увидим, какое
# реальное значение засэмплировал BootROM на boot-mode jumpers.
# ---------------------------------------------------------------
read-bootmode:
	@echo ">>> xsct: reading BOOT_MODE_REG via JTAG"
	@bash -c "$(VITIS_ENV) && xsct $(CURDIR)/boot/read-bootmode.tcl"

read-sdio:
	@echo ">>> xsct: reading SDIO0 / MIO40..45 / clocks"
	@bash -c "$(VITIS_ENV) && xsct $(CURDIR)/boot/read-sdio.tcl"

jtag-ps7:
	@$(MAKE) --no-print-directory jtag-boot JTAG_MODE=ps7only

# ---------------------------------------------------------------
# Buildroot
# ---------------------------------------------------------------
# Конфигурируется через переменные окружения:
#   BR2_VERSION       — тег buildroot (по умолчанию 2024.02.7 LTS)
#   BR2_DIR           — куда положить дерево исходников (./buildroot-src)
#   BUILDROOT_OUT     — куда писать build (./buildroot-build)
BR2_VERSION  ?= 2024.02.7
BR2_DIR      ?= $(CURDIR)/buildroot-src
BR2_EXT      := $(CURDIR)/buildroot
BR2_DEFCONF  := zynq_mini_revb_defconfig
BR2_MAKE     := $(MAKE) -C $(BR2_DIR) BR2_EXTERNAL=$(BR2_EXT) O=$(BUILDROOT_OUT)

buildroot-init:
	@if [ ! -d "$(BR2_DIR)" ]; then \
	    echo ">>> cloning buildroot $(BR2_VERSION) → $(BR2_DIR)"; \
	    git clone --branch $(BR2_VERSION) --depth 1 \
	        https://gitlab.com/buildroot.org/buildroot.git $(BR2_DIR); \
	else \
	    echo ">>> buildroot already cloned at $(BR2_DIR)"; \
	fi
	@mkdir -p $(BUILDROOT_OUT)
	$(BR2_MAKE) $(BR2_DEFCONF)
	@echo "DONE: defconfig применён.  далее → make buildroot-build"

buildroot-menuconfig:
	$(BR2_MAKE) menuconfig

buildroot-build:
	@if [ ! -d "$(BR2_DIR)" ]; then \
	    echo "ERROR: buildroot не инициализирован → make buildroot-init"; \
	    exit 1; fi
	$(BR2_MAKE) -j$$(nproc)
	@echo "DONE: $(BR_IMAGES)/sdcard.img готов."

buildroot-rebuild:
	@if [ ! -d "$(BR2_DIR)" ]; then \
	    echo "ERROR: buildroot не инициализирован → make buildroot-init"; \
	    exit 1; fi
	$(BR2_MAKE) i2c-master-axi-rebuild linux-rebuild all
	@echo "DONE: пересобрано (kernel + i2c-master-axi)."

# Пересобрать только U-Boot (после правки uboot.fragment, или после
# установки/снятия host-зависимостей вроде libgnutls-dev).
uboot-rebuild:
	@if [ ! -d "$(BR2_DIR)" ]; then \
	    echo "ERROR: buildroot не инициализирован → make buildroot-init"; \
	    exit 1; fi
	$(BR2_MAKE) uboot-dirclean
	$(BR2_MAKE) uboot-reconfigure
	$(BR2_MAKE) all
	@echo "DONE: U-Boot пересобран."

# Пересобрать только ядро + DTB (после правки linux.fragment или DTS).
linux-rebuild:
	@if [ ! -d "$(BR2_DIR)" ]; then \
	    echo "ERROR: buildroot не инициализирован → make buildroot-init"; \
	    exit 1; fi
	$(BR2_MAKE) linux-rebuild all
	@echo "DONE: ядро + DTB пересобраны."

# Пересобрать ТОЛЬКО SD-образ (после того, как обновили boot/BOOT.BIN
# через `make boot-bin`). Это в разы быстрее `buildroot-rebuild`,
# потому что не трогает U-Boot/kernel/rootfs — только переупаковывает
# готовые компоненты в boot.vfat + sdcard.img.
#
# ⚠ Buildroot-овский target-post-image сам по себе зависит от целой
# цепочки prerequisite-целей (target-finalize, host-finalize и т.п.),
# поэтому может отрабатывать минутами. Если вы только что выполнили
# `make boot-bin` и хотите быстро (≈секунды) пересобрать sdcard.img —
# используйте sdcard-quick: он запускает post-image.sh + genimage
# напрямую, минуя Buildroot-овскую логику зависимостей.
sdcard-rebuild:
	@if [ ! -d "$(BR2_DIR)" ]; then \
	    echo "ERROR: buildroot не инициализирован → make buildroot-init"; \
	    exit 1; fi
	$(BR2_MAKE) target-post-image
	@echo "DONE: $(BR_IMAGES)/sdcard.img пересобран."

# Быстрая переупаковка sdcard.img: вызывает post-image.sh напрямую
# с минимальным набором переменных окружения, которые ему нужны.
# Подразумевает, что Buildroot уже хотя бы раз прошёл buildroot-build
# (есть rootfs.tar / uImage / *.dtb / u-boot* в $(BR_IMAGES) и host-
# тулзы genimage / genext2fs / mcopy / mkfs.vfat в host/bin).
sdcard-quick:
	@if [ ! -f "$(BR_IMAGES)/uImage" ] || [ ! -f "$(BR_IMAGES)/rootfs.tar" ]; then \
	    echo "ERROR: в $(BR_IMAGES) нет uImage/rootfs.tar."; \
	    echo "       Сначала выполните 'make buildroot-build'."; \
	    exit 1; fi
	@if [ ! -x "$(BUILDROOT_OUT)/host/bin/mcopy" ]; then \
	    echo "ERROR: $(BUILDROOT_OUT)/host/bin/mcopy не найден."; \
	    echo "       Buildroot должен был собрать host-mtools (включён в"; \
	    echo "       defconfig: BR2_PACKAGE_HOST_MTOOLS=y). Пересоберите:"; \
	    echo "         make buildroot-build"; \
	    exit 1; fi
	@echo ">>> running post-image.sh directly (skipping Buildroot deps)"
	@PATH="$(BUILDROOT_OUT)/host/bin:$(BUILDROOT_OUT)/host/sbin:$$PATH" \
	 BR2_EXTERNAL_ZYNQ_MINI_I2C_PATH="$(BR2_EXT)" \
	 BUILD_DIR="$(BUILDROOT_OUT)/build" \
	 BINARIES_DIR="$(BR_IMAGES)" \
	 TARGET_DIR="$(BUILDROOT_OUT)/target" \
	 HOST_DIR="$(BUILDROOT_OUT)/host" \
	 bash "$(BR2_EXT)/board/zynq_mini_revb/post-image.sh"
	@if [ -f "$(BR_IMAGES)/BOOT.BIN.MISSING" ]; then \
	    if [ -s "$(CURDIR)/boot/BOOT.BIN" ] && \
	       [ "$$(stat -c %s $(CURDIR)/boot/BOOT.BIN)" -gt 1024 ]; then \
	        rm -f "$(BR_IMAGES)/BOOT.BIN.MISSING"; \
	    fi; fi
	@echo "DONE: $(BR_IMAGES)/sdcard.img пересобран (quick mode)."

buildroot-clean:
	rm -rf $(BUILDROOT_OUT)
	@echo ">>> wiped $(BUILDROOT_OUT) (исходники в $(BR2_DIR) сохранены)"

# ---------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------
clean: questa-clean
	rm -rf $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd $(SIM_DIR)/*.fst obj_dir
