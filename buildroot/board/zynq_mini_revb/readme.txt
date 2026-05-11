ZYNQ MINI Rev B board files
===========================

Layout
------
  post-build.sh   — runs after target/ is populated; installs network
                    and module-autoload files.
  post-image.sh   — runs after rootfs+kernel are built; copies BOOT.BIN
                    + uEnv.txt and invokes genimage.
  genimage.cfg    — describes the SD-card layout (FAT32 + ext4 + MBR).
  uEnv.txt        — U-Boot environment loaded automatically by the
                    Xilinx defconfig boot script.
  linux.fragment  — kconfig overlay merged on top of multi_v7_defconfig
                    (enables I2C, SSD1307FB, RTL8211E, USB host, etc.).
  uboot.fragment  — kconfig overlay for U-Boot (FAT/ext4/uImage).

After Buildroot finishes
------------------------
  output/images/sdcard.img   — bit-exact SD card image
  output/images/uImage       — kernel
  output/images/zynq-mini-revb.dtb
  output/images/rootfs.ext4
  output/images/BOOT.BIN     — *only* if `make boot-bin` was run
                                in the project root *before* Buildroot.

Flash:
  sudo dd if=output/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress

After first boot:
  login: root  (no password)
  i2cdetect -y 1
  cat /proc/device-tree/amba_pl/i2c@43c00000/compatible
