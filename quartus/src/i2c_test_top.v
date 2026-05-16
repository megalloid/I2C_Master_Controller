`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// I2C EEPROM Hardware Test — Top Level for ALINX AX301 (EP4CE6F17C8)
//
// Board: ALINX AX301 v2, Cyclone IV EP4CE6F17C8, 50 MHz oscillator.
// Peripherals used:
//   - I2C bus (SCL/SDA) → 24LC04 EEPROM at 0xA0
//   - 7-segment display (6 digits, active-low, common cathode)
//   - 4 LEDs (active-high)
//   - Button key1 (active-low) — start tests
//   - Button rst_n (active-low) — hardware reset
//
// Operation:
//   1. Power on → display "------", LEDs off
//   2. Press key1 → 4 EEPROM tests execute sequentially
//   3. Each test: write byte → wait 6ms → read back → verify
//   4. Display shows test#, pass/fail, written & read data
//   5. LEDs indicate per-test pass status
//   6. After all tests: summary "Pn Fn" (n=count)
//   7. Press key1 again to re-run
// ---------------------------------------------------------------------------
module i2c_test_top (
    input  wire       clk,         // 50 MHz
    input  wire       rst_n,       // Active-low reset (active-low button)

    input  wire       key1,        // Start button (active-low, active = pressed)

    output wire [3:0] led,         // 4 LEDs

    output wire [5:0] seg_sel,     // 7-segment digit select (active-low)
    output wire [7:0] seg_data,    // 7-segment data (active-low, bit 7 = DP)

    inout  wire       i2c_sda,     // I2C data (open-drain)
    inout  wire       i2c_scl      // I2C clock (open-drain)
);

    // ---------------------------------------------------------------
    // Prescaler for I2C core
    //   SCL = 50 MHz / (4 × (PRESCALE+1)) = 100 kHz
    // ---------------------------------------------------------------
    localparam [15:0] PRESCALE = 16'd124;

    reg [15:0] pre_cnt;
    reg        core_ena;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_cnt  <= 16'd0;
            core_ena <= 1'b0;
        end else if (pre_cnt == 16'd0) begin
            pre_cnt  <= PRESCALE;
            core_ena <= 1'b1;
        end else begin
            pre_cnt  <= pre_cnt - 16'd1;
            core_ena <= 1'b0;
        end
    end

    // ---------------------------------------------------------------
    // Button debouncer (общий rtl/ax_debounce.v, default 50 МГц / 20 мс)
    // ---------------------------------------------------------------
    wire btn_negedge;

    ax_debounce u_debounce (
        .clk_i           (clk),
        .rstn_i          (rst_n),
        .btn_i           (key1),
        .btn_o           (),
        .btn_pressed_o   (btn_negedge),    // pulse при нажатии (1→0)
        .btn_released_o  ()
    );

    // ---------------------------------------------------------------
    // I2C master core
    // ---------------------------------------------------------------
    wire        core_cmd_valid;
    wire [2:0]  core_cmd;
    wire [7:0]  core_din;
    wire [7:0]  core_dout;
    wire        core_rx_ack;
    wire        core_ready;
    wire        core_arb_lost;
    wire        core_arb_lost_clr;
    wire        core_busy;

    wire        scl_oen, sda_oen;

    i2c_master_core u_core (
        .clk_i            (clk),
        .rstn_i           (rst_n),
        .ena_i            (core_ena),
        .cmd_valid_i      (core_cmd_valid),
        .cmd_i            (core_cmd),
        .din_i            (core_din),
        .dout_o           (core_dout),
        .rx_ack_o         (core_rx_ack),
        .ready_o          (core_ready),
        .arb_lost_o       (core_arb_lost),
        .arb_lost_clear_i (core_arb_lost_clr),
        .busy_o           (core_busy),
        .scl_i            (i2c_scl),
        .scl_oen_o        (scl_oen),
        .sda_i            (i2c_sda),
        .sda_oen_o        (sda_oen)
    );

    // Open-drain tri-state buffers
    assign i2c_scl = scl_oen ? 1'bz : 1'b0;
    assign i2c_sda = sda_oen ? 1'bz : 1'b0;

    // ---------------------------------------------------------------
    // Test controller
    // ---------------------------------------------------------------
    wire [7:0] dig5, dig4, dig3, dig2, dig1, dig0;

    i2c_test_ctrl #(
        .SHOW_TICKS (25_000_000),  // 500 ms
        .WR_TICKS   (300_000)      // 6 ms
    ) u_ctrl (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (btn_negedge),
        .cmd_valid    (core_cmd_valid),
        .cmd          (core_cmd),
        .din          (core_din),
        .dout         (core_dout),
        .rx_ack       (core_rx_ack),
        .ready        (core_ready),
        .arb_lost     (core_arb_lost),
        .arb_lost_clr (core_arb_lost_clr),
        .seg5         (dig5),
        .seg4         (dig4),
        .seg3         (dig3),
        .seg2         (dig2),
        .seg1         (dig1),
        .seg0         (dig0),
        .led          (led)
    );

    // ---------------------------------------------------------------
    // 7-segment display scanner (6 digits)
    // ---------------------------------------------------------------
    seg_scan #(
        .CLK_FREQ  (50_000_000),
        .SCAN_FREQ (200)
    ) u_seg (
        .clk        (clk),
        .rst_n      (rst_n),
        .seg_sel    (seg_sel),
        .seg_data   (seg_data),
        .seg_data_0 (dig0),
        .seg_data_1 (dig1),
        .seg_data_2 (dig2),
        .seg_data_3 (dig3),
        .seg_data_4 (dig4),
        .seg_data_5 (dig5)
    );

endmodule
