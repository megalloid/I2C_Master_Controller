`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// I2C Master — AXI4-Lite slave wrapper
//
// Contains: register file, prescaler, command sequencer, interrupt logic,
//           2-stage synchronisers for SDA/SCL inputs, i2c_master_core instance.
//
// Register map  (32-bit data, byte-address step = 4):
//   0x00  CTRL      R/W   [1:0] = {IEN, EN}
//   0x04  STATUS    R     [3:0] = {AL, BUSY, RXACK, TIP}
//   0x08  CMD       W     [4:0] = {NACK, WR, RD, STO, STA}
//   0x0C  TX_DATA   R/W   [7:0]
//   0x10  RX_DATA   R     [7:0]
//   0x14  PRESCALE  R/W   [15:0]   SCL = clk / (4*(PRESCALE+1))
//   0x18  ISR       R/W1C [1:0] = {AL_IRQ, DONE_IRQ}
// ---------------------------------------------------------------------------
module i2c_master_axi #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 5,
    parameter DEFAULT_PRESCALE   = 16'd249   // 100 MHz → 100 kHz
)(
    // AXI4-Lite slave interface
    input  wire                              s_axi_aclk,
    input  wire                              s_axi_aresetn,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire                              s_axi_awvalid,
    output reg                               s_axi_awready,

    input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]   s_axi_wstrb,
    input  wire                              s_axi_wvalid,
    output reg                               s_axi_wready,

    output reg  [1:0]                        s_axi_bresp,
    output reg                               s_axi_bvalid,
    input  wire                              s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire                              s_axi_arvalid,
    output reg                               s_axi_arready,

    output reg  [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output reg  [1:0]                        s_axi_rresp,
    output reg                               s_axi_rvalid,
    input  wire                              s_axi_rready,

    // Interrupt (directly to GIC / concat)
    output wire                              irq_o,

    // I2C pads (active-low open-drain, directly to tri-state buffers)
    input  wire                              scl_pad_i,
    output wire                              scl_pad_o,
    output wire                              scl_padoen_o,  // 1=tristate, 0=drive low
    input  wire                              sda_pad_i,
    output wire                              sda_pad_o,
    output wire                              sda_padoen_o   // 1=tristate, 0=drive low
);

    // ---------------------------------------------------------------
    // Local wires / aliases
    // ---------------------------------------------------------------
    wire clk   = s_axi_aclk;
    wire rst_n = s_axi_aresetn;

    // Constant low output (open-drain drives 0 when enabled)
    assign scl_pad_o = 1'b0;
    assign sda_pad_o = 1'b0;

    // ---------------------------------------------------------------
    // 2-stage synchronisers for SDA and SCL inputs
    // ---------------------------------------------------------------
    reg [1:0] scl_sync_r;
    reg [1:0] sda_sync_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
    // Register addresses
    // ---------------------------------------------------------------
    localparam [C_S_AXI_ADDR_WIDTH-1:0]
        ADDR_CTRL     = 5'h00,
        ADDR_STATUS   = 5'h04,
        ADDR_CMD      = 5'h08,
        ADDR_TX_DATA  = 5'h0C,
        ADDR_RX_DATA  = 5'h10,
        ADDR_PRESCALE = 5'h14,
        ADDR_ISR      = 5'h18;

    // ---------------------------------------------------------------
    // Software-writable registers
    // ---------------------------------------------------------------
    reg        ctrl_en_r;        // CTRL[0]
    reg        ctrl_ien_r;       // CTRL[1]
    reg [15:0] prescale_r;       // PRESCALE
    reg [7:0]  tx_data_r;        // TX_DATA

    // Command register (latched on write, consumed by sequencer)
    reg        cmd_sta_r, cmd_sto_r, cmd_rd_r, cmd_wr_r, cmd_nack_r;
    reg        cmd_write_strobe;

    // Interrupt status (W1C)
    reg        isr_done_r;       // ISR[0]
    reg        isr_al_r;         // ISR[1]

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
    // Prescaler — generate clock enable for core
    // ---------------------------------------------------------------
    reg [15:0] prescale_cnt_r;
    reg        core_ena_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
    // Command sequencer
    //
    // Translates compound CMD register writes (STA+WR, RD+NACK+STO …)
    // into atomic core commands (CMD_START, CMD_WRITE, CMD_READ,
    // CMD_STOP, CMD_RESTART).
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
    reg        sub_cmd_sent_r;      // 0=waiting acceptance, 1=waiting completion

    wire       core_arb_lost_clear = cmd_write_strobe;

    // Track previous core_ready for edge detection (used for interrupt)
    reg        core_ready_d_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) core_ready_d_r <= 1'b1;
        else        core_ready_d_r <= core_ready;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
                end else begin
                    if (core_ready) begin
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
            end

            SEQ_WRITE: begin
                if (!sub_cmd_sent_r) begin
                    if (!core_ready) begin
                        core_cmd_valid_r <= 1'b0;
                        sub_cmd_sent_r   <= 1'b1;
                    end
                end else begin
                    if (core_ready) begin
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
            end

            SEQ_READ: begin
                if (!sub_cmd_sent_r) begin
                    if (!core_ready) begin
                        core_cmd_valid_r <= 1'b0;
                        sub_cmd_sent_r   <= 1'b1;
                    end
                end else begin
                    if (core_ready) begin
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
            end

            SEQ_STOP: begin
                if (!sub_cmd_sent_r) begin
                    if (!core_ready) begin
                        core_cmd_valid_r <= 1'b0;
                        sub_cmd_sent_r   <= 1'b1;
                    end
                end else begin
                    if (core_ready) begin
                        sub_cmd_sent_r <= 1'b0;
                        tip_r          <= 1'b0;
                        seq_state_r    <= SEQ_IDLE;
                    end
                end
            end

            default: seq_state_r <= SEQ_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // Interrupt logic
    // ---------------------------------------------------------------
    // DONE fires on tip falling edge, AL fires on core_arb_lost rising edge
    reg tip_d_r;
    reg core_al_d_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
    // AXI4-Lite write channel
    // ---------------------------------------------------------------
    reg aw_done_r, w_done_r;
    reg [C_S_AXI_ADDR_WIDTH-1:0] aw_addr_r;
    reg [C_S_AXI_DATA_WIDTH-1:0] w_data_r;
    reg [C_S_AXI_DATA_WIDTH/8-1:0] w_strb_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            aw_done_r     <= 1'b0;
            w_done_r      <= 1'b0;
            aw_addr_r     <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            w_data_r      <= {C_S_AXI_DATA_WIDTH{1'b0}};
            w_strb_r      <= {(C_S_AXI_DATA_WIDTH/8){1'b0}};
            ctrl_en_r     <= 1'b0;
            ctrl_ien_r    <= 1'b0;
            prescale_r    <= DEFAULT_PRESCALE;
            tx_data_r     <= 8'd0;
            cmd_sta_r     <= 1'b0;
            cmd_sto_r     <= 1'b0;
            cmd_rd_r      <= 1'b0;
            cmd_wr_r      <= 1'b0;
            cmd_nack_r    <= 1'b0;
            cmd_write_strobe <= 1'b0;
            isr_done_r    <= 1'b0;
            isr_al_r      <= 1'b0;
        end else begin
            // Defaults
            s_axi_awready    <= 1'b0;
            s_axi_wready     <= 1'b0;
            cmd_write_strobe <= 1'b0;

            // ISR set events
            if (tip_fall) isr_done_r <= 1'b1;
            if (al_rise)  isr_al_r   <= 1'b1;

            // Accept write address
            if (s_axi_awvalid && !aw_done_r) begin
                s_axi_awready <= 1'b1;
                aw_addr_r     <= s_axi_awaddr;
                aw_done_r     <= 1'b1;
            end

            // Accept write data
            if (s_axi_wvalid && !w_done_r) begin
                s_axi_wready <= 1'b1;
                w_data_r     <= s_axi_wdata;
                w_strb_r     <= s_axi_wstrb;
                w_done_r     <= 1'b1;
            end

            // Both address and data received — perform write
            if (aw_done_r && w_done_r && !s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;    // OKAY
                aw_done_r    <= 1'b0;
                w_done_r     <= 1'b0;

                case (aw_addr_r)
                    ADDR_CTRL: begin
                        if (w_strb_r[0]) begin
                            ctrl_en_r  <= w_data_r[0];
                            ctrl_ien_r <= w_data_r[1];
                        end
                    end
                    ADDR_CMD: begin
                        if (w_strb_r[0]) begin
                            cmd_sta_r  <= w_data_r[0];
                            cmd_sto_r  <= w_data_r[1];
                            cmd_rd_r   <= w_data_r[2];
                            cmd_wr_r   <= w_data_r[3];
                            cmd_nack_r <= w_data_r[4];
                            cmd_write_strobe <= 1'b1;
                        end
                    end
                    ADDR_TX_DATA: begin
                        if (w_strb_r[0]) tx_data_r <= w_data_r[7:0];
                    end
                    ADDR_PRESCALE: begin
                        if (w_strb_r[0]) prescale_r[7:0]  <= w_data_r[7:0];
                        if (w_strb_r[1]) prescale_r[15:8]  <= w_data_r[15:8];
                    end
                    ADDR_ISR: begin
                        if (w_strb_r[0]) begin
                            if (w_data_r[0]) isr_done_r <= 1'b0;
                            if (w_data_r[1]) isr_al_r   <= 1'b0;
                        end
                    end
                    default: ;
                endcase
            end

            // Write response handshake
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // ---------------------------------------------------------------
    // AXI4-Lite read channel
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= {C_S_AXI_DATA_WIDTH{1'b0}};
            s_axi_rresp   <= 2'b00;
        end else begin
            s_axi_arready <= 1'b0;

            if (s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;
                s_axi_rdata   <= {C_S_AXI_DATA_WIDTH{1'b0}};

                case (s_axi_araddr)
                    ADDR_CTRL:     s_axi_rdata[1:0]  <= {ctrl_ien_r, ctrl_en_r};
                    ADDR_STATUS:   s_axi_rdata[3:0]  <= {core_arb_lost, core_busy, core_rx_ack, tip_r};
                    ADDR_CMD:      s_axi_rdata        <= {C_S_AXI_DATA_WIDTH{1'b0}};
                    ADDR_TX_DATA:  s_axi_rdata[7:0]  <= tx_data_r;
                    ADDR_RX_DATA:  s_axi_rdata[7:0]  <= core_dout;
                    ADDR_PRESCALE: s_axi_rdata[15:0] <= prescale_r;
                    ADDR_ISR:      s_axi_rdata[1:0]  <= {isr_al_r, isr_done_r};
                    default:       s_axi_rdata        <= {C_S_AXI_DATA_WIDTH{1'b0}};
                endcase
            end

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

    // ---------------------------------------------------------------
    // I2C master core instantiation
    // ---------------------------------------------------------------
    i2c_master_core u_core (
        .clk_i            (clk),
        .rstn_i           (rst_n),
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
