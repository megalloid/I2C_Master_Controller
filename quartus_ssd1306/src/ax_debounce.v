`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// Button debouncer — active-low input, single-cycle active-high pulse output
// ---------------------------------------------------------------------------
module ax_debounce #(
    parameter CLK_FREQ    = 50_000_000,
    parameter DEBOUNCE_MS = 20
)(
    input  wire clk_i,
    input  wire rstn_i,
    input  wire key_i,
    output reg  key_pulse_o
);

    localparam CNT_MAX = (CLK_FREQ / 1000) * DEBOUNCE_MS;

    reg [19:0] cnt;
    reg        key_d;
    reg        key_stable;

    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            cnt         <= 20'd0;
            key_d       <= 1'b1;
            key_stable  <= 1'b1;
            key_pulse_o <= 1'b0;
        end else begin
            key_pulse_o <= 1'b0;
            key_d       <= key_i;

            if (key_d != key_stable) begin
                if (cnt >= CNT_MAX[19:0] - 20'd1) begin
                    cnt        <= 20'd0;
                    key_stable <= key_d;
                    if (!key_d)
                        key_pulse_o <= 1'b1;
                end else
                    cnt <= cnt + 20'd1;
            end else
                cnt <= 20'd0;
        end
    end

endmodule
