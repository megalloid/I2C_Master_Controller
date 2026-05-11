#!/bin/bash
# deploy.sh — заливает свежий oled-clock на плату и помогает гонять диагностики.
#
# Запускать с твоего хоста (там, где есть sshpass, ip связь с платой):
#   bash linux/userspace/oled-clock/deploy.sh                    # залить и запустить (LSB+mmap)
#   bash linux/userspace/oled-clock/deploy.sh stop               # остановить демон
#   bash linux/userspace/oled-clock/deploy.sh info               # FBIOGET_*SCREENINFO
#   bash linux/userspace/oled-clock/deploy.sh test A             # один паттерн (Z,G,A,D,F,T,R,H,L,B,8,9,P,Q)
#   bash linux/userspace/oled-clock/deploy.sh test A --msb       # тот же паттерн, MSB-first
#   bash linux/userspace/oled-clock/deploy.sh test A --no-mmap   # тот же, только write()
#   bash linux/userspace/oled-clock/deploy.sh run --msb          # запустить часы с MSB-форматом
#   bash linux/userspace/oled-clock/deploy.sh run --no-mmap      # запустить только через write()
#   bash linux/userspace/oled-clock/deploy.sh console            # OLED в режим Linux console + getty (USB-клавиатура)
#   bash linux/userspace/oled-clock/deploy.sh clock              # OLED в режим часов (по умолчанию)
#   bash linux/userspace/oled-clock/deploy.sh shell '<cmd>'      # выполнить <cmd> на плате
set -eu

HOST=${OLED_HOST:-root@192.168.2.145}
PASS=${OLED_PASS:-root}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$SCRIPT_DIR/oled-clock"
SWITCH_CLK="$SCRIPT_DIR/oled-clock-start.sh"
SWITCH_CON="$SCRIPT_DIR/oled-console.sh"

ssh_cmd() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "$HOST" "$@"
}

copy_to_remote() {
  local src="$1" dst="$2"
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "$HOST" "cat > '$dst' && chmod +x '$dst'" < "$src"
}

ensure_module_and_bin() {
  ssh_cmd 'mkdir -p /usr/local/bin && modprobe i2c-master-axi 2>/dev/null; \
           ls /dev/fb0 /dev/i2c-0 2>&1 | head'
  if [ "${SKIP_UPLOAD:-0}" != 1 ] && [ -x "$BIN" ]; then
    copy_to_remote "$BIN" /usr/local/bin/oled-clock
  fi
  # Скрипты-переключатели режимов (clock ↔ Linux-console на /dev/fb0).
  [ -r "$SWITCH_CLK" ] && copy_to_remote "$SWITCH_CLK" /usr/local/bin/oled-clock-start
  [ -r "$SWITCH_CON" ] && copy_to_remote "$SWITCH_CON" /usr/local/bin/oled-console
}

case "${1-deploy}" in
  stop)
    ssh_cmd 'killall -q oled-clock 2>/dev/null; sleep 0.3; pgrep -laf oled-clock || echo stopped'
    ;;
  info)
    ensure_module_and_bin
    ssh_cmd 'killall -q oled-clock 2>/dev/null; sleep 0.2; /usr/local/bin/oled-clock --info'
    ;;
  test)
    PATTERN=${2:-A}
    shift 2 2>/dev/null || shift 1
    ensure_module_and_bin
    ssh_cmd "killall -q oled-clock 2>/dev/null; sleep 0.2; /usr/local/bin/oled-clock --test $PATTERN $*"
    ;;
  run)
    shift
    ensure_module_and_bin
    # передаём дополнительные флаги в демона
    ssh_cmd "killall -q oled-clock 2>/dev/null; sleep 0.2; \
             nohup /usr/local/bin/oled-clock $* >/tmp/oled.log 2>&1 & \
             sleep 0.6; pgrep -laf oled-clock; cat /tmp/oled.log"
    ;;
  shell)
    shift
    ssh_cmd "$*"
    ;;
  console)
    ensure_module_and_bin
    ssh_cmd '/usr/local/bin/oled-console'
    ;;
  clock)
    ensure_module_and_bin
    ssh_cmd '/usr/local/bin/oled-clock-start'
    ;;
  deploy|"")
    ensure_module_and_bin
    ssh_cmd 'killall -q oled-clock 2>/dev/null; sleep 0.2; \
             nohup /usr/local/bin/oled-clock >/tmp/oled.log 2>&1 & \
             sleep 0.6; pgrep -laf oled-clock; cat /tmp/oled.log'
    ;;
  *)
    echo "unknown subcommand: $1"
    exit 1
    ;;
esac
