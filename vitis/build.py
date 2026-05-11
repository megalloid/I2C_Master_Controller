#!/usr/bin/env python3
"""
Vitis 2025.2 Unified CLI — build script.

Создаёт workspace, импортирует XSA из Vivado, генерирует platform (standalone
для ps7_cortexa9_0), создаёт application "oled_demo", добавляет исходники из
vitis/src, собирает .elf.

Запуск:
    source /opt/xilinx/2025.2/Vitis/settings64.sh
    vitis -s vitis/build.py
"""
import os, sys, shutil
import vitis  # noqa: E402  (предоставляется средой Vitis)

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
WS   = os.path.join(REPO, "vitis", "workspace")
XSA  = os.path.join(REPO, "vivado", "zynq_mini_oled.xsa")
SRC  = os.path.join(REPO, "vitis", "src")

PLATFORM_NAME = "zynq_mini_oled_platform"
APP_NAME      = "oled_demo"
DOMAIN_CPU    = "ps7_cortexa9_0"
DOMAIN_OS     = "standalone"
DOMAIN_NAME   = f"{DOMAIN_OS}_{DOMAIN_CPU}"

if not os.path.exists(XSA):
    sys.exit(f"ERROR: XSA не найден: {XSA}\n"
             "Сначала: make vivado-build")

if os.path.exists(WS):
    print(f"INFO: removing previous workspace {WS}")
    shutil.rmtree(WS)
os.makedirs(WS, exist_ok=True)

print(f"INFO: workspace = {WS}")
client = vitis.create_client()
client.set_workspace(path=WS)

# ---- Platform ------------------------------------------------------------
print(f"INFO: creating platform {PLATFORM_NAME} from {XSA}")
platform = client.create_platform_component(
    name = PLATFORM_NAME,
    hw_design = XSA,
    os = DOMAIN_OS,
    cpu = DOMAIN_CPU,
    domain_name = DOMAIN_NAME,
)
print("INFO: building platform...")
platform.build()

xpfm = os.path.join(WS, PLATFORM_NAME, "export", PLATFORM_NAME, f"{PLATFORM_NAME}.xpfm")
print(f"INFO: platform xpfm = {xpfm}")

# ---- Application ---------------------------------------------------------
print(f"INFO: creating app {APP_NAME}")
app = client.create_app_component(
    name = APP_NAME,
    platform = xpfm,
    domain = DOMAIN_NAME,
    template = "empty_application",
)

print("INFO: importing sources from vitis/src/")
# lscript.ld тоже импортируем — заменит дефолтный (DDR-only) на наш (OCM-only).
for fname in ("main.c", "i2c_master.c", "i2c_master.h",
              "ssd1306.c", "ssd1306.h", "lscript.ld"):
    app.import_files(from_loc = SRC,
                     files     = [fname],
                     dest_dir_in_cmp = "src")

print("INFO: building application...")
app.build()

elf = os.path.join(WS, APP_NAME, "build", f"{APP_NAME}.elf")
print(f"DONE: ELF = {elf}")
