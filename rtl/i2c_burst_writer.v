`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// I2C Burst Writer — auto-sequences multi-byte I2C write transactions.
//
// Accepts: slave address, byte count, and a data stream.
// Generates: START → WRITE(addr) → WRITE(data[0]) → ... → WRITE(data[N-1]) → STOP
//
// Data source interface: combinational or registered.
//   data_req_o asserted for one cycle → data_i / data_valid_i must be valid.
//   For combinational sources, wire data_valid_i = data_req_o.
// ---------------------------------------------------------------------------
module i2c_burst_writer #(
    parameter CNT_W = 16
)(
    input  wire              clk_i,
    input  wire              rstn_i,

    // Control
    input  wire              start_i,          // Pulse to begin transaction
    input  wire [6:0]        slave_addr_i,     // 7-bit I2C slave address
    input  wire [CNT_W-1:0]  byte_count_i,     // Data bytes to write (after addr)
    output wire              busy_o,
    output reg               done_o,           // One-cycle pulse when complete
    output reg               error_o,          // NACK or arbitration lost

    // Data source
    output wire              data_req_o,       // Request next byte
    input  wire [7:0]        data_i,           // Data byte from source
    input  wire              data_valid_i,     // Source has valid data

    // i2c_master_core command interface
    output reg               cmd_valid_o,
    output reg  [2:0]        cmd_o,
    output reg  [7:0]        din_o,
    input  wire              ready_i,
    input  wire              rx_ack_i,         // 0=ACK, 1=NACK
    input  wire              arb_lost_i
);

    localparam [2:0] CMD_START = 3'd1,
                     CMD_WRITE = 3'd2,
                     CMD_STOP  = 3'd4;

    localparam [3:0] S_IDLE        = 4'd0,
                     S_START_CMD   = 4'd1,
                     S_START_WAIT  = 4'd2,
                     S_ADDR_CMD    = 4'd3,
                     S_ADDR_WAIT   = 4'd4,
                     S_DATA_REQ    = 4'd5,
                     S_DATA_CMD    = 4'd6,
                     S_DATA_WAIT   = 4'd7,
                     S_STOP_CMD    = 4'd8,
                     S_STOP_WAIT   = 4'd9,
                     S_DONE        = 4'd10;

    reg [3:0]        state;
    reg [CNT_W-1:0]  cnt;
    reg [7:0]        addr_byte;
    reg              nack_flag;

    assign busy_o     = (state != S_IDLE);
    assign data_req_o = (state == S_DATA_REQ);

    always @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            state       <= S_IDLE;
            cnt         <= {CNT_W{1'b0}};
            addr_byte   <= 8'd0;
            nack_flag   <= 1'b0;
            cmd_valid_o <= 1'b0;
            cmd_o       <= 3'd0;
            din_o       <= 8'd0;
            done_o      <= 1'b0;
            error_o     <= 1'b0;
        end else begin
            done_o <= 1'b0;

            if (arb_lost_i && busy_o) begin
                cmd_valid_o <= 1'b0;
                nack_flag   <= 1'b1;
                state       <= S_DONE;
            end else begin

            case (state)
            // -------------------------------------------------------
            S_IDLE: begin
                if (start_i) begin
                    addr_byte <= {slave_addr_i, 1'b0};
                    cnt       <= byte_count_i;
                    nack_flag <= 1'b0;
                    error_o   <= 1'b0;
                    state     <= S_START_CMD;
                end
            end

            // -------------------------------------------------------
            // START condition
            // -------------------------------------------------------
            S_START_CMD: begin
                cmd_o <= CMD_START;
                if (ready_i)
                    cmd_valid_o <= 1'b1;
                if (cmd_valid_o && !ready_i) begin
                    cmd_valid_o <= 1'b0;
                    state       <= S_START_WAIT;
                end
            end
            S_START_WAIT: begin
                if (ready_i)
                    state <= S_ADDR_CMD;
            end

            // -------------------------------------------------------
            // Slave address byte (addr << 1 | W=0)
            // -------------------------------------------------------
            S_ADDR_CMD: begin
                cmd_o <= CMD_WRITE;
                din_o <= addr_byte;
                if (ready_i)
                    cmd_valid_o <= 1'b1;
                if (cmd_valid_o && !ready_i) begin
                    cmd_valid_o <= 1'b0;
                    state       <= S_ADDR_WAIT;
                end
            end
            S_ADDR_WAIT: begin
                if (ready_i) begin
                    if (rx_ack_i) begin
                        nack_flag <= 1'b1;
                        state     <= S_STOP_CMD;
                    end else if (cnt == {CNT_W{1'b0}})
                        state <= S_STOP_CMD;
                    else
                        state <= S_DATA_REQ;
                end
            end

            // -------------------------------------------------------
            // Data bytes — request from source, then write
            // -------------------------------------------------------
            S_DATA_REQ: begin
                if (data_valid_i) begin
                    din_o <= data_i;
                    state <= S_DATA_CMD;
                end
            end
            S_DATA_CMD: begin
                cmd_o <= CMD_WRITE;
                if (ready_i)
                    cmd_valid_o <= 1'b1;
                if (cmd_valid_o && !ready_i) begin
                    cmd_valid_o <= 1'b0;
                    state       <= S_DATA_WAIT;
                end
            end
            S_DATA_WAIT: begin
                if (ready_i) begin
                    cnt <= cnt - {{(CNT_W-1){1'b0}}, 1'b1};
                    if (rx_ack_i) begin
                        nack_flag <= 1'b1;
                        state     <= S_STOP_CMD;
                    end else if (cnt == {{(CNT_W-1){1'b0}}, 1'b1})
                        state <= S_STOP_CMD;
                    else
                        state <= S_DATA_REQ;
                end
            end

            // -------------------------------------------------------
            // STOP condition
            // -------------------------------------------------------
            S_STOP_CMD: begin
                cmd_o <= CMD_STOP;
                if (ready_i)
                    cmd_valid_o <= 1'b1;
                if (cmd_valid_o && !ready_i) begin
                    cmd_valid_o <= 1'b0;
                    state       <= S_STOP_WAIT;
                end
            end
            S_STOP_WAIT: begin
                if (ready_i)
                    state <= S_DONE;
            end

            // -------------------------------------------------------
            S_DONE: begin
                done_o  <= 1'b1;
                error_o <= nack_flag;
                state   <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase

            end // arb_lost guard
        end
    end

endmodule
