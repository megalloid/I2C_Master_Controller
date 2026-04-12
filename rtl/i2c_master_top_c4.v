`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// I2C Master Top — Cyclone IV variant
//
// Wraps i2c_master_avalon with tri-state (inout) pads for SDA/SCL.
// For Platform Designer (Qsys) integration, instantiate i2c_master_avalon
// directly and connect _pad_o / _padoen_o to ALT_IOBUF or bidir pins.
// ---------------------------------------------------------------------------
module i2c_master_top_c4 #(
    parameter DEFAULT_PRESCALE = 16'd124   // 50 MHz → 100 kHz
)(
    // Avalon-MM slave
    input  wire        clk,
    input  wire        reset_n,

    input  wire [2:0]  avs_address,
    input  wire        avs_read,
    output wire [31:0] avs_readdata,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire [3:0]  avs_byteenable,
    output wire        avs_waitrequest,

    // Interrupt
    output wire        irq_o,

    // I2C tri-state pads
    inout  wire        sda_io,
    inout  wire        scl_io
);

    wire scl_pad_i;
    wire scl_pad_o;
    wire scl_padoen;
    wire sda_pad_i;
    wire sda_pad_o;
    wire sda_padoen;

    // Tri-state buffers (open-drain)
    assign scl_io    = scl_padoen ? 1'bz : scl_pad_o;
    assign scl_pad_i = scl_io;

    assign sda_io    = sda_padoen ? 1'bz : sda_pad_o;
    assign sda_pad_i = sda_io;

    i2c_master_avalon #(
        .DEFAULT_PRESCALE (DEFAULT_PRESCALE)
    ) u_avalon (
        .clk            (clk),
        .reset_n        (reset_n),

        .avs_address    (avs_address),
        .avs_read       (avs_read),
        .avs_readdata   (avs_readdata),
        .avs_write      (avs_write),
        .avs_writedata  (avs_writedata),
        .avs_byteenable (avs_byteenable),
        .avs_waitrequest(avs_waitrequest),

        .irq_o          (irq_o),

        .scl_pad_i      (scl_pad_i),
        .scl_pad_o      (scl_pad_o),
        .scl_padoen_o   (scl_padoen),
        .sda_pad_i      (sda_pad_i),
        .sda_pad_o      (sda_pad_o),
        .sda_padoen_o   (sda_padoen)
    );

endmodule
