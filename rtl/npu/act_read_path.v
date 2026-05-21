// act_read_path: activation read DMA wrapper
// Wraps dma_axi_reader, provides buffer write port interface
// Spec §4.2: logically separate from weight_read_path, shares AXI4 read port externally
`timescale 1ns / 1ps

module act_read_path #(
    parameter AXI_ADDR_W = 32,
    parameter AXI_DATA_W = 32,
    parameter BUF_DATA_W  = 32,
    parameter BUF_ADDR_W  = 10
) (
    input  wire        clk,
    input  wire        rst_n,

    // Control
    input  wire                        start,
    input  wire [AXI_ADDR_W-1:0]       base_addr,
    input  wire [31:0]                 byte_count,
    output wire                        done,
    output wire                        error,
    output wire [7:0]                  error_code,
    output wire                        busy,

    // Buffer write port (to npu_buffer)
    output wire [BUF_ADDR_W-1:0]       buf_wr_addr,
    output wire [BUF_DATA_W-1:0]       buf_wr_data,
    output wire                        buf_wr_en,

    // AXI4 Read Master (shared bus)
    output wire [AXI_ADDR_W-1:0]       m_axi_araddr,
    output wire                        m_axi_arvalid,
    input  wire                        m_axi_arready,
    output wire [7:0]                  m_axi_arlen,
    output wire [2:0]                  m_axi_arsize,
    output wire [1:0]                  m_axi_arburst,
    input  wire [AXI_DATA_W-1:0]       m_axi_rdata,
    input  wire                        m_axi_rvalid,
    output wire                        m_axi_rready,
    input  wire                        m_axi_rlast,
    input  wire [1:0]                  m_axi_rresp
);

    wire [AXI_DATA_W-1:0] dma_data_out;
    wire                  dma_data_valid;
    wire                  dma_data_ready;

    // Buffer write address counter
    reg [BUF_ADDR_W-1:0] wr_addr_cnt;

    // DMA reader always ready for data during active transfer
    assign dma_data_ready = 1'b1;

    dma_axi_reader #(
        .AXI_DATA_WIDTH(AXI_DATA_W),
        .AXI_ADDR_WIDTH(AXI_ADDR_W)
    ) u_dma (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .base_addr  (base_addr),
        .byte_count (byte_count),
        .done       (done),
        .error      (error),
        .error_code (error_code),
        .busy       (busy),
        .data_out   (dma_data_out),
        .data_valid (dma_data_valid),
        .data_ready (dma_data_ready),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rresp   (m_axi_rresp)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr_cnt <= 0;
        end else if (start) begin
            wr_addr_cnt <= 0;
        end else if (dma_data_valid && dma_data_ready) begin
            wr_addr_cnt <= wr_addr_cnt + 1;
        end
    end

    assign buf_wr_addr = wr_addr_cnt;
    assign buf_wr_data = dma_data_out;
    assign buf_wr_en   = dma_data_valid && dma_data_ready;

endmodule
