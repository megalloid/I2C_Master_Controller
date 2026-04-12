`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// I2C Master — Avalon-MM slave wrapper (Intel/Altera)
//
// Drop-in replacement for i2c_master_axi, using Avalon-MM bus protocol
// for NIOS II / Platform Designer integration.
//
// Register map identical to AXI version (32-bit data, byte-address step = 4):
//   0x00  CTRL      R/W   [1:0] = {IEN, EN}
//   0x04  STATUS    R     [3:0] = {AL, BUSY, RXACK, TIP}
//   0x08  CMD       W     [4:0] = {NACK, WR, RD, STO, STA}
//   0x0C  TX_DATA   R/W   [7:0]
//   0x10  RX_DATA   R     [7:0]
//   0x14  PRESCALE  R/W   [15:0]   SCL = clk / (4*(PRESCALE+1))
//   0x18  ISR       R/W1C [1:0] = {AL_IRQ, DONE_IRQ}
// ---------------------------------------------------------------------------
module i2c_master_avalon #(
    parameter DEFAULT_PRESCALE = 16'd249   // 50 MHz → 50 kHz default
)(
    // Avalon-MM slave interface
    input  wire        clk,
    input  wire        reset_n,

    input  wire [2:0]  avs_address,        // Word address (0-6)
    input  wire        avs_read,
    output reg  [31:0] avs_readdata,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire [3:0]  avs_byteenable,
    output wire        avs_waitrequest,

    // Interrupt (directly to NIOS II IRQ controller)
    output wire        irq_o,

    // I2C pads (active-low open-drain)
    input  wire        scl_pad_i,
    output wire        scl_pad_o,
    output wire        scl_padoen_o,       // 1=tristate, 0=drive low
    input  wire        sda_pad_i,
    output wire        sda_pad_o,
    output wire        sda_padoen_o        // 1=tristate, 0=drive low
);

    // Avalon-MM: no wait states for register access
    assign avs_waitrequest = 1'b0;

    // Constant low output (open-drain drives 0 when enabled)
    assign scl_pad_o = 1'b0;
    assign sda_pad_o = 1'b0;

    // ---------------------------------------------------------------
    // 2-stage synchronisers for SDA and SCL inputs
    // ---------------------------------------------------------------
    reg [1:0] scl_sync_r;
    reg [1:0] sda_sync_r;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            scl_sync_r <= 2'b11;
            sda_sync_r <= 2'b11;
        end else begin
            scl_sync_r <= {scl_sync_r[0], scl_pad_i};
            sda_sync_r <= {sda_sync_r[0], sda_pad_i};
        end
    end

    wire scl_sync = scl_sync_r[1];
    wire sda_sync = sda_sync_r[1];

    // ---------------------------------------------------------------
    // Register addresses (word-aligned, address is word index)
    // ---------------------------------------------------------------
    localparam [2:0]
        ADDR_CTRL     = 3'd0,   // 0x00
        ADDR_STATUS   = 3'd1,   // 0x04
        ADDR_CMD      = 3'd2,   // 0x08
        ADDR_TX_DATA  = 3'd3,   // 0x0C
        ADDR_RX_DATA  = 3'd4,   // 0x10
        ADDR_PRESCALE = 3'd5,   // 0x14
        ADDR_ISR      = 3'd6;   // 0x18

    // ---------------------------------------------------------------
    // Software-writable registers
    // ---------------------------------------------------------------
    reg        ctrl_en_r;
    reg        ctrl_ien_r;
    reg [15:0] prescale_r;
    reg [7:0]  tx_data_r;

    reg        cmd_sta_r, cmd_sto_r, cmd_rd_r, cmd_wr_r, cmd_nack_r;
    reg        cmd_write_strobe;

    reg        isr_done_r;
    reg        isr_al_r;

    // ---------------------------------------------------------------
    // Core outputs
    // ---------------------------------------------------------------
    wire [7:0] core_dout;
    wire       core_rx_ack;
    wire       core_ready;
    wire       core_arb_lost;
    wire       core_busy;
    wire       core_scl_oen;
    wire       core_sda_oen;

    assign scl_padoen_o = ctrl_en_r ? core_scl_oen : 1'b1;
    assign sda_padoen_o = ctrl_en_r ? core_sda_oen : 1'b1;

    // ---------------------------------------------------------------
    // Prescaler
    // ---------------------------------------------------------------
    reg [15:0] prescale_cnt_r;
    reg        core_ena_r;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            prescale_cnt_r <= 16'd0;
            core_ena_r     <= 1'b0;
        end else if (!ctrl_en_r) begin
            prescale_cnt_r <= prescale_r;
            core_ena_r     <= 1'b0;
        end else if (prescale_cnt_r == 16'd0) begin
            prescale_cnt_r <= prescale_r;
            core_ena_r     <= 1'b1;
        end else begin
            prescale_cnt_r <= prescale_cnt_r - 16'd1;
            core_ena_r     <= 1'b0;
        end
    end

    // ---------------------------------------------------------------
    // Command sequencer (identical to AXI version)
    // ---------------------------------------------------------------
    localparam [2:0] CMD_C_NOP     = 3'd0,
                     CMD_C_START   = 3'd1,
                     CMD_C_WRITE   = 3'd2,
                     CMD_C_READ    = 3'd3,
                     CMD_C_STOP    = 3'd4,
                     CMD_C_RESTART = 3'd5;

    localparam [2:0] SEQ_IDLE  = 3'd0,
                     SEQ_START = 3'd1,
                     SEQ_WRITE = 3'd2,
                     SEQ_READ  = 3'd3,
                     SEQ_STOP  = 3'd4;

    reg [2:0]  seq_state_r;
    reg        seq_sto_r, seq_wr_r, seq_rd_r, seq_nack_r;
    reg        core_cmd_valid_r;
    reg [2:0]  core_cmd_r;
    reg [7:0]  core_din_r;
    reg        tip_r;
    reg        sub_cmd_sent_r;

    wire       core_arb_lost_clear = cmd_write_strobe;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            seq_state_r      <= SEQ_IDLE;
            core_cmd_valid_r <= 1'b0;
            core_cmd_r       <= CMD_C_NOP;
            core_din_r       <= 8'd0;
            tip_r            <= 1'b0;
            sub_cmd_sent_r   <= 1'b0;
            seq_sto_r        <= 1'b0;
            seq_wr_r         <= 1'b0;
            seq_rd_r         <= 1'b0;
            seq_nack_r       <= 1'b0;
        end else if (!ctrl_en_r) begin
            seq_state_r      <= SEQ_IDLE;
            core_cmd_valid_r <= 1'b0;
            tip_r            <= 1'b0;
            sub_cmd_sent_r   <= 1'b0;
        end else if (core_arb_lost) begin
            seq_state_r      <= SEQ_IDLE;
            core_cmd_valid_r <= 1'b0;
            tip_r            <= 1'b0;
            sub_cmd_sent_r   <= 1'b0;
        end else begin
            case (seq_state_r)

            SEQ_IDLE: begin
                core_cmd_valid_r <= 1'b0;
                sub_cmd_sent_r   <= 1'b0;
                if (cmd_write_strobe) begin
                    tip_r      <= 1'b1;
                    seq_sto_r  <= cmd_sto_r;
                    seq_wr_r   <= cmd_wr_r;
                    seq_rd_r   <= cmd_rd_r;
                    seq_nack_r <= cmd_nack_r;

                    if (cmd_sta_r) begin
                        core_cmd_r       <= core_busy ? CMD_C_RESTART : CMD_C_START;
                        core_cmd_valid_r <= 1'b1;
                        seq_state_r      <= SEQ_START;
                    end else if (cmd_wr_r) begin
                        core_cmd_r       <= CMD_C_WRITE;
                        core_din_r       <= tx_data_r;
                        core_cmd_valid_r <= 1'b1;
                        seq_state_r      <= SEQ_WRITE;
                    end else if (cmd_rd_r) begin
                        core_cmd_r       <= CMD_C_READ;
                        core_din_r       <= {7'd0, cmd_nack_r};
                        core_cmd_valid_r <= 1'b1;
                        seq_state_r      <= SEQ_READ;
                    end else if (cmd_sto_r) begin
                        core_cmd_r       <= CMD_C_STOP;
                        core_cmd_valid_r <= 1'b1;
                        seq_state_r      <= SEQ_STOP;
                    end else begin
                        tip_r <= 1'b0;
                    end
                end
            end

            SEQ_START: begin
                if (!sub_cmd_sent_r) begin
                    if (!core_ready) begin
                        core_cmd_valid_r <= 1'b0;
                        sub_cmd_sent_r   <= 1'b1;
                    end
                end else if (core_ready) begin
                    sub_cmd_sent_r <= 1'b0;
                    if (seq_wr_r) begin
                        core_cmd_r       <= CMD_C_WRITE;
                        core_din_r       <= tx_data_r;
                        core_cmd_valid_r <= 1'b1;
                        seq_state_r      <= SEQ_WRITE;
                    end else if (seq_rd_r) begin
                        core_cmd_r       <= CMD_C_READ;
                        core_din_r       <= {7'd0, seq_nack_r};
                        core_cmd_valid_r <= 1'b1;
                        seq_state_r      <= SEQ_READ;
                    end else begin
                        tip_r       <= 1'b0;
                        seq_state_r <= SEQ_IDLE;
                    end
                end
            end

            SEQ_WRITE: begin
                if (!sub_cmd_sent_r) begin
                    if (!core_ready) begin
                        core_cmd_valid_r <= 1'b0;
                        sub_cmd_sent_r   <= 1'b1;
                    end
                end else if (core_ready) begin
                    sub_cmd_sent_r <= 1'b0;
                    if (seq_sto_r) begin
                        core_cmd_r       <= CMD_C_STOP;
                        core_cmd_valid_r <= 1'b1;
                        seq_state_r      <= SEQ_STOP;
                    end else begin
                        tip_r       <= 1'b0;
                        seq_state_r <= SEQ_IDLE;
                    end
                end
            end

            SEQ_READ: begin
                if (!sub_cmd_sent_r) begin
                    if (!core_ready) begin
                        core_cmd_valid_r <= 1'b0;
                        sub_cmd_sent_r   <= 1'b1;
                    end
                end else if (core_ready) begin
                    sub_cmd_sent_r <= 1'b0;
                    if (seq_sto_r) begin
                        core_cmd_r       <= CMD_C_STOP;
                        core_cmd_valid_r <= 1'b1;
                        seq_state_r      <= SEQ_STOP;
                    end else begin
                        tip_r       <= 1'b0;
                        seq_state_r <= SEQ_IDLE;
                    end
                end
            end

            SEQ_STOP: begin
                if (!sub_cmd_sent_r) begin
                    if (!core_ready) begin
                        core_cmd_valid_r <= 1'b0;
                        sub_cmd_sent_r   <= 1'b1;
                    end
                end else if (core_ready) begin
                    sub_cmd_sent_r <= 1'b0;
                    tip_r          <= 1'b0;
                    seq_state_r    <= SEQ_IDLE;
                end
            end

            default: seq_state_r <= SEQ_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // Interrupt logic
    // ---------------------------------------------------------------
    reg tip_d_r;
    reg core_al_d_r;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tip_d_r     <= 1'b0;
            core_al_d_r <= 1'b0;
        end else begin
            tip_d_r     <= tip_r;
            core_al_d_r <= core_arb_lost;
        end
    end

    wire tip_fall = tip_d_r & ~tip_r;
    wire al_rise  = core_arb_lost & ~core_al_d_r;

    assign irq_o = ctrl_ien_r & (isr_done_r | isr_al_r);

    // ---------------------------------------------------------------
    // Avalon-MM write logic
    // ---------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ctrl_en_r        <= 1'b0;
            ctrl_ien_r       <= 1'b0;
            prescale_r       <= DEFAULT_PRESCALE;
            tx_data_r        <= 8'd0;
            cmd_sta_r        <= 1'b0;
            cmd_sto_r        <= 1'b0;
            cmd_rd_r         <= 1'b0;
            cmd_wr_r         <= 1'b0;
            cmd_nack_r       <= 1'b0;
            cmd_write_strobe <= 1'b0;
            isr_done_r       <= 1'b0;
            isr_al_r         <= 1'b0;
        end else begin
            cmd_write_strobe <= 1'b0;

            // ISR set events
            if (tip_fall) isr_done_r <= 1'b1;
            if (al_rise)  isr_al_r   <= 1'b1;

            if (avs_write) begin
                case (avs_address)
                    ADDR_CTRL: begin
                        if (avs_byteenable[0]) begin
                            ctrl_en_r  <= avs_writedata[0];
                            ctrl_ien_r <= avs_writedata[1];
                        end
                    end
                    ADDR_CMD: begin
                        if (avs_byteenable[0]) begin
                            cmd_sta_r        <= avs_writedata[0];
                            cmd_sto_r        <= avs_writedata[1];
                            cmd_rd_r         <= avs_writedata[2];
                            cmd_wr_r         <= avs_writedata[3];
                            cmd_nack_r       <= avs_writedata[4];
                            cmd_write_strobe <= 1'b1;
                        end
                    end
                    ADDR_TX_DATA: begin
                        if (avs_byteenable[0]) tx_data_r <= avs_writedata[7:0];
                    end
                    ADDR_PRESCALE: begin
                        if (avs_byteenable[0]) prescale_r[7:0]  <= avs_writedata[7:0];
                        if (avs_byteenable[1]) prescale_r[15:8] <= avs_writedata[15:8];
                    end
                    ADDR_ISR: begin
                        if (avs_byteenable[0]) begin
                            if (avs_writedata[0]) isr_done_r <= 1'b0;
                            if (avs_writedata[1]) isr_al_r   <= 1'b0;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    // ---------------------------------------------------------------
    // Avalon-MM read logic (combinational, 0 wait states)
    // ---------------------------------------------------------------
    always @(*) begin
        avs_readdata = 32'd0;
        if (avs_read) begin
            case (avs_address)
                ADDR_CTRL:     avs_readdata[1:0]  = {ctrl_ien_r, ctrl_en_r};
                ADDR_STATUS:   avs_readdata[3:0]  = {core_arb_lost, core_busy, core_rx_ack, tip_r};
                ADDR_TX_DATA:  avs_readdata[7:0]  = tx_data_r;
                ADDR_RX_DATA:  avs_readdata[7:0]  = core_dout;
                ADDR_PRESCALE: avs_readdata[15:0] = prescale_r;
                ADDR_ISR:      avs_readdata[1:0]  = {isr_al_r, isr_done_r};
                default:       avs_readdata        = 32'd0;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // I2C master core instantiation
    // ---------------------------------------------------------------
    i2c_master_core u_core (
        .clk_i            (clk),
        .rstn_i           (reset_n),
        .ena_i            (core_ena_r),

        .cmd_valid_i      (core_cmd_valid_r),
        .cmd_i            (core_cmd_r),
        .din_i            (core_din_r),

        .dout_o           (core_dout),
        .rx_ack_o         (core_rx_ack),
        .ready_o          (core_ready),

        .arb_lost_o       (core_arb_lost),
        .arb_lost_clear_i (core_arb_lost_clear),
        .busy_o           (core_busy),

        .scl_i            (scl_sync),
        .scl_oen_o        (core_scl_oen),
        .sda_i            (sda_sync),
        .sda_oen_o        (core_sda_oen)
    );

endmodule
