`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// Testbench for i2c_master_core — direct command-level testing
//
// 10 test scenarios (14 checks):
//   1.  Single WRITE + ACK
//   2.  Single READ + NACK (write 0xA5, read back)
//   3.  Full transaction: START + WRITE addr + WRITE data + STOP
//   4.  Repeated START (RESTART)
//   5.  NACK from slave (wrong address) + recovery
//   6.  Clock stretching (via stretching slave at 0x51)
//   7.  Arbitration lost (4 checks: detect, release, block, clear)
//   8.  Reset during transaction + post-reset write/read
//   9.  CMD_NOP does nothing
//   10. Sequential read (4 bytes)
// ---------------------------------------------------------------------------
module i2c_core_tb;

    // ─── Parameters ───
    localparam CLK_PERIOD = 10;
    localparam ENA_DIV    = 4;
    localparam [6:0] SLAVE_ADDR       = 7'h50;
    localparam [6:0] SLAVE_ADDR_STR   = 7'h51;  // stretching slave
    localparam       STRETCH_CYCLES   = 80;
    localparam       TIMEOUT_LIMIT    = 200_000;

    localparam [2:0]
        CMD_NOP     = 3'd0,
        CMD_START   = 3'd1,
        CMD_WRITE   = 3'd2,
        CMD_READ    = 3'd3,
        CMD_STOP    = 3'd4,
        CMD_RESTART = 3'd5;

    // ─── Signals ───
    reg        clk, rstn;
    reg        ena;
    reg        cmd_valid;
    reg  [2:0] cmd;
    reg  [7:0] din;
    wire [7:0] dout;
    wire       rx_ack, ready;
    wire       arb_lost, busy;
    reg        arb_lost_clear;
    wire       scl_oen, sda_oen;

    // ─── I2C bus with pull-ups ───
    wire sda, scl;
    pullup (sda);
    pullup (scl);

    assign scl = scl_oen ? 1'bz : 1'b0;
    assign sda = sda_oen ? 1'bz : 1'b0;

    // External interferer for arbitration-lost test
    reg ext_sda_drive;
    assign sda = (ext_sda_drive) ? 1'b0 : 1'bz;

    wire scl_i = scl;
    wire sda_i = sda;

    // ─── Clock ───
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ─── ENA generator ───
    reg [7:0] ena_cnt;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            ena_cnt <= 0;
            ena     <= 0;
        end else begin
            if (ena_cnt == ENA_DIV - 1) begin
                ena_cnt <= 0;
                ena     <= 1;
            end else begin
                ena_cnt <= ena_cnt + 1;
                ena     <= 0;
            end
        end
    end

    // ─── DUT ───
    i2c_master_core dut (
        .clk_i            (clk),
        .rstn_i           (rstn),
        .ena_i            (ena),
        .cmd_valid_i      (cmd_valid),
        .cmd_i            (cmd),
        .din_i            (din),
        .dout_o           (dout),
        .rx_ack_o         (rx_ack),
        .ready_o          (ready),
        .arb_lost_o       (arb_lost),
        .arb_lost_clear_i (arb_lost_clear),
        .busy_o           (busy),
        .scl_i            (scl_i),
        .scl_oen_o        (scl_oen),
        .sda_i            (sda_i),
        .sda_oen_o        (sda_oen)
    );

    // ─── Normal slave (addr 0x50) ───
    i2c_slave_model #(.I2C_ADDR(SLAVE_ADDR)) slave (
        .sda_io (sda),
        .scl_io (scl)
    );

    // ─── Stretching slave (addr 0x51) ───
    i2c_slave_model #(.I2C_ADDR(SLAVE_ADDR_STR)) slave_str (
        .sda_io (sda),
        .scl_io (scl)
    );

    // SCL-hold logic for stretching slave
    reg scl_hold;
    assign scl = scl_hold ? 1'b0 : 1'bz;

    integer stretch_cnt;
    initial begin
        scl_hold    = 0;
        stretch_cnt = 0;
    end

    always @(negedge scl) begin
        if (slave_str.state == 4'd2 ||   // S_ADDR_ACK
            slave_str.state == 4'd4 ||   // S_REG_ACK
            slave_str.state == 4'd6) begin // S_WR_ACK
            scl_hold    <= 1;
            stretch_cnt <= STRETCH_CYCLES;
        end
    end

    always @(posedge clk) begin
        if (scl_hold && stretch_cnt > 0)
            stretch_cnt <= stretch_cnt - 1;
        else if (scl_hold && stretch_cnt == 0)
            scl_hold <= 0;
    end

    // ─── Counters ───
    integer pass_cnt, fail_cnt;

    // =====================================================================
    // Helper tasks
    // =====================================================================
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

    task send_cmd(input [2:0] c, input [7:0] d);
        integer wcnt;
        begin
            @(posedge clk);
            wcnt = 0;
            while (!ready) begin
                @(posedge clk);
                wcnt = wcnt + 1;
                if (wcnt > TIMEOUT_LIMIT) begin
                    test_fail("TIMEOUT waiting for ready before cmd");
                    disable send_cmd;
                end
            end
            cmd       <= c;
            din       <= d;
            cmd_valid <= 1;
            @(posedge clk);
            wcnt = 0;
            while (ready) begin
                @(posedge clk);
                wcnt = wcnt + 1;
                if (wcnt > TIMEOUT_LIMIT) begin
                    test_fail("TIMEOUT: ready never fell");
                    cmd_valid <= 0;
                    disable send_cmd;
                end
            end
            cmd_valid <= 0;
            cmd       <= CMD_NOP;
            wcnt = 0;
            while (!ready) begin
                @(posedge clk);
                wcnt = wcnt + 1;
                if (wcnt > TIMEOUT_LIMIT) begin
                    test_fail("TIMEOUT waiting for ready after cmd");
                    disable send_cmd;
                end
            end
        end
    endtask

    task do_start;
        begin send_cmd(CMD_START, 8'd0); end
    endtask

    task do_stop;
        begin send_cmd(CMD_STOP, 8'd0); end
    endtask

    task do_restart;
        begin send_cmd(CMD_RESTART, 8'd0); end
    endtask

    task do_write(input [7:0] data, output ack);
        begin
            send_cmd(CMD_WRITE, data);
            ack = rx_ack;
        end
    endtask

    task do_read(input nack_bit, output [7:0] data);
        begin
            send_cmd(CMD_READ, {7'd0, nack_bit});
            data = dout;
        end
    endtask

    // =====================================================================
    // Main test sequence
    // =====================================================================
    initial begin
        $dumpfile("i2c_core_tb.vcd");
        $dumpvars(0, i2c_core_tb);

        pass_cnt = 0;
        fail_cnt = 0;
        ext_sda_drive = 0;

        rstn           = 0;
        cmd_valid      = 0;
        cmd            = CMD_NOP;
        din            = 8'd0;
        arb_lost_clear = 0;

        repeat (20) @(posedge clk);
        rstn = 1;
        repeat (20) @(posedge clk);

        // =============================================================
        // TEST 1: Single WRITE + ACK
        // =============================================================
        $display("\n=== TEST 1: Single WRITE + ACK ===");
        begin : test1
            reg ack;
            do_start;
            do_write({SLAVE_ADDR, 1'b0}, ack);

            if (ack == 1'b0)
                test_pass("Slave ACK received (rx_ack_o = 0)");
            else
                test_fail("Expected ACK, got NACK");

            do_stop;
        end

        repeat (50) @(posedge clk);

        // =============================================================
        // TEST 2: Single READ + NACK (write 0xA5, read back)
        // =============================================================
        $display("\n=== TEST 2: Single READ + NACK ===");
        begin : test2
            reg ack;
            reg [7:0] rdata;

            do_start;
            do_write({SLAVE_ADDR, 1'b0}, ack);
            do_write(8'h10, ack);
            do_write(8'hA5, ack);
            do_stop;

            repeat (50) @(posedge clk);

            do_start;
            do_write({SLAVE_ADDR, 1'b0}, ack);
            do_write(8'h10, ack);
            do_restart;
            do_write({SLAVE_ADDR, 1'b1}, ack);
            do_read(1'b1, rdata);
            do_stop;

            if (rdata === 8'hA5)
                test_pass("Read 0xA5 matches written value");
            else
                test_fail("Read mismatch");
        end

        repeat (50) @(posedge clk);

        // =============================================================
        // TEST 3: Full transaction START + WRITE + WRITE + STOP
        // =============================================================
        $display("\n=== TEST 3: Full transaction ===");
        begin : test3
            reg ack1, ack2;

            do_start;

            if (busy !== 1'b1)
                test_fail("busy_o should be 1 after START");

            do_write({SLAVE_ADDR, 1'b0}, ack1);
            if (ack1 !== 1'b0)
                test_fail("Expected ACK on address byte");

            do_write(8'h42, ack2);
            if (ack2 !== 1'b0)
                test_fail("Expected ACK on data byte");

            do_stop;

            repeat (10) @(posedge clk);
            if (busy !== 1'b0)
                test_fail("busy_o should be 0 after STOP");
            else
                test_pass("Full transaction OK, busy cleared");
        end

        repeat (50) @(posedge clk);

        // =============================================================
        // TEST 4: Repeated START (RESTART)
        // =============================================================
        $display("\n=== TEST 4: Repeated START (RESTART) ===");
        begin : test4
            reg ack;
            reg [7:0] rdata;

            do_start;
            do_write({SLAVE_ADDR, 1'b0}, ack);
            do_write(8'h20, ack);
            do_write(8'hBE, ack);
            do_stop;

            repeat (50) @(posedge clk);

            do_start;
            do_write({SLAVE_ADDR, 1'b0}, ack);
            do_write(8'h20, ack);
            do_restart;

            if (busy !== 1'b1)
                test_fail("busy_o dropped during RESTART");

            do_write({SLAVE_ADDR, 1'b1}, ack);
            do_read(1'b1, rdata);
            do_stop;

            if (rdata === 8'hBE)
                test_pass("RESTART read-back OK");
            else
                test_fail("RESTART read-back mismatch");
        end

        repeat (50) @(posedge clk);

        // =============================================================
        // TEST 5: NACK from slave (wrong address) + recovery
        // =============================================================
        $display("\n=== TEST 5: NACK from slave ===");
        begin : test5
            reg ack;

            do_start;
            do_write({7'h3F, 1'b0}, ack);

            if (ack === 1'b1)
                test_pass("Got NACK for nonexistent address 0x3F");
            else
                test_fail("Expected NACK, got ACK for 0x3F");

            do_stop;

            repeat (10) @(posedge clk);
            if (busy !== 1'b0)
                test_fail("busy_o not cleared after NACK + STOP");

            // Recovery: normal address should still work
            do_start;
            do_write({SLAVE_ADDR, 1'b0}, ack);
            if (ack === 1'b0)
                test_pass("Normal ACK after NACK recovery");
            else
                test_fail("Controller stuck after NACK");
            do_stop;
        end

        repeat (50) @(posedge clk);

        // =============================================================
        // TEST 6: Clock stretching (via stretching slave at 0x51)
        // =============================================================
        $display("\n=== TEST 6: Clock stretching ===");
        begin : test6
            reg ack;
            reg [7:0] rdata;

            do_start;
            do_write({SLAVE_ADDR_STR, 1'b0}, ack);
            if (ack !== 1'b0) begin
                test_fail("Stretching slave NACK on address");
            end else begin
                do_write(8'h30, ack);
                do_write(8'hCD, ack);
                do_stop;

                repeat (50) @(posedge clk);

                do_start;
                do_write({SLAVE_ADDR_STR, 1'b0}, ack);
                do_write(8'h30, ack);
                do_restart;
                do_write({SLAVE_ADDR_STR, 1'b1}, ack);
                do_read(1'b1, rdata);
                do_stop;

                if (rdata === 8'hCD)
                    test_pass("Clock stretching handled OK");
                else
                    test_fail("Data corrupted after stretching");
            end
        end

        repeat (50) @(posedge clk);

        // =============================================================
        // TEST 7: Arbitration lost
        // =============================================================
        $display("\n=== TEST 7: Arbitration lost ===");
        begin : test7
            do_start;

            // Issue WRITE command manually to catch the right moment
            cmd       <= CMD_WRITE;
            din       <= {SLAVE_ADDR, 1'b0};   // 0xA0, MSB=1
            cmd_valid <= 1;
            @(posedge clk);
            begin : test7_wait_accept
                integer wc;
                wc = 0;
                while (ready) begin
                    @(posedge clk);
                    wc = wc + 1;
                    if (wc > TIMEOUT_LIMIT) begin
                        test_fail("TIMEOUT waiting for core to accept WRITE");
                        disable test7;
                    end
                end
            end
            cmd_valid <= 0;

            // Wait for DATA state phase 0 (core sets up SDA)
            begin : test7_wait_data
                integer wc;
                wc = 0;
                while (!(dut.state_r == 3'd2 && dut.phase_r == 2'd0)) begin
                    @(posedge clk);
                    wc = wc + 1;
                    if (wc > TIMEOUT_LIMIT) begin
                        test_fail("TIMEOUT waiting for DATA phase 0");
                        disable test7;
                    end
                end
            end
            @(posedge clk);

            // Interfere: pull SDA low externally
            ext_sda_drive <= 1;

            begin : test7_wait_arb
                integer wc;
                wc = 0;
                while (arb_lost !== 1'b1) begin
                    @(posedge clk);
                    wc = wc + 1;
                    if (wc > TIMEOUT_LIMIT) begin
                        test_fail("TIMEOUT waiting for arb_lost");
                        ext_sda_drive <= 0;
                        disable test7;
                    end
                end
            end
            ext_sda_drive <= 0;

            if (arb_lost === 1'b1)
                test_pass("Arbitration lost detected");
            else
                test_fail("Arbitration lost NOT detected");

            if (dut.scl_oen_o === 1'b1 && dut.sda_oen_o === 1'b1)
                test_pass("Bus released after arb_lost");
            else
                test_fail("Bus NOT released after arb_lost");

            // Core should ignore commands while arb_lost=1
            cmd_valid <= 1;
            cmd       <= CMD_START;
            repeat (20) @(posedge clk);
            if (ready === 1'b1)
                test_pass("Core ignores commands while arb_lost=1");
            else
                test_fail("Core accepted command despite arb_lost=1");
            cmd_valid <= 0;
            cmd       <= CMD_NOP;

            // Clear arb_lost
            arb_lost_clear <= 1;
            @(posedge clk);
            arb_lost_clear <= 0;
            repeat (5) @(posedge clk);

            if (arb_lost === 1'b0)
                test_pass("arb_lost cleared");
            else
                test_fail("arb_lost NOT cleared");

            do_stop;
        end

        repeat (50) @(posedge clk);

        // =============================================================
        // TEST 8: Reset during transaction
        // =============================================================
        $display("\n=== TEST 8: Reset during transaction ===");
        begin : test8
            reg ack;
            reg [7:0] rdata;

            do_start;

            cmd       <= CMD_WRITE;
            din       <= {SLAVE_ADDR, 1'b0};
            cmd_valid <= 1;
            @(posedge clk);
            begin : test8_wait
                integer wc;
                wc = 0;
                while (ready) begin
                    @(posedge clk);
                    wc = wc + 1;
                    if (wc > TIMEOUT_LIMIT) begin
                        test_fail("TIMEOUT in reset test setup");
                        disable test8;
                    end
                end
            end
            cmd_valid <= 0;

            // Let 3-4 bits transmit
            repeat (4) begin : test8_bits
                integer wc;
                wc = 0;
                while (dut.phase_r != 2'd3) begin
                    @(posedge clk);
                    wc = wc + 1;
                    if (wc > TIMEOUT_LIMIT) begin
                        test_fail("TIMEOUT waiting for phase 3");
                        disable test8;
                    end
                end
                @(posedge clk);
            end

            // Assert reset
            rstn <= 0;
            repeat (10) @(posedge clk);
            rstn <= 1;
            repeat (20) @(posedge clk);

            // Check post-reset state
            if (dut.state_r !== 3'd0)
                test_fail("state_r not IDLE after reset");
            if (dut.scl_oen_o !== 1'b1 || dut.sda_oen_o !== 1'b1)
                test_fail("Bus not released after reset");
            if (ready !== 1'b1)
                test_fail("ready_o not 1 after reset");
            if (busy !== 1'b0)
                test_fail("busy_o not 0 after reset");
            if (arb_lost !== 1'b0)
                test_fail("arb_lost_o not 0 after reset");

            // Verify core works after reset
            do_start;
            do_write({SLAVE_ADDR, 1'b0}, ack);
            if (ack !== 1'b0)
                test_fail("NACK after reset — controller broken");

            do_write(8'h70, ack);
            do_write(8'hEE, ack);
            do_stop;

            repeat (50) @(posedge clk);

            do_start;
            do_write({SLAVE_ADDR, 1'b0}, ack);
            do_write(8'h70, ack);
            do_restart;
            do_write({SLAVE_ADDR, 1'b1}, ack);
            do_read(1'b1, rdata);
            do_stop;

            if (rdata === 8'hEE)
                test_pass("Post-reset write/read OK");
            else
                test_fail("Post-reset data mismatch");
        end

        repeat (50) @(posedge clk);

        // =============================================================
        // TEST 9: CMD_NOP does nothing
        // =============================================================
        $display("\n=== TEST 9: CMD_NOP ===");
        begin : test9
            // NOP is ignored: ready stays 1, state stays IDLE
            @(posedge clk);
            cmd       <= CMD_NOP;
            din       <= 8'hFF;
            cmd_valid <= 1;
            repeat (20) @(posedge clk);
            cmd_valid <= 0;
            cmd       <= CMD_NOP;

            if (dut.state_r === 3'd0 && ready === 1'b1)
                test_pass("NOP: state stayed IDLE, ready=1");
            else
                test_fail("NOP: unexpected state change");
        end

        repeat (50) @(posedge clk);

        // =============================================================
        // TEST 10: Sequential read (4 bytes)
        // =============================================================
        $display("\n=== TEST 10: Sequential read (4 bytes) ===");
        begin : test10
            reg ack;
            reg [7:0] r0, r1, r2, r3;
            integer seq_ok;

            // Slave memory is initialized as mem[i] = i.
            // Read from address 0x00.
            do_start;
            do_write({SLAVE_ADDR, 1'b0}, ack);
            do_write(8'h00, ack);
            do_restart;
            do_write({SLAVE_ADDR, 1'b1}, ack);

            do_read(1'b0, r0);  // ACK
            do_read(1'b0, r1);  // ACK
            do_read(1'b0, r2);  // ACK
            do_read(1'b1, r3);  // NACK

            do_stop;

            seq_ok = (r0 === 8'h00) && (r1 === 8'h01) &&
                     (r2 === 8'h02) && (r3 === 8'h03);

            if (seq_ok)
                test_pass("Sequential read 00,01,02,03 OK");
            else begin
                $display("    got: %02h %02h %02h %02h", r0, r1, r2, r3);
                test_fail("Sequential read mismatch");
            end
        end

        repeat (50) @(posedge clk);

        // =============================================================
        // SUMMARY
        // =============================================================
        $display("\n========================================");
        $display("  TEST SUMMARY:  PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("  All tests PASSED");
        else
            $display("  *** FAILURES DETECTED ***");
        $display("========================================\n");

        $finish;
    end

    // Watchdog
    initial begin
        #(TIMEOUT_LIMIT * CLK_PERIOD * 20);
        $display("WATCHDOG: simulation timeout");
        $finish;
    end

endmodule
