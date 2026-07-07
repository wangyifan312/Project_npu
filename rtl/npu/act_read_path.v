// act_read_path: 激活读取 DMA 封装
// 封装 dma_axi_reader，提供 buffer 写端口接口
//  与 weight_read_path 逻辑分离，外部共享 AXI4 读端口
`timescale 1ns / 1ps

module act_read_path #(
    parameter AXI_ADDR_W = 32,
    parameter AXI_DATA_W = 256,
    parameter BUF_DATA_W  = 256,
    parameter BUF_ADDR_W  = 10
) (
    input  wire        clk,
    input  wire        rst_n,

    // 控制
    input  wire                        start,
    input  wire [AXI_ADDR_W-1:0]       base_addr,
    input  wire [31:0]                 byte_count,
    output wire                        done,
    output wire                        error,
    output wire [7:0]                  error_code,
    output wire                        busy,

    // Buffer 写端口（至 npu_buffer）
    output wire [BUF_ADDR_W-1:0]       buf_wr_addr,
    output wire [BUF_DATA_W-1:0]       buf_wr_data,
    output wire                        buf_wr_en,

    // AXI4 读 Master（共享总线）
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
    wire [(AXI_DATA_W/8)-1:0] dma_data_strb;

    // Buffer 写地址计数器
    reg [BUF_ADDR_W-1:0] wr_addr_cnt;

    // DMA 读取器在活跃传输期间始终准备好接收数据
    assign dma_data_ready = 1'b1;

    // 将字节级 strb 扩展为位级掩码以清零无效字节
    wire [BUF_DATA_W-1:0] strb_mask;
    genvar gi;
    generate
        for (gi = 0; gi < AXI_DATA_W/8; gi = gi + 1) begin : gen_strb_expand
            assign strb_mask[gi*8 +: 8] = {8{dma_data_strb[gi]}};
        end
    endgenerate

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
        .data_strb  (dma_data_strb),
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
    assign buf_wr_data = dma_data_out & strb_mask;
    assign buf_wr_en   = dma_data_valid && dma_data_ready;

endmodule
