`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// SSD1306 OLED Controller — init + test pattern display via I2C
//
// Sequence on start_i pulse:
//   1. Delay 100 ms (VCC stabilization)
//   2. I2C burst: init commands (32 bytes including 0x00 control prefix)
//   3. I2C burst: framebuffer data (1025 bytes: 0x40 prefix + 1024 pixels)
//
// Test pattern: 4-quadrant image with border, stripes, checkerboard, gradient.
// Display: SSD1306 128x64 at I2C address 0x3C (configurable).
// ---------------------------------------------------------------------------
module ssd1306_ctrl #(
    parameter CLK_FREQ = 50_000_000,
    parameter I2C_ADDR = 7'h3C,
    parameter DELAY_MS = 100
)(
    input  wire        clk_i,
    input  wire        rstn_i,
    input  wire        start_i,

    output wire        busy_o,
    output reg         done_o,
    output reg         err_o,
    output reg  [10:0] progress_o,

    // i2c_master_core interface (directly exposed from burst_writer)
    output wire        cmd_valid_o,
    output wire [2:0]  cmd_o,
    output wire [7:0]  din_o,
    input  wire        ready_i,
    input  wire        rx_ack_i,
    input  wire        arb_lost_i,

    output wire        arb_lost_clear_o
);

    // ---------------------------------------------------------------
    // Init ROM — SSD1306 128x64 initialization sequence
    // ---------------------------------------------------------------
    localparam [5:0] INIT_LEN = 6'd32;

    function [7:0] init_rom;
        input [5:0] idx;
        case (idx)
            6'd0:  init_rom = 8'h00;   // I2C control: command stream
            6'd1:  init_rom = 8'hAE;   // Display OFF
            6'd2:  init_rom = 8'hD5;   // Set display clock divider
            6'd3:  init_rom = 8'h80;   //   default
            6'd4:  init_rom = 8'hA8;   // Set multiplex ratio
            6'd5:  init_rom = 8'h3F;   //   1/64
            6'd6:  init_rom = 8'hD3;   // Set display offset
            6'd7:  init_rom = 8'h00;   //   no offset
            6'd8:  init_rom = 8'h40;   // Set start line = 0
            6'd9:  init_rom = 8'h8D;   // Charge pump
            6'd10: init_rom = 8'h14;   //   enable
            6'd11: init_rom = 8'h20;   // Memory addressing mode
            6'd12: init_rom = 8'h00;   //   horizontal
            6'd13: init_rom = 8'hA1;   // Segment re-map (col 127 → SEG0)
            6'd14: init_rom = 8'hC8;   // COM scan direction (remapped)
            6'd15: init_rom = 8'hDA;   // COM pins config
            6'd16: init_rom = 8'h12;   //   alternative, no remap
            6'd17: init_rom = 8'h81;   // Set contrast
            6'd18: init_rom = 8'hCF;   //   207
            6'd19: init_rom = 8'hD9;   // Pre-charge period
            6'd20: init_rom = 8'hF1;   //   phase1=1, phase2=15
            6'd21: init_rom = 8'hDB;   // VCOMH deselect level
            6'd22: init_rom = 8'h40;   //   ~0.77×Vcc
            6'd23: init_rom = 8'hA4;   // Entire display ON from RAM
            6'd24: init_rom = 8'hA6;   // Normal display (not inverted)
            6'd25: init_rom = 8'h21;   // Set column address range
            6'd26: init_rom = 8'h00;   //   start = 0
            6'd27: init_rom = 8'h7F;   //   end = 127
            6'd28: init_rom = 8'h22;   // Set page address range
            6'd29: init_rom = 8'h00;   //   start = 0
            6'd30: init_rom = 8'h07;   //   end = 7
            6'd31: init_rom = 8'hAF;   // Display ON
            default: init_rom = 8'h00;
        endcase
    endfunction

    // ---------------------------------------------------------------
    // Test pattern generator — 4-quadrant pattern with border
    //
    // SSD1306 memory: 8 pages × 128 columns = 1024 bytes
    // Each byte = 8 vertical pixels (bit 0 = top, bit 7 = bottom)
    //
    //  ┌──────────────┬──────────────┐
    //  │  Vert.stripes│  Checkerboard│  pages 0-3
    //  │  (8px wide)  │  (8×8 blocks)│
    //  ├──────────────┼──────────────┤
    //  │  Horiz.lines │  Diagonal    │  pages 4-7
    //  │  (dotted)    │  (staircase) │
    //  └──────────────┴──────────────┘
    //    cols 0-63       cols 64-127
    // ---------------------------------------------------------------
    localparam [10:0] DATA_LEN = 11'd1025;

    function [7:0] gen_pattern;
        input [6:0] col;
        input [2:0] page;
        begin
            // verilator lint_off BLKSEQ
            if (col == 7'd0 || col == 7'd127)
                gen_pattern = 8'hFF;
            else if (page == 3'd0)
                gen_pattern = 8'h01;
            else if (page == 3'd7)
                gen_pattern = 8'h80;
            else if (page < 3'd4 && col < 7'd64)
                gen_pattern = col[3] ? 8'hFF : 8'h00;
            else if (page < 3'd4)
                gen_pattern = (col[3] ^ page[0]) ? 8'hFF : 8'h00;
            else if (col < 7'd64)
                gen_pattern = 8'h55;
            else
                gen_pattern = 8'hFF >> col[2:0];
            // verilator lint_on BLKSEQ
        end
    endfunction

    // ---------------------------------------------------------------
    // Phase FSM
    // ---------------------------------------------------------------
    localparam [2:0] PH_IDLE  = 3'd0,
                     PH_DELAY = 3'd1,
                     PH_INIT  = 3'd2,
                     PH_INITW = 3'd3,
                     PH_DATA  = 3'd4,
                     PH_DATAW = 3'd5,
                     PH_OK    = 3'd6,
                     PH_ERR   = 3'd7;

    reg  [2:0]  phase;
    reg  [22:0] delay_cnt;
    reg  [10:0] src_idx;

    /* verilator lint_off WIDTHTRUNC */
    localparam [22:0] DELAY_CYCLES = (CLK_FREQ / 1000) * DELAY_MS;
    /* verilator lint_on WIDTHTRUNC */

    // ---------------------------------------------------------------
    // Burst writer interface
    // ---------------------------------------------------------------
    wire        bw_busy;
    wire        bw_done;
    wire        bw_error;
    wire        bw_data_req;
    reg         bw_start;
    reg  [15:0] bw_byte_count;

    // ---------------------------------------------------------------
    // Data source mux
    // ---------------------------------------------------------------
    wire [10:0] pix_raw  = src_idx - 11'd1;
    wire [6:0]  pix_col  = pix_raw[6:0];
    wire [2:0]  pix_page = pix_raw[9:7];

    wire [7:0]  init_byte = init_rom(src_idx[5:0]);
    wire [7:0]  data_byte = (src_idx == 11'd0) ? 8'h40
                                                : gen_pattern(pix_col, pix_page);
    wire [7:0]  bw_data   = (phase == PH_INITW) ? init_byte : data_byte;

    assign busy_o = (phase != PH_IDLE && phase != PH_OK && phase != PH_ERR);
    assign arb_lost_clear_o = (phase == PH_IDLE && start_i) ||
                              (phase == PH_OK   && start_i) ||
                              (phase == PH_ERR  && start_i);

    // Source index: advances once per byte consumed
    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i)
            src_idx <= 11'd0;
        else if (phase == PH_INIT || phase == PH_DATA)
            src_idx <= 11'd0;
        else if (bw_data_req)
            src_idx <= src_idx + 11'd1;
    end

    // ---------------------------------------------------------------
    // Main FSM
    // ---------------------------------------------------------------
    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            phase         <= PH_IDLE;
            delay_cnt     <= 23'd0;
            bw_start      <= 1'b0;
            bw_byte_count <= 16'd0;
            done_o        <= 1'b0;
            err_o         <= 1'b0;
            progress_o    <= 11'd0;
        end else begin
            bw_start <= 1'b0;
            done_o   <= 1'b0;

            case (phase)
            PH_IDLE: begin
                if (start_i) begin
                    delay_cnt <= DELAY_CYCLES;
                    err_o     <= 1'b0;
                    phase     <= PH_DELAY;
                end
            end

            PH_DELAY: begin
                if (delay_cnt == 23'd0)
                    phase <= PH_INIT;
                else
                    delay_cnt <= delay_cnt - 23'd1;
            end

            PH_INIT: begin
                bw_start      <= 1'b1;
                bw_byte_count <= {10'd0, INIT_LEN};
                phase         <= PH_INITW;
            end

            PH_INITW: begin
                progress_o <= src_idx;
                if (bw_done) begin
                    if (bw_error) begin
                        err_o <= 1'b1;
                        phase <= PH_ERR;
                    end else
                        phase <= PH_DATA;
                end
            end

            PH_DATA: begin
                bw_start      <= 1'b1;
                bw_byte_count <= {5'd0, DATA_LEN};
                phase         <= PH_DATAW;
            end

            PH_DATAW: begin
                progress_o <= src_idx;
                if (bw_done) begin
                    if (bw_error) begin
                        err_o <= 1'b1;
                        phase <= PH_ERR;
                    end else begin
                        done_o <= 1'b1;
                        phase  <= PH_OK;
                    end
                end
            end

            PH_OK: begin
                if (start_i) begin
                    delay_cnt <= DELAY_CYCLES;
                    err_o     <= 1'b0;
                    phase     <= PH_DELAY;
                end
            end

            PH_ERR: begin
                if (start_i) begin
                    delay_cnt <= DELAY_CYCLES;
                    err_o     <= 1'b0;
                    phase     <= PH_DELAY;
                end
            end

            default: phase <= PH_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // Burst writer instance
    // ---------------------------------------------------------------
    i2c_burst_writer #(
        .CNT_W (16)
    ) u_burst (
        .clk_i        (clk_i),
        .rstn_i       (rstn_i),
        .start_i      (bw_start),
        .slave_addr_i (I2C_ADDR),
        .byte_count_i (bw_byte_count),
        .busy_o       (bw_busy),
        .done_o       (bw_done),
        .error_o      (bw_error),
        .data_req_o   (bw_data_req),
        .data_i       (bw_data),
        .data_valid_i (bw_data_req),
        .cmd_valid_o  (cmd_valid_o),
        .cmd_o        (cmd_o),
        .din_o        (din_o),
        .ready_i      (ready_i),
        .rx_ack_i     (rx_ack_i),
        .arb_lost_i   (arb_lost_i)
    );

endmodule
