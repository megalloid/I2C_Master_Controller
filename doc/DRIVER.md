# Linux-драйвер I2C Master Controller

## Обзор

Драйвер `i2c-zynq-master` — полноценный Linux I2C adapter driver для кастомного IP-ядра `i2c_master_axi`, реализованного в PL-части Xilinx Zynq. Драйвер интегрируется в стандартную подсистему Linux I2C и позволяет использовать все стандартные утилиты (`i2cdetect`, `i2cget`, `i2cset`, `i2cdump`) и клиентские драйверы (EEPROM, датчики, RTC и т.д.).

## Архитектура

```mermaid
graph TD
    subgraph Userspace
        APP[Приложение / i2c-tools]
    end
    subgraph Kernel
        I2C_CORE[Linux I2C Core]
        DRV[i2c-zynq-master]
        IRQ_H[IRQ Handler]
    end
    subgraph Hardware [Zynq PL]
        AXI[AXI4-Lite Regs]
        CORE[i2c_master_core]
        PAD[SDA/SCL Pads]
    end

    APP -->|/dev/i2c-N| I2C_CORE
    I2C_CORE -->|master_xfer| DRV
    DRV -->|readl/writel| AXI
    AXI --> CORE
    CORE --> PAD
    PAD -->|IRQ| IRQ_H
    IRQ_H -->|complete()| DRV
```

## Возможности

| Возможность | Поддержка |
|-------------|-----------|
| Standard Mode (100 кГц) | Да |
| Fast Mode (400 кГц) | Да |
| Fast Mode Plus (1 МГц) | Да |
| 7-bit адресация | Да |
| 10-bit адресация | Нет |
| Прерывания | Да (опционально) |
| Polling-режим | Да (fallback) |
| Clock stretching | Да (аппаратно) |
| Arbitration lost | Да (возвращает -EAGAIN) |
| Suspend / Resume | Да |
| SMBus emulation | Да (I2C_FUNC_SMBUS_EMUL) |
| Device Tree | Обязательно |

## Файлы

```
driver/
├── i2c-zynq-master.c           # Исходный код драйвера
├── Makefile                     # Out-of-tree сборка
├── Kconfig                      # Для in-tree интеграции
├── custom,i2c-master.yaml       # DT binding документация
└── zynq-i2c-master-overlay.dts  # Пример Device Tree overlay
```

## Сборка

### Out-of-tree (кросс-компиляция для Zynq)

```bash
cd driver/

# Указать путь к исходникам ядра и кросс-компилятор
make KERNEL_SRC=/path/to/linux-xlnx \
     ARCH=arm \
     CROSS_COMPILE=arm-linux-gnueabihf-
```

Результат: `i2c-zynq-master.ko`

### In-tree

1. Скопировать `i2c-zynq-master.c` в `drivers/i2c/busses/`
2. Добавить в `drivers/i2c/busses/Makefile`:
   ```makefile
   obj-$(CONFIG_I2C_ZYNQ_MASTER) += i2c-zynq-master.o
   ```
3. Добавить в `drivers/i2c/busses/Kconfig` содержимое файла `Kconfig`
4. Включить `CONFIG_I2C_ZYNQ_MASTER=y` (или `=m`) в конфигурации ядра

## Device Tree

### Обязательные свойства

| Свойство | Тип | Описание |
|----------|-----|----------|
| `compatible` | string | `"custom,i2c-master-1.0"` |
| `reg` | u32 пара | Базовый адрес и размер (0x1C) |

### Опциональные свойства

| Свойство | Тип | По умолчанию | Описание |
|----------|-----|-------------|----------|
| `interrupts` | — | отсутствует | IRQ линия; без неё — polling |
| `clocks` | phandle | — | Тактовый сигнал (FCLK) |
| `clock-frequency` | u32 | 100000 | Частота SCL (Гц) |
| `input-clock-frequency` | u32 | 100000000 | Частота входного клока (если нет `clocks`) |

### Пример

```dts
i2c@43c00000 {
    compatible = "custom,i2c-master-1.0";
    reg = <0x43c00000 0x1c>;
    interrupts = <0 61 4>;       /* GIC_SPI 61 LEVEL_HIGH */
    clocks = <&clkc 15>;         /* FCLK_CLK0 */
    clock-frequency = <400000>;  /* Fast Mode */
    #address-cells = <1>;
    #size-cells = <0>;

    eeprom@50 {
        compatible = "atmel,24c02";
        reg = <0x50>;
    };
};
```

### Определение адреса и IRQ

Адрес (`reg`) берётся из Vivado Address Editor. Номер IRQ:

| Vivado IRQ | GIC SPI | DTS формат |
|-----------|---------|------------|
| `IRQ_F2P[0]` | 61 | `<0 61 4>` |
| `IRQ_F2P[1]` | 62 | `<0 62 4>` |
| ... | ... | ... |
| `IRQ_F2P[15]` | 76 | `<0 76 4>` |

Формат: `<type number flags>` где `type=0` (SPI), `flags=4` (LEVEL_HIGH).

## Загрузка и использование

### Загрузка модуля

```bash
# Скопировать .ko на целевую систему
scp i2c-zynq-master.ko root@zynq:/lib/modules/$(uname -r)/extra/

# Загрузить
insmod /lib/modules/$(uname -r)/extra/i2c-zynq-master.ko

# Или через depmod (для modprobe)
depmod -a
modprobe i2c-zynq-master
```

### Проверка

```bash
# Должен появиться новый I2C адаптер
dmesg | grep i2c-zynq-master
# i2c-zynq-master 43c00000.i2c: prescale=249, SCL≈100000 Hz, irq=yes
# i2c-zynq-master 43c00000.i2c: I2C master controller registered (bus 0)

# Список адаптеров
i2cdetect -l
# i2c-0  i2c  i2c-zynq-master at 43c00000.i2c  I2C adapter

# Сканирование шины
i2cdetect -y 0
```

### Утилиты i2c-tools

```bash
# Чтение байта из EEPROM (slave 0x50, регистр 0x00)
i2cget -y 0 0x50 0x00

# Запись байта в EEPROM
i2cset -y 0 0x50 0x10 0xAB

# Дамп первых 256 байт EEPROM
i2cdump -y 0 0x50
```

### Программный доступ из userspace (C)

```c
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>

int fd = open("/dev/i2c-0", O_RDWR);
ioctl(fd, I2C_SLAVE, 0x50);

/* Запись: регистр 0x10, данные 0xAB */
uint8_t wr_buf[] = {0x10, 0xAB};
write(fd, wr_buf, 2);
usleep(5000);  /* Ожидание записи EEPROM */

/* Чтение: установить указатель, затем прочитать */
uint8_t reg = 0x10;
write(fd, &reg, 1);
uint8_t data;
read(fd, &data, 1);
printf("Read: 0x%02X\n", data);

close(fd);
```

## Обработка ошибок

| Код возврата | Причина | Действие |
|-------------|---------|----------|
| `-ENXIO` | NACK на адрес slave | Устройство не отвечает; проверить адрес и подключение |
| `-EIO` | NACK на байт данных | Ошибка протокола |
| `-EAGAIN` | Arbitration Lost | Повторить транзакцию (I2C core делает retry) |
| `-ETIMEDOUT` | Таймаут (1 сек) | Шина зависла; возможно, требуется bus recovery |

## Отладка

### Включение debug-логов

```bash
echo 8 > /proc/sys/kernel/printk
echo "file i2c-zynq-master.c +p" > /sys/kernel/debug/dynamic_debug/control
```

### Проверка регистров через devmem

```bash
# Читать STATUS (при базе 0x43c00000)
devmem 0x43c00004

# Читать PRESCALE
devmem 0x43c00014
```

### Типичные проблемы

| Проблема | Причина | Решение |
|----------|---------|---------|
| `i2cdetect` не находит устройства | Нет pull-up на SDA/SCL | Установить внешние 2.2–4.7 кОм |
| Таймаут при каждой операции | Неверный prescaler / нет тактового сигнала | Проверить `clocks` в DTS |
| `NACK` на все адреса | Неверное напряжение I/O | Проверить уровни (3.3V / 1.8V) |
| Модуль не загружается | Нет compatible в DTS | Проверить Device Tree overlay |
| `irq=polling` в логах | IRQ не подключён | Добавить `interrupts` в DTS |

## Suspend / Resume

Драйвер поддерживает системный suspend/resume:

- **Suspend**: контроллер выключается (`EN=0`), тактовый сигнал отключается
- **Resume**: тактовый сигнал включается, prescaler восстанавливается, контроллер включается

Активные транзакции во время suspend будут прерваны. Клиентские драйверы должны обрабатывать это самостоятельно.

## Ограничения

1. **Только 7-bit адресация** — 10-bit не поддерживается аппаратно
2. **Нет DMA** — передача побайтная через MMIO
3. **Нет multi-master** — контроллер определяет потерю арбитража, но не гарантирует fairness
4. **Нет SMBus Alert** — только базовый I2C протокол
