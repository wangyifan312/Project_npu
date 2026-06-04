// axi_interconnect: simple AXI address decoder + mux
// Routes: CPU (AXI-Lite master) → Memory or NPU registers
//          NPU DMA (AXI4 master) → Memory
`timescale 1ns / 1ps

module axi_interconnect #(
    parameter AXI_ADDR_W      = 32,
    parameter CPU_AXI_DATA_W  = 32,
    parameter DMA_AXI_DATA_W  = 256,
    parameter NPU_BASE   = 32'h1000_0000,
    parameter NPU_MASK   = 32'hFFFF_FF00  // 256B NPU register space
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

    // Address decode: is this an NPU access?
    wire is_npu_aw = (cpu_awaddr & NPU_MASK) == NPU_BASE;
    wire is_npu_ar = (cpu_araddr & NPU_MASK) == NPU_BASE;

    // Latched target selection — safe against AW/W and AR/R decoupling
    reg  wr_target_npu;  // 1 = NPU, 0 = Memory (write transaction)
    reg  rd_target_npu;  // 1 = NPU, 0 = Memory (read transaction)
    reg  aw_seen;        // AW received for current write (prevents W-before-AW routing)

    wire aw_hs = cpu_awvalid && cpu_awready;
    wire ar_hs = cpu_arvalid && cpu_arready;
    wire w_hs  = cpu_wvalid  && cpu_wready;
    wire b_hs  = cpu_bvalid  && cpu_bready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_target_npu <= 1'b0;
            rd_target_npu <= 1'b0;
            aw_seen       <= 1'b0;
        end else begin
            if (aw_hs) begin
                wr_target_npu <= is_npu_aw;
                aw_seen       <= 1'b1;
            end
            // Clear aw_seen when write transaction completes (B accepted)
            if (b_hs)
                aw_seen <= 1'b0;
            if (ar_hs)
                rd_target_npu <= is_npu_ar;
        end
    end

    // === CPU → NPU (when write target is NPU) ===
    assign npu_awvalid = cpu_awvalid && is_npu_aw;
    assign npu_awaddr  = cpu_awaddr;
    assign npu_wvalid  = cpu_wvalid && wr_target_npu && aw_seen;
    assign npu_wdata   = cpu_wdata;
    assign npu_wstrb   = cpu_wstrb;
    assign npu_bready  = cpu_bready && wr_target_npu;
    assign npu_arvalid = cpu_arvalid && is_npu_ar;
    assign npu_araddr  = cpu_araddr;
    assign npu_rready  = cpu_rready && rd_target_npu;

    // === CPU → Memory (when write target is Memory) ===
    assign mem_awvalid = cpu_awvalid && !is_npu_aw;
    assign mem_awaddr  = cpu_awaddr;
    assign mem_wvalid  = cpu_wvalid && !wr_target_npu && aw_seen;
    assign mem_wdata   = cpu_wdata;
    assign mem_wstrb   = cpu_wstrb;
    assign mem_bready  = cpu_bready && !wr_target_npu;
    assign mem_arvalid = cpu_arvalid && !is_npu_ar;
    assign mem_araddr  = cpu_araddr;
    assign mem_rready  = cpu_rready && !rd_target_npu;

    // === CPU Response mux (use latched targets for W/B/R routing) ===
    assign cpu_awready = is_npu_aw ? npu_awready : mem_awready;
    // W accepted only after AW has been latched for the current transaction.
    // aw_seen=0 → W-before-AW is blocked even if a slave asserts wready.
    assign cpu_wready  = aw_seen && (wr_target_npu ? npu_wready : mem_wready);
    assign cpu_bvalid  = wr_target_npu ? npu_bvalid  : mem_bvalid;
    assign cpu_bresp   = wr_target_npu ? npu_bresp   : mem_bresp;
    assign cpu_arready = is_npu_ar ? npu_arready : mem_arready;
    assign cpu_rvalid  = rd_target_npu ? npu_rvalid  : mem_rvalid;
    assign cpu_rdata   = rd_target_npu ? npu_rdata   : mem_rdata;
    assign cpu_rresp   = rd_target_npu ? npu_rresp   : mem_rresp;

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
