// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * I2C Master Controller — Linux I2C adapter driver
 *
 * Platform driver for the custom I2C master IP core with AXI4-Lite
 * register interface, intended for Xilinx Zynq (PL) integration.
 *
 * Features:
 *   - Interrupt-driven with polling fallback
 *   - 7-bit addressing, Standard / Fast / Fast-Mode-Plus
 *   - Clock stretching, arbitration lost detection
 *   - I2C_FUNC_I2C | I2C_FUNC_SMBUS_EMUL
 *
 * Register map matches rtl/i2c_master_axi.v and doc/GUIDE_VIVADO_VITIS_FROM_SCRATCH.md §1.4:
 *   0x00  CTRL      R/W    [1:0] = {IEN, EN}
 *   0x04  STATUS    R      [3:0] = {AL, BUSY, RXACK, TIP}
 *   0x08  CMD       W      [4:0] = {NACK, WR, RD, STO, STA}
 *   0x0C  TX_DATA   R/W    [7:0]
 *   0x10  RX_DATA   R      [7:0]
 *   0x14  PRESCALE  R/W    [15:0]   SCL = clk / (4*(PRESCALE+1))
 *   0x18  ISR       R/W1C  [1:0] = {AL_IRQ, DONE_IRQ}
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/i2c.h>
#include <linux/io.h>
#include <linux/interrupt.h>
#include <linux/clk.h>
#include <linux/of.h>
#include <linux/completion.h>
#include <linux/jiffies.h>
#include <linux/delay.h>
#include <linux/err.h>

/* ------------------------------------------------------------------ */
/* Register offsets                                                     */
/* ------------------------------------------------------------------ */
#define I2CM_REG_CTRL       0x00
#define I2CM_REG_STATUS     0x04
#define I2CM_REG_CMD        0x08
#define I2CM_REG_TX_DATA    0x0C
#define I2CM_REG_RX_DATA    0x10
#define I2CM_REG_PRESCALE   0x14
#define I2CM_REG_ISR        0x18

/* CTRL register bits */
#define I2CM_CTRL_EN        BIT(0)
#define I2CM_CTRL_IEN       BIT(1)

/* STATUS register bits */
#define I2CM_STATUS_TIP     BIT(0)  /* Transfer In Progress */
#define I2CM_STATUS_RXACK   BIT(1)  /* 0=ACK, 1=NACK from slave */
#define I2CM_STATUS_BUSY    BIT(2)  /* Bus busy (between START..STOP) */
#define I2CM_STATUS_AL      BIT(3)  /* Arbitration Lost */

/* CMD register bits */
#define I2CM_CMD_STA        BIT(0)  /* Generate START */
#define I2CM_CMD_STO        BIT(1)  /* Generate STOP */
#define I2CM_CMD_RD         BIT(2)  /* Read byte */
#define I2CM_CMD_WR         BIT(3)  /* Write byte */
#define I2CM_CMD_NACK       BIT(4)  /* Send NACK instead of ACK (read) */

/* ISR register bits (W1C) */
#define I2CM_ISR_DONE       BIT(0)  /* Transfer complete */
#define I2CM_ISR_AL         BIT(1)  /* Arbitration Lost */

#define I2CM_TIMEOUT_MS     1000
#define I2CM_POLL_INTERVAL  10      /* microseconds between polls */

#define DRIVER_NAME         "i2c-zynq-master"

struct i2cm_dev {
	void __iomem        *base;
	struct device       *dev;
	struct i2c_adapter   adapter;
	struct completion    cmd_done;
	struct clk          *clk;
	u32                  input_clk_hz;
	u32                  bus_freq_hz;
	int                  irq;
	bool                 use_irq;
};

/* ------------------------------------------------------------------ */
/* Register access helpers                                             */
/* ------------------------------------------------------------------ */

static inline void i2cm_wreg(struct i2cm_dev *i2c, u32 reg, u32 val)
{
	writel(val, i2c->base + reg);
}

static inline u32 i2cm_rreg(struct i2cm_dev *i2c, u32 reg)
{
	return readl(i2c->base + reg);
}

/* ------------------------------------------------------------------ */
/* Wait for TIP (Transfer In Progress) to clear                        */
/* ------------------------------------------------------------------ */

static int i2cm_wait_complete(struct i2cm_dev *i2c)
{
	u32 status;
	int ret;

	if (i2c->use_irq) {
		ret = wait_for_completion_timeout(&i2c->cmd_done,
				msecs_to_jiffies(I2CM_TIMEOUT_MS));
		if (ret == 0) {
			dev_err(i2c->dev, "timeout waiting for transfer\n");
			return -ETIMEDOUT;
		}
	} else {
		unsigned long timeout = jiffies + msecs_to_jiffies(I2CM_TIMEOUT_MS);

		do {
			status = i2cm_rreg(i2c, I2CM_REG_STATUS);
			if (!(status & I2CM_STATUS_TIP))
				break;
			usleep_range(I2CM_POLL_INTERVAL,
				     I2CM_POLL_INTERVAL * 2);
		} while (time_before(jiffies, timeout));

		if (status & I2CM_STATUS_TIP) {
			dev_err(i2c->dev, "poll timeout waiting for transfer\n");
			return -ETIMEDOUT;
		}
	}

	status = i2cm_rreg(i2c, I2CM_REG_STATUS);

	if (status & I2CM_STATUS_AL) {
		dev_dbg(i2c->dev, "arbitration lost\n");
		return -EAGAIN;
	}

	return 0;
}

/* ------------------------------------------------------------------ */
/* Send STOP condition to release the bus                               */
/* ------------------------------------------------------------------ */

static void i2cm_stop(struct i2cm_dev *i2c)
{
	if (i2c->use_irq)
		reinit_completion(&i2c->cmd_done);

	i2cm_wreg(i2c, I2CM_REG_CMD, I2CM_CMD_STO);
	i2cm_wait_complete(i2c);
}

/* ------------------------------------------------------------------ */
/* Interrupt handler                                                    */
/* ------------------------------------------------------------------ */

static irqreturn_t i2cm_isr(int irq, void *dev_id)
{
	struct i2cm_dev *i2c = dev_id;
	u32 isr;

	isr = i2cm_rreg(i2c, I2CM_REG_ISR);
	if (!isr)
		return IRQ_NONE;

	/* Clear handled interrupt bits (W1C) */
	i2cm_wreg(i2c, I2CM_REG_ISR, isr);

	if (isr & (I2CM_ISR_DONE | I2CM_ISR_AL))
		complete(&i2c->cmd_done);

	return IRQ_HANDLED;
}

/* ------------------------------------------------------------------ */
/* Send one byte over I2C (address or data), return 0 on ACK           */
/* ------------------------------------------------------------------ */

static int i2cm_send_byte(struct i2cm_dev *i2c, u8 byte, u32 cmd_flags)
{
	int ret;

	if (i2c->use_irq)
		reinit_completion(&i2c->cmd_done);

	i2cm_wreg(i2c, I2CM_REG_TX_DATA, byte);
	i2cm_wreg(i2c, I2CM_REG_CMD, cmd_flags);

	ret = i2cm_wait_complete(i2c);
	if (ret)
		return ret;

	if (i2cm_rreg(i2c, I2CM_REG_STATUS) & I2CM_STATUS_RXACK)
		return -ENXIO;  /* NACK */

	return 0;
}

/* ------------------------------------------------------------------ */
/* Read one byte from I2C                                               */
/* ------------------------------------------------------------------ */

static int i2cm_recv_byte(struct i2cm_dev *i2c, u8 *byte, u32 cmd_flags)
{
	int ret;

	if (i2c->use_irq)
		reinit_completion(&i2c->cmd_done);

	i2cm_wreg(i2c, I2CM_REG_CMD, cmd_flags);

	ret = i2cm_wait_complete(i2c);
	if (ret)
		return ret;

	*byte = i2cm_rreg(i2c, I2CM_REG_RX_DATA) & 0xFF;
	return 0;
}

/* ------------------------------------------------------------------ */
/* i2c_algorithm: master_xfer                                          */
/* ------------------------------------------------------------------ */

static int i2cm_xfer(struct i2c_adapter *adap, struct i2c_msg *msgs, int num)
{
	struct i2cm_dev *i2c = i2c_get_adapdata(adap);
	int i, j;
	int ret = 0;

	for (i = 0; i < num; i++) {
		struct i2c_msg *msg = &msgs[i];
		bool is_read = !!(msg->flags & I2C_M_RD);
		bool is_last_msg = (i == num - 1);
		u8 addr_byte;
		u32 cmd;

		/* Address phase: START + slave address */
		addr_byte = i2c_8bit_addr_from_msg(msg);
		cmd = I2CM_CMD_STA | I2CM_CMD_WR;

		ret = i2cm_send_byte(i2c, addr_byte, cmd);
		if (ret == -ENXIO) {
			dev_dbg(i2c->dev, "NACK on address 0x%02x\n",
				msg->addr);
			i2cm_stop(i2c);
			return -ENXIO;
		}
		if (ret) {
			i2cm_stop(i2c);
			return ret;
		}

		/* Data phase */
		if (is_read) {
			for (j = 0; j < msg->len; j++) {
				bool is_last_byte = (j == msg->len - 1);

				cmd = I2CM_CMD_RD;
				if (is_last_byte)
					cmd |= I2CM_CMD_NACK;
				if (is_last_byte && is_last_msg)
					cmd |= I2CM_CMD_STO;

				ret = i2cm_recv_byte(i2c, &msg->buf[j], cmd);
				if (ret) {
					i2cm_stop(i2c);
					return ret;
				}
			}
		} else {
			for (j = 0; j < msg->len; j++) {
				bool is_last_byte = (j == msg->len - 1);

				cmd = I2CM_CMD_WR;
				if (is_last_byte && is_last_msg)
					cmd |= I2CM_CMD_STO;

				ret = i2cm_send_byte(i2c, msg->buf[j], cmd);
				if (ret == -ENXIO) {
					dev_dbg(i2c->dev,
						"NACK on data byte %d\n", j);
					i2cm_stop(i2c);
					return -EIO;
				}
				if (ret) {
					i2cm_stop(i2c);
					return ret;
				}
			}
		}

		/*
		 * For zero-length messages (SMBus quick command):
		 * the address phase already handled STA+WR; just send STOP
		 * if this is the last message.
		 */
		if (msg->len == 0 && is_last_msg)
			i2cm_stop(i2c);
	}

	return num;
}

static u32 i2cm_func(struct i2c_adapter *adap)
{
	return I2C_FUNC_I2C | I2C_FUNC_SMBUS_EMUL;
}

static const struct i2c_algorithm i2cm_algo = {
	.master_xfer = i2cm_xfer,
	.functionality = i2cm_func,
};

/* ------------------------------------------------------------------ */
/* Hardware init / deinit                                               */
/* ------------------------------------------------------------------ */

static void i2cm_hw_init(struct i2cm_dev *i2c)
{
	u32 prescale;
	u32 ctrl;

	/* Disable core while configuring */
	i2cm_wreg(i2c, I2CM_REG_CTRL, 0);

	/* Set prescaler: SCL = input_clk / (4 * (PRESCALE + 1)) */
	if (i2c->input_clk_hz && i2c->bus_freq_hz) {
		prescale = i2c->input_clk_hz / (4 * i2c->bus_freq_hz) - 1;
		if (prescale > 0xFFFF)
			prescale = 0xFFFF;
	} else {
		prescale = 249;  /* 100 MHz → 100 kHz fallback */
	}

	i2cm_wreg(i2c, I2CM_REG_PRESCALE, prescale);

	/* Clear any pending interrupts */
	i2cm_wreg(i2c, I2CM_REG_ISR, I2CM_ISR_DONE | I2CM_ISR_AL);

	/* Enable core (+ interrupts if available) */
	ctrl = I2CM_CTRL_EN;
	if (i2c->use_irq)
		ctrl |= I2CM_CTRL_IEN;

	i2cm_wreg(i2c, I2CM_REG_CTRL, ctrl);

	dev_info(i2c->dev,
		 "prescale=%u, SCL≈%lu Hz, irq=%s\n",
		 prescale,
		 i2c->input_clk_hz ?
			i2c->input_clk_hz / (4 * ((unsigned long)prescale + 1)) : 0,
		 i2c->use_irq ? "yes" : "polling");
}

static void i2cm_hw_deinit(struct i2cm_dev *i2c)
{
	i2cm_wreg(i2c, I2CM_REG_CTRL, 0);
	i2cm_wreg(i2c, I2CM_REG_ISR, I2CM_ISR_DONE | I2CM_ISR_AL);
}

/* ------------------------------------------------------------------ */
/* Platform driver probe / remove                                      */
/* ------------------------------------------------------------------ */

static int i2cm_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct i2cm_dev *i2c;
	struct resource *res;
	int ret;

	i2c = devm_kzalloc(dev, sizeof(*i2c), GFP_KERNEL);
	if (!i2c)
		return -ENOMEM;

	i2c->dev = dev;
	platform_set_drvdata(pdev, i2c);
	init_completion(&i2c->cmd_done);

	/* Memory-mapped registers */
	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	i2c->base = devm_ioremap_resource(dev, res);
	if (IS_ERR(i2c->base))
		return PTR_ERR(i2c->base);

	/* Input clock */
	i2c->clk = devm_clk_get_optional(dev, NULL);
	if (IS_ERR(i2c->clk))
		return dev_err_probe(dev, PTR_ERR(i2c->clk),
				     "failed to get clock\n");

	if (i2c->clk) {
		ret = clk_prepare_enable(i2c->clk);
		if (ret) {
			dev_err(dev, "failed to enable clock: %d\n", ret);
			return ret;
		}
		i2c->input_clk_hz = clk_get_rate(i2c->clk);
	} else {
		/* Fallback: read from DT or assume 100 MHz */
		of_property_read_u32(dev->of_node, "input-clock-frequency",
				     &i2c->input_clk_hz);
		if (!i2c->input_clk_hz)
			i2c->input_clk_hz = 100000000;
	}

	/* Bus (SCL) frequency — default 100 kHz */
	of_property_read_u32(dev->of_node, "clock-frequency",
			     &i2c->bus_freq_hz);
	if (!i2c->bus_freq_hz)
		i2c->bus_freq_hz = 100000;

	/* Interrupt (optional — falls back to polling) */
	i2c->irq = platform_get_irq_optional(pdev, 0);
	if (i2c->irq > 0) {
		ret = devm_request_irq(dev, i2c->irq, i2cm_isr,
				       IRQF_SHARED, DRIVER_NAME, i2c);
		if (ret) {
			dev_warn(dev, "IRQ request failed (%d), using polling\n",
				 ret);
			i2c->use_irq = false;
		} else {
			i2c->use_irq = true;
		}
	} else {
		dev_info(dev, "no IRQ specified, using polling mode\n");
		i2c->use_irq = false;
	}

	/* Hardware initialisation */
	i2cm_hw_init(i2c);

	/* Register I2C adapter */
	i2c->adapter.owner = THIS_MODULE;
	i2c->adapter.algo = &i2cm_algo;
	i2c->adapter.dev.parent = dev;
	i2c->adapter.dev.of_node = dev->of_node;
	i2c->adapter.nr = -1;  /* auto-assign */
	snprintf(i2c->adapter.name, sizeof(i2c->adapter.name),
		 "i2c-zynq-master at %pR", res);
	i2c_set_adapdata(&i2c->adapter, i2c);

	ret = i2c_add_numbered_adapter(&i2c->adapter);
	if (ret) {
		dev_err(dev, "failed to add I2C adapter: %d\n", ret);
		goto err_hw;
	}

	dev_info(dev, "I2C master controller registered (bus %d)\n",
		 i2c->adapter.nr);
	return 0;

err_hw:
	i2cm_hw_deinit(i2c);
	if (i2c->clk)
		clk_disable_unprepare(i2c->clk);
	return ret;
}

static void i2cm_remove(struct platform_device *pdev)
{
	struct i2cm_dev *i2c = platform_get_drvdata(pdev);

	i2c_del_adapter(&i2c->adapter);
	i2cm_hw_deinit(i2c);

	if (i2c->clk)
		clk_disable_unprepare(i2c->clk);
}

/* ------------------------------------------------------------------ */
/* Power management                                                    */
/* ------------------------------------------------------------------ */

static int __maybe_unused i2cm_suspend(struct device *dev)
{
	struct i2cm_dev *i2c = dev_get_drvdata(dev);

	i2cm_hw_deinit(i2c);
	if (i2c->clk)
		clk_disable_unprepare(i2c->clk);

	return 0;
}

static int __maybe_unused i2cm_resume(struct device *dev)
{
	struct i2cm_dev *i2c = dev_get_drvdata(dev);
	int ret;

	if (i2c->clk) {
		ret = clk_prepare_enable(i2c->clk);
		if (ret) {
			dev_err(dev, "failed to re-enable clock: %d\n", ret);
			return ret;
		}
	}

	i2cm_hw_init(i2c);
	return 0;
}

static SIMPLE_DEV_PM_OPS(i2cm_pm_ops, i2cm_suspend, i2cm_resume);

/* ------------------------------------------------------------------ */
/* Device Tree matching                                                */
/* ------------------------------------------------------------------ */

static const struct of_device_id i2cm_of_match[] = {
	{ .compatible = "custom,i2c-master-1.0" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, i2cm_of_match);

static struct platform_driver i2cm_driver = {
	.probe  = i2cm_probe,
	.remove = i2cm_remove,
	.driver = {
		.name           = DRIVER_NAME,
		.of_match_table = i2cm_of_match,
		.pm             = &i2cm_pm_ops,
	},
};

module_platform_driver(i2cm_driver);

MODULE_AUTHOR("Megalloid");
MODULE_DESCRIPTION("I2C Master Controller driver for Zynq FPGA");
MODULE_LICENSE("GPL");
