`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// I2C Master Top — convenience wrapper
//
// Instantiates i2c_master_axi and provides tri-state (inout) pads for
// SDA and SCL.  For Zynq block-design integration you may instantiate
// i2c_master_axi directly and wire _pad_o / _padoen_o to IOBUF primitives
// instead.
// ---------------------------------------------------------------------------
module i2c_master_top #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 5,
    parameter DEFAULT_PRESCALE   = 16'd249
)(
    // AXI4-Lite slave
    input  wire                              s_axi_aclk,
    input  wire                              s_axi_aresetn,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire                              s_axi_awvalid,
    output wire                              s_axi_awready,

    input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]   s_axi_wstrb,
    input  wire                              s_axi_wvalid,
    output wire                              s_axi_wready,

    output wire [1:0]                        s_axi_bresp,
    output wire                              s_axi_bvalid,
    input  wire                              s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire                              s_axi_arvalid,
    output wire                              s_axi_arready,

    output wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output wire [1:0]                        s_axi_rresp,
    output wire                              s_axi_rvalid,
    input  wire                              s_axi_rready,

    // Interrupt
    output wire                              irq_o,

    // I2C tri-state pads
    inout  wire                              sda_io,
    inout  wire                              scl_io
);

    // Internal wires between AXI wrapper and pads
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

    i2c_master_axi #(
        .C_S_AXI_DATA_WIDTH (C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH),
        .DEFAULT_PRESCALE   (DEFAULT_PRESCALE)
    ) u_axi (
        .s_axi_aclk    (s_axi_aclk),
        .s_axi_aresetn (s_axi_aresetn),

        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),

        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),

        .irq_o         (irq_o),

        .scl_pad_i     (scl_pad_i),
        .scl_pad_o     (scl_pad_o),
        .scl_padoen_o  (scl_padoen),
        .sda_pad_i     (sda_pad_i),
        .sda_pad_o     (sda_pad_o),
        .sda_padoen_o  (sda_padoen)
    );

endmodule
