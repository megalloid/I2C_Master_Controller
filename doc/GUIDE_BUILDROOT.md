# Buildroot для ZYNQ MINI Rev B + I2C Master Controller

Пошаговый рецепт сборки **полной Linux-системы** (U-Boot + ядро + DTB +
rootfs) c встроенным драйвером `i2c-master-axi`. На выходе — образ
`sdcard.img`, которым можно сразу прошить SD-карту и загрузить плату.

> **Вход:** успешно отработал `make vivado-build` (есть `.bit` и `.xsa`)
> и в `/opt/xilinx/2025.2/Vitis/gnu/aarch32/lin/` стоит
> `gcc-arm-linux-gnueabi`.

---

## 1. Архитектура того, что мы собираем

```
   ┌──────────────────── BOOT.BIN ───────────────────┐
   │  [bootloader]  fsbl.elf      ← Vitis FSBL       │
   │                bitstream     ← Vivado .bit      │
   │                u-boot        ← Buildroot/U-Boot (ELF) │
   └──────────────────────────────────────────────────┘

   FAT-раздел SD:   BOOT.BIN  uImage  zynq-mini-revb.dtb  uEnv.txt
   ext4-раздел SD:  rootfs (включая i2c-master-axi.ko)

   Boot path: BootROM → FSBL → bitstream → U-Boot → uImage + DTB → init
```

Ключевые компоненты:

| Слой | Файл/исходник | Откуда |
|------|---------------|--------|
| FSBL | `vitis/workspace/.../fsbl.elf` | генерируется Vitis-ом из `.xsa` |
| Bitstream | `vivado/proj/.../zynq_mini_oled_top.bit` | `make vivado-build` |
| U-Boot ELF | `buildroot-build/images/u-boot` (без расширения, это ELF) | Buildroot |
| uImage | `buildroot-build/images/uImage` | Buildroot |
| DTB | `buildroot-build/images/zynq-mini-revb.dtb` | Buildroot ← `linux/dts/zynq-mini-revb.dts` |
| `i2c-master-axi.ko` | модуль ядра, лежит в `/lib/modules/.../extra/` | Buildroot package `i2c-master-axi` |

---

## 2. Структура нового кода в репозитории

```
linux/
├── drivers/i2c-master-axi/        ← out-of-tree модуль (i2c_adapter)
│   ├── i2c-master-axi.c
│   ├── Kbuild  Kconfig  Makefile  README.md
└── dts/
    └── zynq-mini-revb.dts         ← полный device tree платы

buildroot/                         ← BR2_EXTERNAL tree
├── external.desc / external.mk / Config.in
├── configs/zynq_mini_revb_defconfig
├── package/i2c-master-axi/        ← рецепт kernel-module
│   ├── Config.in
│   └── i2c-master-axi.mk
└── board/zynq_mini_revb/
    ├── post-build.sh   (модули автозагрузки, network)
    ├── post-image.sh   (BOOT.BIN, genimage → sdcard.img)
    ├── genimage.cfg    (FAT32 + ext4 + MBR)
    ├── uEnv.txt        (U-Boot bootcmd)
    ├── linux.fragment  (kconfig overlay)
    ├── uboot.fragment  (U-Boot kconfig overlay)
    └── readme.txt

boot/
└── boot.bif            ← шаблон для bootgen (BOOT.BIN)
```

---

## 3. Однократная настройка хоста

Debian/Ubuntu:
```bash
sudo apt install -y build-essential bc bison flex libssl-dev \
                    libgnutls28-dev libncurses-dev pkg-config \
                    python3 python3-pip rsync wget cpio file unzip \
                    device-tree-compiler gawk u-boot-tools git \
                    mtools dosfstools
```

Fedora/RHEL:
```bash
sudo dnf install -y gcc gcc-c++ make bc bison flex openssl-devel \
                    gnutls-devel ncurses-devel pkgconf-pkg-config \
                    python3 python3-pip rsync wget cpio file unzip \
                    dtc gawk uboot-tools git mtools dosfstools
```

> **Зачем `libgnutls28-dev` (`gnutls-devel`)?** U-Boot 2024.01
> в `xilinx_zynq_virt_defconfig` по умолчанию собирает host-tool
> `tools/mkeficapsule`, который требует gnutls. Если этот пакет не
> установлен, сборка падает на
> `fatal error: gnutls/gnutls.h: No such file or directory`.
> Альтернатива — отключить EFI-функциональность в нашем
> `buildroot/board/zynq_mini_revb/uboot.fragment` (там уже стоят
> соответствующие `# CONFIG_… is not set`), но проще поставить
> пакет — он маленький и нужен в любом случае при включении EFI/FIT.

---

## 4. Сборка PL и FSBL (если ещё не сделано)

```bash
make vivado-build PART=xc7z020clg400-1   # либо xc7z010
make vitis-build                         # сгенерирует FSBL ELF
```

После этого должны появиться:
```
vivado/zynq_mini_oled.xsa
vivado/proj/.../zynq_mini_oled_top.bit
vitis/workspace/.../fsbl.elf
```

> **Важно:** в `vivado/build.tcl` теперь полная PS7-конфигурация
> (DDR3 MT41J256M16 16-bit, UART1/SD0/ENET0/USB0/QSPI). Это критично для
> Linux — при минимальной конфигурации (как в bare-metal) у платы
> молчит DDR и ядро повиснет на etree.

---

## 5. Сборка Buildroot

```bash
make buildroot-init     # склонирует buildroot 2024.02.7 LTS, применит defconfig
make buildroot-build    # собирает всё (≈30–60 минут на первой сборке)
```

Что положено в дереве:

| Переменная | По умолчанию | Что |
|------------|--------------|-----|
| `BR2_VERSION` | `2024.02.7` | тег Buildroot |
| `BR2_DIR` | `./buildroot-src` | исходники Buildroot |
| `BUILDROOT_OUT` | `./buildroot-build` | output-каталог сборки |

В конце `make buildroot-build` имеем:

```
buildroot-build/images/
├── boot.vfat                ← готовая FAT32-партиция (32 MB)
├── rootfs.ext4              ← готовый ext4-rootfs (256 MB)
├── sdcard.img               ← MBR + FAT + ext4, образ SD-карты
├── uImage                   ← linux kernel (uImage, 0x8000 LMA)
├── zynq-mini-revb.dtb       ← скомпилирован из linux/dts/...
└── u-boot                   ← ELF для bootgen (без расширения)
```

`sdcard.img` пока **без** BOOT.BIN — добавляем его на шаге 6.

---

## 6. Сборка `BOOT.BIN`

```bash
make boot-bin
```

Что делает цель:
1. Подставляет в `boot/boot.bif` пути:
   - `[bootloader]` → `vitis/workspace/.../fsbl.elf`
   - `bitstream` → `vivado/proj/.../zynq_mini_oled_top.bit`
   - `u-boot.elf` → `buildroot-build/images/u-boot` (Buildroot кладёт ELF
     под именем без расширения; bootgen распознаёт его по ELF-magic)
2. Запускает `bootgen -arch zynq -image boot.bif -o boot/BOOT.BIN`.
3. Сообщает абсолютный путь к получившемуся `BOOT.BIN`.

> Если `fsbl.elf` отсутствует, цель честно скажет «нет FSBL», и предложит
> либо запустить `make vitis-build`, либо использовать
> `u-boot-spl.bin` из Buildroot (в нашем defconfig он не собирается, но
> при желании можно включить через `BR2_TARGET_UBOOT_SPL=y` в menuconfig).

---

## 7. Финализация SD-образа

При первом `make buildroot-build` `BOOT.BIN` ещё нет, поэтому
`post-image.sh` кладёт текстовый **placeholder** в `images/BOOT.BIN`
(чтобы genimage не падал) и записывает флаг `images/BOOT.BIN.MISSING`.
После того как `make boot-bin` сгенерирует настоящий `BOOT.BIN`, нужно
**пересобрать только SD-образ**. Доступны две цели:

```bash
make sdcard-quick     # быстрый путь — пара секунд
# или
make sdcard-rebuild   # «правильный» путь через Buildroot — 1–10+ мин
```

| Цель | Что делает | Когда использовать |
|------|------------|--------------------|
| `sdcard-quick` | вызывает `post-image.sh` + `genimage` напрямую, минуя Buildroot-овскую цепочку зависимостей | если `buildroot-build` уже отрабатывал и вам нужно только переупаковать `sdcard.img` после `make boot-bin` |
| `sdcard-rebuild` | вызывает Buildroot `target-post-image`, который перетряхивает `target-finalize` (rsync rootfs, regen ext4 и т.п.) | если вы изменили содержимое rootfs (модули, конфиги в `post-build.sh`) и хотите чтобы Buildroot подтянул эти изменения |

> Если нужна полная пересборка с U-Boot/kernel — `make buildroot-rebuild`.

---

## 8. Прошивка SD и старт

```bash
sudo dd if=buildroot-build/images/sdcard.img \
        of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

> Замените `/dev/sdX` на ваш реальный SD-диск. **Проверьте** через
> `lsblk` чтобы случайно не затереть системный диск!

Установите BOOT-переключатели на плате в `11` (TF-карта, см. схему,
стр. 4). Подайте питание.

В UART (115200n8 на TF1 type-c, через CH340E) увидите:

```
U-Boot SPL ...
U-Boot 2024.04 ...
zynq-mini> mmc dev 0
zynq-mini> run uenvcmd
...
[    0.000000] Booting Linux on physical CPU 0x0
[    0.000000] Linux version 6.6.x ...
...
i2c-master-axi 43c00000.i2c: input=50000000 Hz, bus=100000 Hz, prescale=124, irq=yes
...

ZYNQ MINI Rev B - I2C_Master_Controller
zynq-mini login: root
#
```

---

## 9. Проверка драйвера

```bash
# Шина детектируется?
ls /sys/bus/i2c/devices
# i2c-1   ← наша

i2cdetect -y 1
#      0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f
# 30: -- -- -- -- -- -- -- -- -- -- -- -- 3c -- -- --   ← SSD1306

# Что в device tree?
cat /proc/device-tree/amba_pl/i2c@43c00000/compatible
# user,i2c-master-axi-1.0

# Модуль загружен?
lsmod | grep i2c_master
# i2c_master_axi          ...

# SSD1306 как fbdev?
cat /sys/class/graphics/fb0/name
# ssd1307fb

cat /dev/urandom > /dev/fb0   # на дисплее «снег» :)
```

---

## 10. Обновление после правки RTL/драйвера

| Что меняется | Минимальная пересборка |
|--------------|------------------------|
| RTL (`rtl/i2c_master_*.v`) | `make vivado-build && make boot-bin && make buildroot-rebuild` |
| `linux/drivers/i2c-master-axi/*.c` | `make buildroot-rebuild` (пересоберёт только модуль и rootfs) |
| `linux/dts/zynq-mini-revb.dts` | `make buildroot-rebuild` (пересоберёт DTB и образ) |
| Buildroot config | `make buildroot-menuconfig`, затем `make buildroot-build` |

---

## 11. Часто задаваемые вопросы и подводные камни

**Q. Ядро висит на `[    0.000000] OF: fdt: Machine model: ...`**

DDR не настроен. Проверьте, что `vivado/build.tcl` содержит блок DDR3
с `MT41J256M16 RE-125` и `Bus Width = 16 Bit`. После правки —
`make vivado-build` и `make boot-bin` заново.

**Q. `i2c-1` есть, но `i2cdetect` не видит SSD1306.**

Откройте `dmesg | grep i2c` — драйвер должен напечатать «`prescale=124,
irq=yes`». Если IRQ говорит `polled` — это нормально, скорость
пострадает, но bus заработает.

Затем проверьте физическое подключение: SDA на T20, SCL на P20 (по
схеме CAM1-разъёма, см. `vivado/pins.xdc`). Подтяжки 4.7 кΩ к 3.3 В
обязательны (на самой OLED-плате они почти всегда есть).

**Q. Хочу драйвер in-tree, не как модуль.**

Скопируйте `linux/drivers/i2c-master-axi/i2c-master-axi.c` в
`drivers/i2c/busses/`, добавьте Kconfig-запись, поправьте Makefile
ядра — и в `linux.fragment` добавьте `CONFIG_I2C_MASTER_AXI=y`. Дальше
`make buildroot-rebuild`.

**Q. Хочу NFS-rootfs вместо ext4.**

В `buildroot-menuconfig` включите `BR2_TARGET_ROOTFS_TAR`, отключите
`BR2_TARGET_ROOTFS_EXT2`, и подмените `bootargs` в
`buildroot/board/zynq_mini_revb/uEnv.txt` на стандартный
`root=/dev/nfs nfsroot=...`.

**Q. Buildroot ругается «External tree not found».**

Проверьте, что путь до `BR2_EXTERNAL` в `make buildroot-init` совпадает
с реальным размещением `buildroot/external.desc` (в нашем `Makefile`
он жёстко привязан к корню репозитория).

**Q. U-Boot падает с `tools/mkeficapsule.c: gnutls/gnutls.h: No such file or directory`.**

`xilinx_zynq_virt_defconfig` по умолчанию включает EFI-инструменты,
которым нужен `libgnutls-dev` на хосте. Для SD-загрузки они не нужны —
в нашем `buildroot/board/zynq_mini_revb/uboot.fragment` они уже
отключены (`# CONFIG_TOOLS_MKEFICAPSULE is not set` и серия других
EFI-опций). Если ошибка всё равно появляется при первом запуске
`make buildroot-build` (fragment ещё не применился к старому build-tree),
то после правки fragment сделайте полную пересборку U-Boot:

```bash
make uboot-rebuild
```

Альтернатива — поставить gnutls на хосте:
```bash
sudo apt install -y libgnutls28-dev libssl-dev   # Debian/Ubuntu
sudo dnf install -y gnutls-devel openssl-devel   # Fedora
```
но отключить EFI чище и быстрее.

**Q. `make sdcard-quick` падает с `/bin/sh: 1: mcopy: not found`.**

`genimage` при создании FAT32-раздела вызывает `mcopy` из пакета
`mtools`. Buildroot собирает его как host-пакет в
`buildroot-build/host/bin/mcopy` (включено
`BR2_PACKAGE_HOST_MTOOLS=y` в нашем defconfig). Цель `sdcard-quick`
автоматически добавляет `host/bin` в `PATH`, но если host-пакет ещё
не собран — нужно сначала прогнать `make buildroot-build` (он
соберёт `host-mtools`, `host-dosfstools`, `host-genimage`,
`host-genext2fs`). Альтернативно — поставить `mtools` системно:
```bash
sudo apt install -y mtools dosfstools   # Debian/Ubuntu
sudo dnf install -y mtools dosfstools   # Fedora
```

**Q. Где Buildroot подсасывает источники драйвера `i2c-master-axi`?**

В `buildroot/package/i2c-master-axi/i2c-master-axi.mk` указано
`I2C_MASTER_AXI_SITE = $(BR2_EXTERNAL_ZYNQ_MINI_I2C_PATH)/../linux/drivers/i2c-master-axi`,
поэтому всё, что в репозитории лежит в `linux/drivers/i2c-master-axi/`,
автоматически копируется в build-дерево. После любой правки кода
драйвера достаточно `make buildroot-rebuild` (он позовёт
`i2c-master-axi-rebuild`).

---

## 12. Краткий чек-лист

```bash
# 1. Hardware
make vivado-build PART=xc7z020clg400-1
make vitis-build

# 2. Linux
make buildroot-init
make buildroot-build          # ≈45 минут (на первом запуске)

# 3. Boot bundle
make boot-bin                 # FSBL + bitstream + u-boot.elf → boot/BOOT.BIN
make sdcard-quick             # ≈10 секунд: переупакует BOOT.BIN в sdcard.img
                              # (sdcard-rebuild — то же через Buildroot, но в разы дольше)

# 4. Flash
sudo dd if=buildroot-build/images/sdcard.img \
        of=/dev/sdX bs=4M conv=fsync status=progress
```

Готово.
