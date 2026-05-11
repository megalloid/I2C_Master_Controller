// SPDX-License-Identifier: GPL-2.0+
/*
 * i2c-master-axi.c — Linux I2C bus driver for the custom i2c_master_axi IP
 * (AXI4-Lite slave) shipped in this repository.
 *
 * Hardware register map (32-bit data, byte-address step = 4):
 *   0x00  CTRL      R/W   [1:0] = {IEN, EN}
 *   0x04  STATUS    R     [3:0] = {AL, BUSY, RXACK, TIP}
 *   0x08  CMD       W     [4:0] = {NACK, WR, RD, STO, STA}
 *   0x0C  TX_DATA   R/W   [7:0]
 *   0x10  RX_DATA   R     [7:0]
 *   0x14  PRESCALE  R/W   [15:0]   SCL = clk / (4*(PRESCALE+1))
 *   0x18  ISR       R/W1C [1:0] = {AL_IRQ, DONE_IRQ}
 *
 * SCL frequency:   f_SCL = f_clk / (4 * (PRESCALE + 1))
 *
 * Device-tree binding (compatible = "user,i2c-master-axi-1.0"):
 *
 *   i2c0: i2c@43c00000 {
 *       compatible        = "user,i2c-master-axi-1.0";
 *       reg               = <0x43c00000 0x1000>;
 *       interrupts        = <0 29 4>;
 *       interrupt-parent  = <&intc>;
 *       clocks            = <&clkc 15>;        // FCLK0 (50 MHz on this design)
 *       clock-frequency   = <100000>;          // I2C bus speed
 *       #address-cells    = <1>;
 *       #size-cells       = <0>;
 *
 *       ssd1306@3c {
 *           compatible    = "solomon,ssd1306fb-i2c";
 *           reg           = <0x3c>;
 *           solomon,height = <64>;
 *           solomon,width  = <128>;
 *           solomon,page-offset = <0>;
 *       };
 *   };
 *
 * Polled mode is the default: the IRQ wiring on Zynq sometimes lags behind
 * device-tree changes, but the controller is fast enough for SSD1306 traffic
 * even without interrupts. Pass `interrupts = <...>` and the driver will
 * automatically use IRQ-driven completion.
 */

#include <linux/clk.h>
#include <linux/completion.h>
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>

#define DRV_NAME			"i2c-master-axi"

#define I2C_REG_CTRL			0x00
#define I2C_REG_STATUS			0x04
#define I2C_REG_CMD			0x08
#define I2C_REG_TX_DATA			0x0C
#define I2C_REG_RX_DATA			0x10
#define I2C_REG_PRESCALE		0x14
#define I2C_REG_ISR			0x18

#define CTRL_EN				BIT(0)
#define CTRL_IEN			BIT(1)

#define STATUS_TIP			BIT(0)
#define STATUS_RXACK			BIT(1)
#define STATUS_BUSY			BIT(2)
#define STATUS_AL			BIT(3)

#define CMD_STA				BIT(0)
#define CMD_STO				BIT(1)
#define CMD_RD				BIT(2)
#define CMD_WR				BIT(3)
#define CMD_NACK			BIT(4)

#define ISR_DONE			BIT(0)
#define ISR_AL				BIT(1)

#define I2C_DEFAULT_BUS_HZ		100000U
#define I2C_DEFAULT_INPUT_HZ		50000000U

/* TIP polling timeout — generous, covers full byte at 50 kHz */
#define I2C_TIP_TIMEOUT_US		20000U

struct i2c_master_axi {
	void __iomem		*regs;
	struct device		*dev;
	struct clk		*clk;
	struct i2c_adapter	adap;
	struct completion	cmd_done;
	int			irq;
	bool			use_irq;
	u32			input_hz;
	u32			bus_hz;
};

static inline u32 axi_read(struct i2c_master_axi *i, u32 off)
{
	return ioread32(i->regs + off);
}

static inline void axi_write(struct i2c_master_axi *i, u32 off, u32 val)
{
	iowrite32(val, i->regs + off);
}

static int axi_wait_tip(struct i2c_master_axi *i, u32 *status)
{
	u32 st;
	int ret;

	if (i->use_irq) {
		unsigned long t = wait_for_completion_timeout(&i->cmd_done,
				usecs_to_jiffies(I2C_TIP_TIMEOUT_US) + 1);
		st = axi_read(i, I2C_REG_STATUS);
		if (!t && (st & STATUS_TIP)) {
			dev_err(i->dev, "TIP IRQ timeout (status=0x%02x)\n", st);
			return -ETIMEDOUT;
		}
		ret = 0;
	} else {
		ret = readl_poll_timeout(i->regs + I2C_REG_STATUS, st,
					 !(st & STATUS_TIP), 1,
					 I2C_TIP_TIMEOUT_US);
		if (ret) {
			dev_err(i->dev, "TIP poll timeout (status=0x%02x)\n", st);
			return -ETIMEDOUT;
		}
	}

	if (st & STATUS_AL) {
		dev_dbg(i->dev, "arbitration lost\n");
		return -EAGAIN;
	}

	if (status)
		*status = st;
	return 0;
}

static int axi_send_cmd(struct i2c_master_axi *i, u32 cmd, u32 *status)
{
	if (i->use_irq) {
		reinit_completion(&i->cmd_done);
		axi_write(i, I2C_REG_ISR, ISR_DONE | ISR_AL);
	}
	axi_write(i, I2C_REG_CMD, cmd);
	return axi_wait_tip(i, status);
}

static int axi_xfer_one(struct i2c_master_axi *i, struct i2c_msg *m,
			bool first, bool last)
{
	u32 cmd, status;
	u8 addr_byte;
	int j, ret;

	addr_byte = (m->addr << 1) | ((m->flags & I2C_M_RD) ? 1 : 0);
	axi_write(i, I2C_REG_TX_DATA, addr_byte);

	cmd = CMD_WR | (first ? CMD_STA : 0);
	ret = axi_send_cmd(i, cmd, &status);
	if (ret)
		return ret;
	if (status & STATUS_RXACK) {
		dev_dbg(i->dev, "no ACK on address 0x%02x\n", m->addr);
		axi_write(i, I2C_REG_CMD, CMD_STO);
		axi_wait_tip(i, NULL);
		return -ENXIO;
	}

	if (m->flags & I2C_M_RD) {
		for (j = 0; j < m->len; j++) {
			cmd = CMD_RD;
			if (j == m->len - 1) {
				cmd |= CMD_NACK;
				if (last)
					cmd |= CMD_STO;
			}
			ret = axi_send_cmd(i, cmd, &status);
			if (ret)
				return ret;
			m->buf[j] = axi_read(i, I2C_REG_RX_DATA) & 0xff;
		}
	} else {
		for (j = 0; j < m->len; j++) {
			axi_write(i, I2C_REG_TX_DATA, m->buf[j]);
			cmd = CMD_WR;
			if (j == m->len - 1 && last)
				cmd |= CMD_STO;
			ret = axi_send_cmd(i, cmd, &status);
			if (ret)
				return ret;
			if (status & STATUS_RXACK) {
				dev_dbg(i->dev,
					"no ACK on data byte %d (0x%02x)\n",
					j, m->buf[j]);
				if (!last) {
					axi_write(i, I2C_REG_CMD, CMD_STO);
					axi_wait_tip(i, NULL);
				}
				return -EIO;
			}
		}
	}

	return 0;
}

static int axi_master_xfer(struct i2c_adapter *adap, struct i2c_msg *msgs,
			   int num)
{
	struct i2c_master_axi *i = i2c_get_adapdata(adap);
	int k, ret;
	u32 status;

	status = axi_read(i, I2C_REG_STATUS);
	if (status & STATUS_BUSY) {
		dev_dbg(i->dev, "bus busy at xfer start (status=0x%02x)\n",
			status);
		return -EAGAIN;
	}

	for (k = 0; k < num; k++) {
		ret = axi_xfer_one(i, &msgs[k], (k == 0), (k == num - 1));
		if (ret < 0)
			return ret;
	}

	return num;
}

static u32 axi_functionality(struct i2c_adapter *adap)
{
	return I2C_FUNC_I2C | I2C_FUNC_SMBUS_EMUL;
}

static const struct i2c_algorithm axi_algo = {
	.master_xfer	= axi_master_xfer,
	.functionality	= axi_functionality,
};

static const struct i2c_adapter_quirks axi_quirks = {
	.flags		= I2C_AQ_NO_ZERO_LEN,
};

static irqreturn_t i2c_master_axi_isr(int irq, void *dev_id)
{
	struct i2c_master_axi *i = dev_id;
	u32 isr = axi_read(i, I2C_REG_ISR);

	if (!isr)
		return IRQ_NONE;

	axi_write(i, I2C_REG_ISR, isr);
	complete(&i->cmd_done);
	return IRQ_HANDLED;
}

static int i2c_master_axi_hw_init(struct i2c_master_axi *i)
{
	u32 prescale;

	if (i->bus_hz == 0 || i->input_hz == 0)
		return -EINVAL;

	if (i->bus_hz * 4 > i->input_hz) {
		dev_err(i->dev,
			"requested bus %u Hz exceeds input/4 = %u Hz\n",
			i->bus_hz, i->input_hz / 4);
		return -EINVAL;
	}

	prescale = (i->input_hz / (4U * i->bus_hz));
	if (prescale == 0) {
		dev_err(i->dev, "computed prescale=0, refusing\n");
		return -EINVAL;
	}
	prescale -= 1;
	if (prescale > 0xFFFFU) {
		dev_err(i->dev, "prescale %u out of 16-bit range\n", prescale);
		return -EINVAL;
	}

	axi_write(i, I2C_REG_CTRL, 0);
	axi_write(i, I2C_REG_PRESCALE, prescale);
	axi_write(i, I2C_REG_ISR, ISR_DONE | ISR_AL);
	axi_write(i, I2C_REG_CTRL, CTRL_EN | (i->use_irq ? CTRL_IEN : 0));

	dev_info(i->dev,
		 "input=%u Hz, bus=%u Hz, prescale=%u, irq=%s\n",
		 i->input_hz, i->bus_hz, prescale,
		 i->use_irq ? "yes" : "polled");

	return 0;
}

static int i2c_master_axi_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct i2c_master_axi *i;
	int ret;

	i = devm_kzalloc(dev, sizeof(*i), GFP_KERNEL);
	if (!i)
		return -ENOMEM;

	i->dev = dev;
	init_completion(&i->cmd_done);
	platform_set_drvdata(pdev, i);

	i->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(i->regs))
		return PTR_ERR(i->regs);

	i->clk = devm_clk_get_optional(dev, NULL);
	if (IS_ERR(i->clk))
		return PTR_ERR(i->clk);
	if (i->clk) {
		ret = clk_prepare_enable(i->clk);
		if (ret)
			return ret;
		i->input_hz = clk_get_rate(i->clk);
	}

	if (!i->input_hz)
		i->input_hz = I2C_DEFAULT_INPUT_HZ;
	of_property_read_u32(dev->of_node, "input-clock-frequency",
			     &i->input_hz);

	i->bus_hz = I2C_DEFAULT_BUS_HZ;
	of_property_read_u32(dev->of_node, "clock-frequency", &i->bus_hz);

	i->irq = platform_get_irq_optional(pdev, 0);
	if (i->irq > 0) {
		ret = devm_request_irq(dev, i->irq, i2c_master_axi_isr,
				       0, dev_name(dev), i);
		if (ret) {
			dev_warn(dev,
				 "request_irq(%d) failed (%d), falling back to polling\n",
				 i->irq, ret);
			i->use_irq = false;
		} else {
			i->use_irq = true;
		}
	}

	ret = i2c_master_axi_hw_init(i);
	if (ret)
		goto err_clk;

	i->adap.owner = THIS_MODULE;
	i->adap.class = I2C_CLASS_DEPRECATED;
	i->adap.algo = &axi_algo;
	i->adap.quirks = &axi_quirks;
	i->adap.dev.parent = dev;
	i->adap.dev.of_node = of_node_get(dev->of_node);
	strscpy(i->adap.name, dev_name(dev), sizeof(i->adap.name));
	i2c_set_adapdata(&i->adap, i);

	ret = i2c_add_adapter(&i->adap);
	if (ret)
		goto err_disable;

	return 0;

err_disable:
	axi_write(i, I2C_REG_CTRL, 0);
err_clk:
	if (i->clk)
		clk_disable_unprepare(i->clk);
	return ret;
}

/*
 * .remove signature changed across kernel versions:
 *   < 6.11  : int  (*remove)(struct platform_device *)
 *  >= 6.11  : void (*remove)(struct platform_device *)
 *   6.6+    : void (*remove_new)(struct platform_device *) (transitional)
 *
 * The "int + return 0" form below works on every kernel from 4.x to 6.10
 * inclusive, and Linux 6.11+ accepts an int-returning callback as long as
 * we keep using `.remove` (it just ignores the return value). For the
 * Buildroot 2024.02 default (Linux 6.6) this is the correct shape.
 */
static int i2c_master_axi_remove(struct platform_device *pdev)
{
	struct i2c_master_axi *i = platform_get_drvdata(pdev);

	i2c_del_adapter(&i->adap);
	axi_write(i, I2C_REG_CTRL, 0);
	if (i->clk)
		clk_disable_unprepare(i->clk);
	return 0;
}

static const struct of_device_id i2c_master_axi_of_match[] = {
	{ .compatible = "user,i2c-master-axi-1.0" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, i2c_master_axi_of_match);

static struct platform_driver i2c_master_axi_driver = {
	.driver = {
		.name		= DRV_NAME,
		.of_match_table	= i2c_master_axi_of_match,
	},
	.probe		= i2c_master_axi_probe,
	.remove		= i2c_master_axi_remove,
};
module_platform_driver(i2c_master_axi_driver);

MODULE_AUTHOR("I2C Master Controller project");
MODULE_DESCRIPTION("AXI4-Lite I2C master driver (i2c_master_axi IP)");
MODULE_LICENSE("GPL v2");
