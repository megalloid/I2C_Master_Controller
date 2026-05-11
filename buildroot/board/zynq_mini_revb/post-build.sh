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
# i2c-master-axi — out-of-tree модуль PL-контроллера. Драйвер ssd1307fb
# уже встроен в ядро (CONFIG_FB_SSD1307=y) и сам подцепится к i2c-узлу
# 0-003c сразу после регистрации шины. ssd1306 — это compatible-имя,
# а не модуль, его modprobe-ить бесполезно.
cat > "${TARGET}/etc/modules-load.d/i2c-master-axi.conf" <<'EOF'
i2c-master-axi
EOF

# BusyBox-init не читает /etc/modules-load.d/ — нужен явный rcS-script.
install -d "${TARGET}/etc/init.d"
cat > "${TARGET}/etc/init.d/S03modules" <<'EOF'
#!/bin/sh
# Загружаем модули из /etc/modules-load.d/*.conf, как это делает systemd.
case "$1" in
    start|"")
        [ -d /etc/modules-load.d ] || exit 0
        for f in /etc/modules-load.d/*.conf; do
            [ -e "$f" ] || continue
            while IFS= read -r mod; do
                case "$mod" in ""|\#*) continue ;; esac
                modprobe "$mod" 2>/dev/null || true
            done < "$f"
        done
        ;;
    stop|restart|reload) : ;;
    *) echo "usage: $0 {start|stop|restart|reload}" ; exit 1 ;;
esac
exit 0
EOF
chmod 0755 "${TARGET}/etc/init.d/S03modules"

# Auto-getty на tty1 — login через USB-клавиатуру на /dev/fb0 (fbcon).
# Если строки ещё нет (sanity для повторных запусков post-build).
if ! grep -q '^tty1::' "${TARGET}/etc/inittab"; then
    sed -i '/^ttyPS0::/a tty1::respawn:/sbin/getty -L tty1 0 linux' \
        "${TARGET}/etc/inittab"
fi

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
