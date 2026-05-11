################################################################################
#
# i2c-master-axi  -  out-of-tree kernel module for the I2C_Master_Controller IP
#
# Source lives outside this BR2_EXTERNAL tree (one level up: linux/drivers/...).
# We use OVERRIDE_SRCDIR semantics by copying the sources into $(@D) before the
# kernel module is built.
#
################################################################################

I2C_MASTER_AXI_VERSION = 1.0
I2C_MASTER_AXI_SITE = $(BR2_EXTERNAL_ZYNQ_MINI_I2C_PATH)/../linux/drivers/i2c-master-axi
I2C_MASTER_AXI_SITE_METHOD = local
I2C_MASTER_AXI_LICENSE = GPL-2.0+
I2C_MASTER_AXI_LICENSE_FILES = i2c-master-axi.c

# Build as a Linux kernel module (kernel-module infra picks up obj-m).
$(eval $(kernel-module))
$(eval $(generic-package))
