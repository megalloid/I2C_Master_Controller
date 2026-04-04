`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// I2C Slave Model — behavioural model for simulation
//
// Emulates a generic I2C slave with 256-byte memory (like AT24C02 EEPROM).
// - 7-bit addressing, ACK/NACK, byte-write, byte-read, sequential read
// - Open-drain: sda_out_en=1 → drive SDA low, sda_out_en=0 → release (high-Z)
// ---------------------------------------------------------------------------
module i2c_slave_model #(
    parameter [6:0] I2C_ADDR = 7'h50,
    parameter       MEM_SIZE = 256
)(
    inout wire sda_io,
    inout wire scl_io
);

    // Internal memory
    reg [7:0] mem [0:MEM_SIZE-1];

    // Open-drain SDA driver
    reg sda_out_en;
    assign sda_io = sda_out_en ? 1'b0 : 1'bz;
    assign scl_io = 1'bz;

    // FSM states
    localparam [3:0]
        S_IDLE      = 4'd0,
        S_ADDR_IN   = 4'd1,   // Receiving 8-bit address byte
        S_ADDR_ACK  = 4'd2,   // Driving ACK for address
        S_REG_IN    = 4'd3,   // Receiving register-pointer byte
        S_REG_ACK   = 4'd4,   // Driving ACK for register pointer
        S_WR_IN     = 4'd5,   // Receiving write-data byte
        S_WR_ACK    = 4'd6,   // Driving ACK for write data
        S_RD_OUT    = 4'd7,   // Driving read-data bit
        S_RD_MACK   = 4'd8;   // Waiting for master ACK/NACK after read byte

    reg [3:0]  state;
    reg [7:0]  sr;           // Shift register
    reg [3:0]  bcnt;         // Bit counter
    reg [7:0]  mem_ptr;      // Memory address pointer
    reg        rw_bit;       // 0=write, 1=read

    // Initialise memory with known pattern
    integer k;
    initial begin
        sda_out_en = 0;
        state      = S_IDLE;
        sr         = 0;
        bcnt       = 0;
        mem_ptr    = 0;
        rw_bit     = 0;
        for (k = 0; k < MEM_SIZE; k = k + 1)
            mem[k] = k[7:0];
    end

    // ---------------------------------------------------------------
    // START detection (SDA falls while SCL high)
    // ---------------------------------------------------------------
    always @(negedge sda_io) begin
        if (scl_io === 1'b1) begin
            state      <= S_ADDR_IN;
            bcnt       <= 0;
            sr         <= 0;
            sda_out_en <= 0;
        end
    end

    // ---------------------------------------------------------------
    // STOP detection (SDA rises while SCL high)
    // ---------------------------------------------------------------
    always @(posedge sda_io) begin
        if (scl_io === 1'b1) begin
            state      <= S_IDLE;
            sda_out_en <= 0;
        end
    end

    // ---------------------------------------------------------------
    // SCL rising edge: sample SDA (for bytes coming from master) or
    // sample master ACK/NACK (after read byte)
    // ---------------------------------------------------------------
    always @(posedge scl_io) begin
        case (state)
            S_ADDR_IN, S_REG_IN, S_WR_IN: begin
                sr   <= {sr[6:0], sda_io};
                bcnt <= bcnt + 4'd1;
            end
            S_RD_MACK: begin
                if (sda_io === 1'b0) begin
                    // Master ACK → send next byte
                    mem_ptr <= mem_ptr + 8'd1;
                end else begin
                    // Master NACK → stop
                    state      <= S_IDLE;
                    sda_out_en <= 0;
                end
            end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------
    // SCL falling edge: drive SDA, handle state transitions
    // ---------------------------------------------------------------
    always @(negedge scl_io) begin
        case (state)

            // --- Address byte received ---
            S_ADDR_IN: begin
                if (bcnt == 4'd8) begin
                    if (sr[7:1] == I2C_ADDR) begin
                        rw_bit     <= sr[0];
                        sda_out_en <= 1;         // ACK (drive SDA low)
                        state      <= S_ADDR_ACK;
                    end else begin
                        sda_out_en <= 0;         // NACK
                        state      <= S_IDLE;
                    end
                end
            end

            // --- After address ACK ---
            S_ADDR_ACK: begin
                bcnt <= 0;
                sr   <= 0;
                if (rw_bit) begin
                    // Read: drive first data bit immediately
                    sda_out_en <= mem[mem_ptr][7] ? 1'b0 : 1'b1;
                    bcnt       <= 4'd1;
                    state      <= S_RD_OUT;
                end else begin
                    // Write: receive register-pointer byte
                    sda_out_en <= 0;             // Release ACK
                    state      <= S_REG_IN;
                end
            end

            // --- Register-pointer byte received ---
            S_REG_IN: begin
                if (bcnt == 4'd8) begin
                    mem_ptr    <= sr;
                    sda_out_en <= 1;             // ACK
                    state      <= S_REG_ACK;
                end
            end

            // --- After register-pointer ACK ---
            S_REG_ACK: begin
                sda_out_en <= 0;
                bcnt       <= 0;
                sr         <= 0;
                state      <= S_WR_IN;
            end

            // --- Write-data byte received ---
            S_WR_IN: begin
                if (bcnt == 4'd8) begin
                    mem[mem_ptr] <= sr;
                    mem_ptr      <= mem_ptr + 8'd1;
                    sda_out_en   <= 1;           // ACK
                    state        <= S_WR_ACK;
                end
            end

            // --- After write-data ACK ---
            S_WR_ACK: begin
                sda_out_en <= 0;
                bcnt       <= 0;
                sr         <= 0;
                state      <= S_WR_IN;
            end

            // --- Read: drive data bits ---
            S_RD_OUT: begin
                if (bcnt < 4'd8) begin
                    sda_out_en <= mem[mem_ptr][7 - bcnt] ? 1'b0 : 1'b1;
                    bcnt       <= bcnt + 4'd1;
                end else begin
                    sda_out_en <= 0;             // Release SDA for master ACK/NACK
                    state      <= S_RD_MACK;
                end
            end

            // --- After master ACK (NACK handled in posedge block) ---
            S_RD_MACK: begin
                // If we reach here, state was NOT changed to IDLE → master sent ACK.
                // mem_ptr was already incremented in posedge block.
                bcnt       <= 4'd1;
                sda_out_en <= mem[mem_ptr][7] ? 1'b0 : 1'b1;
                state      <= S_RD_OUT;
            end

            default: ;
        endcase
    end

endmodule
