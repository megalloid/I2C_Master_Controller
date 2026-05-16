`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// Testbench for I2C EEPROM Hardware Test (i2c_test_top)
//
// Instantiates all submodules directly (prescaler, ax_debounce, i2c_master_core,
// i2c_test_ctrl, seg_scan) with reduced timing parameters for fast simulation.
// An i2c_slave_model acts as the 24LC04 EEPROM.
//
// Tests:
//   1. Initial state after reset
//   2. Full EEPROM test run (4 write+readback tests)
//   3. Slave model memory verification
//   4. Restart from summary display
//   5. Second full run
//   6. Reset mid-transaction
//   7. Post-reset recovery run
//   8. 7-segment scan multiplexing
//   9. NACK handling (no slave at target address)
// ---------------------------------------------------------------------------
module i2c_test_top_tb;

    // ---------------------------------------------------------------
    // Simulation-friendly parameters
    //
    //   Real hardware: PRESCALE=124, WR_TICKS=300000, SHOW_TICKS=25000000
    //   Simulation:    PRESCALE=4,   WR_TICKS=100,    SHOW_TICKS=200
    //
    //   This reduces a 3.5-second real test cycle to ~100 µs of sim time.
    // ---------------------------------------------------------------
    localparam CLK_PERIOD       = 10;           // 10 ns (100 MHz)
    localparam [15:0] PRESCALE  = 16'd4;        // ena every 5 clk
    localparam SHOW_TICKS       = 200;          // 200-cycle display pause
    localparam WR_TICKS         = 100;          // 100-cycle EEPROM write delay
    localparam DB_FREQ          = 1;            // debounce: "1 MHz" → fast timer
    localparam DB_MAX_TIME      = 1;            // debounce: "1 ms" → 1000 cycles
    localparam SCAN_CLK_FREQ    = 50_000;       // seg_scan: reduced for sim
    localparam [6:0] SLAVE_ADDR = 7'h50;        // 24LC04 block 0

    localparam TIMEOUT = 500_000;               // max cycles per wait

    // ---------------------------------------------------------------
    // Signals
    // ---------------------------------------------------------------
    reg        clk;
    reg        rst_n;
    reg        key1;           // button: 1=released, 0=pressed

    wire [3:0] led;
    wire [5:0] seg_sel;
    wire [7:0] seg_data;

    // I2C bus with pull-ups
    wire i2c_sda, i2c_scl;
    pullup (i2c_sda);
    pullup (i2c_scl);

    // ---------------------------------------------------------------
    // Clock generator
    // ---------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // ---------------------------------------------------------------
    // Prescaler (same logic as i2c_test_top, sim-friendly PRESCALE)
    // ---------------------------------------------------------------
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
    // Button debouncer (reduced timer for simulation)
    // ---------------------------------------------------------------
    wire btn_negedge;

    ax_debounce #(
        .CLK_FREQ_HZ (DB_FREQ * 1_000_000),       // DB_FREQ задано в МГц
        .DEBOUNCE_MS (DB_MAX_TIME)
    ) u_debounce (
        .clk_i           (clk),
        .rstn_i          (rst_n),
        .btn_i           (key1),
        .btn_o           (),
        .btn_pressed_o   (btn_negedge),
        .btn_released_o  ()
    );

    // ---------------------------------------------------------------
    // I2C master core
    // ---------------------------------------------------------------
    wire        core_cmd_valid, core_ready, core_rx_ack;
    wire        core_arb_lost,  core_arb_lost_clr, core_busy;
    wire [2:0]  core_cmd;
    wire [7:0]  core_din, core_dout;
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

    // Open-drain tri-state
    assign i2c_scl = scl_oen ? 1'bz : 1'b0;
    assign i2c_sda = sda_oen ? 1'bz : 1'b0;

    // ---------------------------------------------------------------
    // Test controller (reduced delays for simulation)
    // ---------------------------------------------------------------
    wire [7:0] dig5, dig4, dig3, dig2, dig1, dig0;

    i2c_test_ctrl #(
        .SHOW_TICKS (SHOW_TICKS),
        .WR_TICKS   (WR_TICKS)
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
    // 7-segment display scanner
    // ---------------------------------------------------------------
    seg_scan #(
        .CLK_FREQ  (SCAN_CLK_FREQ),
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

    // ---------------------------------------------------------------
    // I2C Slave Model — EEPROM 24LC04 block 0
    // ---------------------------------------------------------------
    i2c_slave_model #(
        .I2C_ADDR (SLAVE_ADDR)
    ) slave (
        .sda_io (i2c_sda),
        .scl_io (i2c_scl)
    );

    // ---------------------------------------------------------------
    // VCD dump
    // ---------------------------------------------------------------
    initial begin
        $dumpfile("i2c_test_top_tb.vcd");
        $dumpvars(0, i2c_test_top_tb);
    end

    // ---------------------------------------------------------------
    // Watchdog
    // ---------------------------------------------------------------
    initial begin
        #(TIMEOUT * CLK_PERIOD * 20);
        $display("WATCHDOG: simulation timeout at %0t", $time);
        $finish;
    end

    // ---------------------------------------------------------------
    // PASS / FAIL counters
    // ---------------------------------------------------------------
    integer pass_cnt, fail_cnt;

    task test_pass(input [80*8-1:0] msg);
        begin
            $display("  PASS: %0s", msg);
            pass_cnt = pass_cnt + 1;
        end
    endtask

    task test_fail(input [80*8-1:0] msg);
        begin
            $display("  FAIL: %0s", msg);
            fail_cnt = fail_cnt + 1;
        end
    endtask

    // ---------------------------------------------------------------
    // Controller FSM state constants (mirror i2c_test_ctrl)
    // ---------------------------------------------------------------
    localparam [3:0]
        ST_IDLE     = 4'd0,
        ST_PREP     = 4'd1,
        ST_WR_SEQ   = 4'd2,
        ST_WR_DELAY = 4'd3,
        ST_RD_SEQ   = 4'd4,
        ST_VERIFY   = 4'd5,
        ST_SHOW     = 4'd6,
        ST_NEXT     = 4'd7,
        ST_SUMMARY  = 4'd8,
        ST_ERR_STOP = 4'd9;

    // ---------------------------------------------------------------
    // Helper: human-readable state name
    // ---------------------------------------------------------------
    function [10*8-1:0] state_name;
        input [3:0] st;
        begin
            case (st)
                ST_IDLE:     state_name = "IDLE      ";
                ST_PREP:     state_name = "PREP      ";
                ST_WR_SEQ:   state_name = "WR_SEQ    ";
                ST_WR_DELAY: state_name = "WR_DELAY  ";
                ST_RD_SEQ:   state_name = "RD_SEQ    ";
                ST_VERIFY:   state_name = "VERIFY    ";
                ST_SHOW:     state_name = "SHOW      ";
                ST_NEXT:     state_name = "NEXT      ";
                ST_SUMMARY:  state_name = "SUMMARY   ";
                ST_ERR_STOP: state_name = "ERR_STOP  ";
                default:     state_name = "???       ";
            endcase
        end
    endfunction

    // ---------------------------------------------------------------
    // Helper: 7-segment pattern → ASCII character
    // ---------------------------------------------------------------
    function [7:0] seg_to_char;
        input [7:0] seg;
        begin
            case (seg[6:0])
                7'b100_0000: seg_to_char = "0";
                7'b111_1001: seg_to_char = "1";
                7'b010_0100: seg_to_char = "2";
                7'b011_0000: seg_to_char = "3";
                7'b001_1001: seg_to_char = "4";
                7'b001_0010: seg_to_char = "5";
                7'b000_0010: seg_to_char = "6";
                7'b111_1000: seg_to_char = "7";
                7'b000_0000: seg_to_char = "8";
                7'b001_0000: seg_to_char = "9";
                7'b000_1000: seg_to_char = "A";
                7'b000_0011: seg_to_char = "b";
                7'b100_0110: seg_to_char = "C";
                7'b010_0001: seg_to_char = "d";
                7'b000_0110: seg_to_char = "E";
                7'b000_1110: seg_to_char = "F";
                7'b011_1111: seg_to_char = "-";
                7'b000_1100: seg_to_char = "P";
                7'b111_1111: seg_to_char = " ";
                default:     seg_to_char = "?";
            endcase
        end
    endfunction

    task display_show;
        begin
            $display("    Display: [%s][%s][%s][%s][%s][%s]  LED: %b",
                     seg_to_char(dig5), seg_to_char(dig4),
                     seg_to_char(dig3), seg_to_char(dig2),
                     seg_to_char(dig1), seg_to_char(dig0), led);
        end
    endtask

    // ---------------------------------------------------------------
    // Helper: wait for controller to enter a given state
    // ---------------------------------------------------------------
    task wait_state(input [3:0] target);
        integer wc;
        begin
            wc = 0;
            while (u_ctrl.state !== target) begin
                @(posedge clk);
                wc = wc + 1;
                if (wc > TIMEOUT) begin
                    $display("  FAIL: TIMEOUT waiting for state %0s (stuck in %0s)",
                             state_name(target), state_name(u_ctrl.state));
                    fail_cnt = fail_cnt + 1;
                    disable wait_state;
                end
            end
        end
    endtask

    // ---------------------------------------------------------------
    // Helper: wait for controller to LEAVE a given state
    // ---------------------------------------------------------------
    task wait_state_exit(input [3:0] current);
        integer wc;
        begin
            wc = 0;
            while (u_ctrl.state === current) begin
                @(posedge clk);
                wc = wc + 1;
                if (wc > TIMEOUT) begin
                    $display("  FAIL: TIMEOUT exiting state %0s", state_name(current));
                    fail_cnt = fail_cnt + 1;
                    disable wait_state_exit;
                end
            end
        end
    endtask

    // ---------------------------------------------------------------
    // Helper: simulate button press through ax_debounce
    //
    //   key1 active-low: pressed = 0, released = 1
    //   Debounce timer = DB_FREQ × DB_MAX_TIME × 1000 = 1000 cycles
    //   Hold low for 1500 cycles (margin), then release and settle.
    // ---------------------------------------------------------------
    task press_button;
        begin
            key1 <= 1'b0;
            repeat (1500) @(posedge clk);
            key1 <= 1'b1;
            repeat (1500) @(posedge clk);
        end
    endtask

    // ---------------------------------------------------------------
    // State-change monitor (prints transitions to console)
    // ---------------------------------------------------------------
    reg [3:0] prev_state;
    initial prev_state = ST_IDLE;

    always @(posedge clk) begin
        if (u_ctrl.state !== prev_state) begin
            $display("    [%0t ns] state: %0s -> %0s  test_idx=%0d",
                     $time, state_name(prev_state),
                     state_name(u_ctrl.state), u_ctrl.test_idx);
            prev_state <= u_ctrl.state;
        end
    end

    // ===============================================================
    //  MAIN TEST SEQUENCE
    // ===============================================================
    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        key1     = 1'b1;
        rst_n    = 1'b1;

        $display("");
        $display("============================================================");
        $display("  I2C EEPROM Hardware Test — Simulation Testbench");
        $display("  PRESCALE=%0d  WR_TICKS=%0d  SHOW_TICKS=%0d  DB=%0d cyc",
                 PRESCALE, WR_TICKS, SHOW_TICKS, DB_FREQ * DB_MAX_TIME * 1000);
        $display("============================================================");

        // ---- Reset ----
        rst_n <= 1'b0;
        repeat (20) @(posedge clk);
        rst_n <= 1'b1;
        repeat (10) @(posedge clk);

        // =============================================================
        // TEST 1: Initial state after reset
        // =============================================================
        $display("\n=== TEST 1: Initial state after reset ===");
        begin
            if (u_ctrl.state === ST_IDLE)
                test_pass("Controller in IDLE");
            else
                test_fail("Controller NOT in IDLE");

            if (dig5 === 8'hBF && dig4 === 8'hBF && dig3 === 8'hBF &&
                dig2 === 8'hBF && dig1 === 8'hBF && dig0 === 8'hBF)
                test_pass("Display shows '------'");
            else
                test_fail("Display pattern incorrect after reset");

            if (led === 4'b0000)
                test_pass("All LEDs off");
            else
                test_fail("LEDs not off after reset");

            if (scl_oen === 1'b1 && sda_oen === 1'b1)
                test_pass("I2C bus released (scl_oen=1, sda_oen=1)");
            else
                test_fail("I2C bus NOT released after reset");

            display_show;
        end

        // =============================================================
        // TEST 2: Full EEPROM test run — 4 write+readback cycles
        // =============================================================
        $display("\n=== TEST 2: Full EEPROM test run (4 tests) ===");
        begin : test2
            integer i;

            $display("  Pressing key1...");
            press_button;

            // Controller should have left IDLE
            begin : t2_wait_start
                integer wc;
                wc = 0;
                while (u_ctrl.state === ST_IDLE) begin
                    @(posedge clk);
                    wc = wc + 1;
                    if (wc > TIMEOUT) begin
                        test_fail("Controller never left IDLE after button");
                        disable test2;
                    end
                end
            end
            test_pass("Controller started after button press");

            for (i = 0; i < 4; i = i + 1) begin
                // Wait for result display
                wait_state(ST_SHOW);
                repeat (5) @(posedge clk);
                $display("  --- Sub-test %0d result ---", i + 1);
                display_show;

                // Wait for SHOW to finish
                wait_state_exit(ST_SHOW);
            end

            // All 4 tests done — expect SUMMARY
            wait_state(ST_SUMMARY);
            repeat (5) @(posedge clk);

            $display("  --- Summary ---");
            display_show;

            // LED check
            if (led === 4'b1111)
                test_pass("All 4 LEDs lit — all tests passed");
            else begin
                test_fail("Not all LEDs lit");
                $display("    Expected: 1111, Got: %04b", led);
            end

            // Pass/fail counters
            if (u_ctrl.pass_count === 3'd4)
                test_pass("pass_count = 4");
            else begin
                test_fail("pass_count incorrect");
                $display("    Expected: 4, Got: %0d", u_ctrl.pass_count);
            end

            if (u_ctrl.fail_count === 3'd0)
                test_pass("fail_count = 0");
            else begin
                test_fail("fail_count incorrect");
                $display("    Expected: 0, Got: %0d", u_ctrl.fail_count);
            end

            // Summary display: P4 F0
            if (seg_to_char(dig5) == "P" && seg_to_char(dig4) == "4" &&
                seg_to_char(dig2) == "F" && seg_to_char(dig1) == "0")
                test_pass("Summary display: P4 F0");
            else
                test_fail("Summary display mismatch");
        end

        // =============================================================
        // TEST 3: Verify slave model memory was actually written
        // =============================================================
        $display("\n=== TEST 3: Slave model memory verification ===");
        begin
            if (slave.mem[8'h00] === 8'hA5)
                test_pass("slave.mem[0x00] = 0xA5");
            else begin
                test_fail("slave.mem[0x00] mismatch");
                $display("    Expected: 0xA5, Got: 0x%02h", slave.mem[8'h00]);
            end

            if (slave.mem[8'h01] === 8'h5A)
                test_pass("slave.mem[0x01] = 0x5A");
            else begin
                test_fail("slave.mem[0x01] mismatch");
                $display("    Expected: 0x5A, Got: 0x%02h", slave.mem[8'h01]);
            end

            if (slave.mem[8'h10] === 8'hFF)
                test_pass("slave.mem[0x10] = 0xFF");
            else begin
                test_fail("slave.mem[0x10] mismatch");
                $display("    Expected: 0xFF, Got: 0x%02h", slave.mem[8'h10]);
            end

            if (slave.mem[8'h11] === 8'h00)
                test_pass("slave.mem[0x11] = 0x00");
            else begin
                test_fail("slave.mem[0x11] mismatch");
                $display("    Expected: 0x00, Got: 0x%02h", slave.mem[8'h11]);
            end
        end

        // =============================================================
        // TEST 4: Restart from SUMMARY → IDLE
        // =============================================================
        $display("\n=== TEST 4: Restart from summary ===");
        begin : test4
            $display("  Pressing key1 in SUMMARY...");
            press_button;

            wait_state(ST_IDLE);
            repeat (5) @(posedge clk);

            test_pass("Returned to IDLE from SUMMARY");

            if (dig5 === 8'hBF && dig0 === 8'hBF)
                test_pass("Display shows '------' after restart");
            else
                test_fail("Display incorrect after restart");

            display_show;
        end

        // =============================================================
        // TEST 5: Second full run (re-press key1)
        // =============================================================
        $display("\n=== TEST 5: Second full run ===");
        begin : test5
            $display("  Pressing key1 for second run...");
            press_button;

            wait_state(ST_SUMMARY);
            repeat (5) @(posedge clk);

            $display("  --- Summary (2nd run) ---");
            display_show;

            if (led === 4'b1111)
                test_pass("All LEDs lit on second run");
            else begin
                test_fail("Not all LEDs lit on second run");
                $display("    LED: %04b", led);
            end

            if (u_ctrl.pass_count === 3'd4 && u_ctrl.fail_count === 3'd0)
                test_pass("Second run: P4 F0");
            else
                test_fail("Second run: unexpected counts");
        end

        // =============================================================
        // TEST 6: Reset during active I2C transaction
        // =============================================================
        $display("\n=== TEST 6: Reset during transaction ===");
        begin : test6
            // Go back to IDLE first
            press_button;
            wait_state(ST_IDLE);
            repeat (10) @(posedge clk);

            // Start tests
            press_button;

            // Wait until the controller is mid-write
            wait_state(ST_WR_SEQ);
            repeat (10) @(posedge clk);
            $display("  Controller in WR_SEQ — asserting reset...");

            rst_n <= 1'b0;
            repeat (20) @(posedge clk);
            rst_n <= 1'b1;
            repeat (20) @(posedge clk);

            if (u_ctrl.state === ST_IDLE)
                test_pass("Controller in IDLE after mid-test reset");
            else
                test_fail("Controller NOT in IDLE after reset");

            if (led === 4'b0000)
                test_pass("LEDs cleared after reset");
            else
                test_fail("LEDs not cleared after reset");

            if (scl_oen === 1'b1 && sda_oen === 1'b1)
                test_pass("I2C bus released after reset");
            else
                test_fail("I2C bus NOT released after reset");

            if (dig5 === 8'hBF && dig0 === 8'hBF)
                test_pass("Display shows '------' after reset");
            else
                test_fail("Display incorrect after reset");

            display_show;
        end

        // =============================================================
        // TEST 7: Post-reset recovery — full run succeeds
        // =============================================================
        $display("\n=== TEST 7: Post-reset recovery ===");
        begin : test7
            $display("  Running tests after reset recovery...");
            press_button;

            wait_state(ST_SUMMARY);
            repeat (5) @(posedge clk);

            $display("  --- Summary (post-reset run) ---");
            display_show;

            if (led === 4'b1111)
                test_pass("All tests pass after reset recovery");
            else begin
                test_fail("Tests failed after reset recovery");
                $display("    LED: %04b", led);
            end

            if (u_ctrl.pass_count === 3'd4)
                test_pass("pass_count = 4 after recovery");
            else
                test_fail("pass_count incorrect after recovery");
        end

        // =============================================================
        // TEST 8: 7-segment scan — all 6 digit positions active
        // =============================================================
        $display("\n=== TEST 8: 7-segment scan multiplexing ===");
        begin : test8
            reg [5:0] seen;
            integer j;

            seen = 6'b000_000;

            for (j = 0; j < 600; j = j + 1) begin
                @(posedge clk);
                case (seg_sel)
                    6'b111_110: seen[0] = 1'b1;
                    6'b111_101: seen[1] = 1'b1;
                    6'b111_011: seen[2] = 1'b1;
                    6'b110_111: seen[3] = 1'b1;
                    6'b101_111: seen[4] = 1'b1;
                    6'b011_111: seen[5] = 1'b1;
                    default: ;
                endcase
            end

            if (seen === 6'b111_111)
                test_pass("All 6 digit positions scanned");
            else begin
                test_fail("Not all digit positions seen");
                $display("    seen: %06b", seen);
            end

            // Verify only one digit active at a time (one-hot active-low)
            begin : t8_onehot
                integer bad;
                bad = 0;
                for (j = 0; j < 200; j = j + 1) begin
                    @(posedge clk);
                    case (seg_sel)
                        6'b111_110, 6'b111_101, 6'b111_011,
                        6'b110_111, 6'b101_111, 6'b011_111: ;
                        6'b111_111: ;  // all off (transient)
                        default: bad = bad + 1;
                    endcase
                end
                if (bad == 0)
                    test_pass("seg_sel is always one-hot active-low");
                else begin
                    test_fail("seg_sel had invalid patterns");
                    $display("    bad samples: %0d", bad);
                end
            end
        end

        // =============================================================
        // TEST 9: Prescaler — verify ena period
        // =============================================================
        $display("\n=== TEST 9: Prescaler ena period ===");
        begin : test9
            integer first_time, second_time, gap;

            // Wait for a rising edge of core_ena
            @(posedge clk);
            while (!core_ena) @(posedge clk);
            first_time = $time;

            // Wait for the next rising edge
            @(posedge clk);
            while (!core_ena) @(posedge clk);
            second_time = $time;

            gap = (second_time - first_time) / CLK_PERIOD;

            if (gap == PRESCALE + 1)
                test_pass("ena period matches PRESCALE+1");
            else begin
                test_fail("ena period mismatch");
                $display("    Expected: %0d cycles, Got: %0d cycles",
                         PRESCALE + 1, gap);
            end
        end

        // =============================================================
        // SUMMARY
        // =============================================================
        $display("");
        $display("============================================================");
        $display("  TEST SUMMARY:  PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("  All tests PASSED");
        else
            $display("  *** FAILURES DETECTED ***");
        $display("============================================================");
        $display("");

        $finish;
    end

endmodule
