`timescale 1ns/1ps

module i2c_bit_controller (
	input i_reset_n, 
	input i_clk, 
	
	input i_wr_i2c,
	input [2:0] i_cmd, 
	
	input [7:0] i_din,
	output [7:0] o_dout,
	output o_ack,
	
	output [3:0] o_state,
	output o_ready,
	output [4:0] o_bit_count,
		
	inout tri io_sda,
  	output tri io_scl
);

	// Commands constants
	localparam START_CMD   			= 3'b001;
	localparam WR_CMD      			= 3'b010;
	localparam RD_CMD      			= 3'b011;
	localparam STOP_CMD    			= 3'b100;
	localparam RESTART_CMD 			= 3'b101;
		
	// States
	localparam IDLE_STATE 			= 4'b0001;
	localparam START1_STATE  		= 4'b0010;
	localparam START2_STATE  		= 4'b0011;
	localparam HOLD_STATE  			= 4'b0100;
	localparam RESTART1_STATE  	= 4'b0101;
	localparam RESTART2_STATE  	= 4'b0110;
	localparam STOP1_STATE  		= 4'b0111;
	localparam STOP2_STATE  		= 4'b1000;
	localparam STOP3_STATE			= 4'b1001;
	localparam DATA1_STATE  		= 4'b1010;
	localparam DATA2_STATE  		= 4'b1011;
	localparam DATA3_STATE  		= 4'b1100;
	localparam DATA4_STATE  		= 4'b1101;
	localparam DATAEND_STATE 		= 4'b1110;
	

	reg reg_ready;
	reg data_phase;
	
	reg [7:0] state_reg;
	reg [7:0] state_next;
	
	reg [3:0] cmd_reg;
	reg [3:0] cmd_next;

	reg [4:0] bit_reg;
	reg [4:0] bit_next;
	
	reg [8:0] tx_reg;
	reg [8:0] tx_next;
	
	reg [8:0] rx_reg;
	reg [8:0] rx_next;
	
	reg sda_out;
	reg scl_out;
	reg sda_reg;
	reg scl_reg;
	

	wire into;
	wire nack;
	
	always @(posedge i_clk, negedge i_reset_n)
	begin
		if (~i_reset_n) 
		begin
			sda_reg <= 1'b1;
			scl_reg <= 1'b1;
      		end else 
		begin
         		sda_reg <= sda_out;
         		scl_reg <= scl_out;
      		end
      end
	
   	assign io_scl = (scl_reg) ? 1'bz : 1'b0;
   
assign into = (data_phase && cmd_reg == RD_CMD && bit_reg < 8) || (data_phase && cmd_reg == WR_CMD && bit_reg == 8); 

assign io_sda = (into || sda_reg) ? 1'bz : 1'b0;
	
	assign o_dout = rx_reg[8:1];
   	assign o_ack = rx_reg[0];    // obtained from slave in write 
	assign nack = i_din[0];      // used by master in read operation 
	

	assign o_state = state_reg;
	assign o_ready = reg_ready;
	assign o_bit_count = bit_reg;
	

   	always @(posedge i_clk, negedge i_reset_n)
    	begin
      		if (~i_reset_n) begin
         		state_reg <= IDLE_STATE;
			bit_reg   <= 0;
			cmd_reg   <= 0;
			tx_reg    <= 0;
			rx_reg    <= 0;
      		end else begin
         		state_reg <= state_next;
			bit_reg   <= bit_next;
			cmd_reg   <= cmd_next;
			tx_reg    <= tx_next;
			rx_reg    <= rx_next;
      end
end  
	
	always @(*)
  	begin
	
      		state_next = state_reg;
		reg_ready = 1'b0;
		cmd_next = cmd_reg;
		bit_next = bit_reg;
		scl_out = 1'b1;
      		sda_out = 1'b1;
		data_phase = 1'b0;
		tx_next = tx_reg;
		rx_next = rx_reg;
		
		case (state_reg)
			
			IDLE_STATE: begin
				reg_ready = 1'b1;	
				
				if(i_wr_i2c && i_cmd == START_CMD)
				begin
					state_next = START1_STATE;
				end
				
			end
			
			START1_STATE: begin 
				sda_out = 1'b0;
								
				state_next = START2_STATE;
				
			end
			
			START2_STATE: begin 
				sda_out = 1'b0;
            			scl_out = 1'b0;
				
				state_next = HOLD_STATE;
				
			end
			
			HOLD_STATE: begin 			
				reg_ready = 1'b1;  
				
            sda_out = 1'b0;
            scl_out = 1'b0;
				
				if (i_wr_i2c) 
   				begin
					cmd_next = i_cmd;
					
					case (i_cmd) 
						RESTART_CMD:
							state_next = RESTART1_STATE;
						
						STOP_CMD:
							state_next = STOP1_STATE;
							
						default: begin
							bit_next   = 0;
							state_next = DATA1_STATE;
							
							tx_next = {i_din, nack}; 
							
						end
					
					endcase
				end			
			end
			
			DATA1_STATE: begin 
			
				sda_out = tx_reg[8];
				scl_out = 1'b0;

            			data_phase = 1'b1;
				state_next = DATA2_STATE;
				
			end
			
			DATA2_STATE: begin 

				sda_out = tx_reg[8];				
				data_phase = 1'b1;
				
				state_next = DATA3_STATE;
				rx_next = {rx_reg[7:0], io_sda}; //shift data in
			end
			
			DATA3_STATE: begin 
				
				sda_out = tx_reg[8];	
				data_phase = 1'b1;
				
				state_next = DATA4_STATE;
				
			end
			
			DATA4_STATE: begin 
			
				sda_out = tx_reg[8];
            			scl_out = 1'b0;

            			data_phase = 1'b1;
				
				if (bit_reg == 8) 
			   	begin
					state_next = DATAEND_STATE;
					
				end else 
				begin
					
					tx_next = {tx_reg[7:0], 1'b0};
					bit_next = bit_reg + 1;
					state_next = DATA1_STATE;
					
				end
			
			end
			
			DATAEND_STATE: begin
			
				sda_out = 1'b0;
            			scl_out = 1'b0;
				
				state_next = HOLD_STATE;
				
			end
			
			RESTART1_STATE: begin 
				scl_out = 1'b0;
				state_next = RESTART2_STATE;
			end
			
			RESTART2_STATE: begin 
				state_next = START1_STATE;
			end
			
			STOP1_STATE: begin 
				sda_out = 1'b0;
				state_next = STOP2_STATE;
			end
			
			STOP2_STATE: begin 
				state_next = STOP3_STATE;
			end
			
			default: begin 	// STOP3 condition
				state_next = IDLE_STATE;
			end
			
		endcase
	end
	
endmodule

