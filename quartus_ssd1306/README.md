# SSD1306 OLED Test — Cyclone IV (AX301)

Аппаратный тест I2C Master Controller с OLED дисплеем SSD1306 128×64
на плате ALINX AX301 (EP4CE6F17C8).

## Обзор

По нажатию кнопки FPGA выполняет:

1. **Пауза 100 мс** — стабилизация питания SSD1306
2. **Инициализация** — отправка 32 байт команд SSD1306 по I2C
3. **Отображение тестовой картинки** — передача 1025 байт данных фреймбуфера

Используется модуль `i2c_burst_writer` для автоматической пакетной передачи.

## Тестовая картинка

Экран 128×64 разделён на 4 квадранта с рамкой по периметру:

```
┌──────────────┬──────────────┐
│ Верт.полосы  │  Шахматная   │  pages 0-3
│ (8 пикс.)   │  доска (8×8) │
├──────────────┼──────────────┤
│ Гориз.линии  │  Диагональная│  pages 4-7
│ (пунктир)    │  лесенка     │
└──────────────┴──────────────┘
  cols 0-63       cols 64-127
```

## Подключение SSD1306

Дисплей подключается к шине I2C, общей с EEPROM 24LC04 (разные адреса):

| SSD1306 пин | Плата AX301 | FPGA пин |
|-------------|-------------|----------|
| VCC | 3.3V | — |
| GND | GND | — |
| SDA | I2C SDA | E6 |
| SCL | I2C SCL | D1 |

Адрес SSD1306 по умолчанию: **0x3C** (SA0=GND).

## Индикация

### Светодиоды

| LED | Значение |
|-----|----------|
| LED[0] | Передача идёт |
| LED[1] | Передача завершена OK |
| LED[2] | Ошибка (NACK / arb lost) |
| LED[3] | Шина I2C занята |

### 7-сегментный дисплей

Показывает счётчик переданных байт в HEX (цифры 3-0).
Цифра 0: `0` при успехе, `E` при ошибке, `-` в процессе.

## Сборка

### Quartus Prime

```bash
cd quartus_ssd1306
# Открыть ssd1306_test.qpf в Quartus Prime Lite
# Processing → Start Compilation
# Tools → Programmer → загрузить .sof
```

### Верификация (lint)

```bash
verilator --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    rtl/i2c_master_core.v rtl/i2c_burst_writer.v \
    quartus_ssd1306/src/*.v --top-module ssd1306_test_top
```

## Архитектура

```
ssd1306_test_top
├── ax_debounce         — антидребезг кнопки
├── i2c_master_core     — ядро I2C (из rtl/)
├── ssd1306_ctrl        — контроллер SSD1306
│   └── i2c_burst_writer — пакетная запись (из rtl/)
├── seg_scan            — сканирование 7-сег дисплея
└── prescaler           — делитель для 100 кГц SCL
```

## Структура файлов

```
quartus_ssd1306/
├── src/
│   ├── ssd1306_test_top.v    — top-level
│   ├── ssd1306_ctrl.v        — контроллер SSD1306 (init ROM + pattern gen)
│   ├── seg_scan.v            — 7-сегментный сканер
│   └── ax_debounce.v         — антидребезг
├── ssd1306_test.qpf          — Quartus проект
├── ssd1306_test_top.qsf      — настройки и пины
├── ssd1306_test_top.sdc      — тайминг-ограничения
└── README.md
```
