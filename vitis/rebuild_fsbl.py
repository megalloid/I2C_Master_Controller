#!/usr/bin/env python3
"""
Пересобрать FSBL приложение в существующем Vitis workspace.

Запуск:
    source /opt/xilinx/2025.2/Vitis/settings64.sh
    vitis -s vitis/rebuild_fsbl.py
"""
import os
import sys
import vitis  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
WS = os.path.join(REPO, "vitis", "workspace")

print(f"[rebuild_fsbl] workspace = {WS}")
client = vitis.create_client()
client.set_workspace(path=WS)

# FSBL — boot domain платформы zynq_mini_oled_platform.
# platform.build() пересобирает BSP + FSBL.
plat = client.get_component(name="zynq_mini_oled_platform")
print(f"[rebuild_fsbl] platform = {plat}")
print("[rebuild_fsbl] platform.build()...")
plat.build()

elf = os.path.join(WS, "zynq_mini_oled_platform", "zynq_fsbl", "build", "fsbl.elf")
if os.path.exists(elf):
    sz = os.path.getsize(elf)
    mt = os.path.getmtime(elf)
    print(f"[rebuild_fsbl] DONE: {elf}  size={sz}  mtime={mt}")
else:
    sys.exit(f"[rebuild_fsbl] ERROR: ELF not found: {elf}")
