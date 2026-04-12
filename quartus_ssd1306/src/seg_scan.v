`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 6-digit 7-segment display scanner (active-low digit select & segments)
// ---------------------------------------------------------------------------
module seg_scan #(
    parameter SCAN_BITS = 16
)(
    input  wire       clk_i,
    input  wire       rstn_i,
    input  wire [7:0] seg_data_0,
    input  wire [7:0] seg_data_1,
    input  wire [7:0] seg_data_2,
    input  wire [7:0] seg_data_3,
    input  wire [7:0] seg_data_4,
    input  wire [7:0] seg_data_5,
    output reg  [5:0] seg_sel,
    output reg  [7:0] seg_data
);

    reg [SCAN_BITS-1:0] scan_cnt;
    wire [2:0] scan_idx = scan_cnt[SCAN_BITS-1 : SCAN_BITS-3];

    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i)
            scan_cnt <= {SCAN_BITS{1'b0}};
        else
            scan_cnt <= scan_cnt + {{(SCAN_BITS-1){1'b0}}, 1'b1};
    end

    always @(*) begin
        case (scan_idx)
            3'd0: begin seg_sel = 6'b111110; seg_data = seg_data_0; end
            3'd1: begin seg_sel = 6'b111101; seg_data = seg_data_1; end
            3'd2: begin seg_sel = 6'b111011; seg_data = seg_data_2; end
            3'd3: begin seg_sel = 6'b110111; seg_data = seg_data_3; end
            3'd4: begin seg_sel = 6'b101111; seg_data = seg_data_4; end
            3'd5: begin seg_sel = 6'b011111; seg_data = seg_data_5; end
            default: begin seg_sel = 6'b111111; seg_data = 8'hFF;   end
        endcase
    end

endmodule
