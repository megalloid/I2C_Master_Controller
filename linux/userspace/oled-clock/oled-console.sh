#!/bin/sh
# oled-console — включить Linux console на /dev/fb0 (SSD1306) и getty
# на tty1 (login через USB-клавиатуру).
#
# После запуска на OLED будут:
#   - kernel boot messages (если их ещё не очистил предыдущий кадр)
#   - login prompt
# Ввод осуществляется с USB-клавиатуры (через usbhid → input → VT).
#
# Размер видимой области очень мал (128x64), но достаточно для login
# и короткого CLI-взаимодействия.

VTCON=/sys/class/vtconsole/vtcon1/bind

# Останавливаем демон часов — он держит fb0 и через detach_fbcon
# отвязывает vtcon1 при каждом старте.
killall -q oled-clock 2>/dev/null
sleep 0.2

# Привязать fbcon обратно к /dev/fb0.
if [ -w "$VTCON" ]; then
    echo 1 > "$VTCON"
fi

# Запустить getty на tty1, если ещё не запущен.
if ! ps | grep -v grep | grep -E '[g]etty[^/]*tty1' >/dev/null; then
    setsid /sbin/getty -L tty1 0 linux </dev/null >/dev/null 2>&1 &
fi

echo "OLED console ready (login: root / password: root, на tty1)"
