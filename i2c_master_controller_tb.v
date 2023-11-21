`timescale 1ns / 1ps

module i2c_master_controller_tb;
	
	// Clock
	reg i_clk;
	localparam CLK_PERIOD = 10;
	always #(CLK_PERIOD/2) i_clk = ~i_clk;

	// Registers
	reg i_reset_n = 1'b1;
	reg [2:0] i_cmd;
	reg [3:0] o_state;
	reg o_ready;
	reg i_wr_i2c = 0;
	reg [4:0] o_bit_count;
	reg [4:0] counter = 0;
	
	reg [7:0] i_din;
	
	// Wires
	wire io_scl;
	wire io_sda;

	i2c_master_controller uut(
		.i_reset_n(i_reset_n),
		.i_clk(i_clk),
		
		.i_wr_i2c(i_wr_i2c),
		.i_cmd(i_cmd),
		
		.i_din(i_din),
		
		.o_state(o_state),
		.o_ready(o_ready),
		.o_bit_count(o_bit_count),
		
		.io_sda(io_sda),
		.io_scl(io_scl)
	);
	

	// Commands constants
   localparam START_CMD   = 3'b001;
   localparam WR_CMD      = 3'b010;
   localparam RD_CMD      = 3'b011;
   localparam STOP_CMD    = 3'b100;
   localparam RESTART_CMD = 3'b101;
	
	initial begin
	
		i_reset_n = 0;
		i_clk = 0;
		
		#10;
		
		i_reset_n = 1;
		
		#10;
		
		i_cmd = START_CMD;	
		
		#10; 
		
		i_wr_i2c = 1;
		i_din = 8'b11111111;
		
		#400;
		
		i_din = 8'b10101010;
		
		#1000;
		$stop;
		
	end
	
	always @(posedge o_ready) begin
		counter = counter + 1;
		
		if (counter == 3)
		begin
			i_cmd = RESTART_CMD;
			i_din = 8'b10101010;
		end else if (counter == 4) 
		begin
			i_cmd = WR_CMD;
		end else if (counter == 5) 
		begin
			i_cmd = STOP_CMD;
		end
	end
	
	
endmodule