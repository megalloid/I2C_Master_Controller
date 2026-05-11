/*
 * oled-clock  -  live OLED status display for Zynq Mini Rev B
 *
 * Каждую секунду:
 *   1) читает PS XADC температуру  (/sys/bus/iio/devices/iio:device0/in_temp0_*)
 *   2) читает время/дату            (localtime_r)
 *   3) читает uptime + voltages
 *   4) растрит 128x64 1bpp кадр (шрифты 6x8 и 8x16 в формате ssd1306xled —
 *      «page-mode», т.е. байт описывает 8 вертикальных пикселей одной колонки)
 *   5) пишет 1024 байта в /dev/fb0 (ssd1307fb ждёт row-major LSB-first MONO10,
 *      driver сам преобразует в SSD1306 page format)
 *
 * Layout жёстко выровнен по 8-пиксельным страницам SSD1306, чтобы избежать
 * визуальных «провалов» на горизонтальных page-boundary:
 *   page 0  (y=0..7)   : header   6x8  "zynq mini rev. b"
 *   page 1-2(y=8..23)  : big time 8x16 "HH:MM:SS"
 *   page 3  (y=24..31) : date     6x8  "YYYY-MM-DD"
 *   page 4-5(y=32..47) : big T    8x16 "T=XX.X C"
 *   page 6  (y=48..55) : voltages 6x8  "Vi=X.XXV Va=X.XXV"
 *   page 7  (y=56..63) : uptime   6x8  "up HhMMmSSs"
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysinfo.h>
#include <linux/fb.h>

#define W            128
#define H            64
#define FB_BYTES     (W * H / 8)        /* = 1024 */

#define XADC_TEMP_RAW    "/sys/bus/iio/devices/iio:device0/in_temp0_raw"
#define XADC_TEMP_OFF    "/sys/bus/iio/devices/iio:device0/in_temp0_offset"
#define XADC_TEMP_SCALE  "/sys/bus/iio/devices/iio:device0/in_temp0_scale"
#define XADC_VINT_RAW    "/sys/bus/iio/devices/iio:device0/in_voltage3_vccpint_raw"
#define XADC_VINT_SCALE  "/sys/bus/iio/devices/iio:device0/in_voltage3_vccpint_scale"
#define XADC_VAUX_RAW    "/sys/bus/iio/devices/iio:device0/in_voltage4_vccpaux_raw"
#define XADC_VAUX_SCALE  "/sys/bus/iio/devices/iio:device0/in_voltage4_vccpaux_scale"

/* -------------------------------------------------------------------------
 * Стандартный 6x8 ssd1306xled-шрифт.
 * Формат: 6 байт на символ; каждый байт описывает одну колонку (8 пикселей
 * по вертикали), bit 0 = верхний пиксель, bit 7 = нижний.
 * ------------------------------------------------------------------------- */
static const uint8_t FONT6x8[][6] = {
    {0x00,0x00,0x00,0x00,0x00,0x00}, /* sp */
    {0x00,0x00,0x00,0x2F,0x00,0x00}, /* !  */
    {0x00,0x00,0x07,0x00,0x07,0x00}, /* "  */
    {0x00,0x14,0x7F,0x14,0x7F,0x14}, /* #  */
    {0x00,0x24,0x2A,0x7F,0x2A,0x12}, /* $  */
    {0x00,0x23,0x13,0x08,0x64,0x62}, /* %  */
    {0x00,0x36,0x49,0x55,0x22,0x50}, /* &  */
    {0x00,0x00,0x05,0x03,0x00,0x00}, /* '  */
    {0x00,0x00,0x1C,0x22,0x41,0x00}, /* (  */
    {0x00,0x00,0x41,0x22,0x1C,0x00}, /* )  */
    {0x00,0x14,0x08,0x3E,0x08,0x14}, /* *  */
    {0x00,0x08,0x08,0x3E,0x08,0x08}, /* +  */
    {0x00,0x00,0x00,0xA0,0x60,0x00}, /* ,  */
    {0x00,0x08,0x08,0x08,0x08,0x08}, /* -  */
    {0x00,0x00,0x60,0x60,0x00,0x00}, /* .  */
    {0x00,0x20,0x10,0x08,0x04,0x02}, /* /  */
    {0x00,0x3E,0x51,0x49,0x45,0x3E}, /* 0  */
    {0x00,0x00,0x42,0x7F,0x40,0x00}, /* 1  */
    {0x00,0x42,0x61,0x51,0x49,0x46}, /* 2  */
    {0x00,0x21,0x41,0x45,0x4B,0x31}, /* 3  */
    {0x00,0x18,0x14,0x12,0x7F,0x10}, /* 4  */
    {0x00,0x27,0x45,0x45,0x45,0x39}, /* 5  */
    {0x00,0x3C,0x4A,0x49,0x49,0x30}, /* 6  */
    {0x00,0x01,0x71,0x09,0x05,0x03}, /* 7  */
    {0x00,0x36,0x49,0x49,0x49,0x36}, /* 8  */
    {0x00,0x06,0x49,0x49,0x29,0x1E}, /* 9  */
    {0x00,0x00,0x36,0x36,0x00,0x00}, /* :  */
    {0x00,0x00,0x56,0x36,0x00,0x00}, /* ;  */
    {0x00,0x08,0x14,0x22,0x41,0x00}, /* <  */
    {0x00,0x14,0x14,0x14,0x14,0x14}, /* =  */
    {0x00,0x00,0x41,0x22,0x14,0x08}, /* >  */
    {0x00,0x02,0x01,0x51,0x09,0x06}, /* ?  */
    {0x00,0x32,0x49,0x59,0x51,0x3E}, /* @  */
    {0x00,0x7C,0x12,0x11,0x12,0x7C}, /* A  */
    {0x00,0x7F,0x49,0x49,0x49,0x36}, /* B  */
    {0x00,0x3E,0x41,0x41,0x41,0x22}, /* C  */
    {0x00,0x7F,0x41,0x41,0x22,0x1C}, /* D  */
    {0x00,0x7F,0x49,0x49,0x49,0x41}, /* E  */
    {0x00,0x7F,0x09,0x09,0x09,0x01}, /* F  */
    {0x00,0x3E,0x41,0x49,0x49,0x7A}, /* G  */
    {0x00,0x7F,0x08,0x08,0x08,0x7F}, /* H  */
    {0x00,0x00,0x41,0x7F,0x41,0x00}, /* I  */
    {0x00,0x20,0x40,0x41,0x3F,0x01}, /* J  */
    {0x00,0x7F,0x08,0x14,0x22,0x41}, /* K  */
    {0x00,0x7F,0x40,0x40,0x40,0x40}, /* L  */
    {0x00,0x7F,0x02,0x0C,0x02,0x7F}, /* M  */
    {0x00,0x7F,0x04,0x08,0x10,0x7F}, /* N  */
    {0x00,0x3E,0x41,0x41,0x41,0x3E}, /* O  */
    {0x00,0x7F,0x09,0x09,0x09,0x06}, /* P  */
    {0x00,0x3E,0x41,0x51,0x21,0x5E}, /* Q  */
    {0x00,0x7F,0x09,0x19,0x29,0x46}, /* R  */
    {0x00,0x46,0x49,0x49,0x49,0x31}, /* S  */
    {0x00,0x01,0x01,0x7F,0x01,0x01}, /* T  */
    {0x00,0x3F,0x40,0x40,0x40,0x3F}, /* U  */
    {0x00,0x1F,0x20,0x40,0x20,0x1F}, /* V  */
    {0x00,0x3F,0x40,0x38,0x40,0x3F}, /* W  */
    {0x00,0x63,0x14,0x08,0x14,0x63}, /* X  */
    {0x00,0x07,0x08,0x70,0x08,0x07}, /* Y  */
    {0x00,0x61,0x51,0x49,0x45,0x43}, /* Z  */
    {0x00,0x00,0x7F,0x41,0x41,0x00}, /* [  */
    {0x00,0x55,0x2A,0x55,0x2A,0x55}, /* \  */
    {0x00,0x00,0x41,0x41,0x7F,0x00}, /* ]  */
    {0x00,0x04,0x02,0x01,0x02,0x04}, /* ^  */
    {0x00,0x40,0x40,0x40,0x40,0x40}, /* _  */
    {0x00,0x00,0x01,0x02,0x04,0x00}, /* `  */
    {0x00,0x20,0x54,0x54,0x54,0x78}, /* a  */
    {0x00,0x7F,0x48,0x44,0x44,0x38}, /* b  */
    {0x00,0x38,0x44,0x44,0x44,0x20}, /* c  */
    {0x00,0x38,0x44,0x44,0x48,0x7F}, /* d  */
    {0x00,0x38,0x54,0x54,0x54,0x18}, /* e  */
    {0x00,0x08,0x7E,0x09,0x01,0x02}, /* f  */
    {0x00,0x18,0xA4,0xA4,0xA4,0x7C}, /* g  */
    {0x00,0x7F,0x08,0x04,0x04,0x78}, /* h  */
    {0x00,0x00,0x44,0x7D,0x40,0x00}, /* i  */
    {0x00,0x40,0x80,0x84,0x7D,0x00}, /* j  */
    {0x00,0x7F,0x10,0x28,0x44,0x00}, /* k  */
    {0x00,0x00,0x41,0x7F,0x40,0x00}, /* l  */
    {0x00,0x7C,0x04,0x18,0x04,0x78}, /* m  */
    {0x00,0x7C,0x08,0x04,0x04,0x78}, /* n  */
    {0x00,0x38,0x44,0x44,0x44,0x38}, /* o  */
    {0x00,0xFC,0x24,0x24,0x24,0x18}, /* p  */
    {0x00,0x18,0x24,0x24,0x18,0xFC}, /* q  */
    {0x00,0x7C,0x08,0x04,0x04,0x08}, /* r  */
    {0x00,0x48,0x54,0x54,0x54,0x20}, /* s  */
    {0x00,0x04,0x3F,0x44,0x40,0x20}, /* t  */
    {0x00,0x3C,0x40,0x40,0x20,0x7C}, /* u  */
    {0x00,0x1C,0x20,0x40,0x20,0x1C}, /* v  */
    {0x00,0x3C,0x40,0x30,0x40,0x3C}, /* w  */
    {0x00,0x44,0x28,0x10,0x28,0x44}, /* x  */
    {0x00,0x1C,0xA0,0xA0,0xA0,0x7C}, /* y  */
    {0x00,0x44,0x64,0x54,0x4C,0x44}, /* z  */
};
#define FONT6x8_FIRST  0x20  /* ' ' */
#define FONT6x8_LAST   0x7A  /* 'z' */

/* -------------------------------------------------------------------------
 * Стандартный 8x16 ssd1306xled-шрифт (старый/правый half stacked):
 *   bytes  0..7  — top page (y =  0..7)  для каждой из 8 колонок
 *   bytes  8..15 — bot page (y =  8..15) для каждой из 8 колонок
 * Каждый байт — 8 вертикальных пикселей; bit 0 = top.
 * Здесь храним только символы '0'..'9', ':', '.' и '-' — достаточно для
 * времени и температурной строки (включая дробную часть и отрицательные
 * значения).
 * ------------------------------------------------------------------------- */
static const uint8_t FONT8x16[][16] = {
    /* '0' */ {0x00,0xE0,0x10,0x08,0x08,0x10,0xE0,0x00, 0x00,0x0F,0x10,0x20,0x20,0x10,0x0F,0x00},
    /* '1' */ {0x00,0x10,0x10,0xF8,0x00,0x00,0x00,0x00, 0x00,0x20,0x20,0x3F,0x20,0x20,0x00,0x00},
    /* '2' */ {0x00,0x70,0x08,0x08,0x08,0x88,0x70,0x00, 0x00,0x30,0x28,0x24,0x22,0x21,0x30,0x00},
    /* '3' */ {0x00,0x30,0x08,0x88,0x88,0x48,0x30,0x00, 0x00,0x18,0x20,0x20,0x20,0x11,0x0E,0x00},
    /* '4' */ {0x00,0x00,0xC0,0x20,0x10,0xF8,0x00,0x00, 0x00,0x07,0x04,0x24,0x24,0x3F,0x24,0x00},
    /* '5' */ {0x00,0xF8,0x08,0x88,0x88,0x08,0x08,0x00, 0x00,0x19,0x21,0x20,0x20,0x11,0x0E,0x00},
    /* '6' */ {0x00,0xE0,0x10,0x88,0x88,0x18,0x00,0x00, 0x00,0x0F,0x11,0x20,0x20,0x11,0x0E,0x00},
    /* '7' */ {0x00,0x38,0x08,0x08,0xC8,0x38,0x08,0x00, 0x00,0x00,0x00,0x3F,0x00,0x00,0x00,0x00},
    /* '8' */ {0x00,0x70,0x88,0x08,0x08,0x88,0x70,0x00, 0x00,0x1C,0x22,0x21,0x21,0x22,0x1C,0x00},
    /* '9' */ {0x00,0xE0,0x10,0x08,0x08,0x10,0xE0,0x00, 0x00,0x00,0x31,0x22,0x22,0x11,0x0F,0x00},
    /* ':' */ {0x00,0x00,0x00,0xC0,0xC0,0x00,0x00,0x00, 0x00,0x00,0x00,0x30,0x30,0x00,0x00,0x00},
    /* '.' */ {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x30,0x30,0x00,0x00,0x00},
    /* '-' */ {0x00,0x00,0x80,0x80,0x80,0x80,0x80,0x00, 0x00,0x00,0x01,0x01,0x01,0x01,0x01,0x00},
};
/* отображение '0'..'9'->[0..9], ':'->10, '.'->11, '-'->12.
 * Возвращает индекс или -1 если символ не поддержан. */
static int idx_8x16(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c == ':')             return 10;
    if (c == '.')             return 11;
    if (c == '-')             return 12;
    return -1;
}

/* -------------------------------------------------------------------------
 * Framebuffer: row-major bool grid 64x128, пакуется в 1024 байта LSB-first.
 * ------------------------------------------------------------------------- */
static uint8_t pix[H][W];

static void clear_fb(void) { memset(pix, 0, sizeof pix); }

static inline void set_px(int x, int y)
{
    if ((unsigned)x < W && (unsigned)y < H) pix[y][x] = 1;
}

static void hline(int y, int x0, int x1) __attribute__((unused));
static void hline(int y, int x0, int x1)
{
    for (int x = x0; x <= x1; x++) set_px(x, y);
}

/* Рисуем 6x8 символ в (x, y).  y ДОЛЖЕН быть кратен 8, иначе появится
 * page-split (буква пересечёт границу страниц SSD1306). */
static void draw_6x8(char c, int x, int y)
{
    unsigned uc = (unsigned char)c;
    if (uc < FONT6x8_FIRST || uc > FONT6x8_LAST) uc = '?';
    const uint8_t *gl = FONT6x8[uc - FONT6x8_FIRST];
    for (int col = 0; col < 6; col++) {
        uint8_t byte = gl[col];
        for (int row = 0; row < 8; row++)
            if (byte & (1u << row))
                set_px(x + col, y + row);
    }
}

static void text_6x8(const char *s, int x, int y)
{
    for (; *s; s++) {
        draw_6x8(*s, x, y);
        x += 6;
    }
}

static int width_6x8(const char *s) { return (int)strlen(s) * 6; }

static void center_6x8(const char *s, int y)
{
    text_6x8(s, (W - width_6x8(s)) / 2, y);
}

/* Рисуем 8x16 символ в (x, y).  y ДОЛЖЕН быть кратен 8 (идеально кратен 16),
 * иначе появится разрыв между верхней и нижней половиной глифа. */
static void draw_8x16(char c, int x, int y)
{
    int i = idx_8x16(c);
    if (i < 0) {
        /* для пробела/неизвестных просто оставим пустое место */
        return;
    }
    const uint8_t *gl = FONT8x16[i];
    /* top page */
    for (int col = 0; col < 8; col++) {
        uint8_t byte = gl[col];
        for (int row = 0; row < 8; row++)
            if (byte & (1u << row))
                set_px(x + col, y + row);
    }
    /* bottom page */
    for (int col = 0; col < 8; col++) {
        uint8_t byte = gl[8 + col];
        for (int row = 0; row < 8; row++)
            if (byte & (1u << row))
                set_px(x + col, y + 8 + row);
    }
}

static void text_8x16(const char *s, int x, int y)
{
    for (; *s; s++) {
        draw_8x16(*s, x, y);
        x += 8;
    }
}

static int width_8x16(const char *s) { return (int)strlen(s) * 8; }

static void center_8x16(const char *s, int y)
{
    text_8x16(s, (W - width_8x16(s)) / 2, y);
}

/* -------------------------------------------------------------------------
 * Сборка кадра /dev/fb0.
 *
 * ssd1307fb (mainline) хранит screen_buffer как row-major mono с LSB-first
 * упаковкой битов внутри байта:
 *   pixel(x, y) = (vmem[y * line_length + x/8] >> (x % 8)) & 1
 *
 * Драйвер использует fb_deferred_io, поэтому write()-only через char-устройство
 * НЕ всегда триггерит обновление контроллера: правильный способ — mmap()
 * страничного буфера + msync(MS_INVALIDATE), чтобы кадр поехал по I2C.
 * ------------------------------------------------------------------------- */
static uint8_t *g_fbmem = NULL;          /* указатель на mmap-region */
static size_t   g_fbsize = 0;            /* реальный line_length * yres */
static int      g_line_len = W / 8;      /* line_length из ядра */

static int fb_setup(int fd)
{
    struct fb_var_screeninfo v;
    struct fb_fix_screeninfo f;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &v) == 0 &&
        ioctl(fd, FBIOGET_FSCREENINFO, &f) == 0) {
        g_line_len = (int)f.line_length;
        g_fbsize   = (size_t)f.line_length * v.yres_virtual;
        if (g_fbsize < (size_t)FB_BYTES) g_fbsize = FB_BYTES;
    } else {
        g_line_len = W / 8;
        g_fbsize   = FB_BYTES;
    }
    g_fbmem = mmap(NULL, g_fbsize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (g_fbmem == MAP_FAILED) {
        g_fbmem = NULL;
        return -1;
    }
    return 0;
}

/* Параметр: 0 = LSB-first within byte (стандарт ssd1307fb mainline),
 *           1 = MSB-first within byte (на случай других ядер/прошивок). */
static int g_bit_order_msb = 0;

/* Параметр: путь записи кадра.  ssd1307fb через defio регистрирует
 * fb_sys_write_with_damage — это самый надёжный способ прокинуть кадр в
 * контроллер.  mmap+msync формально тоже работает, но требует чтобы ядро
 * выловило write-fault — что не всегда устойчиво на 6.6.51 sysmem mappings. */
static void pack_buf(uint8_t *buf, int stride)
{
    memset(buf, 0, stride * H);
    for (int y = 0; y < H; y++) {
        uint8_t *row = buf + y * stride;
        for (int X = 0; X < W / 8; X++) {
            uint8_t byte = 0;
            if (g_bit_order_msb) {
                for (int b = 0; b < 8; b++)
                    if (pix[y][X * 8 + b]) byte |= (uint8_t)(0x80u >> b);
            } else {
                for (int b = 0; b < 8; b++)
                    if (pix[y][X * 8 + b]) byte |= (uint8_t)(1u << b);
            }
            row[X] = byte;
        }
    }
}

static void flush_to_fb(int fd)
{
    uint8_t buf[FB_BYTES];
    int stride = (g_line_len > 0) ? g_line_len : (W / 8);
    pack_buf(buf, stride);

    /* mmap путь: пишем в страничный буфер и просим ядро инвалидировать. */
    if (g_fbmem) {
        memset(g_fbmem, 0, g_fbsize);
        memcpy(g_fbmem, buf, (size_t)stride * H);
        msync(g_fbmem, g_fbsize, MS_SYNC | MS_INVALIDATE);
    }

    /* Дублируем write(): defio_write гарантированно вызовет damage_range. */
    if (lseek(fd, 0, SEEK_SET) == (off_t)-1) return;
    ssize_t left = (ssize_t)stride * H, off = 0;
    while (left > 0) {
        ssize_t n = write(fd, buf + off, left);
        if (n <= 0) { if (errno == EINTR) continue; break; }
        left -= n; off += n;
    }
}

static void fill_test_pattern(const char *name)
{
    clear_fb();
    if (!strcmp(name, "Z")) {
        /* all black */
    } else if (!strcmp(name, "G")) {
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) set_px(x, y);
    } else if (!strcmp(name, "A")) {
        set_px(0, 0);                       /* единичный pixel */
    } else if (!strcmp(name, "D")) {
        for (int y = 0; y < H; y++) set_px(0, y);   /* левая колонка */
    } else if (!strcmp(name, "F")) {
        for (int y = 0; y < H; y += 2)
            for (int x = 0; x < W; x++) set_px(x, y);
    } else if (!strcmp(name, "T")) {
        /* угловые маркеры + диагональ */
        for (int i = 0; i < 8; i++) { set_px(i, 0); set_px(0, i); }
        for (int i = 0; i < 8; i++) { set_px(W - 1 - i, 0); set_px(W - 1, i); }
        for (int i = 0; i < 8; i++) { set_px(i, H - 1); set_px(0, H - 1 - i); }
        for (int i = 0; i < 8; i++) { set_px(W - 1 - i, H - 1); set_px(W - 1, H - 1 - i); }
        for (int i = 0; i < 64; i++) set_px(i, i);
    } else if (!strcmp(name, "R")) {
        /* "ABC" слева сверху простым 6x8 */
        text_6x8("ABC", 0, 0);
    } else if (!strcmp(name, "H")) {
        /* "HELLO" по центру первой страницы */
        center_6x8("HELLO", 0);
    } else if (!strcmp(name, "L")) {
        /* L-маркер: гориз (0..7, 0) + верт (0, 0..7) + одиночка (16, 4) */
        for (int i = 0; i < 8; i++) set_px(i, 0);
        for (int i = 0; i < 8; i++) set_px(0, i);
        set_px(16, 4);
    } else if (!strcmp(name, "B")) {
        /* Рамка по всему экрану — 4 линии шириной 1px */
        for (int x = 0; x < W; x++) { set_px(x, 0); set_px(x, H - 1); }
        for (int y = 0; y < H; y++) { set_px(0, y); set_px(W - 1, y); }
    } else if (!strcmp(name, "8")) {
        /* Одна цифра '0' шрифтом 8x16 в углу (0,0) */
        text_8x16("0", 0, 0);
    } else if (!strcmp(name, "9")) {
        /* "00:00" 8x16 в углу (0,0) */
        text_8x16("00:00", 0, 0);
    } else if (!strcmp(name, "P")) {
        /* Диагональ из 8 одиночных точек: (0,0),(8,8),(16,16),...,(56,56) */
        for (int i = 0; i < 8; i++) set_px(i * 8, i * 8);
    } else if (!strcmp(name, "Q")) {
        /* Точки на всех пересечениях page-boundary y=0,8,16,...,56 */
        for (int y = 0; y < H; y += 8) set_px(0, y);
    } else {
        text_6x8("?pattern", 0, 0);
    }
}

/* -------------------------------------------------------------------------
 * sysfs helpers
 * ------------------------------------------------------------------------- */
static int read_int_file(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    char b[32];
    ssize_t n = read(fd, b, sizeof b - 1);
    close(fd);
    if (n <= 0) return 0;
    b[n] = 0;
    return atoi(b);
}

static double read_double_file(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0.0;
    char b[64];
    ssize_t n = read(fd, b, sizeof b - 1);
    close(fd);
    if (n <= 0) return 0.0;
    b[n] = 0;
    return atof(b);
}

static int    g_temp_offset = 0;
static double g_temp_scale  = 0.0;
static double g_vint_scale  = 0.0;
static double g_vaux_scale  = 0.0;

static void sensors_init(void)
{
    g_temp_offset = read_int_file(XADC_TEMP_OFF);
    g_temp_scale  = read_double_file(XADC_TEMP_SCALE);
    g_vint_scale  = read_double_file(XADC_VINT_SCALE);
    g_vaux_scale  = read_double_file(XADC_VAUX_SCALE);
}

static double temp_celsius(void)
{
    int raw = read_int_file(XADC_TEMP_RAW);
    return (raw + g_temp_offset) * g_temp_scale / 1000.0;
}

static double vint_volts(void)
{
    return read_int_file(XADC_VINT_RAW) * g_vint_scale / 1000.0;
}

static double vaux_volts(void)
{
    return read_int_file(XADC_VAUX_RAW) * g_vaux_scale / 1000.0;
}

/* -------------------------------------------------------------------------
 * Отвязываем fbcon от /dev/fb0, чтобы kernel console не накладывался поверх.
 * ------------------------------------------------------------------------- */
static void detach_fbcon(void)
{
    for (int i = 0; i < 8; i++) {
        char path[64];
        snprintf(path, sizeof path, "/sys/class/vtconsole/vtcon%d/bind", i);
        int fd = open(path, O_WRONLY);
        if (fd < 0) continue;
        (void)write(fd, "0", 1);
        close(fd);
    }
}

static void print_fb_info(int fd)
{
    struct fb_var_screeninfo v;
    struct fb_fix_screeninfo f;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &v) == 0) {
        fprintf(stderr,
            "var: xres=%u yres=%u xres_virtual=%u yres_virtual=%u bpp=%u "
            "red.length=%u grayscale=%u rotate=%u\n",
            v.xres, v.yres, v.xres_virtual, v.yres_virtual, v.bits_per_pixel,
            v.red.length, v.grayscale, v.rotate);
    }
    if (ioctl(fd, FBIOGET_FSCREENINFO, &f) == 0) {
        fprintf(stderr,
            "fix: id=%.16s type=%u visual=%u line_length=%u smem_len=%u\n",
            f.id, f.type, f.visual, f.line_length, f.smem_len);
    }
}

static void usage(const char *p)
{
    fprintf(stderr,
        "usage: %s [options]\n"
        "  --fb PATH       framebuffer device (default /dev/fb0)\n"
        "  --info          print FBIOGET_VSCREENINFO/FSCREENINFO and exit\n"
        "  --msb           pack pixels MSB-first within byte\n"
        "  --lsb           pack pixels LSB-first within byte (default)\n"
        "  --no-mmap       do not mmap, write() only\n"
        "  --no-detach     do not detach fbcon\n"
        "  --test NAME     draw single pattern and exit\n"
        "                  Z=black G=white A=pixel(0,0) D=left-col F=stripes\n"
        "                  T=corners+diag R=\"ABC\"6x8 H=HELLO6x8 L=L-corner\n"
        "                  B=border 8=\"0\"8x16 9=\"00:00\"8x16\n"
        "                  P=8 points on (i*8,i*8) Q=points at every y=0,8,...,56\n",
        p);
}

int main(int argc, char **argv)
{
    const char *fb_path = "/dev/fb0";
    const char *test = NULL;
    int do_info = 0, use_mmap = 1, detach = 1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--fb") && i + 1 < argc) fb_path = argv[++i];
        else if (!strcmp(argv[i], "--info"))      do_info = 1;
        else if (!strcmp(argv[i], "--msb"))       g_bit_order_msb = 1;
        else if (!strcmp(argv[i], "--lsb"))       g_bit_order_msb = 0;
        else if (!strcmp(argv[i], "--no-mmap"))   use_mmap = 0;
        else if (!strcmp(argv[i], "--no-detach")) detach = 0;
        else if (!strcmp(argv[i], "--test") && i + 1 < argc) test = argv[++i];
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
        else if (argv[i][0] != '-')               fb_path = argv[i];
        else { usage(argv[0]); return 2; }
    }

    int fb_fd = open(fb_path, O_RDWR);
    if (fb_fd < 0) {
        fprintf(stderr, "open(%s): %s\n", fb_path, strerror(errno));
        return 1;
    }

    if (do_info) { print_fb_info(fb_fd); close(fb_fd); return 0; }

    sensors_init();
    if (detach) detach_fbcon();
    if (use_mmap && fb_setup(fb_fd) != 0)
        fprintf(stderr, "mmap fallback: используем только write()\n");

    if (test) {
        print_fb_info(fb_fd);
        fill_test_pattern(test);
        flush_to_fb(fb_fd);
        fprintf(stderr, "pattern '%s' drawn (mmap=%d msb=%d)\n",
                test, g_fbmem ? 1 : 0, g_bit_order_msb);
        close(fb_fd);
        return 0;
    }

    while (1) {
        time_t now = time(NULL);
        struct tm tm; localtime_r(&now, &tm);
        struct sysinfo si; sysinfo(&si);

        clear_fb();
        char line[64];

        /* Page 0 (y=0..7): header — 6x8 */
        center_6x8("zynq mini rev. b", 0);

        /* Pages 1-2 (y=8..23): HH:MM:SS — 8x16, ровно две выровненных страницы */
        snprintf(line, sizeof line, "%02d:%02d:%02d",
                 tm.tm_hour, tm.tm_min, tm.tm_sec);
        center_8x16(line, 8);

        /* Page 3 (y=24..31): YYYY-MM-DD — 6x8 */
        snprintf(line, sizeof line, "%04d-%02d-%02d",
                 tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday);
        center_6x8(line, 24);

        /* Pages 4-5 (y=32..47): T=XX.X C — 8x16.  В 8x16 поддержаны цифры,
         * ':', '.' и '-', поэтому "%4.1f" (вкл. отрицательные значения и
         * дробную часть) рисуется целиком; подпись "T=" и "C" — 6x8. */
        if (g_temp_scale > 0.0) {
            double tC = temp_celsius();
            snprintf(line, sizeof line, "%4.1f", tC);
            /* Подпись слева 6x8, цифры по центру справа 8x16.
             * "%4.1f" даёт 4 символа для значений 0..99.9 ("XX.X" или " X.X")
             * и 5 символов для |T|>=100 — 5*8 = 40 px по ширине. */
            text_6x8("T=", 8, 36);
            text_8x16(line, 28, 32);
            text_6x8("C", 28 + 40 + 4, 36);
        } else {
            center_6x8("T = N/A", 36);
        }

        /* Page 6 (y=48..55): voltages — 6x8.
         * Шрифт 6x8 даёт 128/6 = 21 символ на строку, поэтому используем
         * укороченные подписи "Vi=" / "Va=", чтобы строка гарантированно
         * влезала и не уезжала за край при центрировании. */
        if (g_vint_scale > 0.0 && g_vaux_scale > 0.0) {
            snprintf(line, sizeof line, "Vi=%4.2fV Va=%4.2fV",
                     vint_volts(), vaux_volts());
            center_6x8(line, 48);
        } else {
            center_6x8("PS XADC", 48);
        }

        /* Page 7 (y=56..63): uptime — 6x8 */
        long s = (long)si.uptime;
        long h = s / 3600, m = (s % 3600) / 60, sec = s % 60;
        snprintf(line, sizeof line, "up %ldh%02ldm%02lds", h, m, sec);
        center_6x8(line, 56);

        flush_to_fb(fb_fd);

        /* Просыпаемся на границе следующей секунды — без дрейфа. */
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        struct timespec req = {
            .tv_sec  = 0,
            .tv_nsec = 1000000000L - ts.tv_nsec,
        };
        nanosleep(&req, NULL);
    }

    close(fb_fd);
    return 0;
}
