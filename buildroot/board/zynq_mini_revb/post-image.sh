#!/usr/bin/env bash
# Buildroot post-image hook — assembles the SD-card image (sdcard.img).
#
# Layout (genimage.cfg):
#   FAT32 partition  : BOOT.BIN  uImage  zynq-mini-revb.dtb  uEnv.txt
#   ext4 partition   : rootfs.tar contents
#
# BOOT.BIN is built outside Buildroot (Vivado FSBL + u-boot.elf + bitstream),
# but we leave a placeholder if it's missing so the user gets a clear hint.

set -euo pipefail

BOARD_DIR="$(dirname "$0")"
GENIMAGE_CFG="${BOARD_DIR}/genimage.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"
BOOT_BIN_SRC="${BR2_EXTERNAL_ZYNQ_MINI_I2C_PATH}/../boot/BOOT.BIN"

# 1. Copy BOOT.BIN and uEnv.txt into the FAT staging directory ----------------
mkdir -p "${BINARIES_DIR}/boot"

if [[ -f "${BOOT_BIN_SRC}" ]]; then
    cp -v "${BOOT_BIN_SRC}" "${BINARIES_DIR}/BOOT.BIN"
else
    # genimage strictly requires every file listed in genimage.cfg to
    # exist, so we drop a tiny placeholder. The flag-file
    # BOOT.BIN.MISSING tells the user to come back later.
    cat > "${BINARIES_DIR}/BOOT.BIN" <<'PLACEHOLDER'
THIS IS A PLACEHOLDER, NOT A REAL ZYNQ BOOT IMAGE.
Run `make boot-bin` (which produces boot/BOOT.BIN out of FSBL+bitstream+u-boot.elf)
and then `make sdcard-rebuild` to regenerate sdcard.img with the real BOOT.BIN.
PLACEHOLDER
    : > "${BINARIES_DIR}/BOOT.BIN.MISSING"
    echo "WARNING: ${BOOT_BIN_SRC} missing; sdcard.img will boot ONLY after"
    echo "         you run 'make boot-bin && make sdcard-rebuild' in the repo root."
fi

cp -v "${BOARD_DIR}/uEnv.txt" "${BINARIES_DIR}/uEnv.txt"

# 2. Run genimage  -----------------------------------------------------------
rm -rf "${GENIMAGE_TMP}"
mkdir -p "${GENIMAGE_TMP}"

genimage \
    --rootpath "${TARGET_DIR}" \
    --tmppath "${GENIMAGE_TMP}" \
    --inputpath "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}" \
    --config "${GENIMAGE_CFG}"

echo
echo "==========================================================="
echo "  SD-card image:  ${BINARIES_DIR}/sdcard.img"
echo "  Flash with:     sudo dd if=${BINARIES_DIR}/sdcard.img \\"
echo "                       of=/dev/sdX bs=4M conv=fsync status=progress"
echo "==========================================================="
