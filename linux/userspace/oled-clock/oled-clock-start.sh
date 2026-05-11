#!/bin/sh
# oled-clock-start — запустить демон часов на /dev/fb0 (SSD1306).
#
# Останавливает любой getty на tty1, отвязывает fbcon от fb0 (иначе
# kernel console будет перерисовывать кадр и затирать наш вывод), и
# запускает /usr/local/bin/oled-clock в фоне.

VTCON=/sys/class/vtconsole/vtcon1/bind
LOG=/tmp/oled.log

# Останавливаем getty на tty1 (если есть). Не используем pidof, т.к.
# одноимённые процессы могут быть и на UART tty.
ps | grep -v grep | grep -E '[g]etty[^/]*tty1' | awk '{print $1}' \
    | xargs -r kill 2>/dev/null

sleep 0.2

# Отвязать fbcon — чтобы он не перетирал кадр.
if [ -w "$VTCON" ]; then
    echo 0 > "$VTCON"
fi

# Запустить демон если ещё не работает. pidof — точное совпадение
# по имени бинарника, без ложных срабатываний на скрипт-обёртку.
if ! pidof oled-clock >/dev/null 2>&1; then
    nohup /usr/local/bin/oled-clock >"$LOG" 2>&1 &
    sleep 0.5
fi

echo "OLED clock running (log: $LOG)"
pidof oled-clock | xargs -r echo "pid:"
