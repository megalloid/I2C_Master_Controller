`timescale 1ns / 1ps

module top_module 
	(
		input		clk_i,
		input		rstn_i,
		
		input 	[2:0] btn_main_i,
		input 	[5:0] btn_brd_i,
		output 	[3:0] led_brd_o,
		
		output 	[5:0] seg_sel_o,
		output 	[7:0] seg_data_o,
		
		inout		sda_io,
		output	scl_io
		
	);
	
	//#################################################
	//  GPIO Buttons Debouncers
	//#################################################

	wire btn_read_negedge_w;	
	wire btn_write_negedge_w;
	wire btn_reg_p_negedge_w;
	wire btn_reg_n_negedge_w;
	wire btn_data_p_negedge_w;
	wire btn_data_n_negedge_w;
	
	gpio_debouncer gpio_debouncer_m0 (
		.clk_i		(clk_i),               			// Clock input
		.rstn_i		(rstn_i),              			// Reset input
		.button_i	(btn_brd_i[0]),					// Switch input M15

		.button_out_r		(),     		// Switch button state
		.button_negedge_r	(),      					// Switch button negative edge pulse
		.button_posedge_r	(btn_read_negedge_w)   	// Switch button positive edge pulse
	);
	
	gpio_debouncer gpio_debouncer_m1 (
		.clk_i		(clk_i),               			// Clock input
		.rstn_i		(rstn_i),              			// Reset input
		.button_i	(btn_brd_i[1]),					// Switch input M16

		.button_out_r		(),     		// Switch button state
		.button_negedge_r	(),      					// Switch button negative edge pulse
		.button_posedge_r	(btn_write_negedge_w)  	// Switch button positive edge pulse
	);
	
	gpio_debouncer gpio_debouncer_m2 (
		.clk_i		(clk_i),               			// Clock input
		.rstn_i		(rstn_i),              			// Reset input
		.button_i	(btn_brd_i[2]),					// Switch input M16

		.button_out_r		(),     		// Switch button state
		.button_negedge_r	(),      					// Switch button negative edge pulse
		.button_posedge_r	(btn_reg_p_negedge_w)  	// Switch button positive edge pulse
	);
	
	gpio_debouncer gpio_debouncer_m3 (
		.clk_i		(clk_i),               			// Clock input
		.rstn_i		(rstn_i),              			// Reset input
		.button_i	(btn_brd_i[3]),					// Switch input M16

		.button_out_r		(),     		// Switch button state
		.button_negedge_r	(),      					// Switch button negative edge pulse
		.button_posedge_r	(btn_reg_n_negedge_w)  	// Switch button positive edge pulse
	);
	
	gpio_debouncer gpio_debouncer_m4 (
		.clk_i		(clk_i),               			// Clock input
		.rstn_i		(rstn_i),              			// Reset input
		.button_i	(btn_brd_i[4]),					// Switch input M16

		.button_out_r		(),     		// Switch button state
		.button_negedge_r	(),      					// Switch button negative edge pulse
		.button_posedge_r	(btn_data_p_negedge_w)  // Switch button positive edge pulse
	);
	
	gpio_debouncer gpio_debouncer_m5 (
		.clk_i		(clk_i),               			// Clock input
		.rstn_i		(rstn_i),              			// Reset input
		.button_i	(btn_brd_i[5]),					// Switch input M16

		.button_out_r		(),     		// Switch button state
		.button_negedge_r	(),      					// Switch button negative edge pulse
		.button_posedge_r	(btn_data_n_negedge_w)  // Switch button positive edge pulse
	);
	
	//#################################################
	//  LED Drivers
	//#################################################
	
	reg led_write_pulse_r = 0;
	reg led_read_pulse_r = 0;
	
	// ACK bit LED
	led_driver led_driver_m0 (
		.clk_i		(clk_i),
		.rstn_i		(rstn_i),
		.state_i		(ack_bit_w),
		.led_o		(led_brd_o[0])
   );   
	
	// Pulse Write LED
	led_driver led_driver_m1 (
		.clk_i		(clk_i),
		.rstn_i		(rstn_i),
		.state_i		(led_read_pulse_r),
		.led_o		(led_brd_o[1])
   ); 
	
	// Pulse Read LED
	led_driver led_driver_m2 (
		.clk_i		(clk_i),
		.rstn_i		(rstn_i),
		.state_i		(led_write_pulse_r),
		.led_o		(led_brd_o[2])
   ); 
	
	
	//#################################################
	// 7 Segments Display Drivers
	//#################################################
	
	wire[6:0] seg_data_0_w;
	wire[6:0] seg_data_1_w;
	wire[6:0] seg_data_2_w;
	wire[6:0] seg_data_3_w;
	wire[6:0] seg_data_4_w;
	wire[6:0] seg_data_5_w;
	
	seg_decoder seg_decoder_m0 (
		 .bin_data_i  (reg_addr_r[7:4]),
		 .seg_data_o  (seg_data_0_w)
	);
	
	seg_decoder seg_decoder_m1 (
		 .bin_data_i  (reg_addr_r[3:0]),
		 .seg_data_o  (seg_data_1_w)
	);
	
	seg_decoder seg_decoder_m2 (
		 .bin_data_i  (data_write_r[7:4]),
		 .seg_data_o  (seg_data_2_w)
	);
	
	seg_decoder seg_decoder_m3 (
		 .bin_data_i  (data_write_r[3:0]),
		 .seg_data_o  (seg_data_3_w)
	);
	
	seg_decoder seg_decoder_m4 (
		 .bin_data_i  (read_data_r[7:4]),
		 .seg_data_o  (seg_data_4_w)
	);
	
	seg_decoder seg_decoder_m5 (
		 .bin_data_i  (read_data_r[3:0]),
		 .seg_data_o  (seg_data_5_w)
	);
	
	// Main driver for 7-seg display
	seg_scan seg_scan_m0 (
		 .clk_i        (clk_i),
		 .rstn_i      	(rstn_i),
		 .seg_sel_o    (seg_sel_o),
		 .seg_data_o   (seg_data_o),
		 .seg_data_0_i ({1'b1, seg_data_0_w}),
		 .seg_data_1_i ({1'b1, seg_data_1_w}),
		 .seg_data_2_i ({1'b1, seg_data_2_w}),
		 .seg_data_3_i ({1'b1, seg_data_3_w}),
		 .seg_data_4_i ({1'b1, seg_data_4_w}),
		 .seg_data_5_i ({1'b1, seg_data_5_w}),
		 .seg_data_6_i ({1'b1, 7'b1111_111}),	// Don't use this segments, busy by I2C
		 .seg_data_7_i ({1'b1, 7'b1111_111})	// Don't use this segments, busy by I2C
	);
	
	//#################################################
	// Main Operation FSM
	//#################################################
		
	// Main parameters of slave device
	localparam SLAVE_ADDR 		= 7'b1010000;
		
	// FSM States
	reg [3:0] state_r;
	
	localparam IDLE_STATE 		= 4'd1;
	localparam WRITE_STATE		= 4'd2;
	localparam READ_STATE		= 4'd3;
	localparam WAIT_STATE		= 4'd4;
	
	// Commands constants
   localparam START_CMD   		= 4'd1; 
   localparam WR_CMD     		= 4'd2; 
   localparam RD_CMD      		= 3'd3; 
   localparam STOP_CMD    		= 4'd4;
   localparam RESTART_CMD 		= 4'd5;
	
	reg [2:0] cmd_r = START_CMD;
		
	// I2C bits
	localparam READ_BIT			= 1'b1;
	localparam WRITE_BIT			= 1'b0;
	
	// Timer for delay
	reg [31:0] timer_r;	
	
	// Register to start operations
	reg wr_i2c_r;	

	reg [6:0] slave_addr_r = SLAVE_ADDR;
	reg [7:0] reg_addr_r = 0;
	reg [7:0] data_write_r = 0;
	
	// Data buffers
	reg [7:0] read_data_r;
	wire [7:0] read_data_w;
	
	reg [7:0] write_data_r;
	
	reg ack_bit_r;
	wire ack_bit_w;
	
	always @(*) begin
	
		read_data_r <= read_data_w;
		ack_bit_r <= ack_bit_w;
		
	end
	
		// Counter for transactions
	reg [4:0] counter_r = 0;
	always @(posedge ready_w or negedge rstn_i) begin
	
		if(rstn_i == 1'b0) begin		
			counter_r = 0;		
		end 
		else begin 
	
			counter_r = counter_r + 1;
			
			case(state_r)
			
				READ_STATE: begin			
					if (counter_r == 7) begin
						counter_r = 0;
					end				
				end 
				
				WRITE_STATE: begin				
					if (counter_r == 5) begin
						counter_r = 0;
					end				
				end 
				
				default: begin
					counter_r = 0;
				end
				
			endcase
			
		end		
	end

	
	always @(posedge clk_i or negedge rstn_i)
	begin
		
		if(rstn_i == 1'b0) begin		
			reg_addr_r			<= 0;
			data_write_r		<= 0;			
		end 
		else begin
			
			if(btn_reg_p_negedge_w) begin
				reg_addr_r = reg_addr_r + 1;
			
			end
			
			if(btn_reg_n_negedge_w) begin			
				reg_addr_r = reg_addr_r - 1;
			
			end
			
			if(btn_data_p_negedge_w) begin				
				data_write_r = data_write_r + 1;
				
			end
			
			if(btn_data_n_negedge_w) begin			
				data_write_r = data_write_r - 1;
			
			end
			
		end
	end
	
	always @(posedge clk_i or negedge rstn_i)
	begin
	
		if(rstn_i == 1'b0) begin	
		
			led_write_pulse_r	<= 0;
			led_read_pulse_r  <= 0;
			
			cmd_r 				<= START_CMD;
			state_r 				<= IDLE_STATE;
			write_data_r		<= 0;
			wr_i2c_r				<= 0;
			
		end 
		else begin
		
			case(state_r)
				
				IDLE_STATE: begin
					
					wr_i2c_r = 0;	
						
					// Button for Read operation	
					if(btn_read_negedge_w) begin
						if(ready_w) begin							
							state_r = READ_STATE;
						end
						
					end
					
					// Button for Write operation
					if(btn_write_negedge_w) begin						
						if(ready_w) begin							
							state_r = WRITE_STATE;
						end
						
					end
					
				end
				
				READ_STATE: begin
					
					led_read_pulse_r <= ~led_read_pulse_r;
					wr_i2c_r = 1;
					
					case(counter_r)

						0: begin
							
						end
						
						1: begin						
							write_data_r = {slave_addr_r, WRITE_BIT};
						end
						
						2: begin
							write_data_r = reg_addr_r;						
						end
						
						3: begin						
							cmd_r = RESTART_CMD;
							write_data_r = {slave_addr_r, READ_BIT};						
						end
						
						4: begin						
							cmd_r = WR_CMD;
							write_data_r = {slave_addr_r, READ_BIT};						
						end
						
						5: begin							
							cmd_r = RD_CMD;							
						end
						
						6: begin						
							cmd_r = STOP_CMD;	
							state_r = WAIT_STATE;
							timer_r = 0; 
						end
																		
						default: begin						
							cmd_r = START_CMD;
							state_r = IDLE_STATE;
							write_data_r = 0;	
						end
					
					endcase
					
				end
				
				WRITE_STATE: begin
				
					led_write_pulse_r <= ~led_write_pulse_r;
					wr_i2c_r = 1;
					
					case(counter_r)
					
						0: begin
						
						end
						
						1: begin						
							write_data_r = {slave_addr_r, WRITE_BIT};
						end
						
						2: begin
							write_data_r = reg_addr_r;	
						end
						
						3: begin							
							write_data_r <= data_write_r;
						end
						
						4: begin
							cmd_r = STOP_CMD;		
							state_r = WAIT_STATE;
							timer_r = 0; 
						end
						
						default: begin						
							cmd_r = START_CMD;
							state_r = IDLE_STATE;
							write_data_r = 0;	
						end
					
					endcase
				
				end
				
				WAIT_STATE: begin 
				
					wr_i2c_r = 1;
				
					if(timer_r >= 32'd1000) begin
                    state_r <= IDLE_STATE;
						  write_data_r = 0;
						  cmd_r = START_CMD;
					end
					else
                    timer_r <= timer_r + 32'd1;
				end
            
            default: begin
					
					wr_i2c_r = 0;
					state_r <= IDLE_STATE;
					
				end 
				
			endcase
		end
	end
	
	//#################################################
	// Clock Divider for I2C Bit Controller
	//#################################################
	
	wire clk_div_w;
	
	clock_divider clock_divider_m0 (
		.clk_i (clk_i),
		.clk_o (clk_div_w),
	);
	
	//#################################################
	// I2C Bit Controller
	//#################################################
	
	wire ready_w;
	
	i2c_bit_controller i2c_bit_controller_m0 (
	
		.rstn_i(rstn_i), 
		.clk_i(clk_div_w), 
		
		.wr_i2c_i(wr_i2c_r),
		.cmd_i(cmd_r), 
		
		.din_i(write_data_r),
		.dout_o(read_data_w),
		.ack_o(ack_bit_w),
		
		.ready_o(ready_w),
			
		.sda_io(sda_io),
		.scl_io(scl_io)
	);

endmodule
