`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// SSD1306 OLED Controller — init + scene render + continuous frame transfer
//
// Управляющий FSM для OLED-дисплея SSD1306 (128x64, I2C).
//
//   start_i (KEY2)  → статический кадр: текст + фиксированная ориентация куба
//   anim_i  (KEY3)  → непрерывная анимация: угол вращения увеличивается каждый
//                     кадр; повторное нажатие останавливает цикл.
//
// Пайплайн обработки (вся логика — железо, без процессора):
//
//   PH_IDLE → PH_DELAY → PH_INIT → PH_INITW
//                                    │
//                                    ▼
//                                PH_RENDER → PH_RENDW → PH_FRAME → PH_FRAMEW
//                                                                    │
//                                                                    ▼
//                                                       [anim?] → PH_ANEXT → PH_RENDER
//                                                       [else]  → PH_OK
//
// Все пиксельные байты берутся из scene_renderer (framebuffer 1 KiB в BRAM).
// Начальный управляющий байт 0x40 (data prefix) подмешивается контроллером.
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

    // i2c_master_core command interface
    output wire        cmd_valid_o,
    output wire [2:0]  cmd_o,
    output wire [7:0]  din_o,
    input  wire        ready_i,
    input  wire        rx_ack_i,
    input  wire        arb_lost_i,

    output wire        arb_lost_clear_o
);

    // ---------------------------------------------------------------
    // Init ROM — SSD1306 128x64 initialization sequence (32 bytes)
    // ---------------------------------------------------------------
    localparam [5:0] INIT_LEN = 6'd32;

    function [7:0] init_rom;
        input [5:0] idx;
        begin
            // verilator lint_off BLKSEQ
            case (idx)
                6'd0:  init_rom = 8'h00;   // Control byte: command stream
                6'd1:  init_rom = 8'hAE;   // Display OFF
                6'd2:  init_rom = 8'hD5;   // Set display clock divide
                6'd3:  init_rom = 8'h80;
                6'd4:  init_rom = 8'hA8;   // Set multiplex ratio
                6'd5:  init_rom = 8'h3F;   //   64 lines
                6'd6:  init_rom = 8'hD3;   // Set display offset
                6'd7:  init_rom = 8'h00;
                6'd8:  init_rom = 8'h40;   // Set start line = 0
                6'd9:  init_rom = 8'h8D;   // Charge pump
                6'd10: init_rom = 8'h14;   //   enable
                6'd11: init_rom = 8'h20;   // Addressing mode
                6'd12: init_rom = 8'h00;   //   horizontal
                6'd13: init_rom = 8'hA1;   // Segment remap
                6'd14: init_rom = 8'hC8;   // COM scan direction
                6'd15: init_rom = 8'hDA;   // COM pin config
                6'd16: init_rom = 8'h12;
                6'd17: init_rom = 8'h81;   // Contrast
                6'd18: init_rom = 8'hCF;
                6'd19: init_rom = 8'hD9;   // Pre-charge period
                6'd20: init_rom = 8'hF1;
                6'd21: init_rom = 8'hDB;   // VCOMH deselect
                6'd22: init_rom = 8'h40;
                6'd23: init_rom = 8'hA4;   // Resume RAM content
                6'd24: init_rom = 8'hA6;   // Normal (non-inverted)
                6'd25: init_rom = 8'h21;   // Column address
                6'd26: init_rom = 8'h00;
                6'd27: init_rom = 8'h7F;
                6'd28: init_rom = 8'h22;   // Page address
                6'd29: init_rom = 8'h00;
                6'd30: init_rom = 8'h07;
                6'd31: init_rom = 8'hAF;   // Display ON
                default: init_rom = 8'h00;
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    // ---------------------------------------------------------------
    // Frame transfer parameters
    // ---------------------------------------------------------------
    localparam [10:0] DATA_LEN = 11'd1025;  // 1 control byte + 1024 pixel bytes

    // ---------------------------------------------------------------
    // Phase FSM
    // ---------------------------------------------------------------
    localparam [3:0] PH_IDLE   = 4'd0,
                     PH_DELAY  = 4'd1,
                     PH_INIT   = 4'd2,
                     PH_INITW  = 4'd3,
                     PH_RENDER = 4'd4,
                     PH_RENDW  = 4'd5,
                     PH_FRAME  = 4'd6,
                     PH_FRAMEW = 4'd7,
                     PH_ANEXT  = 4'd8,
                     PH_OK     = 4'd9,
                     PH_ERR    = 4'd10;

    reg  [3:0]  phase;
    reg  [22:0] delay_cnt;
    reg  [10:0] src_idx;
    reg         inited;
    reg         mode;
    reg         anim_run;
    reg  [5:0]  angle;

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
    // Scene renderer interface
    // ---------------------------------------------------------------
    reg         scene_start;
    wire        scene_ready;
    wire [7:0]  scene_rdata;
    wire [9:0]  scene_raddr = (src_idx == 11'd0) ? 10'd0 : (src_idx[9:0] - 10'd1);

    scene_renderer u_scene (
        .clk_i   (clk_i),
        .rstn_i  (rstn_i),
        .start_i (scene_start),
        .mode_i  (mode),
        .angle_i (angle),
        .ready_o (scene_ready),
        .raddr_i (scene_raddr),
        .rdata_o (scene_rdata)
    );

    // ---------------------------------------------------------------
    // Data source mux
    //   INIT phase       → init_rom[src_idx]
    //   FRAME phase  0   → 0x40 (data-stream control byte)
    //   FRAME phase  1..1024 → framebuffer byte at scene_raddr
    // ---------------------------------------------------------------
    wire [7:0]  init_byte  = init_rom(src_idx[5:0]);
    wire [7:0]  data_byte  = (src_idx == 11'd0) ? 8'h40 : scene_rdata;
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
            scene_start   <= 1'b0;
            done_o        <= 1'b0;
            err_o         <= 1'b0;
            progress_o    <= 11'd0;
            inited        <= 1'b0;
            mode          <= 1'b0;
            anim_run      <= 1'b0;
            angle         <= 6'd0;
        end else begin
            bw_start    <= 1'b0;
            scene_start <= 1'b0;
            done_o      <= 1'b0;

            case (phase)
            // ----- Idle -----
            PH_IDLE: begin
                if (start_i) begin
                    mode     <= 1'b0;
                    anim_run <= 1'b0;
                    angle    <= 6'd0;
                    err_o    <= 1'b0;
                    if (inited)
                        phase <= PH_RENDER;
                    else begin
                        delay_cnt <= DELAY_CYCLES;
                        phase     <= PH_DELAY;
                    end
                end else if (anim_i) begin
                    mode     <= 1'b1;
                    anim_run <= 1'b1;
                    angle    <= 6'd0;
                    err_o    <= 1'b0;
                    if (inited)
                        phase <= PH_RENDER;
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
                        phase  <= PH_RENDER;
                    end
                end
            end

            // ----- Render one frame into framebuffer -----
            PH_RENDER: begin
                scene_start <= 1'b1;
                phase       <= PH_RENDW;
            end

            PH_RENDW: begin
                if (scene_ready)
                    phase <= PH_FRAME;
            end

            // ----- Transmit framebuffer via I2C -----
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

            // ----- Advance animation angle, loop back to RENDER -----
            PH_ANEXT: begin
                angle <= angle + 6'd1;
                phase <= PH_RENDER;
            end

            // ----- Done / Error: accept new command -----
            PH_OK: begin
                if (start_i) begin
                    mode     <= 1'b0;
                    anim_run <= 1'b0;
                    angle    <= 6'd0;
                    err_o    <= 1'b0;
                    phase    <= inited ? PH_RENDER : PH_DELAY;
                    if (!inited) delay_cnt <= DELAY_CYCLES;
                end else if (anim_i) begin
                    mode     <= 1'b1;
                    anim_run <= 1'b1;
                    angle    <= 6'd0;
                    err_o    <= 1'b0;
                    phase    <= inited ? PH_RENDER : PH_DELAY;
                    if (!inited) delay_cnt <= DELAY_CYCLES;
                end
            end

            PH_ERR: begin
                if (start_i || anim_i) begin
                    inited    <= 1'b0;
                    mode      <= anim_i ? 1'b1 : 1'b0;
                    anim_run  <= anim_i;
                    angle     <= 6'd0;
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


