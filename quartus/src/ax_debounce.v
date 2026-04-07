`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// Button Debouncer (based on ALINX AX301 reference design)
//
// Outputs single-cycle pulses on button_posedge / button_negedge.
// Debounce time ≈ MAX_TIME ms at FREQ MHz clock.
// Reset is active-high.
// ---------------------------------------------------------------------------
module ax_debounce #(
    parameter N        = 32,
    parameter FREQ     = 50,    // MHz
    parameter MAX_TIME = 20     // ms
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,
    output reg  button_posedge,
    output reg  button_negedge,
    output reg  button_out
);

    localparam TIMER_MAX_VAL = MAX_TIME * 1000 * FREQ;

    reg [N-1:0] q_reg, q_next;
    reg         DFF1, DFF2;
    reg         button_out_d0;

    wire q_reset = (DFF1 ^ DFF2);
    wire q_add   = ~(q_reg == TIMER_MAX_VAL);

    always @(*) begin
        case ({q_reset, q_add})
            2'b00:   q_next = q_reg;
            2'b01:   q_next = q_reg + 1;
            default: q_next = {N{1'b0}};
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            DFF1  <= 1'b0;
            DFF2  <= 1'b0;
            q_reg <= {N{1'b0}};
        end else begin
            DFF1  <= button_in;
            DFF2  <= DFF1;
            q_reg <= q_next;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst)
            button_out <= 1'b1;
        else if (q_reg == TIMER_MAX_VAL)
            button_out <= DFF2;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            button_out_d0  <= 1'b1;
            button_posedge <= 1'b0;
            button_negedge <= 1'b0;
        end else begin
            button_out_d0  <= button_out;
            button_posedge <= ~button_out_d0 &  button_out;
            button_negedge <=  button_out_d0 & ~button_out;
        end
    end

endmodule
