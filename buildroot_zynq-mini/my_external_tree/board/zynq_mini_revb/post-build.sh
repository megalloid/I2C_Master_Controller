#!/usr/bin/env bash
# Buildroot post-build hook — runs after rootfs assembly, before image creation.
#
# Tasks:
#   * Install /etc/network/interfaces (eth0 dhcp)
#   * Fixed MAC: /etc/eth0-mac + S39set-eth0-mac (before DHCP)
#   * Auto-load i2c-master-axi at boot (S03modules)
#   * OLED console at boot: /usr/local/bin/oled-console + S45oled-console
#   * Banner /etc/issue, hints in /etc/profile.d/

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

# --- Фиксированный MAC eth0 (до DHCP / S40network) -------------------
# Меняйте последние 3 октета на уникальные для каждой платы в LAN.
# Должен совпадать с local-mac-address в zynq-mini-revb.dts (B.4).
cat > "${TARGET}/etc/eth0-mac" <<'EOF'
00:0a:35:01:02:03
EOF

cat > "${TARGET}/etc/init.d/S39set-eth0-mac" <<'EOF'
#!/bin/sh
# Применить MAC из /etc/eth0-mac до ifup/DHCP (BusyBox init).
case "$1" in
    start|"")
        [ -d /sys/class/net/eth0 ] || exit 0
        MAC=$(grep -E '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$' /etc/eth0-mac 2>/dev/null | head -1)
        [ -n "$MAC" ] || MAC="00:0a:35:01:02:03"
        ip link set dev eth0 down 2>/dev/null || true
        ip link set dev eth0 address "$MAC" 2>/dev/null || true
        ip link set dev eth0 up 2>/dev/null || true
        ;;
    stop|restart|reload) : ;;
    *) echo "usage: $0 {start|stop|restart|reload}"; exit 1 ;;
esac
exit 0
EOF
chmod 0755 "${TARGET}/etc/init.d/S39set-eth0-mac"

# --- OLED: fbcon + getty tty1 при загрузке (E.9) -----------------------
install -d "${TARGET}/usr/local/bin"
cat > "${TARGET}/usr/local/bin/oled-console" <<'EOF'
#!/bin/sh
VTCON=/sys/class/vtconsole/vtcon1/bind
killall -q oled-clock 2>/dev/null
sleep 0.2
if [ -w "$VTCON" ]; then
    echo 1 > "$VTCON"
else
    echo "oled-console: cannot write $VTCON" >&2
    exit 1
fi
if ! ps | grep -v grep | grep -E '[g]etty[^/]*tty1' >/dev/null; then
    setsid /sbin/getty -L tty1 0 linux </dev/null >/dev/null 2>&1 &
fi
echo "OLED console ready — login on tty1 (USB keyboard)"
EOF
chmod 0755 "${TARGET}/usr/local/bin/oled-console"

cat > "${TARGET}/etc/init.d/S45oled-console" <<'EOF'
#!/bin/sh
# После S03modules: ждём /dev/fb0, затем bind fbcon (E.5 / E.9).
case "$1" in
    start|"")
        i=0
        while [ ! -c /dev/fb0 ] && [ "$i" -lt 40 ]; do
            sleep 0.25
            i=$((i + 1))
        done
        [ -x /usr/local/bin/oled-console ] && /usr/local/bin/oled-console
        ;;
    stop)
        killall -q oled-clock 2>/dev/null || true
        [ -w /sys/class/vtconsole/vtcon1/bind ] && echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null || true
        ;;
    restart|reload) "$0" stop; "$0" start ;;
    *) echo "usage: $0 {start|stop|restart|reload}"; exit 1 ;;
esac
exit 0
EOF
chmod 0755 "${TARGET}/etc/init.d/S45oled-console"
