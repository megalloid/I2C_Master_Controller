`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// SSD1306 OLED Controller — init + static pattern + animation
//
// Two modes:
//   start_i  → static test pattern (single frame)
//   anim_i   → animated spotlight sweeping across test pattern (continuous)
//              press anim_i again to stop
//
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
    input  wire        anim_i,

    output wire        busy_o,
    output reg         done_o,
    output reg         err_o,
    output reg  [10:0] progress_o,
    output wire        animating_o,

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
            6'd0:  init_rom = 8'h00;
            6'd1:  init_rom = 8'hAE;
            6'd2:  init_rom = 8'hD5;
            6'd3:  init_rom = 8'h80;
            6'd4:  init_rom = 8'hA8;
            6'd5:  init_rom = 8'h3F;
            6'd6:  init_rom = 8'hD3;
            6'd7:  init_rom = 8'h00;
            6'd8:  init_rom = 8'h40;
            6'd9:  init_rom = 8'h8D;
            6'd10: init_rom = 8'h14;
            6'd11: init_rom = 8'h20;
            6'd12: init_rom = 8'h00;
            6'd13: init_rom = 8'hA1;
            6'd14: init_rom = 8'hC8;
            6'd15: init_rom = 8'hDA;
            6'd16: init_rom = 8'h12;
            6'd17: init_rom = 8'h81;
            6'd18: init_rom = 8'hCF;
            6'd19: init_rom = 8'hD9;
            6'd20: init_rom = 8'hF1;
            6'd21: init_rom = 8'hDB;
            6'd22: init_rom = 8'h40;
            6'd23: init_rom = 8'hA4;
            6'd24: init_rom = 8'hA6;
            6'd25: init_rom = 8'h21;
            6'd26: init_rom = 8'h00;
            6'd27: init_rom = 8'h7F;
            6'd28: init_rom = 8'h22;
            6'd29: init_rom = 8'h00;
            6'd30: init_rom = 8'h07;
            6'd31: init_rom = 8'hAF;
            default: init_rom = 8'h00;
        endcase
    endfunction

    // ---------------------------------------------------------------
    // Static test pattern (4-quadrant + border)
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
    // Animated pattern — spotlight bar sweeping over test pattern
    //
    // A 16-column bright "window" reveals the test pattern as it
    // bounces left-right. Outside the window: sparse dot grid.
    // ---------------------------------------------------------------
    function [7:0] gen_anim;
        input [6:0] col;
        input [2:0] page;
        input [6:0] bp;
        reg in_bar;
        begin
            // verilator lint_off BLKSEQ
            in_bar = (col >= bp) && ({1'b0, col} < {1'b0, bp} + 8'd16);

            if (col == 7'd0 || col == 7'd127)
                gen_anim = 8'hFF;
            else if (page == 3'd0)
                gen_anim = 8'h01;
            else if (page == 3'd7)
                gen_anim = 8'h80;
            else if (in_bar) begin
                if (page < 3'd4 && col < 7'd64)
                    gen_anim = col[3] ? 8'hFF : 8'h00;
                else if (page < 3'd4)
                    gen_anim = (col[3] ^ page[0]) ? 8'hFF : 8'h00;
                else if (col < 7'd64)
                    gen_anim = 8'h55;
                else
                    gen_anim = 8'hFF >> col[2:0];
            end else
                gen_anim = (col[4:0] == 5'd0) ? 8'h10 : 8'h00;
            // verilator lint_on BLKSEQ
        end
    endfunction

    // ---------------------------------------------------------------
    // Phase FSM
    // ---------------------------------------------------------------
    localparam [3:0] PH_IDLE  = 4'd0,
                     PH_DELAY = 4'd1,
                     PH_INIT  = 4'd2,
                     PH_INITW = 4'd3,
                     PH_FRAME = 4'd4,
                     PH_FRAMEW= 4'd5,
                     PH_ANEXT = 4'd6,
                     PH_OK    = 4'd7,
                     PH_ERR   = 4'd8;

    reg  [3:0]  phase;
    reg  [22:0] delay_cnt;
    reg  [10:0] src_idx;
    reg         inited;
    reg         mode;
    reg         anim_run;
    reg  [6:0]  bar_pos;
    reg         bar_dir;

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

    wire [7:0]  init_byte  = init_rom(src_idx[5:0]);
    wire [7:0]  static_pix = gen_pattern(pix_col, pix_page);
    wire [7:0]  anim_pix   = gen_anim(pix_col, pix_page, bar_pos);
    wire [7:0]  pixel_byte = mode ? anim_pix : static_pix;
    wire [7:0]  data_byte  = (src_idx == 11'd0) ? 8'h40 : pixel_byte;
    wire [7:0]  bw_data    = (phase == PH_INITW) ? init_byte : data_byte;

    assign busy_o      = (phase != PH_IDLE && phase != PH_OK && phase != PH_ERR);
    assign animating_o = anim_run;

    wire trigger = start_i || anim_i;
    assign arb_lost_clear_o = trigger && (phase == PH_IDLE ||
                                          phase == PH_OK   ||
                                          phase == PH_ERR);

    // Source index: reset at frame start, advance on each byte consumed
    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i)
            src_idx <= 11'd0;
        else if (phase == PH_INIT || phase == PH_FRAME)
            src_idx <= 11'd0;
        else if (bw_data_req)
            src_idx <= src_idx + 11'd1;
    end

    // Stop animation when anim_i pressed during active animation
    reg anim_stop_req;
    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i)
            anim_stop_req <= 1'b0;
        else if (anim_i && anim_run)
            anim_stop_req <= 1'b1;
        else if (phase == PH_OK || phase == PH_IDLE)
            anim_stop_req <= 1'b0;
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
            inited        <= 1'b0;
            mode          <= 1'b0;
            anim_run      <= 1'b0;
            bar_pos       <= 7'd0;
            bar_dir       <= 1'b0;
        end else begin
            bw_start <= 1'b0;
            done_o   <= 1'b0;

            case (phase)
            // ----- Idle: wait for button -----
            PH_IDLE: begin
                if (start_i) begin
                    mode     <= 1'b0;
                    anim_run <= 1'b0;
                    err_o    <= 1'b0;
                    if (inited)
                        phase <= PH_FRAME;
                    else begin
                        delay_cnt <= DELAY_CYCLES;
                        phase     <= PH_DELAY;
                    end
                end else if (anim_i) begin
                    mode     <= 1'b1;
                    anim_run <= 1'b1;
                    bar_pos  <= 7'd0;
                    bar_dir  <= 1'b0;
                    err_o    <= 1'b0;
                    if (inited)
                        phase <= PH_FRAME;
                    else begin
                        delay_cnt <= DELAY_CYCLES;
                        phase     <= PH_DELAY;
                    end
                end
            end

            // ----- Power-on delay -----
            PH_DELAY: begin
                if (delay_cnt == 23'd0)
                    phase <= PH_INIT;
                else
                    delay_cnt <= delay_cnt - 23'd1;
            end

            // ----- Init SSD1306 -----
            PH_INIT: begin
                bw_start      <= 1'b1;
                bw_byte_count <= {10'd0, INIT_LEN};
                phase         <= PH_INITW;
            end

            PH_INITW: begin
                progress_o <= src_idx;
                if (bw_done) begin
                    if (bw_error) begin
                        err_o  <= 1'b1;
                        inited <= 1'b0;
                        phase  <= PH_ERR;
                    end else begin
                        inited <= 1'b1;
                        phase  <= PH_FRAME;
                    end
                end
            end

            // ----- Send one frame -----
            PH_FRAME: begin
                bw_start      <= 1'b1;
                bw_byte_count <= {5'd0, DATA_LEN};
                phase         <= PH_FRAMEW;
            end

            PH_FRAMEW: begin
                progress_o <= src_idx;
                if (bw_done) begin
                    if (bw_error) begin
                        err_o    <= 1'b1;
                        anim_run <= 1'b0;
                        phase    <= PH_ERR;
                    end else if (anim_run && !anim_stop_req)
                        phase <= PH_ANEXT;
                    else begin
                        done_o   <= 1'b1;
                        anim_run <= 1'b0;
                        phase    <= PH_OK;
                    end
                end
            end

            // ----- Advance animation and loop -----
            PH_ANEXT: begin
                if (!bar_dir) begin
                    if (bar_pos >= 7'd112) begin
                        bar_dir <= 1'b1;
                        bar_pos <= bar_pos - 7'd2;
                    end else
                        bar_pos <= bar_pos + 7'd2;
                end else begin
                    if (bar_pos <= 7'd2) begin
                        bar_dir <= 1'b0;
                        bar_pos <= bar_pos + 7'd2;
                    end else
                        bar_pos <= bar_pos - 7'd2;
                end
                phase <= PH_FRAME;
            end

            // ----- Done / Error: accept new command -----
            PH_OK: begin
                if (start_i) begin
                    mode     <= 1'b0;
                    anim_run <= 1'b0;
                    err_o    <= 1'b0;
                    phase    <= inited ? PH_FRAME : PH_DELAY;
                    if (!inited) delay_cnt <= DELAY_CYCLES;
                end else if (anim_i) begin
                    mode     <= 1'b1;
                    anim_run <= 1'b1;
                    bar_pos  <= 7'd0;
                    bar_dir  <= 1'b0;
                    err_o    <= 1'b0;
                    phase    <= inited ? PH_FRAME : PH_DELAY;
                    if (!inited) delay_cnt <= DELAY_CYCLES;
                end
            end

            PH_ERR: begin
                if (start_i || anim_i) begin
                    inited    <= 1'b0;
                    mode      <= anim_i ? 1'b1 : 1'b0;
                    anim_run  <= anim_i;
                    bar_pos   <= 7'd0;
                    bar_dir   <= 1'b0;
                    err_o     <= 1'b0;
                    delay_cnt <= DELAY_CYCLES;
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
