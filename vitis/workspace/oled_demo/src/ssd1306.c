// ---------------------------------------------------------------------------
// SSD1306 128x64, режим I2C, через i2c_master_axi.
// Init-последовательность взята из datasheet §8.5 «Power-ON Sequence».
// Адреса I2C-фрейма:
//   <slave><Co=0,DC=0><cmd>...   — команды (control byte 0x00)
//   <slave><Co=0,DC=1><data>...  — данные   (control byte 0x40)
// ---------------------------------------------------------------------------
#include "ssd1306.h"
#include "i2c_master.h"
#include <string.h>

#define CTRL_CMD   0x00
#define CTRL_DATA  0x40

static const uint8_t ssd1306_init_seq[] = {
    CTRL_CMD,
    0xAE,              // Display OFF
    0xD5, 0x80,        // Set display clock divide ratio / oscillator freq
    0xA8, 0x3F,        // Multiplex ratio = 64
    0xD3, 0x00,        // Display offset = 0
    0x40,              // Start line = 0
    0x8D, 0x14,        // Charge pump enable
    0x20, 0x00,        // Memory addressing mode = horizontal
    0xA1,              // Segment remap (col 127 → SEG0)
    0xC8,              // COM scan direction (remapped)
    0xDA, 0x12,        // COM pins hardware config
    0x81, 0xCF,        // Contrast
    0xD9, 0xF1,        // Pre-charge period
    0xDB, 0x40,        // VCOMH deselect
    0xA4,              // Display follows RAM
    0xA6,              // Normal display (not inverted)
    0x2E,              // Deactivate scroll
    0xAF               // Display ON
};

static bool send_cmd_block(uintptr_t base, const uint8_t *buf, uint32_t len)
{
    return i2c_write(base, SSD1306_I2C_ADDR, buf, len);
}

bool ssd1306_init(uintptr_t base)
{
    return send_cmd_block(base, ssd1306_init_seq, sizeof(ssd1306_init_seq));
}

static bool set_window(uintptr_t base)
{
    static const uint8_t win[] = {
        CTRL_CMD,
        0x21, 0x00, 0x7F,    // column addr 0..127
        0x22, 0x00, 0x07     // page addr 0..7
    };
    return send_cmd_block(base, win, sizeof(win));
}

bool ssd1306_send_frame(uintptr_t base, const uint8_t fb[1024])
{
    if (!set_window(base)) return false;

    // Передаём кадр по 16-байтовым блокам с control-байтом 0x40
    uint8_t tx[17];
    tx[0] = CTRL_DATA;
    for (uint32_t off = 0; off < 1024; off += 16) {
        memcpy(&tx[1], &fb[off], 16);
        if (!i2c_write(base, SSD1306_I2C_ADDR, tx, sizeof(tx))) return false;
    }
    return true;
}

bool ssd1306_clear(uintptr_t base)
{
    static uint8_t fb[1024];
    memset(fb, 0, sizeof(fb));
    return ssd1306_send_frame(base, fb);
}

// «Шахматная доска» 8×8 — простая визуальная проверка
bool ssd1306_demo_pattern(uintptr_t base)
{
    static uint8_t fb[1024];
    for (uint32_t y = 0; y < 8; y++) {           // 8 страниц по 8 пикс
        for (uint32_t x = 0; x < 128; x++) {
            uint8_t cell_x = x / 8;
            uint8_t cell_y = y;
            fb[y * 128 + x] = ((cell_x ^ cell_y) & 1) ? 0xFF : 0x00;
        }
    }
    return ssd1306_send_frame(base, fb);
}
