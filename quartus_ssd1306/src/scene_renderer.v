`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// Scene Renderer — аппаратный рендер кадра 128x64 в framebuffer.
//
// Рисует:
//   1. Текст "SSD1306" в верхней строке  (page 0).
//   2. Вращающийся псевдотрёхмерный кубик (pages 2..5).
//   3. Подпись внизу: "STATIC" или "ANIM" (page 7).
//
// Пайплайн кадра (всё в железе, без CPU):
//   S_CLEAR     обнуление 1024 байт FB
//   S_ROT_*     поворот 8 вершин куба вокруг оси Y на angle_i·2π/64
//               + псевдо-3D проекция со смещением по Z
//   S_EDGE_*    Брезенхэм по 12 рёбрам, RMW в FB
//   S_TEXT_*    blit двух строк из font ROM в FB
//   S_DONE      ready_o = 1, кадр готов к передаче
//
// Framebuffer — 1024×8 bit dual-port synchronous RAM (M9K).
// Порт A — запись рендерером.  Порт B — чтение ssd1306_ctrl для I2C.
// ---------------------------------------------------------------------------
module scene_renderer (
    input  wire        clk_i,
    input  wire        rstn_i,

    input  wire        start_i,       // Single-cycle start pulse
    input  wire        mode_i,        // 0 = static, 1 = animation
    input  wire [5:0]  angle_i,       // 0..63 → 0..2π
    output reg         ready_o,

    input  wire [9:0]  raddr_i,       // external read port for I2C
    output reg  [7:0]  rdata_o
);

    // ---------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------
    localparam signed [7:0] S            = 8'sd12;
    localparam [3:0]        NUM_EDGES    = 4'd12;
    localparam [6:0]        TOP_COL0     = 7'd43;
    localparam [6:0]        BOT_STA_COL0 = 7'd46;
    localparam [6:0]        BOT_ANI_COL0 = 7'd52;
    localparam [2:0]        TOP_PAGE     = 3'd0;
    localparam [2:0]        BOT_PAGE     = 3'd7;
    localparam [2:0]        TOP_LEN_M1   = 3'd6;   // 7 chars − 1
    localparam [2:0]        STA_LEN_M1   = 3'd5;   // 6 chars − 1
    localparam [2:0]        ANI_LEN_M1   = 3'd3;   // 4 chars − 1

    // ---------------------------------------------------------------
    // Framebuffer — inferred as M9K dual-port RAM
    // ---------------------------------------------------------------
    reg  [7:0] fb [0:1023];

    reg  [9:0] fb_waddr;
    reg  [7:0] fb_wdata;
    reg        fb_we;

    reg  [9:0] fb_raddr_rmw;
    reg  [7:0] fb_rdata_rmw;

    always @(posedge clk_i) begin
        if (fb_we)
            fb[fb_waddr] <= fb_wdata;
        rdata_o      <= fb[raddr_i];
        fb_rdata_rmw <= fb[fb_raddr_rmw];
    end

    // ---------------------------------------------------------------
    // Quarter-wave SIN table  (127·sin(q·π/32),  q = 0..16)
    // ---------------------------------------------------------------
    function signed [8:0] sin_q;
        input [4:0] q;
        begin
            // verilator lint_off BLKSEQ
            case (q)
                5'd0 : sin_q = 9'sd0;    5'd1 : sin_q = 9'sd12;
                5'd2 : sin_q = 9'sd25;   5'd3 : sin_q = 9'sd37;
                5'd4 : sin_q = 9'sd49;   5'd5 : sin_q = 9'sd60;
                5'd6 : sin_q = 9'sd71;   5'd7 : sin_q = 9'sd81;
                5'd8 : sin_q = 9'sd90;   5'd9 : sin_q = 9'sd98;
                5'd10: sin_q = 9'sd106;  5'd11: sin_q = 9'sd112;
                5'd12: sin_q = 9'sd117;  5'd13: sin_q = 9'sd122;
                5'd14: sin_q = 9'sd125;  5'd15: sin_q = 9'sd126;
                5'd16: sin_q = 9'sd127;  default: sin_q = 9'sd0;
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    function signed [8:0] sin6;
        input [5:0] theta;
        reg   [4:0] qi;
        reg signed [8:0] mag;
        begin
            // verilator lint_off BLKSEQ
            qi  = theta[4] ? (5'd16 - {1'b0, theta[3:0]}) : {1'b0, theta[3:0]};
            mag = sin_q(qi);
            sin6 = theta[5] ? -mag : mag;
            // verilator lint_on BLKSEQ
        end
    endfunction

    function signed [8:0] cos6;
        input [5:0] theta;
        begin
            cos6 = sin6(theta + 6'd16);
        end
    endfunction

    // ---------------------------------------------------------------
    // Cube vertex ROM  (base coordinates before rotation)
    // ---------------------------------------------------------------
    function signed [7:0] vx_rom;
        input [2:0] i;
        begin
            // verilator lint_off BLKSEQ
            case (i)
                3'd0: vx_rom = -S;  3'd1: vx_rom =  S;
                3'd2: vx_rom =  S;  3'd3: vx_rom = -S;
                3'd4: vx_rom = -S;  3'd5: vx_rom =  S;
                3'd6: vx_rom =  S;  3'd7: vx_rom = -S;
                default: vx_rom = 8'sd0;
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    function signed [7:0] vy_rom;
        input [2:0] i;
        begin
            // verilator lint_off BLKSEQ
            case (i)
                3'd0: vy_rom = -S;  3'd1: vy_rom = -S;
                3'd2: vy_rom = -S;  3'd3: vy_rom = -S;
                3'd4: vy_rom =  S;  3'd5: vy_rom =  S;
                3'd6: vy_rom =  S;  3'd7: vy_rom =  S;
                default: vy_rom = 8'sd0;
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    function signed [7:0] vz_rom;
        input [2:0] i;
        begin
            // verilator lint_off BLKSEQ
            case (i)
                3'd0: vz_rom = -S;  3'd1: vz_rom = -S;
                3'd2: vz_rom =  S;  3'd3: vz_rom =  S;
                3'd4: vz_rom = -S;  3'd5: vz_rom = -S;
                3'd6: vz_rom =  S;  3'd7: vz_rom =  S;
                default: vz_rom = 8'sd0;
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    // ---------------------------------------------------------------
    // 12 edges — each specifies (v0, v1)
    // ---------------------------------------------------------------
    function [2:0] edge_v0;
        input [3:0] e;
        begin
            // verilator lint_off BLKSEQ
            case (e)
                4'd0:  edge_v0 = 3'd0;  4'd1:  edge_v0 = 3'd1;
                4'd2:  edge_v0 = 3'd2;  4'd3:  edge_v0 = 3'd3;
                4'd4:  edge_v0 = 3'd4;  4'd5:  edge_v0 = 3'd5;
                4'd6:  edge_v0 = 3'd6;  4'd7:  edge_v0 = 3'd7;
                4'd8:  edge_v0 = 3'd0;  4'd9:  edge_v0 = 3'd1;
                4'd10: edge_v0 = 3'd2;  4'd11: edge_v0 = 3'd3;
                default: edge_v0 = 3'd0;
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    function [2:0] edge_v1;
        input [3:0] e;
        begin
            // verilator lint_off BLKSEQ
            case (e)
                4'd0:  edge_v1 = 3'd1;  4'd1:  edge_v1 = 3'd2;
                4'd2:  edge_v1 = 3'd3;  4'd3:  edge_v1 = 3'd0;
                4'd4:  edge_v1 = 3'd5;  4'd5:  edge_v1 = 3'd6;
                4'd6:  edge_v1 = 3'd7;  4'd7:  edge_v1 = 3'd4;
                4'd8:  edge_v1 = 3'd4;  4'd9:  edge_v1 = 3'd5;
                4'd10: edge_v1 = 3'd6;  4'd11: edge_v1 = 3'd7;
                default: edge_v1 = 3'd0;
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    // ---------------------------------------------------------------
    // 5x7 font ROM (chars 0..15).  addr = char<<3 | col ( col ∈ 0..4 )
    //   Chars:  0:'S' 1:'D' 2:'1' 3:'3' 4:'0' 5:'6' 6:' ' 7:'C'
    //           8:'U' 9:'B' 10:'E' 11:'A' 12:'I' 13:'T' 14:'N' 15:'M'
    // ---------------------------------------------------------------
    function [7:0] font_byte;
        input [6:0] addr;
        begin
            // verilator lint_off BLKSEQ
            case (addr)
                // S
                7'd0:  font_byte = 8'h26; 7'd1:  font_byte = 8'h49;
                7'd2:  font_byte = 8'h49; 7'd3:  font_byte = 8'h49;
                7'd4:  font_byte = 8'h32;
                // D
                7'd8:  font_byte = 8'h7F; 7'd9:  font_byte = 8'h41;
                7'd10: font_byte = 8'h41; 7'd11: font_byte = 8'h41;
                7'd12: font_byte = 8'h3E;
                // 1
                7'd16: font_byte = 8'h40; 7'd17: font_byte = 8'h42;
                7'd18: font_byte = 8'h7F; 7'd19: font_byte = 8'h40;
                // 3
                7'd24: font_byte = 8'h41; 7'd25: font_byte = 8'h49;
                7'd26: font_byte = 8'h49; 7'd27: font_byte = 8'h49;
                7'd28: font_byte = 8'h36;
                // 0
                7'd32: font_byte = 8'h3E; 7'd33: font_byte = 8'h51;
                7'd34: font_byte = 8'h49; 7'd35: font_byte = 8'h45;
                7'd36: font_byte = 8'h3E;
                // 6
                7'd40: font_byte = 8'h3C; 7'd41: font_byte = 8'h4A;
                7'd42: font_byte = 8'h49; 7'd43: font_byte = 8'h49;
                7'd44: font_byte = 8'h30;
                // C
                7'd56: font_byte = 8'h3E; 7'd57: font_byte = 8'h41;
                7'd58: font_byte = 8'h41; 7'd59: font_byte = 8'h41;
                7'd60: font_byte = 8'h22;
                // U
                7'd64: font_byte = 8'h3F; 7'd65: font_byte = 8'h40;
                7'd66: font_byte = 8'h40; 7'd67: font_byte = 8'h40;
                7'd68: font_byte = 8'h3F;
                // B
                7'd72: font_byte = 8'h7F; 7'd73: font_byte = 8'h49;
                7'd74: font_byte = 8'h49; 7'd75: font_byte = 8'h49;
                7'd76: font_byte = 8'h36;
                // E
                7'd80: font_byte = 8'h7F; 7'd81: font_byte = 8'h49;
                7'd82: font_byte = 8'h49; 7'd83: font_byte = 8'h49;
                7'd84: font_byte = 8'h41;
                // A
                7'd88: font_byte = 8'h7E; 7'd89: font_byte = 8'h11;
                7'd90: font_byte = 8'h11; 7'd91: font_byte = 8'h11;
                7'd92: font_byte = 8'h7E;
                // I
                7'd96: font_byte = 8'h41; 7'd97: font_byte = 8'h41;
                7'd98: font_byte = 8'h7F; 7'd99: font_byte = 8'h41;
                7'd100: font_byte = 8'h41;
                // T
                7'd104: font_byte = 8'h01; 7'd105: font_byte = 8'h01;
                7'd106: font_byte = 8'h7F; 7'd107: font_byte = 8'h01;
                7'd108: font_byte = 8'h01;
                // N
                7'd112: font_byte = 8'h7F; 7'd113: font_byte = 8'h06;
                7'd114: font_byte = 8'h08; 7'd115: font_byte = 8'h30;
                7'd116: font_byte = 8'h7F;
                // M
                7'd120: font_byte = 8'h7F; 7'd121: font_byte = 8'h02;
                7'd122: font_byte = 8'h04; 7'd123: font_byte = 8'h02;
                7'd124: font_byte = 8'h7F;
                default: font_byte = 8'h00;
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    // ---------------------------------------------------------------
    // Text character lookup
    // ---------------------------------------------------------------
    function [3:0] top_char;
        input [2:0] i;
        begin
            // verilator lint_off BLKSEQ
            case (i)
                3'd0: top_char = 4'd0;   // S
                3'd1: top_char = 4'd0;   // S
                3'd2: top_char = 4'd1;   // D
                3'd3: top_char = 4'd2;   // 1
                3'd4: top_char = 4'd3;   // 3
                3'd5: top_char = 4'd4;   // 0
                3'd6: top_char = 4'd5;   // 6
                default: top_char = 4'd6; // space
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    function [3:0] bot_sta_char;
        input [2:0] i;
        begin
            // verilator lint_off BLKSEQ
            case (i)                             // "STATIC"
                3'd0: bot_sta_char = 4'd0;   // S
                3'd1: bot_sta_char = 4'd13;  // T
                3'd2: bot_sta_char = 4'd11;  // A
                3'd3: bot_sta_char = 4'd13;  // T
                3'd4: bot_sta_char = 4'd12;  // I
                3'd5: bot_sta_char = 4'd7;   // C
                default: bot_sta_char = 4'd6;
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    function [3:0] bot_ani_char;
        input [2:0] i;
        begin
            // verilator lint_off BLKSEQ
            case (i)                             // "ANIM"
                3'd0: bot_ani_char = 4'd11;  // A
                3'd1: bot_ani_char = 4'd14;  // N
                3'd2: bot_ani_char = 4'd12;  // I
                3'd3: bot_ani_char = 4'd15;  // M
                default: bot_ani_char = 4'd6;
            endcase
            // verilator lint_on BLKSEQ
        end
    endfunction

    // ---------------------------------------------------------------
    // Rotated / projected vertex storage  (signed 9-bit screen coords)
    // ---------------------------------------------------------------
    reg signed [8:0] vtx_px [0:7];
    reg signed [8:0] vtx_py [0:7];

    // ---------------------------------------------------------------
    // Main FSM
    // ---------------------------------------------------------------
    localparam [4:0]
        S_IDLE      = 5'd0,
        S_CLEAR     = 5'd1,
        S_ROT_SETUP = 5'd2,
        S_ROT_LOAD  = 5'd3,
        S_ROT_MUL   = 5'd4,
        S_ROT_STORE = 5'd5,
        S_EDGE_INIT = 5'd6,
        S_EDGE_SETUP= 5'd7,
        S_EDGE_RD   = 5'd8,
        S_EDGE_WR   = 5'd9,
        S_EDGE_STEP = 5'd10,
        S_TEXT_INIT = 5'd11,
        S_TEXT_WR   = 5'd12,
        S_TEXT_NEXT = 5'd13,
        S_DONE      = 5'd14;

    reg [4:0]  state;
    reg        mode_r;
    reg [5:0]  angle_r;

    // Clear state
    reg [10:0] clr_idx;

    // Rotation state
    reg signed [8:0]  sin_th, cos_th;
    reg        [2:0]  vtx_idx;
    reg signed [7:0]  cur_vx, cur_vy, cur_vz;
    reg signed [17:0] prod_xc, prod_zs, prod_xs, prod_zc;

    // Bresenham state
    reg [3:0]         edge_idx;
    reg signed [8:0]  bx, by;
    reg signed [8:0]  bx_end, by_end;
    reg signed [8:0]  bdx;           // +|dx|
    reg signed [8:0]  bdy;           // −|dy|
    reg signed [1:0]  bsx, bsy;
    reg signed [10:0] berr;
    reg [7:0]         pix_mask;

    // Text state
    reg [2:0]  txt_char_idx;
    reg [2:0]  txt_col_idx;
    reg        txt_phase;   // 0=top, 1=bottom

    // ---------------------------------------------------------------
    // Derived combinatorial signals — rotation commit
    // ---------------------------------------------------------------
    wire signed [17:0] rot_xp_full = prod_xc - prod_zs;       // vx·cos − vz·sin
    wire signed [17:0] rot_zp_full = prod_xs + prod_zc;       // vx·sin + vz·cos
    wire signed [10:0] rot_xp      = rot_xp_full[17:7];       // ≈ rotated x
    wire signed [10:0] rot_zp      = rot_zp_full[17:7];       // ≈ rotated z
    wire signed [10:0] rot_px      = rot_xp + 11'sd64;        // centre x
    wire signed [10:0] cur_vy_ext  = {{3{cur_vy[7]}}, cur_vy};
    wire signed [10:0] rot_py      = cur_vy_ext + (rot_zp >>> 2) + 11'sd32;

    // ---------------------------------------------------------------
    // Derived combinatorial signals — Bresenham init
    // ---------------------------------------------------------------
    wire [2:0]         e0         = edge_v0(edge_idx);
    wire [2:0]         e1         = edge_v1(edge_idx);
    wire signed [8:0]  p0x        = vtx_px[e0];
    wire signed [8:0]  p0y        = vtx_py[e0];
    wire signed [8:0]  p1x        = vtx_px[e1];
    wire signed [8:0]  p1y        = vtx_py[e1];
    wire signed [8:0]  init_dx    = (p1x >= p0x) ? (p1x - p0x) : (p0x - p1x);
    wire signed [8:0]  init_dy_n  = (p1y >= p0y) ? (p0y - p1y) : (p1y - p0y);  // ≤ 0
    wire signed [1:0]  init_sx    = (p0x < p1x) ?  2'sd1 : -2'sd1;
    wire signed [1:0]  init_sy    = (p0y < p1y) ?  2'sd1 : -2'sd1;
    wire signed [10:0] init_err   = {{2{init_dx[8]}},   init_dx}
                                  + {{2{init_dy_n[8]}}, init_dy_n};

    // ---------------------------------------------------------------
    // Derived combinatorial signals — Bresenham step
    // ---------------------------------------------------------------
    wire signed [10:0] bdx_ext = {{2{bdx[8]}}, bdx};
    wire signed [10:0] bdy_ext = {{2{bdy[8]}}, bdy};
    wire signed [10:0] b_e2    = berr <<< 1;
    wire               step_x  = (b_e2 >= bdy_ext);
    wire               step_y  = (b_e2 <= bdx_ext);
    wire signed [8:0]  bsx_ext = {{7{bsx[1]}}, bsx};
    wire signed [8:0]  bsy_ext = {{7{bsy[1]}}, bsy};
    wire signed [10:0] berr_nx = berr + (step_x ? bdy_ext : 11'sd0)
                                      + (step_y ? bdx_ext : 11'sd0);

    // Pixel address in FB when plotting current (bx, by)
    wire               in_screen = (bx >= 9'sd0) && (bx <= 9'sd127)
                                 && (by >= 9'sd0) && (by <= 9'sd63);
    wire [9:0]         pix_addr  = {by[5:3], bx[6:0]};
    wire [7:0]         new_mask  = 8'd1 << by[2:0];

    // Text
    wire [3:0] cur_char = (!txt_phase) ? top_char(txt_char_idx)
                                       : (mode_r ? bot_ani_char(txt_char_idx)
                                                 : bot_sta_char(txt_char_idx));
    wire [2:0] cur_page = (!txt_phase) ? TOP_PAGE : BOT_PAGE;
    wire [6:0] cur_col0 = (!txt_phase) ? TOP_COL0
                                       : (mode_r ? BOT_ANI_COL0 : BOT_STA_COL0);
    wire [2:0] cur_last = (!txt_phase) ? TOP_LEN_M1
                                       : (mode_r ? ANI_LEN_M1 : STA_LEN_M1);

    // Text glyph base column = cur_col0 + char_idx·6  (= char_idx·4 + char_idx·2)
    wire [5:0] txt_char_mul6 = {txt_char_idx, 2'b00} + {1'b0, txt_char_idx, 1'b0};
    wire [6:0] txt_base_col  = cur_col0 + {1'b0, txt_char_mul6};
    wire [6:0] txt_col       = txt_base_col + {4'd0, txt_col_idx};
    wire [9:0] txt_addr      = {cur_page, txt_col};

    // ---------------------------------------------------------------
    // Main FSM
    // ---------------------------------------------------------------
    integer k;
    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            state        <= S_IDLE;
            ready_o      <= 1'b0;
            fb_we        <= 1'b0;
            fb_waddr     <= 10'd0;
            fb_wdata     <= 8'd0;
            fb_raddr_rmw <= 10'd0;
            clr_idx      <= 11'd0;
            mode_r       <= 1'b0;
            angle_r      <= 6'd0;
            sin_th       <= 9'sd0;
            cos_th       <= 9'sd127;
            vtx_idx      <= 3'd0;
            edge_idx     <= 4'd0;
            bx           <= 9'sd0;
            by           <= 9'sd0;
            bx_end       <= 9'sd0;
            by_end       <= 9'sd0;
            bdx          <= 9'sd0;
            bdy          <= 9'sd0;
            bsx          <= 2'sd1;
            bsy          <= 2'sd1;
            berr         <= 11'sd0;
            pix_mask     <= 8'd0;
            txt_char_idx <= 3'd0;
            txt_col_idx  <= 3'd0;
            txt_phase    <= 1'b0;
            cur_vx       <= 8'sd0;
            cur_vy       <= 8'sd0;
            cur_vz       <= 8'sd0;
            prod_xc      <= 18'sd0;
            prod_zs      <= 18'sd0;
            prod_xs      <= 18'sd0;
            prod_zc      <= 18'sd0;
            for (k = 0; k < 8; k = k + 1) begin
                vtx_px[k] <= 9'sd0;
                vtx_py[k] <= 9'sd0;
            end
        end else begin
            fb_we <= 1'b0;

            case (state)
            // ----------------------------------------
            S_IDLE: begin
                if (start_i) begin
                    mode_r  <= mode_i;
                    angle_r <= angle_i;
                    ready_o <= 1'b0;
                    clr_idx <= 11'd0;
                    state   <= S_CLEAR;
                end
            end

            // ----- Clear framebuffer to 0x00 -----
            S_CLEAR: begin
                fb_we    <= 1'b1;
                fb_waddr <= clr_idx[9:0];
                fb_wdata <= 8'h00;
                if (clr_idx == 11'd1023) begin
                    clr_idx <= 11'd0;
                    state   <= S_ROT_SETUP;
                end else
                    clr_idx <= clr_idx + 11'd1;
            end

            // ----- Load sin/cos and start vertex rotation -----
            S_ROT_SETUP: begin
                sin_th  <= sin6(angle_r);
                cos_th  <= cos6(angle_r);
                vtx_idx <= 3'd0;
                state   <= S_ROT_LOAD;
            end

            S_ROT_LOAD: begin
                cur_vx <= vx_rom(vtx_idx);
                cur_vy <= vy_rom(vtx_idx);
                cur_vz <= vz_rom(vtx_idx);
                state  <= S_ROT_MUL;
            end

            S_ROT_MUL: begin
                prod_xc <= cur_vx * cos_th;
                prod_zs <= cur_vz * sin_th;
                prod_xs <= cur_vx * sin_th;
                prod_zc <= cur_vz * cos_th;
                state   <= S_ROT_STORE;
            end

            S_ROT_STORE: begin
                vtx_px[vtx_idx] <= rot_px[8:0];
                vtx_py[vtx_idx] <= rot_py[8:0];
                if (vtx_idx == 3'd7) begin
                    edge_idx <= 4'd0;
                    state    <= S_EDGE_INIT;
                end else begin
                    vtx_idx <= vtx_idx + 3'd1;
                    state   <= S_ROT_LOAD;
                end
            end

            // ----- Bresenham line rasterisation (12 edges) -----
            S_EDGE_INIT: begin
                bx     <= p0x;
                by     <= p0y;
                bx_end <= p1x;
                by_end <= p1y;
                bdx    <= init_dx;
                bdy    <= init_dy_n;
                bsx    <= init_sx;
                bsy    <= init_sy;
                berr   <= init_err;
                state  <= S_EDGE_SETUP;
            end

            S_EDGE_SETUP: begin
                if (in_screen) begin
                    fb_raddr_rmw <= pix_addr;
                    pix_mask     <= new_mask;
                    state        <= S_EDGE_RD;
                end else begin
                    state <= S_EDGE_STEP;
                end
            end

            S_EDGE_RD: begin
                state <= S_EDGE_WR;
            end

            S_EDGE_WR: begin
                fb_we    <= 1'b1;
                fb_waddr <= fb_raddr_rmw;
                fb_wdata <= fb_rdata_rmw | pix_mask;
                state    <= S_EDGE_STEP;
            end

            S_EDGE_STEP: begin
                if (bx == bx_end && by == by_end) begin
                    if (edge_idx == (NUM_EDGES - 4'd1)) begin
                        txt_phase    <= 1'b0;
                        txt_char_idx <= 3'd0;
                        txt_col_idx  <= 3'd0;
                        state        <= S_TEXT_INIT;
                    end else begin
                        edge_idx <= edge_idx + 4'd1;
                        state    <= S_EDGE_INIT;
                    end
                end else begin
                    berr <= berr_nx;
                    if (step_x) bx <= bx + bsx_ext;
                    if (step_y) by <= by + bsy_ext;
                    state <= S_EDGE_SETUP;
                end
            end

            // ----- Text rendering -----
            S_TEXT_INIT: begin
                state <= S_TEXT_WR;
            end

            S_TEXT_WR: begin
                fb_we    <= 1'b1;
                fb_waddr <= txt_addr;
                fb_wdata <= font_byte({cur_char, txt_col_idx});
                state    <= S_TEXT_NEXT;
            end

            S_TEXT_NEXT: begin
                if (txt_col_idx == 3'd4) begin
                    txt_col_idx <= 3'd0;
                    if (txt_char_idx == cur_last) begin
                        if (!txt_phase) begin
                            txt_phase    <= 1'b1;
                            txt_char_idx <= 3'd0;
                            state        <= S_TEXT_WR;
                        end else begin
                            state <= S_DONE;
                        end
                    end else begin
                        txt_char_idx <= txt_char_idx + 3'd1;
                        state        <= S_TEXT_WR;
                    end
                end else begin
                    txt_col_idx <= txt_col_idx + 3'd1;
                    state       <= S_TEXT_WR;
                end
            end

            S_DONE: begin
                ready_o <= 1'b1;
                state   <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase

            if (start_i && state != S_IDLE) ready_o <= 1'b0;
        end
    end

endmodule
