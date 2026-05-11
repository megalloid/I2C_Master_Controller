#!/usr/bin/env bash
# Buildroot post-build hook — runs after rootfs assembly, before image creation.
#
# Tasks:
#   * Install /etc/network/interfaces (eth0 dhcp)
#   * Auto-load i2c-master-axi at boot
#   * Add a banner with the project name in /etc/issue

set -euo pipefail

TARGET="${1:?usage: post-build.sh <target-dir>}"

install -d "${TARGET}/etc/modules-load.d"
cat > "${TARGET}/etc/modules-load.d/i2c-master-axi.conf" <<'EOF'
i2c-master-axi
ssd1306
EOF

install -d "${TARGET}/etc/network"
cat > "${TARGET}/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

cat > "${TARGET}/etc/issue" <<'EOF'

  ZYNQ MINI Rev B  -  I2C_Master_Controller demo
  ----------------------------------------------
  login: root  (no password)
  i2cdetect -y 1   # SSD1306 lives at 0x3C on i2c-1

EOF

# A welcome script that prints PL info on first login.
install -d "${TARGET}/etc/profile.d"
cat > "${TARGET}/etc/profile.d/zynq-info.sh" <<'EOF'
#!/bin/sh
if [ -d /sys/bus/i2c/devices/i2c-1 ]; then
    echo
    echo "PL i2c master at 0x43c00000 (i2c-1) — try:"
    echo "  i2cdetect -y 1"
    echo "  fb-test  /dev/fb0   (if SSD1306 framebuffer is loaded)"
    echo
fi
EOF
chmod 0755 "${TARGET}/etc/profile.d/zynq-info.sh"
