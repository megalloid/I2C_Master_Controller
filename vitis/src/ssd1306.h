#ifndef SSD1306_H_
#define SSD1306_H_

#include <stdint.h>
#include <stdbool.h>

#define SSD1306_I2C_ADDR  0x3C   // 0x3D на некоторых модулях

bool ssd1306_init      (uintptr_t i2c_base);
bool ssd1306_clear     (uintptr_t i2c_base);
bool ssd1306_send_frame(uintptr_t i2c_base, const uint8_t fb[1024]);
bool ssd1306_demo_pattern(uintptr_t i2c_base);

#endif
