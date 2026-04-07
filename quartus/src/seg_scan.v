`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 7-Segment Display Scanner — 6 digits, active-low select and data
// ---------------------------------------------------------------------------
module seg_scan #(
    parameter CLK_FREQ  = 50_000_000,
    parameter SCAN_FREQ = 200
)(
    input  wire       clk,
    input  wire       rst_n,
    output reg  [5:0] seg_sel,       // digit select (active-low)
    output reg  [7:0] seg_data,      // segment data (active-low, bit 7 = DP)
    input  wire [7:0] seg_data_0,    // rightmost digit
    input  wire [7:0] seg_data_1,
    input  wire [7:0] seg_data_2,
    input  wire [7:0] seg_data_3,
    input  wire [7:0] seg_data_4,
    input  wire [7:0] seg_data_5     // leftmost digit
);

    localparam SCAN_MAX = CLK_FREQ / (SCAN_FREQ * 6) - 1;

    reg [31:0] scan_cnt;
    reg [2:0]  scan_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_cnt <= 32'd0;
            scan_idx <= 3'd0;
        end else if (scan_cnt >= SCAN_MAX) begin
            scan_cnt <= 32'd0;
            scan_idx <= (scan_idx == 3'd5) ? 3'd0 : scan_idx + 3'd1;
        end else begin
            scan_cnt <= scan_cnt + 32'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_sel  <= 6'b111_111;
            seg_data <= 8'hFF;
        end else begin
            case (scan_idx)
                3'd0: begin seg_sel <= 6'b111_110; seg_data <= seg_data_0; end
                3'd1: begin seg_sel <= 6'b111_101; seg_data <= seg_data_1; end
                3'd2: begin seg_sel <= 6'b111_011; seg_data <= seg_data_2; end
                3'd3: begin seg_sel <= 6'b110_111; seg_data <= seg_data_3; end
                3'd4: begin seg_sel <= 6'b101_111; seg_data <= seg_data_4; end
                3'd5: begin seg_sel <= 6'b011_111; seg_data <= seg_data_5; end
                default: begin seg_sel <= 6'b111_111; seg_data <= 8'hFF; end
            endcase
        end
    end

endmodule
