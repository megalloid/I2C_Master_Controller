# I2C Master Controller

Production-ready I2C мастер-контроллер с интерфейсом AXI4-Lite для интеграции в FPGA-часть Xilinx Zynq SoC.
Включает модуль пакетной записи (`i2c_burst_writer`) для эффективной передачи длинных последовательностей байт (страницы EEPROM, фреймбуфер дисплея и т.д.).

## Возможности

- Полная поддержка I2C Master: START, STOP, RESTART, 7-bit адресация
- Запись и чтение байтов с ACK/NACK обработкой
- Clock stretching (ожидание slave)
- Обнаружение потери арбитража (Arbitration Lost)
- Настраиваемая частота SCL через прескалер (Standard / Fast / Fast Mode Plus)
- AXI4-Lite slave интерфейс (7 регистров)
- Прерывания: завершение транзакции (DONE) и потеря арбитража (AL)
- 2-stage синхронизаторы на входах SDA/SCL
- Составные команды (STA+WR, RD+NACK+STO) через секвенсер
- **Пакетная запись** (`i2c_burst_writer`): автоматическая передача N байт одной командой

## Архитектура

```mermaid
graph TD
    PS[Zynq PS / Linux] -->|AXI4-Lite| TOP[i2c_master_top]
    TOP --> AXI[i2c_master_axi]
    AXI --> CORE[i2c_master_core]
    AXI --> SYNC[Синхронизаторы]
    AXI --> PRE[Прескалер]
    AXI --> SEQ[Секвенсер]
    AXI --> IRQ[Прерывания]
    TOP --> BUF[Tri-state буферы]
    BUF --> BUS[I2C Bus: SDA/SCL]
```

## Структура проекта

```
I2C_Master_Controller/
├── rtl/
│   ├── i2c_master_core.v        # Низкоуровневое I2C ядро (FSM)
│   ├── i2c_master_axi.v         # AXI4-Lite обёртка (регистры, прескалер, прерывания)
│   ├── i2c_master_top.v         # Top-level с tri-state буферами
│   └── i2c_burst_writer.v      # Модуль пакетной I2C записи (START+addr+N bytes+STOP)
├── tb/
│   ├── i2c_slave_model.sv       # Модель I2C slave (EEPROM 256 байт)
│   ├── axi_lite_master_bfm.sv   # AXI4-Lite master BFM
│   └── i2c_master_tb.sv         # Основной тестбенч (10 сценариев)
├── driver/
│   ├── i2c-zynq-master.c        # Linux I2C adapter driver
│   ├── Makefile                  # Out-of-tree сборка модуля
│   ├── Kconfig                   # Для in-tree интеграции
│   ├── custom,i2c-master.yaml   # DT binding документация
│   └── zynq-i2c-master-overlay.dts # Пример Device Tree overlay
├── sim/                          # Артефакты симуляции
├── doc/
│   ├── DESIGN.md                 # Архитектура и FSM
│   ├── REGISTERS.md              # Карта регистров
│   ├── TESTPLAN.md               # План тестирования
│   ├── INTEGRATION.md            # Интеграция в Zynq
│   ├── DRIVER.md                 # Документация Linux-драйвера
│   └── GUIDE_I2C_MASTER_CORE.md # Подробный гайд по проектированию ядра
├── quartus_ssd1306/             # Проект: тест SSD1306 OLED на Cyclone IV
│   ├── src/                     # RTL модули (контроллер SSD1306, дисплей, кнопка)
│   ├── ssd1306_test.qpf         # Quartus project
│   ├── ssd1306_test_top.qsf     # Настройки и пины (ALINX AX301)
│   ├── ssd1306_test_top.sdc     # Тайминг-ограничения
│   └── README.md
├── Makefile
├── .gitignore
└── README.md
```

## Быстрый старт

### Предварительные требования

- [Icarus Verilog](http://iverilog.icarus.com/) >= 12.0
- [Verilator](https://www.veripool.org/verilator/) >= 5.0 (для lint)

### Сборка и запуск тестов

```bash
make sim        # Компиляция + симуляция
make lint       # Lint-проверка RTL через Verilator
make wave       # Генерация VCD для просмотра в GTKWave
make clean      # Очистка артефактов
```

### Результат

```
=== TEST 0: Register read-back ===
  PASS: PRESCALE read-back OK
=== TEST 1: Single byte write + read-back ===
  PASS: read 0xa5 == expected 0xA5
...
  TEST SUMMARY:  PASS=10  FAIL=0
All tests PASSED
```

## Карта регистров (кратко)

| Смещение | Имя | Доступ | Описание |
|----------|-----|--------|----------|
| 0x00 | CTRL | R/W | {IEN, EN} |
| 0x04 | STATUS | R | {AL, BUSY, RXACK, TIP} |
| 0x08 | CMD | W | {NACK, WR, RD, STO, STA} |
| 0x0C | TX_DATA | R/W | Данные для передачи |
| 0x10 | RX_DATA | R | Принятые данные |
| 0x14 | PRESCALE | R/W | SCL = clk / (4×(PRESCALE+1)) |
| 0x18 | ISR | R/W1C | {AL_IRQ, DONE_IRQ} |

Подробнее: [doc/REGISTERS.md](doc/REGISTERS.md)

## Linux-драйвер

В каталоге `driver/` — полноценный Linux I2C adapter driver (`i2c-zynq-master`):

```bash
cd driver/
make KERNEL_SRC=/path/to/linux-xlnx ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
```

После загрузки модуля контроллер становится доступен через стандартные интерфейсы:

```bash
i2cdetect -y 0       # Сканирование шины
i2cget -y 0 0x50 0   # Чтение из EEPROM
```

Подробнее: [doc/DRIVER.md](doc/DRIVER.md)

## Интеграция в Vivado / Zynq

Контроллер подключается к PS через AXI Interconnect. Прерывание `irq_o` — к GIC через `IRQ_F2P`.

Подробнее: [doc/INTEGRATION.md](doc/INTEGRATION.md)

## Документация

| Документ | Описание |
|----------|----------|
| [DESIGN.md](doc/DESIGN.md) | Архитектура, FSM-диаграммы, проектные решения |
| [REGISTERS.md](doc/REGISTERS.md) | Полная карта регистров с битовыми полями |
| [TESTPLAN.md](doc/TESTPLAN.md) | Тестовые сценарии и план верификации |
| [INTEGRATION.md](doc/INTEGRATION.md) | Интеграция в Zynq, Device Tree, Linux-драйвер |
| [DRIVER.md](doc/DRIVER.md) | Linux I2C adapter driver: сборка, DT, использование |
| [GUIDE_I2C_MASTER_CORE.md](doc/GUIDE_I2C_MASTER_CORE.md) | Пошаговый гайд по проектированию I2C ядра |
| [SSD1306 README](quartus_ssd1306/README.md) | Тест SSD1306 OLED на Cyclone IV |

## Лицензия

MIT
