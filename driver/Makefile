# SPDX-License-Identifier: GPL-2.0
#
# Out-of-tree build:
#   make KERNEL_SRC=/path/to/kernel/source
#
# Cross-compile for Zynq (ARM):
#   make KERNEL_SRC=/path/to/kernel ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
#
# In-tree: place in drivers/i2c/busses/ and add to parent Makefile/Kconfig

obj-m := i2c-zynq-master.o

KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build

.PHONY: all clean modules_install

all:
	$(MAKE) -C $(KERNEL_SRC) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KERNEL_SRC) M=$(CURDIR) clean

modules_install:
	$(MAKE) -C $(KERNEL_SRC) M=$(CURDIR) modules_install
