// ---------------------------------------------------------------------------
// Bare-metal demo для ZYNQ MINI Rev B  (PS Cortex-A9 + i2c_master_axi в PL).
// Инициализирует SSD1306 (128x64) на разъёме J4 через PL I2C-мастер
// и периодически пере-рисовывает шахматный паттерн.
// ---------------------------------------------------------------------------
#include "xparameters.h"
#include "xil_printf.h"
#include "sleep.h"

#include "i2c_master.h"
#include "ssd1306.h"

// Базовый адрес ставится в build.tcl Vivado: 0x43C00000.
// Для надёжности предпочитаем XPAR_*, если он сгенерирован BSP'ом, иначе
// fallback на жёстко прописанный адрес.
#ifdef XPAR_I2C_BASEADDR
#  define I2C_BASE XPAR_I2C_BASEADDR
#else
#  define I2C_BASE 0x43C00000u
#endif

#define FCLK0_HZ      50000000u
#define I2C_SCL_HZ    100000u
#define I2C_PRESCALE  ((FCLK0_HZ / (4u * I2C_SCL_HZ)) - 1u)   // = 124

int main(void)
{
    xil_printf("\r\n=== ZYNQ MINI OLED demo (PS+PL build) ===\r\n");
    xil_printf("I2C base = 0x%08x, PRESCALE = %d\r\n", I2C_BASE, I2C_PRESCALE);

    i2c_init(I2C_BASE, I2C_PRESCALE);

    if (!ssd1306_init(I2C_BASE)) {
        xil_printf("ERROR: SSD1306 init failed (NACK?)\r\n");
        return -1;
    }
    xil_printf("OLED init OK\r\n");

    if (!ssd1306_clear(I2C_BASE)) {
        xil_printf("ERROR: OLED clear failed\r\n");
        return -1;
    }

    while (1) {
        ssd1306_demo_pattern(I2C_BASE);
        sleep(1);
        ssd1306_clear(I2C_BASE);
        sleep(1);
    }
    return 0;
}
