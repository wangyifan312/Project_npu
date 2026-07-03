// axi_interconnect: simple AXI address decoder + mux
// Routes: CPU (AXI-Lite master) → Memory or NPU registers
//          NPU DMA (AXI4 master) → Memory
`timescale 1ns / 1ps

module axi_interconnect #(
    parameter AXI_ADDR_W      = 32,
    parameter CPU_AXI_DATA_W  = 32,
    parameter DMA_AXI_DATA_W  = 256,
    parameter NPU_BASE   = 32'h1000_0000,
    parameter NPU_MASK   = 32'hFFFF_FE00  // 512B NPU register space (extended for IRQ CSRs)
) (
    input  wire        clk,
    input  wire        rst_n,

    // === CPU AXI-Lite Master ===
    input  wire                        cpu_awvalid,
    output wire                        cpu_awready,
    input  wire [AXI_ADDR_W-1:0]       cpu_awaddr,
    input  wire [2:0]                  cpu_awprot,
    input  wire                        cpu_wvalid,
    output wire                        cpu_wready,
    input  wire [CPU_AXI_DATA_W-1:0]   cpu_wdata,
    input  wire [3:0]                  cpu_wstrb,
    output wire                        cpu_bvalid,
    input  wire                        cpu_bready,
    output wire [1:0]                  cpu_bresp,
    input  wire                        cpu_arvalid,
    output wire                        cpu_arready,
    input  wire [AXI_ADDR_W-1:0]       cpu_araddr,
    input  wire [2:0]                  cpu_arprot,
    output wire                        cpu_rvalid,
    input  wire                        cpu_rready,
    output wire [CPU_AXI_DATA_W-1:0]   cpu_rdata,
    output wire [1:0]                  cpu_rresp,

    // === NPU Register Slave (connected to npu_ctrl) ===
    output wire                        npu_awvalid,
    input  wire                        npu_awready,
    output wire [AXI_ADDR_W-1:0]       npu_awaddr,
    output wire                        npu_wvalid,
    input  wire                        npu_wready,
    output wire [CPU_AXI_DATA_W-1:0]   npu_wdata,
    output wire [3:0]                  npu_wstrb,
    input  wire                        npu_bvalid,
    output wire                        npu_bready,
    input  wire [1:0]                  npu_bresp,
    output wire                        npu_arvalid,
    input  wire                        npu_arready,
    output wire [AXI_ADDR_W-1:0]       npu_araddr,
    input  wire                        npu_rvalid,
    output wire                        npu_rready,
    input  wire [CPU_AXI_DATA_W-1:0]   npu_rdata,
    input  wire [1:0]                  npu_rresp,

    // === Memory Slave (AXI-Lite) ===
    output wire                        mem_awvalid,
    input  wire                        mem_awready,
    output wire [AXI_ADDR_W-1:0]       mem_awaddr,
    output wire                        mem_wvalid,
    input  wire                        mem_wready,
    output wire [CPU_AXI_DATA_W-1:0]   mem_wdata,
    output wire [3:0]                  mem_wstrb,
    input  wire                        mem_bvalid,
    output wire                        mem_bready,
    input  wire [1:0]                  mem_bresp,
    output wire                        mem_arvalid,
    input  wire                        mem_arready,
    output wire [AXI_ADDR_W-1:0]       mem_araddr,
    input  wire                        mem_rvalid,
    output wire                        mem_rready,
    input  wire [CPU_AXI_DATA_W-1:0]   mem_rdata,
    input  wire [1:0]                  mem_rresp,

    // === NPU DMA AXI4 Master (pass-through to memory) ===
    // DMA Read
    input  wire                        dma_arvalid,
    output wire                        dma_arready,
    input  wire [AXI_ADDR_W-1:0]       dma_araddr,
    input  wire [7:0]                  dma_arlen,
    input  wire [2:0]                  dma_arsize,
    input  wire [1:0]                  dma_arburst,
    output wire                        dma_rvalid,
    input  wire                        dma_rready,
    output wire [DMA_AXI_DATA_W-1:0]   dma_rdata,
    output wire                        dma_rlast,
    output wire [1:0]                  dma_rresp,

    // DMA Write
    input  wire                        dma_awvalid,
    output wire                        dma_awready,
    input  wire [AXI_ADDR_W-1:0]       dma_awaddr,
    input  wire [7:0]                  dma_awlen,
    input  wire [2:0]                  dma_awsize,
    input  wire [1:0]                  dma_awburst,
    input  wire                        dma_wvalid,
    output wire                        dma_wready,
    input  wire [DMA_AXI_DATA_W-1:0]   dma_wdata,
    input  wire                        dma_wlast,
    input  wire [(DMA_AXI_DATA_W/8)-1:0] dma_wstrb,
    output wire                        dma_bvalid,
    input  wire                        dma_bready,
    output wire [1:0]                  dma_bresp,

    // === Memory AXI4 Slave port (for DMA) ===
    output wire                        mem4_awvalid,
    input  wire                        mem4_awready,
    output wire [AXI_ADDR_W-1:0]       mem4_awaddr,
    output wire [7:0]                  mem4_awlen,
    output wire [2:0]                  mem4_awsize,
    output wire [1:0]                  mem4_awburst,
    output wire                        mem4_wvalid,
    input  wire                        mem4_wready,
    output wire [DMA_AXI_DATA_W-1:0]   mem4_wdata,
    output wire                        mem4_wlast,
    output wire [(DMA_AXI_DATA_W/8)-1:0] mem4_wstrb,
    input  wire                        mem4_bvalid,
    output wire                        mem4_bready,
    input  wire [1:0]                  mem4_bresp,
    output wire                        mem4_arvalid,
    input  wire                        mem4_arready,
    output wire [AXI_ADDR_W-1:0]       mem4_araddr,
    output wire [7:0]                  mem4_arlen,
    output wire [2:0]                  mem4_arsize,
    output wire [1:0]                  mem4_arburst,
    input  wire                        mem4_rvalid,
    output wire                        mem4_rready,
    input  wire [DMA_AXI_DATA_W-1:0]   mem4_rdata,
    input  wire                        mem4_rlast,
    input  wire [1:0]                  mem4_rresp
);

    localparam [1:0] AXI_RESP_OKAY   = 2'b00;
    localparam [1:0] AXI_RESP_DECERR = 2'b11;
    localparam [1:0] TGT_MEM         = 2'd0;
    localparam [1:0] TGT_NPU         = 2'd1;
    localparam [1:0] TGT_DECERR      = 2'd2;

    function [1:0] decode_cpu_target;
        input [AXI_ADDR_W-1:0] addr;
        begin
            if ((addr & NPU_MASK) == NPU_BASE)
                decode_cpu_target = TGT_NPU;
            else if (addr[31:20] == 12'h000)
                decode_cpu_target = TGT_MEM;
            else
                decode_cpu_target = TGT_DECERR;
        end
    endfunction

    // ============================================================
    // CPU AXI-Lite write bridge
    // ============================================================
    reg                         cpu_aw_buf_valid;
    reg  [AXI_ADDR_W-1:0]       cpu_aw_buf_addr;
    reg                         cpu_w_buf_valid;
    reg  [CPU_AXI_DATA_W-1:0]   cpu_w_buf_data;
    reg  [3:0]                  cpu_w_buf_strb;

    reg                         wr_active;
    reg  [1:0]                  wr_target;
    reg  [AXI_ADDR_W-1:0]       wr_addr;
    reg  [CPU_AXI_DATA_W-1:0]   wr_data;
    reg  [3:0]                  wr_strb;
    reg                         wr_aw_done;
    reg                         wr_w_done;
    reg                         cpu_bvalid_r;
    reg  [1:0]                  cpu_bresp_r;

    wire cpu_aw_hs = cpu_awvalid && cpu_awready;
    wire cpu_w_hs  = cpu_wvalid  && cpu_wready;
    wire cpu_wr_start = !wr_active && !cpu_bvalid_r &&
                        (cpu_aw_buf_valid || cpu_aw_hs) &&
                        (cpu_w_buf_valid || cpu_w_hs);
    wire [AXI_ADDR_W-1:0]     cpu_wr_addr = cpu_aw_hs ? cpu_awaddr : cpu_aw_buf_addr;
    wire [CPU_AXI_DATA_W-1:0] cpu_wr_data = cpu_w_hs  ? cpu_wdata  : cpu_w_buf_data;
    wire [3:0]                cpu_wr_strb = cpu_w_hs  ? cpu_wstrb  : cpu_w_buf_strb;
    wire [1:0]                cpu_wr_target = decode_cpu_target(cpu_wr_addr);

    assign cpu_awready = !cpu_aw_buf_valid && !wr_active && !cpu_bvalid_r;
    assign cpu_wready  = !cpu_w_buf_valid  && !wr_active && !cpu_bvalid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_aw_buf_valid <= 1'b0;
            cpu_aw_buf_addr  <= {AXI_ADDR_W{1'b0}};
            cpu_w_buf_valid  <= 1'b0;
            cpu_w_buf_data   <= {CPU_AXI_DATA_W{1'b0}};
            cpu_w_buf_strb   <= 4'h0;
            wr_active        <= 1'b0;
            wr_target        <= TGT_MEM;
            wr_addr          <= {AXI_ADDR_W{1'b0}};
            wr_data          <= {CPU_AXI_DATA_W{1'b0}};
            wr_strb          <= 4'h0;
            wr_aw_done       <= 1'b0;
            wr_w_done        <= 1'b0;
            cpu_bvalid_r     <= 1'b0;
            cpu_bresp_r      <= AXI_RESP_OKAY;
        end else begin
            if (cpu_aw_hs) begin
                cpu_aw_buf_valid <= 1'b1;
                cpu_aw_buf_addr  <= cpu_awaddr;
            end
            if (cpu_w_hs) begin
                cpu_w_buf_valid <= 1'b1;
                cpu_w_buf_data  <= cpu_wdata;
                cpu_w_buf_strb  <= cpu_wstrb;
            end

            if (cpu_wr_start) begin
                cpu_aw_buf_valid <= 1'b0;
                cpu_w_buf_valid  <= 1'b0;
                wr_target        <= cpu_wr_target;
                wr_addr          <= cpu_wr_addr;
                wr_data          <= cpu_wr_data;
                wr_strb          <= cpu_wr_strb;
                wr_aw_done       <= 1'b0;
                wr_w_done        <= 1'b0;
                if (cpu_wr_target == TGT_DECERR) begin
                    wr_active    <= 1'b0;
                    cpu_bvalid_r <= 1'b1;
                    cpu_bresp_r  <= AXI_RESP_DECERR;
                end else begin
                    wr_active    <= 1'b1;
                end
            end else if (wr_active) begin
                if ((wr_target == TGT_NPU) && npu_awvalid && npu_awready)
                    wr_aw_done <= 1'b1;
                if ((wr_target == TGT_MEM) && mem_awvalid && mem_awready)
                    wr_aw_done <= 1'b1;
                if ((wr_target == TGT_NPU) && npu_wvalid && npu_wready)
                    wr_w_done <= 1'b1;
                if ((wr_target == TGT_MEM) && mem_wvalid && mem_wready)
                    wr_w_done <= 1'b1;

                if ((wr_target == TGT_NPU) && npu_bvalid && npu_bready) begin
                    wr_active    <= 1'b0;
                    cpu_bvalid_r <= 1'b1;
                    cpu_bresp_r  <= npu_bresp;
                end else if ((wr_target == TGT_MEM) && mem_bvalid && mem_bready) begin
                    wr_active    <= 1'b0;
                    cpu_bvalid_r <= 1'b1;
                    cpu_bresp_r  <= mem_bresp;
                end
            end else if (cpu_bvalid_r && cpu_bready) begin
                cpu_bvalid_r <= 1'b0;
            end
        end
    end

    assign npu_awvalid = wr_active && (wr_target == TGT_NPU) && !wr_aw_done;
    assign npu_awaddr  = wr_addr;
    assign npu_wvalid  = wr_active && (wr_target == TGT_NPU) && !wr_w_done;
    assign npu_wdata   = wr_data;
    assign npu_wstrb   = wr_strb;
    assign npu_bready  = wr_active && (wr_target == TGT_NPU) && !cpu_bvalid_r;

    assign mem_awvalid = wr_active && (wr_target == TGT_MEM) && !wr_aw_done;
    assign mem_awaddr  = wr_addr;
    assign mem_wvalid  = wr_active && (wr_target == TGT_MEM) && !wr_w_done;
    assign mem_wdata   = wr_data;
    assign mem_wstrb   = wr_strb;
    assign mem_bready  = wr_active && (wr_target == TGT_MEM) && !cpu_bvalid_r;

    assign cpu_bvalid = cpu_bvalid_r;
    assign cpu_bresp  = cpu_bresp_r;

    // ============================================================
    // CPU AXI-Lite read bridge
    // ============================================================
    reg                       rd_active;
    reg [1:0]                 rd_target;
    reg [AXI_ADDR_W-1:0]      rd_addr;
    reg                       rd_ar_done;
    reg                       cpu_rvalid_r;
    reg [CPU_AXI_DATA_W-1:0]  cpu_rdata_r;
    reg [1:0]                 cpu_rresp_r;

    wire cpu_ar_hs = cpu_arvalid && cpu_arready;
    wire [1:0] cpu_ar_target = decode_cpu_target(cpu_araddr);

    assign cpu_arready = !rd_active && !cpu_rvalid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active    <= 1'b0;
            rd_target    <= TGT_MEM;
            rd_addr      <= {AXI_ADDR_W{1'b0}};
            rd_ar_done   <= 1'b0;
            cpu_rvalid_r <= 1'b0;
            cpu_rdata_r  <= {CPU_AXI_DATA_W{1'b0}};
            cpu_rresp_r  <= AXI_RESP_OKAY;
        end else begin
            if (cpu_ar_hs) begin
                rd_target  <= cpu_ar_target;
                rd_addr    <= cpu_araddr;
                rd_ar_done <= 1'b0;
                if (cpu_ar_target == TGT_DECERR) begin
                    rd_active    <= 1'b0;
                    cpu_rvalid_r <= 1'b1;
                    cpu_rdata_r  <= {CPU_AXI_DATA_W{1'b0}};
                    cpu_rresp_r  <= AXI_RESP_DECERR;
                end else begin
                    rd_active <= 1'b1;
                end
            end else if (rd_active) begin
                if ((rd_target == TGT_NPU) && npu_arvalid && npu_arready)
                    rd_ar_done <= 1'b1;
                if ((rd_target == TGT_MEM) && mem_arvalid && mem_arready)
                    rd_ar_done <= 1'b1;

                if ((rd_target == TGT_NPU) && npu_rvalid && npu_rready) begin
                    rd_active    <= 1'b0;
                    cpu_rvalid_r <= 1'b1;
                    cpu_rdata_r  <= npu_rdata;
                    cpu_rresp_r  <= npu_rresp;
                end else if ((rd_target == TGT_MEM) && mem_rvalid && mem_rready) begin
                    rd_active    <= 1'b0;
                    cpu_rvalid_r <= 1'b1;
                    cpu_rdata_r  <= mem_rdata;
                    cpu_rresp_r  <= mem_rresp;
                end
            end else if (cpu_rvalid_r && cpu_rready) begin
                cpu_rvalid_r <= 1'b0;
            end
        end
    end

    assign npu_arvalid = rd_active && (rd_target == TGT_NPU) && !rd_ar_done;
    assign npu_araddr  = rd_addr;
    assign npu_rready  = rd_active && (rd_target == TGT_NPU) && !cpu_rvalid_r;

    assign mem_arvalid = rd_active && (rd_target == TGT_MEM) && !rd_ar_done;
    assign mem_araddr  = rd_addr;
    assign mem_rready  = rd_active && (rd_target == TGT_MEM) && !cpu_rvalid_r;

    assign cpu_rvalid = cpu_rvalid_r;
    assign cpu_rdata  = cpu_rdata_r;
    assign cpu_rresp  = cpu_rresp_r;

    // === NPU DMA → Memory AXI4 (direct pass-through) ===
    assign mem4_awvalid = dma_awvalid;
    assign mem4_awaddr  = dma_awaddr;
    assign mem4_awlen   = dma_awlen;
    assign mem4_awsize  = dma_awsize;
    assign mem4_awburst = dma_awburst;
    assign mem4_wvalid  = dma_wvalid;
    assign mem4_wdata   = dma_wdata;
    assign mem4_wlast   = dma_wlast;
    assign mem4_wstrb   = dma_wstrb;
    assign mem4_bready  = dma_bready;
    assign mem4_arvalid = dma_arvalid;
    assign mem4_araddr  = dma_araddr;
    assign mem4_arlen   = dma_arlen;
    assign mem4_arsize  = dma_arsize;
    assign mem4_arburst = dma_arburst;
    assign mem4_rready  = dma_rready;

    assign dma_awready = mem4_awready;
    assign dma_wready  = mem4_wready;
    assign dma_bvalid  = mem4_bvalid;
    assign dma_bresp   = mem4_bresp;
    assign dma_arready = mem4_arready;
    assign dma_rvalid  = mem4_rvalid;
    assign dma_rdata   = mem4_rdata;
    assign dma_rlast   = mem4_rlast;
    assign dma_rresp   = mem4_rresp;

endmodule
