`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// I2C Master Controller — Cyclone IV testbench (Avalon-MM)
//
// Same test scenarios as AXI version, but using Avalon-MM BFM
// and i2c_master_top_c4 DUT.
// ---------------------------------------------------------------------------
module i2c_master_c4_tb;

    // ---------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------
    localparam CLK_PERIOD    = 20;           // 50 MHz (typical Cyclone IV)
    localparam PRESCALE_VAL  = 16'd4;        // Fast for simulation
    localparam ADDR_WIDTH    = 3;
    localparam DATA_WIDTH    = 32;
    localparam [6:0] SLAVE_ADDR = 7'h50;

    // Register word-addresses (byte addr / 4)
    localparam [ADDR_WIDTH-1:0]
        REG_CTRL     = 3'd0,
        REG_STATUS   = 3'd1,
        REG_CMD      = 3'd2,
        REG_TX_DATA  = 3'd3,
        REG_RX_DATA  = 3'd4,
        REG_PRESCALE = 3'd5,
        REG_ISR      = 3'd6;

    // CMD bits
    localparam CMD_STA  = 32'h01;
    localparam CMD_STO  = 32'h02;
    localparam CMD_RD   = 32'h04;
    localparam CMD_WR   = 32'h08;
    localparam CMD_NACK = 32'h10;

    // ---------------------------------------------------------------
    // Clock and reset
    // ---------------------------------------------------------------
    reg clk;
    reg reset_n;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---------------------------------------------------------------
    // I2C bus with pull-ups
    // ---------------------------------------------------------------
    wire sda, scl;
    pullup (sda);
    pullup (scl);

    // ---------------------------------------------------------------
    // Avalon BFM wires
    // ---------------------------------------------------------------
    wire [ADDR_WIDTH-1:0]  avs_address;
    wire                   avs_read;
    wire [DATA_WIDTH-1:0]  avs_readdata;
    wire                   avs_write;
    wire [DATA_WIDTH-1:0]  avs_writedata;
    wire [DATA_WIDTH/8-1:0] avs_byteenable;
    wire                   avs_waitrequest;
    wire                   irq;

    // ---------------------------------------------------------------
    // DUT — Cyclone IV top
    // ---------------------------------------------------------------
    i2c_master_top_c4 #(
        .DEFAULT_PRESCALE (PRESCALE_VAL)
    ) dut (
        .clk             (clk),
        .reset_n         (reset_n),

        .avs_address     (avs_address),
        .avs_read        (avs_read),
        .avs_readdata    (avs_readdata),
        .avs_write       (avs_write),
        .avs_writedata   (avs_writedata),
        .avs_byteenable  (avs_byteenable),
        .avs_waitrequest (avs_waitrequest),

        .irq_o           (irq),
        .sda_io          (sda),
        .scl_io          (scl)
    );

    // ---------------------------------------------------------------
    // I2C Slave model
    // ---------------------------------------------------------------
    i2c_slave_model #(
        .I2C_ADDR (SLAVE_ADDR)
    ) slave (
        .sda_io (sda),
        .scl_io (scl)
    );

    // ---------------------------------------------------------------
    // Avalon-MM Master BFM
    // ---------------------------------------------------------------
    avalon_mm_master_bfm #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) bfm (
        .clk              (clk),
        .reset_n          (reset_n),

        .m_avs_address    (avs_address),
        .m_avs_read       (avs_read),
        .m_avs_readdata   (avs_readdata),
        .m_avs_write      (avs_write),
        .m_avs_writedata  (avs_writedata),
        .m_avs_byteenable (avs_byteenable),
        .m_avs_waitrequest(avs_waitrequest)
    );

    // ---------------------------------------------------------------
    // Helper tasks
    // ---------------------------------------------------------------
    reg [DATA_WIDTH-1:0] rd_data;
    integer test_pass, test_fail;

    task wait_tip_clear;
        integer timeout;
        begin
            timeout = 0;
            rd_data = 32'h1;
            while (rd_data[0] && timeout < 5000) begin
                bfm.avl_read(REG_STATUS, rd_data);
                timeout = timeout + 1;
            end
            if (timeout >= 5000)
                $error("TIMEOUT: TIP did not clear");
        end
    endtask

    task i2c_write_byte(
        input [6:0] slave_addr,
        input [7:0] reg_addr,
        input [7:0] data
    );
        begin : wr_body
            $display("[%0t] I2C WRITE: slave=0x%02h reg=0x%02h data=0x%02h",
                     $time, slave_addr, reg_addr, data);

            bfm.avl_write(REG_TX_DATA, {24'd0, slave_addr, 1'b0});
            bfm.avl_write(REG_CMD, CMD_STA | CMD_WR);
            wait_tip_clear();

            bfm.avl_read(REG_STATUS, rd_data);
            if (rd_data[1]) begin
                $error("  NACK on slave address");
                test_fail = test_fail + 1;
                disable wr_body;
            end

            bfm.avl_write(REG_TX_DATA, {24'd0, reg_addr});
            bfm.avl_write(REG_CMD, CMD_WR);
            wait_tip_clear();

            bfm.avl_write(REG_TX_DATA, {24'd0, data});
            bfm.avl_write(REG_CMD, CMD_WR | CMD_STO);
            wait_tip_clear();

            $display("[%0t] I2C WRITE complete", $time);
        end
    endtask

    task i2c_read_byte(
        input  [6:0] slave_addr,
        input  [7:0] reg_addr,
        output [7:0] data
    );
        begin : rd_body
            data = 8'hFF;
            $display("[%0t] I2C READ: slave=0x%02h reg=0x%02h",
                     $time, slave_addr, reg_addr);

            bfm.avl_write(REG_TX_DATA, {24'd0, slave_addr, 1'b0});
            bfm.avl_write(REG_CMD, CMD_STA | CMD_WR);
            wait_tip_clear();

            bfm.avl_read(REG_STATUS, rd_data);
            if (rd_data[1]) begin
                $error("  NACK on slave address (write phase)");
                test_fail = test_fail + 1;
                disable rd_body;
            end

            bfm.avl_write(REG_TX_DATA, {24'd0, reg_addr});
            bfm.avl_write(REG_CMD, CMD_WR);
            wait_tip_clear();

            bfm.avl_write(REG_TX_DATA, {24'd0, slave_addr, 1'b1});
            bfm.avl_write(REG_CMD, CMD_STA | CMD_WR);
            wait_tip_clear();

            bfm.avl_read(REG_STATUS, rd_data);
            if (rd_data[1]) begin
                $error("  NACK on slave address (read phase)");
                test_fail = test_fail + 1;
                disable rd_body;
            end

            bfm.avl_write(REG_CMD, CMD_RD | CMD_NACK | CMD_STO);
            wait_tip_clear();

            bfm.avl_read(REG_RX_DATA, rd_data);
            data = rd_data[7:0];

            $display("[%0t] I2C READ complete: data=0x%02h", $time, data);
        end
    endtask

    // ---------------------------------------------------------------
    // Test scenarios
    // ---------------------------------------------------------------
    reg [7:0] read_val;

    initial begin
        $dumpfile("i2c_master_c4_tb.vcd");
        $dumpvars(0, i2c_master_c4_tb);

        test_pass = 0;
        test_fail = 0;

        // Reset
        reset_n = 0;
        repeat (20) @(posedge clk);
        reset_n = 1;
        repeat (10) @(posedge clk);

        // -------------------------------------------------------
        // Test 0: Prescaler read-back
        // -------------------------------------------------------
        $display("\n=== TEST 0: Register read-back ===");
        bfm.avl_read(REG_PRESCALE, rd_data);
        if (rd_data[15:0] !== PRESCALE_VAL) begin
            $error("  PRESCALE mismatch: got 0x%04h, expected 0x%04h",
                   rd_data[15:0], PRESCALE_VAL);
            test_fail = test_fail + 1;
        end else begin
            $display("  PRESCALE read-back OK: 0x%04h", rd_data[15:0]);
            test_pass = test_pass + 1;
        end

        // Enable core
        bfm.avl_write(REG_CTRL, 32'h03);
        repeat (5) @(posedge clk);

        // -------------------------------------------------------
        // Test 1: Single byte write + read-back
        // -------------------------------------------------------
        $display("\n=== TEST 1: Single byte write + read-back ===");
        i2c_write_byte(SLAVE_ADDR, 8'h10, 8'hA5);
        repeat (100) @(posedge clk);

        i2c_read_byte(SLAVE_ADDR, 8'h10, read_val);
        if (read_val === 8'hA5) begin
            $display("  PASS: read 0x%02h == expected 0xA5", read_val);
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: read 0x%02h != expected 0xA5", read_val);
            test_fail = test_fail + 1;
        end

        // -------------------------------------------------------
        // Test 2: Multi-byte write + read
        // -------------------------------------------------------
        $display("\n=== TEST 2: Multi-byte write + read-back ===");
        i2c_write_byte(SLAVE_ADDR, 8'h20, 8'hDE);
        repeat (100) @(posedge clk);
        i2c_write_byte(SLAVE_ADDR, 8'h21, 8'hAD);
        repeat (100) @(posedge clk);

        i2c_read_byte(SLAVE_ADDR, 8'h20, read_val);
        if (read_val === 8'hDE) begin
            $display("  PASS: addr 0x20 = 0x%02h", read_val);
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: addr 0x20 = 0x%02h, expected 0xDE", read_val);
            test_fail = test_fail + 1;
        end

        repeat (100) @(posedge clk);
        i2c_read_byte(SLAVE_ADDR, 8'h21, read_val);
        if (read_val === 8'hAD) begin
            $display("  PASS: addr 0x21 = 0x%02h", read_val);
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: addr 0x21 = 0x%02h, expected 0xAD", read_val);
            test_fail = test_fail + 1;
        end

        // -------------------------------------------------------
        // Test 3: NACK on wrong address
        // -------------------------------------------------------
        $display("\n=== TEST 3: NACK on wrong slave address ===");
        bfm.avl_write(REG_TX_DATA, {24'd0, 7'h3F, 1'b0});
        bfm.avl_write(REG_CMD, CMD_STA | CMD_WR);
        wait_tip_clear();
        bfm.avl_read(REG_STATUS, rd_data);
        if (rd_data[1]) begin
            $display("  PASS: Got NACK for wrong address as expected");
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: Expected NACK but got ACK");
            test_fail = test_fail + 1;
        end
        bfm.avl_write(REG_CMD, CMD_STO);
        wait_tip_clear();

        // -------------------------------------------------------
        // Test 4: Interrupt flags
        // -------------------------------------------------------
        $display("\n=== TEST 4: Interrupt flags ===");
        bfm.avl_write(REG_ISR, 32'h03);
        repeat (5) @(posedge clk);
        bfm.avl_read(REG_ISR, rd_data);
        if (rd_data[1:0] === 2'b00) begin
            $display("  PASS: ISR cleared");
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: ISR not cleared: 0x%02h", rd_data[1:0]);
            test_fail = test_fail + 1;
        end

        i2c_write_byte(SLAVE_ADDR, 8'h30, 8'h42);
        repeat (20) @(posedge clk);
        bfm.avl_read(REG_ISR, rd_data);
        if (rd_data[0]) begin
            $display("  PASS: DONE interrupt set after write");
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: DONE interrupt not set");
            test_fail = test_fail + 1;
        end
        bfm.avl_write(REG_ISR, 32'h01);

        // -------------------------------------------------------
        // Test 5: Back-to-back
        // -------------------------------------------------------
        $display("\n=== TEST 5: Back-to-back write + read ===");
        i2c_write_byte(SLAVE_ADDR, 8'h40, 8'h55);
        i2c_read_byte(SLAVE_ADDR, 8'h40, read_val);
        if (read_val === 8'h55) begin
            $display("  PASS: back-to-back OK: 0x%02h", read_val);
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: back-to-back: 0x%02h != 0x55", read_val);
            test_fail = test_fail + 1;
        end

        // -------------------------------------------------------
        // Test 6: Reset recovery
        // -------------------------------------------------------
        $display("\n=== TEST 6: Reset recovery ===");
        reset_n = 0;
        repeat (10) @(posedge clk);
        reset_n = 1;
        repeat (10) @(posedge clk);
        bfm.avl_write(REG_CTRL, 32'h03);
        repeat (5) @(posedge clk);

        i2c_write_byte(SLAVE_ADDR, 8'h50, 8'hBB);
        repeat (100) @(posedge clk);
        i2c_read_byte(SLAVE_ADDR, 8'h50, read_val);
        if (read_val === 8'hBB) begin
            $display("  PASS: post-reset OK: 0x%02h", read_val);
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: post-reset: 0x%02h != 0xBB", read_val);
            test_fail = test_fail + 1;
        end

        // -------------------------------------------------------
        // Test 7: Prescaler change
        // -------------------------------------------------------
        $display("\n=== TEST 7: Prescaler change ===");
        bfm.avl_write(REG_CTRL, 32'h00);
        bfm.avl_write(REG_PRESCALE, 32'h0002);
        bfm.avl_write(REG_CTRL, 32'h03);
        repeat (5) @(posedge clk);

        i2c_write_byte(SLAVE_ADDR, 8'h60, 8'hCC);
        repeat (100) @(posedge clk);
        i2c_read_byte(SLAVE_ADDR, 8'h60, read_val);
        if (read_val === 8'hCC) begin
            $display("  PASS: different prescaler OK: 0x%02h", read_val);
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: different prescaler: 0x%02h != 0xCC", read_val);
            test_fail = test_fail + 1;
        end

        bfm.avl_write(REG_CTRL, 32'h00);
        bfm.avl_write(REG_PRESCALE, {16'd0, PRESCALE_VAL});
        bfm.avl_write(REG_CTRL, 32'h03);
        repeat (5) @(posedge clk);

        // -------------------------------------------------------
        // Summary
        // -------------------------------------------------------
        repeat (200) @(posedge clk);
        $display("\n============================================");
        $display("  CYCLONE IV TB SUMMARY:  PASS=%0d  FAIL=%0d", test_pass, test_fail);
        $display("============================================\n");
        if (test_fail > 0)
            $fatal(1, "Some tests FAILED");
        else
            $display("All tests PASSED");

        $finish;
    end

    // ---------------------------------------------------------------
    // Watchdog
    // ---------------------------------------------------------------
    initial begin
        #100_000_000;
        $fatal(1, "WATCHDOG: simulation timeout");
    end

endmodule
