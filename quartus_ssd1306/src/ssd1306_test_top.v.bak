`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// SSD1306 OLED Test — top-level for ALINX AX301 (EP4CE6F17C8, 50 MHz)
//
// Button press → init SSD1306 → send test pattern → show result.
// I2C shares the bus with on-board EEPROM (different address).
//
// LEDs (active-high):
//   [0] transfer in progress
//   [1] done OK
//   [2] error (NACK / arb lost)
//   [3] I2C bus busy
//
// 7-segment (6 digits, active-low):
//   Digits 5-4: phase indicator
//   Digits 3-0: byte counter (hex)
// ---------------------------------------------------------------------------
module ssd1306_test_top (
    input  wire       clk_50m,
    input  wire       rst_n,
    input  wire       key_start,

    inout  wire       i2c_sda,
    inout  wire       i2c_scl,

    output wire [3:0] led,
    output wire [5:0] seg_sel,
    output wire [7:0] seg_data
);

    // ---------------------------------------------------------------
    // I2C prescaler — 100 kHz SCL from 50 MHz clk
    // SCL_freq = clk / (4 * (PRE_TOP + 1)) = 50M / (4 * 125) = 100 kHz
    // ---------------------------------------------------------------
    localparam [6:0] PRE_TOP = 7'd124;

    reg [6:0] pre_cnt;
    reg       core_ena;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            pre_cnt  <= 7'd0;
            core_ena <= 1'b0;
        end else begin
            if (pre_cnt == PRE_TOP) begin
                pre_cnt  <= 7'd0;
                core_ena <= 1'b1;
            end else begin
                pre_cnt  <= pre_cnt + 7'd1;
                core_ena <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------
    // SDA / SCL synchronizers (2-stage) + tri-state buffers
    // ---------------------------------------------------------------
    wire sda_pad_in, scl_pad_in;
    wire sda_oen, scl_oen;

    assign i2c_sda   = sda_oen ? 1'bz : 1'b0;
    assign i2c_scl   = scl_oen ? 1'bz : 1'b0;
    assign sda_pad_in = i2c_sda;
    assign scl_pad_in = i2c_scl;

    reg [1:0] sda_sync, scl_sync;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            sda_sync <= 2'b11;
            scl_sync <= 2'b11;
        end else begin
            sda_sync <= {sda_sync[0], sda_pad_in};
            scl_sync <= {scl_sync[0], scl_pad_in};
        end
    end
    wire sda_s = sda_sync[1];
    wire scl_s = scl_sync[1];

    // ---------------------------------------------------------------
    // Button debouncer
    // ---------------------------------------------------------------
    wire key_pulse;

    ax_debounce #(
        .CLK_FREQ   (50_000_000),
        .DEBOUNCE_MS(20)
    ) u_debounce (
        .clk_i      (clk_50m),
        .rstn_i     (rst_n),
        .key_i      (key_start),
        .key_pulse_o(key_pulse)
    );

    // ---------------------------------------------------------------
    // I2C Master Core
    // ---------------------------------------------------------------
    wire       cmd_valid, ready, rx_ack, arb_lost, busy;
    wire       arb_lost_clear;
    wire [2:0] cmd;
    wire [7:0] din;

    i2c_master_core u_core (
        .clk_i            (clk_50m),
        .rstn_i           (rst_n),
        .ena_i            (core_ena),
        .cmd_valid_i      (cmd_valid),
        .cmd_i            (cmd),
        .din_i            (din),
        .dout_o           (),
        .rx_ack_o         (rx_ack),
        .ready_o          (ready),
        .arb_lost_o       (arb_lost),
        .arb_lost_clear_i (arb_lost_clear),
        .busy_o           (busy),
        .scl_i            (scl_s),
        .scl_oen_o        (scl_oen),
        .sda_i            (sda_s),
        .sda_oen_o        (sda_oen)
    );

    // ---------------------------------------------------------------
    // SSD1306 Controller
    // ---------------------------------------------------------------
    wire        ssd_busy, ssd_done, ssd_err;
    wire [10:0] ssd_progress;

    ssd1306_ctrl #(
        .CLK_FREQ (50_000_000),
        .I2C_ADDR (7'h3C),
        .DELAY_MS (100)
    ) u_ssd (
        .clk_i            (clk_50m),
        .rstn_i           (rst_n),
        .start_i          (key_pulse),
        .busy_o           (ssd_busy),
        .done_o           (ssd_done),
        .err_o            (ssd_err),
        .progress_o       (ssd_progress),
        .cmd_valid_o      (cmd_valid),
        .cmd_o            (cmd),
        .din_o            (din),
        .ready_i          (ready),
        .rx_ack_i         (rx_ack),
        .arb_lost_i       (arb_lost),
        .arb_lost_clear_o (arb_lost_clear)
    );

    // ---------------------------------------------------------------
    // LED status
    // ---------------------------------------------------------------
    reg ssd_done_latch;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n)
            ssd_done_latch <= 1'b0;
        else if (ssd_done)
            ssd_done_latch <= 1'b1;
        else if (key_pulse)
            ssd_done_latch <= 1'b0;
    end

    assign led[0] = ssd_busy;
    assign led[1] = ssd_done_latch;
    assign led[2] = ssd_err;
    assign led[3] = busy;

    // ---------------------------------------------------------------
    // 7-segment display — hex byte counter + status
    // ---------------------------------------------------------------
    function [7:0] seg_hex;
        input [3:0] val;
        begin
            // verilator lint_off BLKSEQ
            case (val)
                4'h0: seg_hex = 8'hC0;
                4'h1: seg_hex = 8'hF9;
                4'h2: seg_hex = 8'hA4;
                4'h3: seg_hex = 8'hB0;
                4'h4: seg_hex = 8'h99;
                4'h5: seg_hex = 8'h92;
                4'h6: seg_hex = 8'h82;
                4'h7: seg_hex = 8'hF8;
                4'h8: seg_hex = 8'h80;
                4'h9: seg_hex = 8'h90;
                4'hA: seg_hex = 8'h88;
                4'hB: seg_hex = 8'h83;
                4'hC: seg_hex = 8'hC6;
                4'hD: seg_hex = 8'hA1;
                4'hE: seg_hex = 8'h86;
                4'hF: seg_hex = 8'h8E;
                default: seg_hex = 8'hFF;
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    localparam [7:0] SEG_BLANK = 8'hFF;
    localparam [7:0] SEG_DASH  = 8'hBF;

    wire [7:0] seg_d0 = ssd_err ? 8'h86 :
                         ssd_done_latch ? seg_hex(4'h0) : SEG_DASH;
    wire [7:0] seg_d1 = seg_hex(ssd_progress[3:0]);
    wire [7:0] seg_d2 = seg_hex(ssd_progress[7:4]);
    wire [7:0] seg_d3 = seg_hex({1'b0, ssd_progress[10:8]});
    wire [7:0] seg_d4 = SEG_BLANK;
    wire [7:0] seg_d5 = SEG_BLANK;

    seg_scan #(
        .SCAN_BITS(16)
    ) u_seg (
        .clk_i     (clk_50m),
        .rstn_i    (rst_n),
        .seg_data_0(seg_d0),
        .seg_data_1(seg_d1),
        .seg_data_2(seg_d2),
        .seg_data_3(seg_d3),
        .seg_data_4(seg_d4),
        .seg_data_5(seg_d5),
        .seg_sel   (seg_sel),
        .seg_data  (seg_data)
    );

endmodule
