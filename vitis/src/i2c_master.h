// ---------------------------------------------------------------------------
// Bare-metal driver for i2c_master_axi (см. rtl/i2c_master_axi.v).
// Adress map (32-bit data, byte step = 4):
//   0x00 CTRL     [1:0] = {IEN, EN}
//   0x04 STATUS   [3:0] = {AL, BUSY, RXACK, TIP}
//   0x08 CMD      [4:0] = {NACK, WR, RD, STO, STA}
//   0x0C TX_DATA  [7:0]
//   0x10 RX_DATA  [7:0]
//   0x14 PRESCALE [15:0]   SCL = clk / (4*(PRESCALE+1))
//   0x18 ISR      [1:0] = {AL_IRQ, DONE_IRQ}  (W1C)
// ---------------------------------------------------------------------------
#ifndef I2C_MASTER_H_
#define I2C_MASTER_H_

#include <stdint.h>
#include <stdbool.h>

#define I2C_REG_CTRL     0x00
#define I2C_REG_STATUS   0x04
#define I2C_REG_CMD      0x08
#define I2C_REG_TX_DATA  0x0C
#define I2C_REG_RX_DATA  0x10
#define I2C_REG_PRESCALE 0x14
#define I2C_REG_ISR      0x18

#define I2C_CTRL_EN      (1u << 0)
#define I2C_CTRL_IEN     (1u << 1)

#define I2C_STATUS_TIP   (1u << 0)
#define I2C_STATUS_RXACK (1u << 1)
#define I2C_STATUS_BUSY  (1u << 2)
#define I2C_STATUS_AL    (1u << 3)

#define I2C_CMD_STA      (1u << 0)
#define I2C_CMD_STO      (1u << 1)
#define I2C_CMD_RD       (1u << 2)
#define I2C_CMD_WR       (1u << 3)
#define I2C_CMD_NACK     (1u << 4)

void  i2c_init   (uintptr_t base, uint16_t prescale);
bool  i2c_write  (uintptr_t base, uint8_t slave_addr, const uint8_t *data, uint32_t len);
bool  i2c_read   (uintptr_t base, uint8_t slave_addr, uint8_t *data, uint32_t len);
void  i2c_disable(uintptr_t base);

#endif
