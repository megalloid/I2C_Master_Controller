transcript on
if {[file exists rtl_work]} {
	vdel -lib rtl_work -all
}
vlib rtl_work
vmap work rtl_work

vlog  -work work +incdir+/home/megalloid/sources/I2C_Master_Controller/quartus_ssd1306/src {/home/megalloid/sources/I2C_Master_Controller/quartus_ssd1306/src/ssd1306_test_top.v}
vlog  -work work +incdir+/home/megalloid/sources/I2C_Master_Controller/quartus_ssd1306/src {/home/megalloid/sources/I2C_Master_Controller/quartus_ssd1306/src/ssd1306_ctrl.v}
vlog  -work work +incdir+/home/megalloid/sources/I2C_Master_Controller/quartus_ssd1306/src {/home/megalloid/sources/I2C_Master_Controller/quartus_ssd1306/src/seg_scan.v}
vlog  -work work +incdir+/home/megalloid/sources/I2C_Master_Controller/quartus_ssd1306/src {/home/megalloid/sources/I2C_Master_Controller/quartus_ssd1306/src/ax_debounce.v}
vlog  -work work +incdir+/home/megalloid/sources/I2C_Master_Controller/rtl {/home/megalloid/sources/I2C_Master_Controller/rtl/i2c_master_core.v}
vlog  -work work +incdir+/home/megalloid/sources/I2C_Master_Controller/rtl {/home/megalloid/sources/I2C_Master_Controller/rtl/i2c_burst_writer.v}

