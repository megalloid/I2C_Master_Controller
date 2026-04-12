`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// I2C Master Core — bit/byte-level I2C master controller
//
// Atomic commands: START, WRITE (byte), READ (byte), STOP, RESTART
// Each byte = 9 bit-slots (8 data + 1 ACK/NACK).
// Each bit-slot = 4 clock-enable phases (quarter-SCL periods).
// Clock stretching supported: waits for SCL release in phases where SCL
// is expected high.
// Arbitration lost detection: monitors SDA when master expects it high.
// Open-drain outputs: oen=1 → release (high-Z pulled up), oen=0 → drive low.
// ---------------------------------------------------------------------------
module i2c_master_core (
    input  wire        clk_i,
    input  wire        rstn_i,
    input  wire        ena_i,            // 1-tick pulse per quarter-SCL period

    // Command interface (active when ready_o == 1)
    input  wire        cmd_valid_i,      // Level: held high until accepted
    input  wire [2:0]  cmd_i,            // Command code
    input  wire [7:0]  din_i,            // TX data (WRITE) / {7'bx, NACK} (READ)

    output reg  [7:0]  dout_o,           // RX data (valid after READ completes)
    output reg         rx_ack_o,         // ACK received from slave (0=ACK,1=NACK)
    output reg         ready_o,          // Ready to accept next command

    // Status
    output reg         arb_lost_o,       // Arbitration lost (sticky, clear via _clear_i)
    input  wire        arb_lost_clear_i, // Pulse to clear arb_lost_o
    output reg         busy_o,           // I2C bus busy (START seen, no STOP yet)

    // I2C pad interface — directly to tri-state buffers
    input  wire        scl_i,            // SCL pad input  (synchronised externally)
    output reg         scl_oen_o,        // SCL output-enable: 1=release, 0=drive low
    input  wire        sda_i,            // SDA pad input  (synchronised externally)
    output reg         sda_oen_o         // SDA output-enable: 1=release, 0=drive low
);

    // ---------------------------------------------------------------
    // Command encoding
    // ---------------------------------------------------------------
    localparam [2:0] CMD_NOP     = 3'd0,
                     CMD_START   = 3'd1,
                     CMD_WRITE   = 3'd2,
                     CMD_READ    = 3'd3,
                     CMD_STOP    = 3'd4,
                     CMD_RESTART = 3'd5;

    // ---------------------------------------------------------------
    // FSM states (high-level)  +  phase counter (0-3 per operation)
    // ---------------------------------------------------------------
    localparam [2:0] ST_IDLE    = 3'd0,
                     ST_START   = 3'd1,
                     ST_DATA    = 3'd2,
                     ST_STOP    = 3'd3,
                     ST_RESTART = 3'd4;

    reg [2:0] state_r;
    reg [1:0] phase_r;
    reg [2:0] cmd_r;         // Latched command (WRITE / READ) for data transfer
    reg [3:0] bit_cnt_r;     // 0..8  (9 bit-slots per byte)
    reg [8:0] tx_shift_r;    // TX shift register  {data[7]…data[0], ack_ctl}
    reg [8:0] rx_shift_r;    // RX shift register

    // ---------------------------------------------------------------
    // SDA/SCL edge detection — for bus monitoring
    // ---------------------------------------------------------------
    reg sda_d_r;

    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i)
            sda_d_r <= 1'b1;
        else
            sda_d_r <= sda_i;
    end

    wire sda_rising  =  sda_i & ~sda_d_r;
    wire sda_falling = ~sda_i &  sda_d_r;

    // ---------------------------------------------------------------
    // Bus BUSY tracking (any START/STOP on the bus)
    // ---------------------------------------------------------------
    wire start_on_bus = sda_falling & scl_i;
    wire stop_on_bus  = sda_rising  & scl_i;

    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i)
            busy_o <= 1'b0;
        else if (start_on_bus)
            busy_o <= 1'b1;
        else if (stop_on_bus)
            busy_o <= 1'b0;
    end

    // ---------------------------------------------------------------
    // SDA direction helpers
    // ---------------------------------------------------------------
    // sda_input_mode = 1 when the *slave* should be driving SDA:
    //   READ  bits 0-7  — slave sends data
    //   WRITE bit  8    — slave sends ACK/NACK
    wire sda_input_mode = (state_r == ST_DATA) && (
        (cmd_r == CMD_READ  && bit_cnt_r < 4'd8) ||
        (cmd_r == CMD_WRITE && bit_cnt_r == 4'd8)
    );

    // ---------------------------------------------------------------
    // Arbitration lost detection
    // ---------------------------------------------------------------
    // We lose arbitration when we release SDA (expect high) but read low
    // while SCL is high.  Checked in DATA phase-1 (SCL just went high)
    // and during START/RESTART when SDA should be high.
    wire al_data = (state_r == ST_DATA) && (phase_r == 2'd1) && scl_i &&
                   !sda_input_mode && sda_oen_o && !sda_i;

    wire al_start = (state_r == ST_START   && phase_r == 2'd0 && sda_oen_o && scl_i && !sda_i) ||
                    (state_r == ST_RESTART  && phase_r == 2'd1 && sda_oen_o && scl_i && !sda_i);

    wire al_event = al_data | al_start;

    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i)
            arb_lost_o <= 1'b0;
        else if (arb_lost_clear_i)
            arb_lost_o <= 1'b0;
        else if (ena_i && al_event)
            arb_lost_o <= 1'b1;
    end

    // ---------------------------------------------------------------
    // Main FSM
    // ---------------------------------------------------------------
    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            state_r    <= ST_IDLE;
            phase_r    <= 2'd0;
            cmd_r      <= CMD_NOP;
            bit_cnt_r  <= 4'd0;
            tx_shift_r <= 9'd0;
            rx_shift_r <= 9'd0;
            scl_oen_o  <= 1'b1;
            sda_oen_o  <= 1'b1;
            ready_o    <= 1'b1;
            dout_o     <= 8'd0;
            rx_ack_o   <= 1'b0;
        end else if (ena_i) begin
            // --- arbitration lost: release bus immediately ---
            if (al_event && state_r != ST_IDLE) begin
                state_r   <= ST_IDLE;
                phase_r   <= 2'd0;
                scl_oen_o <= 1'b1;
                sda_oen_o <= 1'b1;
                ready_o   <= 1'b1;
            end else begin

            case (state_r)
            // =======================================================
            // IDLE — wait for a command
            // =======================================================
            ST_IDLE: begin
                if (cmd_valid_i && !arb_lost_o) begin
                    ready_o <= 1'b0;
                    case (cmd_i)
                        CMD_START: begin
                            state_r <= ST_START;
                            phase_r <= 2'd0;
                        end
                        CMD_WRITE: begin
                            state_r    <= ST_DATA;
                            phase_r    <= 2'd0;
                            bit_cnt_r  <= 4'd0;
                            cmd_r      <= CMD_WRITE;
                            tx_shift_r <= {din_i, 1'b0};
                        end
                        CMD_READ: begin
                            state_r    <= ST_DATA;
                            phase_r    <= 2'd0;
                            bit_cnt_r  <= 4'd0;
                            cmd_r      <= CMD_READ;
                            tx_shift_r <= {8'hFF, din_i[0]};
                        end
                        CMD_STOP: begin
                            state_r <= ST_STOP;
                            phase_r <= 2'd0;
                        end
                        CMD_RESTART: begin
                            state_r <= ST_RESTART;
                            phase_r <= 2'd0;
                        end
                        default: ready_o <= 1'b1;
                    endcase
                end else if (!busy_o) begin
                    // Bus not busy (after STOP or at power-up) — release
                    scl_oen_o <= 1'b1;
                    sda_oen_o <= 1'b1;
                end
                // If busy but no command pending: hold SCL/SDA as-is
            end

            // =======================================================
            // START condition: SDA 1→0 while SCL=1
            //   Phase 0 : SDA=1, SCL=1 — wait for SCL high (stretching)
            //   Phase 1 : SDA=1, SCL=1 — hold
            //   Phase 2 : SDA=0, SCL=1 — START
            //   Phase 3 : SDA=0, SCL=0 — done
            // =======================================================
            ST_START: begin
                case (phase_r)
                    2'd0: begin
                        sda_oen_o <= 1'b1;
                        scl_oen_o <= 1'b1;
                        if (scl_i) phase_r <= 2'd1;
                    end
                    2'd1: begin
                        sda_oen_o <= 1'b1;
                        scl_oen_o <= 1'b1;
                        phase_r   <= 2'd2;
                    end
                    2'd2: begin
                        sda_oen_o <= 1'b0;   // SDA LOW — START condition
                        scl_oen_o <= 1'b1;
                        phase_r   <= 2'd3;
                    end
                    2'd3: begin
                        sda_oen_o <= 1'b0;
                        scl_oen_o <= 1'b0;   // SCL LOW
                        state_r   <= ST_IDLE;
                        ready_o   <= 1'b1;
                    end
                endcase
            end

            // =======================================================
            // DATA — 9 bit-slots (8 data + 1 ACK/NACK), 4 phases each
            //   Phase 0 : SCL=0, setup SDA
            //   Phase 1 : SCL=1, sample SDA (wait for stretching)
            //   Phase 2 : SCL=1, hold
            //   Phase 3 : SCL=0, advance bit counter
            // =======================================================
            ST_DATA: begin
                case (phase_r)
                    2'd0: begin
                        scl_oen_o <= 1'b0;
                        if (sda_input_mode)
                            sda_oen_o <= 1'b1;
                        else
                            sda_oen_o <= tx_shift_r[8];
                        phase_r <= 2'd1;
                    end
                    2'd1: begin
                        scl_oen_o <= 1'b1;   // Release SCL
                        if (sda_input_mode)
                            sda_oen_o <= 1'b1;
                        else
                            sda_oen_o <= tx_shift_r[8];
                        if (scl_i) begin      // SCL actually high (stretching done)
                            rx_shift_r <= {rx_shift_r[7:0], sda_i};
                            phase_r    <= 2'd2;
                        end
                    end
                    2'd2: begin
                        scl_oen_o <= 1'b1;
                        if (sda_input_mode)
                            sda_oen_o <= 1'b1;
                        else
                            sda_oen_o <= tx_shift_r[8];
                        phase_r <= 2'd3;
                    end
                    2'd3: begin
                        scl_oen_o <= 1'b0;   // SCL LOW
                        // SDA must NOT change simultaneously with SCL
                        // to avoid spurious START/STOP on the bus.
                        // Phase 0 of the next bit handles SDA setup.
                        if (bit_cnt_r == 4'd8) begin
                            dout_o   <= rx_shift_r[8:1];
                            rx_ack_o <= rx_shift_r[0];
                            state_r  <= ST_IDLE;
                            ready_o  <= 1'b1;
                        end else begin
                            bit_cnt_r  <= bit_cnt_r + 4'd1;
                            tx_shift_r <= {tx_shift_r[7:0], 1'b0};
                            phase_r    <= 2'd0;
                        end
                    end
                endcase
            end

            // =======================================================
            // STOP condition: SDA 0→1 while SCL=1
            //   Phase 0 : SDA=0, SCL=0
            //   Phase 1 : SDA=0, SCL=1 — wait for stretching
            //   Phase 2 : SDA=1, SCL=1 — STOP
            //   Phase 3 : hold — done
            // =======================================================
            ST_STOP: begin
                case (phase_r)
                    2'd0: begin
                        sda_oen_o <= 1'b0;
                        scl_oen_o <= 1'b0;
                        phase_r   <= 2'd1;
                    end
                    2'd1: begin
                        sda_oen_o <= 1'b0;
                        scl_oen_o <= 1'b1;
                        if (scl_i) phase_r <= 2'd2;
                    end
                    2'd2: begin
                        sda_oen_o <= 1'b1;   // SDA HIGH — STOP condition
                        scl_oen_o <= 1'b1;
                        phase_r   <= 2'd3;
                    end
                    2'd3: begin
                        sda_oen_o <= 1'b1;
                        scl_oen_o <= 1'b1;
                        state_r   <= ST_IDLE;
                        ready_o   <= 1'b1;
                    end
                endcase
            end

            // =======================================================
            // RESTART — repeated START
            //   Phase 0 : SDA=1, SCL=0 — release SDA first
            //   Phase 1 : SDA=1, SCL=1 — wait for stretching
            //   Phase 2 : SDA=0, SCL=1 — START condition
            //   Phase 3 : SDA=0, SCL=0 — done
            // =======================================================
            ST_RESTART: begin
                case (phase_r)
                    2'd0: begin
                        sda_oen_o <= 1'b1;
                        scl_oen_o <= 1'b0;
                        phase_r   <= 2'd1;
                    end
                    2'd1: begin
                        sda_oen_o <= 1'b1;
                        scl_oen_o <= 1'b1;
                        if (scl_i) phase_r <= 2'd2;
                    end
                    2'd2: begin
                        sda_oen_o <= 1'b0;   // SDA LOW — START condition
                        scl_oen_o <= 1'b1;
                        phase_r   <= 2'd3;
                    end
                    2'd3: begin
                        sda_oen_o <= 1'b0;
                        scl_oen_o <= 1'b0;
                        state_r   <= ST_IDLE;
                        ready_o   <= 1'b1;
                    end
                endcase
            end

            default: begin
                state_r   <= ST_IDLE;
                scl_oen_o <= 1'b1;
                sda_oen_o <= 1'b1;
                ready_o   <= 1'b1;
            end
            endcase

            end // else (not al_event)
        end // ena_i
    end

endmodule
