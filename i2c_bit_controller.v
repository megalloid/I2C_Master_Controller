`timescale 1ns/1ps

module i2c_bit_controller 

	// Порты
	(
	input rstn_i, 
	input clk_i, 
	
	input wr_i2c_i,
	input [2:0] cmd_i, 
	
	input [7:0] din_i,
	output [7:0] dout_o,
	output ack_o,
	
	output [3:0] state_o,
	output ready_o,
	output [4:0] bit_count_o,
		
	inout tri sda_io,
   	output tri scl_io
);

	// Команды
	localparam START_CMD   			= 3'b001;
	localparam WR_CMD      			= 3'b010;
	localparam RD_CMD      			= 3'b011;
	localparam STOP_CMD    			= 3'b100;
	localparam RESTART_CMD 			= 3'b101;
		
	// Состояния FSM
	localparam IDLE_STATE 			= 4'b0001;
	localparam START1_STATE  		= 4'b0010;
	localparam START2_STATE  		= 4'b0011;
	localparam HOLD_STATE  			= 4'b0100;
	localparam RESTART1_STATE  		= 4'b0101;
	localparam RESTART2_STATE  		= 4'b0110;
	localparam STOP1_STATE  		= 4'b0111;
	localparam STOP2_STATE  		= 4'b1000;
	localparam STOP3_STATE			= 4'b1001;
	localparam DATA1_STATE  		= 4'b1010;
	localparam DATA2_STATE  		= 4'b1011;
	localparam DATA3_STATE  		= 4'b1100;
	localparam DATA4_STATE  		= 4'b1101;
	localparam DATAEND_STATE 		= 4'b1110;
	
	// Регистры
	reg ready_r;
	reg data_phase_r;
	
	reg [7:0] state_r;
	reg [7:0] state_next_r;
	
	reg [3:0] cmd_r;
	reg [3:0] cmd_next_r;

	reg [4:0] bit_r;
	reg [4:0] bit_next_r;
	
	reg [8:0] tx_r;
	reg [8:0] tx_next_r;
	
	reg [8:0] rx_r;
	reg [8:0] rx_next_r;
	
	reg sda_out_r;
	reg scl_out_r;
	reg sda_r;
	reg scl_r;
	
	// Провода
	wire into_w;
	wire nack_w;
	
	always @(posedge clk_i, negedge rstn_i)
	begin
		if (~rstn_i) 
		begin
			sda_r <= 1'b1;
			scl_r <= 1'b1;
      	end else 
		begin
         		sda_r <= sda_out_r;
         		scl_r <= scl_out_r;
      		end
	end
	
   	assign scl_io = (scl_r) ? 1'bz : 1'b0;
   
   	assign into_w = (data_phase_r && cmd_r == RD_CMD && bit_r < 8) || (data_phase_r && cmd_r == WR_CMD && bit_r == 8); 
   	assign sda_io = (into_w || sda_r) ? 1'bz : 1'b0;
	
	assign dout_o 	= rx_r[8:1];
   	assign ack_o 	= rx_r[0];    
	assign nack_w 	= din_i[0];     
	
	// Отладочный вывод 
	assign state_o = state_r;
	assign ready_o = ready_r;
	assign bit_count_o = bit_r;
	
   // Обновление регистров
   always @(posedge clk_i, negedge rstn_i)
    begin
      if (~rstn_i) begin
         	state_r <= IDLE_STATE;
		bit_r   <= 0;
		cmd_r   <= 0;
		tx_r    <= 0;
		rx_r    <= 0;
      end
      else begin
		state_r <= state_next_r;
		bit_r   <= bit_next_r;
		cmd_r   <= cmd_next_r;
		tx_r   	<= tx_next_r;
		rx_r    <= rx_next_r;
      end
	end  
	
	// Next-state машина
   always @(*)
   begin
	
      state_next_r 	= state_r;
		ready_r 			= 1'b0;
		cmd_next_r 		= cmd_r;
		bit_next_r 		= bit_r;
		scl_out_r 		= 1'b1;
      		sda_out_r		= 1'b1;
		data_phase_r 	= 1'b0;
		tx_next_r 		= tx_r;
		rx_next_r 		= rx_r;
		
		case (state_r)
			
			IDLE_STATE: begin
				ready_r = 1'b1;	
				
				if(wr_i2c_i && cmd_i == START_CMD)
				begin
					state_next_r = START1_STATE;
				end
				
			end
			
			START1_STATE: begin 
			
				sda_out_r = 1'b0;								
				state_next_r = START2_STATE;
				
			end
			
			START2_STATE: begin 
			
				sda_out_r = 1'b0;
            			scl_out_r = 1'b0;
				
				state_next_r = HOLD_STATE;
				
			end
			
			HOLD_STATE: begin 		
			
				ready_r = 1'b1;  
				
            			sda_out_r = 1'b0;
            			scl_out_r = 1'b0;
				
				if (wr_i2c_i) 
   			begin
					cmd_next_r = cmd_i;
					
					case (cmd_i) 
						RESTART_CMD:
							state_next_r = RESTART1_STATE;
						
						STOP_CMD:
							state_next_r = STOP1_STATE;
							
						default: begin
							bit_next_r   = 0;
							state_next_r = DATA1_STATE;
							
							tx_next_r = {din_i, nack_w}; 
							
						end
					
					endcase
				end			
			end
			
			DATA1_STATE: begin 
			
				sda_out_r = tx_r[8];
				scl_out_r = 1'b0;

            			data_phase_r = 1'b1;
				state_next_r = DATA2_STATE;
				
			end
			
			DATA2_STATE: begin 
			
				sda_out_r = tx_r[8];				
				data_phase_r = 1'b1;
				
				state_next_r = DATA3_STATE;
				rx_next_r = {rx_r[7:0], sda_io}; 
				
			end
			
			DATA3_STATE: begin 
				
				sda_out_r = tx_r[8];	
				data_phase_r = 1'b1;
				
				state_next_r = DATA4_STATE;
				
			end
			
			DATA4_STATE: begin 
			
				sda_out_r = tx_r[8];
            			scl_out_r = 1'b0;
            			data_phase_r = 1'b1;
				
				if (bit_r == 8) 
			   begin
					state_next_r = DATAEND_STATE;					
				end else 
				begin
					
					tx_next_r = {tx_r[7:0], 1'b0};
					bit_next_r = bit_r + 1;
					state_next_r = DATA1_STATE;
					
				end
			
			end
			
			DATAEND_STATE: begin
			
				sda_out_r = 1'b0;
            			scl_out_r = 1'b0;
				
				state_next_r = HOLD_STATE;
				
			end
			
			RESTART1_STATE: begin 
			
				scl_out_r = 1'b0;
				state_next_r = RESTART2_STATE;
				
			end
			
			RESTART2_STATE: begin 
				state_next_r = START1_STATE;
			end
			
			STOP1_STATE: begin 
			
				sda_out_r = 1'b0;
				state_next_r = STOP2_STATE;
				
			end
			
			STOP2_STATE: begin 
				state_next_r = STOP3_STATE;
			end
			
			default: begin 								// STOP3 condition
				state_next_r = IDLE_STATE;
			end
			
		endcase
	end
	
endmodule
