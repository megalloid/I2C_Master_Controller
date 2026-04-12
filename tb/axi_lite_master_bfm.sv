`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// AXI4-Lite Master BFM — behavioural bus-functional model for simulation
// ---------------------------------------------------------------------------
module axi_lite_master_bfm #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 5
)(
    input  wire                    clk,
    input  wire                    rst_n,

    output reg  [ADDR_WIDTH-1:0]   m_axi_awaddr,
    output reg                     m_axi_awvalid,
    input  wire                    m_axi_awready,

    output reg  [DATA_WIDTH-1:0]   m_axi_wdata,
    output reg  [DATA_WIDTH/8-1:0] m_axi_wstrb,
    output reg                     m_axi_wvalid,
    input  wire                    m_axi_wready,

    input  wire [1:0]              m_axi_bresp,
    input  wire                    m_axi_bvalid,
    output reg                     m_axi_bready,

    output reg  [ADDR_WIDTH-1:0]   m_axi_araddr,
    output reg                     m_axi_arvalid,
    input  wire                    m_axi_arready,

    input  wire [DATA_WIDTH-1:0]   m_axi_rdata,
    input  wire [1:0]              m_axi_rresp,
    input  wire                    m_axi_rvalid,
    output reg                     m_axi_rready
);

    initial begin
        m_axi_awaddr  = 0;
        m_axi_awvalid = 0;
        m_axi_wdata   = 0;
        m_axi_wstrb   = 0;
        m_axi_wvalid  = 0;
        m_axi_bready  = 0;
        m_axi_araddr  = 0;
        m_axi_arvalid = 0;
        m_axi_rready  = 0;
    end

    // ---------------------------------------------------------------
    // AXI write
    // ---------------------------------------------------------------
    task axi_write(
        input [ADDR_WIDTH-1:0] addr,
        input [DATA_WIDTH-1:0] data
    );
        reg aw_accepted, w_accepted;
        begin
            @(posedge clk);
            m_axi_awaddr  <= addr;
            m_axi_awvalid <= 1'b1;
            m_axi_wdata   <= data;
            m_axi_wstrb   <= {(DATA_WIDTH/8){1'b1}};
            m_axi_wvalid  <= 1'b1;
            m_axi_bready  <= 1'b1;
            aw_accepted = 0;
            w_accepted  = 0;

            while (!aw_accepted || !w_accepted) begin
                @(posedge clk);
                if (m_axi_awready && m_axi_awvalid && !aw_accepted) begin
                    m_axi_awvalid <= 1'b0;
                    aw_accepted = 1;
                end
                if (m_axi_wready && m_axi_wvalid && !w_accepted) begin
                    m_axi_wvalid <= 1'b0;
                    w_accepted = 1;
                end
            end

            // Wait for write response
            @(posedge clk);
            while (!(m_axi_bvalid && m_axi_bready)) @(posedge clk);
            m_axi_bready <= 1'b0;
        end
    endtask

    // ---------------------------------------------------------------
    // AXI read
    // ---------------------------------------------------------------
    task axi_read(
        input  [ADDR_WIDTH-1:0] addr,
        output [DATA_WIDTH-1:0] data
    );
        begin
            @(posedge clk);
            m_axi_araddr  <= addr;
            m_axi_arvalid <= 1'b1;
            m_axi_rready  <= 1'b1;

            @(posedge clk);
            while (!(m_axi_arready && m_axi_arvalid)) @(posedge clk);
            m_axi_arvalid <= 1'b0;

            while (!(m_axi_rvalid && m_axi_rready)) @(posedge clk);
            data = m_axi_rdata;
            m_axi_rready <= 1'b0;
        end
    endtask

endmodule
