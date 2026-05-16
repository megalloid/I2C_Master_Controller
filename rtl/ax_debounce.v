`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// Button debouncer — общий модуль для всех проектов репозитория.
//
// История: исходно — фрагмент ALINX AX301 reference design (стиль *_reg/*_next
// над одним счётчиком + фиксированная разрядность N=32).  Перепрощён к
// одно-процессному стилю; ширина счётчика выводится из CLK_FREQ_HZ/DEBOUNCE_MS
// через $clog2 — никаких ручных N, нет риска переполнения при смене параметров.
//
// API (project-style _i/_o, active-low reset):
//   - CLK_FREQ_HZ  : тактовая частота clk_i в герцах (например 50_000_000)
//   - DEBOUNCE_MS  : длительность стабильности в мс перед фиксацией (~20 мс)
//   - btn_i        : сырой вход кнопки (активный уровень — низкий: pressed = 0)
//   - btn_o        : устаканенное значение (тоже active-low: pressed = 0)
//   - btn_pressed_o   : 1-тактный pulse в момент устаканенного нажатия  (1→0)
//   - btn_released_o  : 1-тактный pulse в момент устаканенного отпускания (0→1)
//
// Логика:
//   1) двух-стадийный синхронизатор   btn_i → dff1 → dff2;
//   2) любое расхождение dff1/dff2 (вход дрогнул) сбрасывает таймер;
//   3) когда таймер досчитан до TIMER_MAX — фиксируем dff2 в btn_o;
//   4) edge-детектор на btn_o выдаёт одно-тактные импульсы pressed/released.
// ---------------------------------------------------------------------------
module ax_debounce #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk_i,
    input  wire rstn_i,                // active-low async reset
    input  wire btn_i,                 // raw input (active-low button)
    output reg  btn_o,                 // debounced level (active-low)
    output reg  btn_pressed_o,         // 1-cycle pulse on press   (1→0)
    output reg  btn_released_o         // 1-cycle pulse on release (0→1)
);

    // Сколько тактов = DEBOUNCE_MS  →  ширина счётчика по $clog2.
    localparam integer TIMER_MAX = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    localparam integer CNT_W     = $clog2(TIMER_MAX + 1);

    reg [CNT_W-1:0] cnt;
    reg             dff1, dff2;
    reg             btn_o_d;

    wire edge_seen  = (dff1 ^ dff2);                          // вход дрогнул
    wire cnt_at_max = (cnt == TIMER_MAX[CNT_W-1:0]);

    // -----------------------------------------------------------------------
    // Sync + debounce-таймер. Один always-блок, приоритеты явные:
    //   reset > edge_seen > increment.
    // -----------------------------------------------------------------------
    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            dff1 <= 1'b1;        // unpressed
            dff2 <= 1'b1;
            cnt  <= {CNT_W{1'b0}};
        end else begin
            dff1 <= btn_i;
            dff2 <= dff1;
            if (edge_seen)        cnt <= {CNT_W{1'b0}};
            else if (!cnt_at_max) cnt <= cnt + 1'b1;
            // если cnt_at_max — стоим до следующего дребезга
        end
    end

    // -----------------------------------------------------------------------
    // Фиксация устаканенного значения: после DEBOUNCE_MS стабильности.
    // -----------------------------------------------------------------------
    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i)
            btn_o <= 1'b1;                // unpressed
        else if (cnt_at_max)
            btn_o <= dff2;
    end

    // -----------------------------------------------------------------------
    // Edge-детектор: pressed_o (1→0) и released_o (0→1).
    // -----------------------------------------------------------------------
    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            btn_o_d         <= 1'b1;
            btn_pressed_o   <= 1'b0;
            btn_released_o  <= 1'b0;
        end else begin
            btn_o_d         <= btn_o;
            btn_pressed_o   <=  btn_o_d & ~btn_o;   // press   = 1 → 0
            btn_released_o  <= ~btn_o_d &  btn_o;   // release = 0 → 1
        end
    end

endmodule
