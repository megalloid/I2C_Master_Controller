# SPDX-License-Identifier: GPL-2.0+
#
# Out-of-tree module Makefile (works standalone or via Buildroot).
#
# Standalone:
#     make KDIR=/path/to/linux-source modules
#     make KDIR=/path/to/linux-source clean
#
# Cross-compile example:
#     make KDIR=$BR_LINUX ARCH=arm \
#          CROSS_COMPILE=$HOME/x-tools/arm-cortexa9_neon-linux-gnueabihf-/bin/arm-cortexa9_neon-linux-gnueabihf- \
#          modules

obj-m += i2c-master-axi.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

modules_install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: modules modules_install clean
