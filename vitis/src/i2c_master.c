#include "i2c_master.h"
#include "xil_io.h"

static inline uint32_t i2c_rd(uintptr_t base, uint32_t off)            { return Xil_In32(base + off); }
static inline void     i2c_wr(uintptr_t base, uint32_t off, uint32_t v){ Xil_Out32(base + off, v); }

static bool wait_done(uintptr_t base)
{
    // Опрашиваем TIP до сброса.  Простой spin без таймера —  для bare-metal
    // достаточно; при необходимости добавьте бюджетный счётчик.
    for (uint32_t i = 0; i < 1000000; i++) {
        uint32_t st = i2c_rd(base, I2C_REG_STATUS);
        if ((st & I2C_STATUS_TIP) == 0) {
            if (st & I2C_STATUS_AL) {
                // Arbitration lost — сбрасываем флаг через запись в CMD (NOP)
                i2c_wr(base, I2C_REG_CMD, 0);
                return false;
            }
            return true;
        }
    }
    return false;
}

void i2c_init(uintptr_t base, uint16_t prescale)
{
    // Disable, set prescaler, enable
    i2c_wr(base, I2C_REG_CTRL,     0);
    i2c_wr(base, I2C_REG_PRESCALE, prescale);
    i2c_wr(base, I2C_REG_ISR,      0x3);          // Clear pending IRQs (W1C)
    i2c_wr(base, I2C_REG_CTRL,     I2C_CTRL_EN);
}

void i2c_disable(uintptr_t base)
{
    i2c_wr(base, I2C_REG_CTRL, 0);
}

bool i2c_write(uintptr_t base, uint8_t slave_addr, const uint8_t *data, uint32_t len)
{
    // 1. START + WRITE(addr<<1 | 0)
    i2c_wr(base, I2C_REG_TX_DATA, (uint32_t)(slave_addr << 1));
    i2c_wr(base, I2C_REG_CMD,     I2C_CMD_STA | I2C_CMD_WR);
    if (!wait_done(base)) return false;
    if (i2c_rd(base, I2C_REG_STATUS) & I2C_STATUS_RXACK) {
        // NACK — slave не ответил
        i2c_wr(base, I2C_REG_CMD, I2C_CMD_STO);
        wait_done(base);
        return false;
    }

    // 2. WRITE(data[i])
    for (uint32_t i = 0; i < len; i++) {
        i2c_wr(base, I2C_REG_TX_DATA, data[i]);
        uint32_t cmd = I2C_CMD_WR;
        if (i == len - 1) cmd |= I2C_CMD_STO;     // последний — со STOP
        i2c_wr(base, I2C_REG_CMD, cmd);
        if (!wait_done(base)) return false;
        if (i != len - 1 && (i2c_rd(base, I2C_REG_STATUS) & I2C_STATUS_RXACK)) {
            i2c_wr(base, I2C_REG_CMD, I2C_CMD_STO);
            wait_done(base);
            return false;
        }
    }
    return true;
}

bool i2c_read(uintptr_t base, uint8_t slave_addr, uint8_t *data, uint32_t len)
{
    if (len == 0) return true;

    // 1. START + WRITE(addr<<1 | 1)
    i2c_wr(base, I2C_REG_TX_DATA, (uint32_t)((slave_addr << 1) | 1));
    i2c_wr(base, I2C_REG_CMD,     I2C_CMD_STA | I2C_CMD_WR);
    if (!wait_done(base)) return false;
    if (i2c_rd(base, I2C_REG_STATUS) & I2C_STATUS_RXACK) {
        i2c_wr(base, I2C_REG_CMD, I2C_CMD_STO);
        wait_done(base);
        return false;
    }

    // 2. READ data
    for (uint32_t i = 0; i < len; i++) {
        uint32_t cmd = I2C_CMD_RD;
        if (i == len - 1) cmd |= I2C_CMD_NACK | I2C_CMD_STO;
        i2c_wr(base, I2C_REG_CMD, cmd);
        if (!wait_done(base)) return false;
        data[i] = (uint8_t)i2c_rd(base, I2C_REG_RX_DATA);
    }
    return true;
}
