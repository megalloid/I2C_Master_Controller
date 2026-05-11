# Standalone Makefile for oled-clock.
# Used outside Buildroot (manual cross-compile, dev iterations).
# Inside Buildroot the package/oled-clock recipe drives the build instead.

CROSS_COMPILE ?=
CC      := $(CROSS_COMPILE)gcc
STRIP   := $(CROSS_COMPILE)strip

CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter
LDFLAGS ?=

TARGET  := oled-clock
SRC     := oled-clock.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	-$(STRIP) $@ 2>/dev/null || true

clean:
	rm -f $(TARGET) *.o

.PHONY: all clean
