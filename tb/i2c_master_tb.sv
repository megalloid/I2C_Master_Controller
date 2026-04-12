`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// I2C Master Controller — main testbench
//
// Instantiates DUT (i2c_master_top), I2C Slave model, AXI Master BFM.
// Self-checking test scenarios with $error / $fatal.
// ---------------------------------------------------------------------------
module i2c_master_tb;

    // ---------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------
    localparam CLK_PERIOD    = 10;           // 100 MHz
    localparam PRESCALE_VAL  = 16'd4;        // Fast prescaler for simulation
    localparam ADDR_WIDTH    = 5;
    localparam DATA_WIDTH    = 32;
    localparam [6:0] SLAVE_ADDR = 7'h50;

    // Register addresses
    localparam [ADDR_WIDTH-1:0]
        REG_CTRL     = 5'h00,
        REG_STATUS   = 5'h04,
        REG_CMD      = 5'h08,
        REG_TX_DATA  = 5'h0C,
        REG_RX_DATA  = 5'h10,
        REG_PRESCALE = 5'h14,
        REG_ISR      = 5'h18;

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
    reg rst_n;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---------------------------------------------------------------
    // I2C bus with pull-ups
    // ---------------------------------------------------------------
    wire sda, scl;
    pullup (sda);
    pullup (scl);

    // ---------------------------------------------------------------
    // AXI BFM wires
    // ---------------------------------------------------------------
    wire [ADDR_WIDTH-1:0]  axi_awaddr;
    wire                   axi_awvalid, axi_awready;
    wire [DATA_WIDTH-1:0]  axi_wdata;
    wire [DATA_WIDTH/8-1:0] axi_wstrb;
    wire                   axi_wvalid, axi_wready;
    wire [1:0]             axi_bresp;
    wire                   axi_bvalid, axi_bready;
    wire [ADDR_WIDTH-1:0]  axi_araddr;
    wire                   axi_arvalid, axi_arready;
    wire [DATA_WIDTH-1:0]  axi_rdata;
    wire [1:0]             axi_rresp;
    wire                   axi_rvalid, axi_rready;
    wire                   irq;

    // ---------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------
    i2c_master_top #(
        .C_S_AXI_DATA_WIDTH (DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (ADDR_WIDTH),
        .DEFAULT_PRESCALE   (PRESCALE_VAL)
    ) dut (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (rst_n),

        .s_axi_awaddr  (axi_awaddr),
        .s_axi_awvalid (axi_awvalid),
        .s_axi_awready (axi_awready),
        .s_axi_wdata   (axi_wdata),
        .s_axi_wstrb   (axi_wstrb),
        .s_axi_wvalid  (axi_wvalid),
        .s_axi_wready  (axi_wready),
        .s_axi_bresp   (axi_bresp),
        .s_axi_bvalid  (axi_bvalid),
        .s_axi_bready  (axi_bready),

        .s_axi_araddr  (axi_araddr),
        .s_axi_arvalid (axi_arvalid),
        .s_axi_arready (axi_arready),
        .s_axi_rdata   (axi_rdata),
        .s_axi_rresp   (axi_rresp),
        .s_axi_rvalid  (axi_rvalid),
        .s_axi_rready  (axi_rready),

        .irq_o         (irq),
        .sda_io        (sda),
        .scl_io        (scl)
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
    // AXI Master BFM
    // ---------------------------------------------------------------
    axi_lite_master_bfm #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) bfm (
        .clk             (clk),
        .rst_n           (rst_n),

        .m_axi_awaddr    (axi_awaddr),
        .m_axi_awvalid   (axi_awvalid),
        .m_axi_awready   (axi_awready),
        .m_axi_wdata     (axi_wdata),
        .m_axi_wstrb     (axi_wstrb),
        .m_axi_wvalid    (axi_wvalid),
        .m_axi_wready    (axi_wready),
        .m_axi_bresp     (axi_bresp),
        .m_axi_bvalid    (axi_bvalid),
        .m_axi_bready    (axi_bready),

        .m_axi_araddr    (axi_araddr),
        .m_axi_arvalid   (axi_arvalid),
        .m_axi_arready   (axi_arready),
        .m_axi_rdata     (axi_rdata),
        .m_axi_rresp     (axi_rresp),
        .m_axi_rvalid    (axi_rvalid),
        .m_axi_rready    (axi_rready)
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
                bfm.axi_read(REG_STATUS, rd_data);
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

            bfm.axi_write(REG_TX_DATA, {24'd0, slave_addr, 1'b0});
            bfm.axi_write(REG_CMD, CMD_STA | CMD_WR);
            wait_tip_clear();

            bfm.axi_read(REG_STATUS, rd_data);
            if (rd_data[1]) begin
                $error("  NACK on slave address");
                test_fail = test_fail + 1;
                disable wr_body;
            end

            bfm.axi_write(REG_TX_DATA, {24'd0, reg_addr});
            bfm.axi_write(REG_CMD, CMD_WR);
            wait_tip_clear();

            bfm.axi_write(REG_TX_DATA, {24'd0, data});
            bfm.axi_write(REG_CMD, CMD_WR | CMD_STO);
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

            bfm.axi_write(REG_TX_DATA, {24'd0, slave_addr, 1'b0});
            bfm.axi_write(REG_CMD, CMD_STA | CMD_WR);
            wait_tip_clear();

            bfm.axi_read(REG_STATUS, rd_data);
            if (rd_data[1]) begin
                $error("  NACK on slave address (write phase)");
                test_fail = test_fail + 1;
                disable rd_body;
            end

            bfm.axi_write(REG_TX_DATA, {24'd0, reg_addr});
            bfm.axi_write(REG_CMD, CMD_WR);
            wait_tip_clear();

            bfm.axi_write(REG_TX_DATA, {24'd0, slave_addr, 1'b1});
            bfm.axi_write(REG_CMD, CMD_STA | CMD_WR);
            wait_tip_clear();

            bfm.axi_read(REG_STATUS, rd_data);
            if (rd_data[1]) begin
                $error("  NACK on slave address (read phase)");
                test_fail = test_fail + 1;
                disable rd_body;
            end

            bfm.axi_write(REG_CMD, CMD_RD | CMD_NACK | CMD_STO);
            wait_tip_clear();

            bfm.axi_read(REG_RX_DATA, rd_data);
            data = rd_data[7:0];

            $display("[%0t] I2C READ complete: data=0x%02h", $time, data);
        end
    endtask

    // ---------------------------------------------------------------
    // Test scenarios
    // ---------------------------------------------------------------
    reg [7:0] read_val;

    initial begin
        $dumpfile("i2c_master_tb.vcd");
        $dumpvars(0, i2c_master_tb);

        test_pass = 0;
        test_fail = 0;

        // Reset
        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // -------------------------------------------------------
        // Test 0: Register access — prescaler read-back
        // -------------------------------------------------------
        $display("\n=== TEST 0: Register read-back ===");
        bfm.axi_read(REG_PRESCALE, rd_data);
        if (rd_data[15:0] !== PRESCALE_VAL) begin
            $error("  PRESCALE mismatch: got 0x%04h, expected 0x%04h",
                   rd_data[15:0], PRESCALE_VAL);
            test_fail = test_fail + 1;
        end else begin
            $display("  PRESCALE read-back OK: 0x%04h", rd_data[15:0]);
            test_pass = test_pass + 1;
        end

        // Enable core
        bfm.axi_write(REG_CTRL, 32'h03);  // EN=1, IEN=1
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
        // Test 2: Write multiple bytes, read back
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
        // Test 3: NACK on wrong slave address
        // -------------------------------------------------------
        $display("\n=== TEST 3: NACK on wrong slave address ===");
        bfm.axi_write(REG_TX_DATA, {24'd0, 7'h3F, 1'b0});  // Wrong address
        bfm.axi_write(REG_CMD, CMD_STA | CMD_WR);
        wait_tip_clear();
        bfm.axi_read(REG_STATUS, rd_data);
        if (rd_data[1]) begin
            $display("  PASS: Got NACK for wrong address as expected");
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: Expected NACK but got ACK");
            test_fail = test_fail + 1;
        end
        // Clean up: send STOP
        bfm.axi_write(REG_CMD, CMD_STO);
        wait_tip_clear();

        // -------------------------------------------------------
        // Test 4: Interrupt flag check
        // -------------------------------------------------------
        $display("\n=== TEST 4: Interrupt flags ===");
        // Clear ISR
        bfm.axi_write(REG_ISR, 32'h03);
        repeat (5) @(posedge clk);
        bfm.axi_read(REG_ISR, rd_data);
        if (rd_data[1:0] === 2'b00) begin
            $display("  PASS: ISR cleared");
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: ISR not cleared: 0x%02h", rd_data[1:0]);
            test_fail = test_fail + 1;
        end

        // Do a simple write — should set DONE interrupt
        i2c_write_byte(SLAVE_ADDR, 8'h30, 8'h42);
        repeat (20) @(posedge clk);
        bfm.axi_read(REG_ISR, rd_data);
        if (rd_data[0]) begin
            $display("  PASS: DONE interrupt set after write");
            test_pass = test_pass + 1;
        end else begin
            $error("  FAIL: DONE interrupt not set");
            test_fail = test_fail + 1;
        end
        // Clear it
        bfm.axi_write(REG_ISR, 32'h01);

        // -------------------------------------------------------
        // Test 5: Back-to-back transactions
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
        // Test 6: Reset during idle
        // -------------------------------------------------------
        $display("\n=== TEST 6: Reset recovery ===");
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        bfm.axi_write(REG_CTRL, 32'h03);
        repeat (5) @(posedge clk);

        // Verify controller still works
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
        // Test 7: Different prescaler value
        // -------------------------------------------------------
        $display("\n=== TEST 7: Prescaler change ===");
        bfm.axi_write(REG_CTRL, 32'h00);  // Disable
        bfm.axi_write(REG_PRESCALE, 32'h0002);  // Faster
        bfm.axi_write(REG_CTRL, 32'h03);  // Re-enable
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

        // Restore prescaler
        bfm.axi_write(REG_CTRL, 32'h00);
        bfm.axi_write(REG_PRESCALE, {16'd0, PRESCALE_VAL});
        bfm.axi_write(REG_CTRL, 32'h03);
        repeat (5) @(posedge clk);

        // -------------------------------------------------------
        // Summary
        // -------------------------------------------------------
        repeat (200) @(posedge clk);
        $display("\n============================================");
        $display("  TEST SUMMARY:  PASS=%0d  FAIL=%0d", test_pass, test_fail);
        $display("============================================\n");
        if (test_fail > 0)
            $fatal(1, "Some tests FAILED");
        else
            $display("All tests PASSED");

        $finish;
    end

    // ---------------------------------------------------------------
    // Watchdog — prevent infinite hang
    // ---------------------------------------------------------------
    initial begin
        #50_000_000;
        $fatal(1, "WATCHDOG: simulation timeout");
    end

endmodule
