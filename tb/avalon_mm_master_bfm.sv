`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// Avalon-MM Master BFM — behavioural bus-functional model for simulation
// ---------------------------------------------------------------------------
module avalon_mm_master_bfm #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 3
)(
    input  wire                    clk,
    input  wire                    reset_n,

    output reg  [ADDR_WIDTH-1:0]   m_avs_address,
    output reg                     m_avs_read,
    input  wire [DATA_WIDTH-1:0]   m_avs_readdata,
    output reg                     m_avs_write,
    output reg  [DATA_WIDTH-1:0]   m_avs_writedata,
    output reg  [DATA_WIDTH/8-1:0] m_avs_byteenable,
    input  wire                    m_avs_waitrequest
);

    initial begin
        m_avs_address    = 0;
        m_avs_read       = 0;
        m_avs_write      = 0;
        m_avs_writedata  = 0;
        m_avs_byteenable = 0;
    end

    // ---------------------------------------------------------------
    // Avalon write (word address)
    // ---------------------------------------------------------------
    task avl_write(
        input [ADDR_WIDTH-1:0] addr,
        input [DATA_WIDTH-1:0] data
    );
        begin
            @(posedge clk);
            m_avs_address    <= addr;
            m_avs_writedata  <= data;
            m_avs_byteenable <= {(DATA_WIDTH/8){1'b1}};
            m_avs_write      <= 1'b1;

            @(posedge clk);
            while (m_avs_waitrequest) @(posedge clk);
            m_avs_write <= 1'b0;
        end
    endtask

    // ---------------------------------------------------------------
    // Avalon read (word address)
    // ---------------------------------------------------------------
    task avl_read(
        input  [ADDR_WIDTH-1:0] addr,
        output [DATA_WIDTH-1:0] data
    );
        begin
            @(posedge clk);
            m_avs_address <= addr;
            m_avs_read    <= 1'b1;

            @(posedge clk);
            while (m_avs_waitrequest) @(posedge clk);
            data = m_avs_readdata;
            m_avs_read <= 1'b0;
        end
    endtask

endmodule
