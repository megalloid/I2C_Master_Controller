# `i2c-master-axi` — Linux driver

Standard `i2c_adapter` driver for the custom **i2c_master_axi** IP
(AXI4-Lite slave) shipped in this repository.

| File | Purpose |
|------|---------|
| `i2c-master-axi.c` | Driver source (probe, xfer, IRQ/poll completion). |
| `Kbuild`           | Used when the driver is built as an out-of-tree module. |
| `Makefile`         | Stand-alone build wrapper (`make KDIR=…`). |
| `Kconfig`          | Stub for in-tree integration (`drivers/i2c/busses/`). |

## Hardware register map

```
0x00  CTRL      R/W   [1:0] = {IEN, EN}
0x04  STATUS    R     [3:0] = {AL, BUSY, RXACK, TIP}
0x08  CMD       W     [4:0] = {NACK, WR, RD, STO, STA}
0x0C  TX_DATA   R/W   [7:0]
0x10  RX_DATA   R     [7:0]
0x14  PRESCALE  R/W   [15:0]   SCL = clk / (4*(PRESCALE+1))
0x18  ISR       R/W1C [1:0] = {AL_IRQ, DONE_IRQ}
```

## Device-tree binding

```dts
i2c0: i2c@43c00000 {
    compatible        = "user,i2c-master-axi-1.0";
    reg               = <0x43c00000 0x1000>;
    interrupt-parent  = <&intc>;
    interrupts        = <0 29 4>;
    clocks            = <&clkc 15>;     /* FCLK0 = 50 MHz here */
    clock-frequency   = <100000>;       /* I2C bus speed   */

    #address-cells    = <1>;
    #size-cells       = <0>;

    ssd1306@3c {
        compatible    = "solomon,ssd1306fb-i2c";
        reg           = <0x3c>;
        solomon,height = <64>;
        solomon,width  = <128>;
        solomon,page-offset = <0>;
    };
};
```

If a `clocks` phandle is not provided, the driver falls back to
`input-clock-frequency` (default 50 MHz). The bus speed defaults to
100 kHz when `clock-frequency` is absent.

The driver requests the IRQ via `platform_get_irq_optional()`; if no
interrupt is wired (or `request_irq()` fails), it gracefully falls
back to TIP polling — convenient when iterating on hardware.

## Runtime bus speed (`bus_hz` sysfs)

After the module is loaded, the I2C SCL rate can be changed without
rebuilding DT or the full image. The driver exposes **`bus_hz`** on the
platform device (find the path on the board):

```bash
# typical Zynq MINI node name after probe:
BUS=$(dirname $(readlink -f /sys/bus/i2c/devices/i2c-1/device))
cat "$BUS/bus_hz"          # current Hz (from DT clock-frequency at boot)
echo 400000 | sudo tee "$BUS/bus_hz"
dmesg | tail -3            # new prescale line from hw_init
i2cdetect -y 1             # must still see 0x3c
```

Limits: `bus_hz * 4 <= input_hz` (with 50 MHz AXI clock, max ~12.5 MHz
in theory). SSD1306 modules are usually reliable up to **400 kHz**; higher
rates may NACK depending on wiring and pull-ups.

If `hw_init()` rejects a value, the driver rolls back both **`i->bus_hz`**
and the hardware prescale to the previous frequency.

Initial value still comes from DT **`clock-frequency`** at `probe`; sysfs
only overrides until reboot (or until you write again).

## Build standalone

```bash
make KDIR=$BR_DIR/output/build/linux-X.Y.Z \
     ARCH=arm \
     CROSS_COMPILE=$BR_DIR/output/host/bin/arm-buildroot-linux-gnueabihf- \
     modules
```

Resulting `i2c-master-axi.ko` can be `scp`-ed to the target and
loaded with `insmod` (provided the device-tree node is in place).

## Build via Buildroot

The package recipe in `buildroot/package/i2c-master-axi/` integrates
this driver into the Buildroot rootfs (auto-loaded at boot).
See `doc/GUIDE_BUILDROOT.md` for the full flow.
