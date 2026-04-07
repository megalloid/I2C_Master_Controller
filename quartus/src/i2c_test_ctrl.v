`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// I2C EEPROM Test Controller
//
// Runs 4 write+readback tests on a 24LC04 EEPROM (block 0, addr 0xA0/A1).
// Triggered by 'start' pulse (button press). Results shown on 7-segment
// display (6 digits) and LEDs (1 LED per test).
//
// Display format (left → right, digits 5..0):
//   IDLE:    "------"
//   Running: "N - W W - -"   (N=test, WW=write data hex)
//   Result:  "N P W W R R"   (P/F = pass/fail, RR=read data hex)
//   Summary: "P n   F n  "   (n = count)
//
// LED[k] = 1 if test k passed.
// ---------------------------------------------------------------------------
module i2c_test_ctrl #(
    parameter SHOW_TICKS = 25_000_000, // display pause per test (500 ms @ 50 MHz)
    parameter WR_TICKS   = 300_000     // EEPROM write cycle delay (6 ms @ 50 MHz)
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    // i2c_master_core command interface
    output reg         cmd_valid,
    output reg  [2:0]  cmd,
    output reg  [7:0]  din,
    input  wire [7:0]  dout,
    input  wire        rx_ack,
    input  wire        ready,
    input  wire        arb_lost,
    output reg         arb_lost_clr,

    // 7-segment digit data (active-low, bit 7 = DP)
    output reg  [7:0]  seg5, seg4, seg3, seg2, seg1, seg0,

    // LED outputs (active-high: 1 = lit)
    output reg  [3:0]  led
);

    // ----- I2C command codes (must match i2c_master_core) -----
    localparam [2:0]
        I2C_START   = 3'd1,
        I2C_WRITE   = 3'd2,
        I2C_READ    = 3'd3,
        I2C_STOP    = 3'd4,
        I2C_RESTART = 3'd5;

    localparam [7:0] SLAVE_W = 8'hA0;  // 24LC04 block 0 write
    localparam [7:0] SLAVE_R = 8'hA1;  // 24LC04 block 0 read

    // ----- 7-segment character patterns (active-low) -----
    localparam [7:0]
        S_BLK = 8'hFF,                       // blank
        S_DSH = {1'b1, 7'b011_1111},         // '-'
        S_P   = {1'b1, 7'b000_1100},         // 'P'
        S_FC  = {1'b1, 7'b000_1110};         // 'F'

    function [7:0] seg_hex;
        input [3:0] h;
        reg [6:0] s;
        begin
            case (h) // synopsys full_case parallel_case
                4'h0: s = 7'b100_0000; // verilator lint_off BLKSEQ
                4'h1: s = 7'b111_1001;
                4'h2: s = 7'b010_0100;
                4'h3: s = 7'b011_0000;
                4'h4: s = 7'b001_1001;
                4'h5: s = 7'b001_0010;
                4'h6: s = 7'b000_0010;
                4'h7: s = 7'b111_1000;
                4'h8: s = 7'b000_0000;
                4'h9: s = 7'b001_0000;
                4'hA: s = 7'b000_1000;
                4'hB: s = 7'b000_0011;
                4'hC: s = 7'b100_0110;
                4'hD: s = 7'b010_0001;
                4'hE: s = 7'b000_0110;
                4'hF: s = 7'b000_1110; // verilator lint_on BLKSEQ
                default: s = 7'b111_1111;
            endcase
            seg_hex = {1'b1, s};        // verilator lint_off BLKSEQ
        end                             // verilator lint_on BLKSEQ
    endfunction

    // ----- Test ROM: {reg_addr[7:0], write_data[7:0]} -----
    localparam NUM_TESTS = 4;
    reg [7:0] tst_addr;
    reg [7:0] tst_data;

    always @(*) begin
        case (test_idx)
            2'd0: begin tst_addr = 8'h00; tst_data = 8'hA5; end
            2'd1: begin tst_addr = 8'h01; tst_data = 8'h5A; end
            2'd2: begin tst_addr = 8'h10; tst_data = 8'hFF; end
            2'd3: begin tst_addr = 8'h11; tst_data = 8'h00; end
            default: begin tst_addr = 8'h00; tst_data = 8'h00; end
        endcase
    end

    // ----- FSM states -----
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

    localparam [1:0]
        SS_ISSUE  = 2'd0,
        SS_ACCEPT = 2'd1,
        SS_DONE   = 2'd2;

    reg [3:0]  state;
    reg [1:0]  sub;
    reg [2:0]  step;         // command step within write/read sequence
    reg [1:0]  test_idx;     // current test (0..3)
    reg [31:0] delay_cnt;
    reg [7:0]  rd_data;      // data read back from EEPROM
    reg [3:0]  pass_flags;
    reg [3:0]  fail_flags;
    reg        test_error;   // flag: current test failed

    // ----- Pass/fail counters for summary display -----
    wire [2:0] pass_count = {2'd0, pass_flags[0]} + {2'd0, pass_flags[1]}
                          + {2'd0, pass_flags[2]} + {2'd0, pass_flags[3]};
    wire [2:0] fail_count = {2'd0, fail_flags[0]} + {2'd0, fail_flags[1]}
                          + {2'd0, fail_flags[2]} + {2'd0, fail_flags[3]};

    // ----- Write sequence command generator (5 steps: 0-4) -----
    reg [2:0] wr_cmd;
    reg [7:0] wr_din;
    always @(*) begin
        case (step)
            3'd0: begin wr_cmd = I2C_START; wr_din = 8'h00;    end
            3'd1: begin wr_cmd = I2C_WRITE; wr_din = SLAVE_W;   end
            3'd2: begin wr_cmd = I2C_WRITE; wr_din = tst_addr;  end
            3'd3: begin wr_cmd = I2C_WRITE; wr_din = tst_data;  end
            3'd4: begin wr_cmd = I2C_STOP;  wr_din = 8'h00;     end
            default: begin wr_cmd = I2C_STOP; wr_din = 8'h00;   end
        endcase
    end

    // ----- Read sequence command generator (7 steps: 0-6) -----
    reg [2:0] rd_cmd;
    reg [7:0] rd_din;
    always @(*) begin
        case (step)
            3'd0: begin rd_cmd = I2C_START;   rd_din = 8'h00;          end
            3'd1: begin rd_cmd = I2C_WRITE;   rd_din = SLAVE_W;        end
            3'd2: begin rd_cmd = I2C_WRITE;   rd_din = tst_addr;       end
            3'd3: begin rd_cmd = I2C_RESTART;  rd_din = 8'h00;          end
            3'd4: begin rd_cmd = I2C_WRITE;   rd_din = SLAVE_R;        end
            3'd5: begin rd_cmd = I2C_READ;    rd_din = {7'd0, 1'b1};   end // NACK
            3'd6: begin rd_cmd = I2C_STOP;    rd_din = 8'h00;          end
            default: begin rd_cmd = I2C_STOP; rd_din = 8'h00;          end
        endcase
    end

    // Write steps that require ACK check (slave must ACK)
    wire wr_check_ack = (step == 3'd1 || step == 3'd2 || step == 3'd3);
    // Read steps that require ACK check
    wire rd_check_ack = (step == 3'd1 || step == 3'd2 || step == 3'd4);

    // ----- Display update task (active display depends on state) -----
    task display_idle;
        begin
            seg5 <= S_DSH; seg4 <= S_DSH; seg3 <= S_DSH;
            seg2 <= S_DSH; seg1 <= S_DSH; seg0 <= S_DSH;
        end
    endtask

    task display_running;
        begin
            seg5 <= seg_hex({2'b0, test_idx} + 4'd1);
            seg4 <= S_DSH;
            seg3 <= seg_hex(tst_data[7:4]);
            seg2 <= seg_hex(tst_data[3:0]);
            seg1 <= S_DSH;
            seg0 <= S_DSH;
        end
    endtask

    task display_result;
        begin
            seg5 <= seg_hex({2'b0, test_idx} + 4'd1);
            seg4 <= test_error ? S_FC : S_P;
            seg3 <= seg_hex(tst_data[7:4]);
            seg2 <= seg_hex(tst_data[3:0]);
            seg1 <= seg_hex(rd_data[7:4]);
            seg0 <= seg_hex(rd_data[3:0]);
        end
    endtask

    // ----- Main FSM -----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            sub         <= SS_ISSUE;
            step        <= 3'd0;
            test_idx    <= 2'd0;
            delay_cnt   <= 32'd0;
            cmd_valid   <= 1'b0;
            cmd         <= 3'd0;
            din         <= 8'd0;
            arb_lost_clr <= 1'b0;
            rd_data     <= 8'd0;
            pass_flags  <= 4'd0;
            fail_flags  <= 4'd0;
            test_error  <= 1'b0;
            led         <= 4'b0000;
            seg5 <= S_DSH; seg4 <= S_DSH; seg3 <= S_DSH;
            seg2 <= S_DSH; seg1 <= S_DSH; seg0 <= S_DSH;
        end else begin
            arb_lost_clr <= 1'b0;

            case (state)

            // ===== IDLE =====
            ST_IDLE: begin
                display_idle;
                if (start) begin
                    test_idx   <= 2'd0;
                    pass_flags <= 4'd0;
                    fail_flags <= 4'd0;
                    led        <= 4'b0000;
                    state      <= ST_PREP;
                end
            end

            // ===== PREP: setup for current test =====
            ST_PREP: begin
                step       <= 3'd0;
                sub        <= SS_ISSUE;
                test_error <= 1'b0;
                arb_lost_clr <= 1'b1;
                display_running;
                state      <= ST_WR_SEQ;
            end

            // ===== WRITE SEQUENCE (5 steps: 0-4) =====
            ST_WR_SEQ: begin
                case (sub)
                    SS_ISSUE: begin
                        if (ready) begin
                            cmd_valid <= 1'b1;
                            cmd       <= wr_cmd;
                            din       <= wr_din;
                            sub       <= SS_ACCEPT;
                        end
                    end
                    SS_ACCEPT: begin
                        if (!ready) begin
                            cmd_valid <= 1'b0;
                            sub       <= SS_DONE;
                        end
                    end
                    SS_DONE: begin
                        if (ready) begin
                            if (wr_check_ack && rx_ack) begin
                                test_error <= 1'b1;
                                state <= ST_ERR_STOP;
                                sub   <= SS_ISSUE;
                            end else if (step == 3'd4) begin
                                delay_cnt <= 32'd0;
                                state     <= ST_WR_DELAY;
                            end else begin
                                step <= step + 3'd1;
                                sub  <= SS_ISSUE;
                            end
                        end
                    end
                    default: sub <= SS_ISSUE;
                endcase
            end

            // ===== WRITE DELAY (EEPROM write cycle) =====
            ST_WR_DELAY: begin
                if (delay_cnt >= WR_TICKS) begin
                    step  <= 3'd0;
                    sub   <= SS_ISSUE;
                    state <= ST_RD_SEQ;
                end else begin
                    delay_cnt <= delay_cnt + 32'd1;
                end
            end

            // ===== READ SEQUENCE (7 steps: 0-6) =====
            ST_RD_SEQ: begin
                case (sub)
                    SS_ISSUE: begin
                        if (ready) begin
                            cmd_valid <= 1'b1;
                            cmd       <= rd_cmd;
                            din       <= rd_din;
                            sub       <= SS_ACCEPT;
                        end
                    end
                    SS_ACCEPT: begin
                        if (!ready) begin
                            cmd_valid <= 1'b0;
                            sub       <= SS_DONE;
                        end
                    end
                    SS_DONE: begin
                        if (ready) begin
                            if (rd_check_ack && rx_ack) begin
                                test_error <= 1'b1;
                                state <= ST_ERR_STOP;
                                sub   <= SS_ISSUE;
                            end else begin
                                if (step == 3'd5)
                                    rd_data <= dout;
                                if (step == 3'd6) begin
                                    state <= ST_VERIFY;
                                end else begin
                                    step <= step + 3'd1;
                                    sub  <= SS_ISSUE;
                                end
                            end
                        end
                    end
                    default: sub <= SS_ISSUE;
                endcase
            end

            // ===== VERIFY =====
            ST_VERIFY: begin
                if (rd_data != tst_data)
                    test_error <= 1'b1;
                display_result;
                delay_cnt <= 32'd0;
                state     <= ST_SHOW;
            end

            // ===== SHOW: pause for display readability =====
            ST_SHOW: begin
                if (!test_error)
                    display_result;

                if (test_error) begin
                    fail_flags[test_idx] <= 1'b1;
                    display_result;
                end else begin
                    pass_flags[test_idx] <= 1'b1;
                    led[test_idx]        <= 1'b1;
                end

                if (delay_cnt >= SHOW_TICKS)
                    state <= ST_NEXT;
                else
                    delay_cnt <= delay_cnt + 32'd1;
            end

            // ===== NEXT TEST =====
            ST_NEXT: begin
                if (test_idx == 2'd3)
                    state <= ST_SUMMARY;
                else begin
                    test_idx <= test_idx + 2'd1;
                    state    <= ST_PREP;
                end
            end

            // ===== SUMMARY =====
            ST_SUMMARY: begin
                seg5 <= S_P;
                seg4 <= seg_hex({1'b0, pass_count});
                seg3 <= S_BLK;
                seg2 <= S_FC;
                seg1 <= seg_hex({1'b0, fail_count});
                seg0 <= S_BLK;

                if (start)
                    state <= ST_IDLE;
            end

            // ===== ERROR: send STOP then mark fail =====
            ST_ERR_STOP: begin
                case (sub)
                    SS_ISSUE: begin
                        if (ready) begin
                            cmd_valid <= 1'b1;
                            cmd       <= I2C_STOP;
                            din       <= 8'd0;
                            sub       <= SS_ACCEPT;
                        end
                    end
                    SS_ACCEPT: begin
                        if (!ready) begin
                            cmd_valid <= 1'b0;
                            sub       <= SS_DONE;
                        end
                    end
                    SS_DONE: begin
                        if (ready) begin
                            rd_data <= 8'hEE;
                            display_result;
                            delay_cnt <= 32'd0;
                            state <= ST_SHOW;
                            sub   <= SS_ISSUE;
                        end
                    end
                    default: sub <= SS_ISSUE;
                endcase
            end

            default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
