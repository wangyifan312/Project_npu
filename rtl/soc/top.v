// top.v: CPU+NPU heterogeneous processor — top-level integration
// PicoRV32 (AXI-Lite) → AXI Interconnect → Memory + NPU registers
// NPU DMA (AXI4) → Memory
`timescale 1ns / 1ps

module top #(
    parameter AXI_ADDR_W = 32,
    parameter AXI_DATA_W = 32
) (
    input  wire        clk,
    input  wire        rst_n,

    // Debug/trace outputs
    output wire        cpu_trap,
    output wire [31:0] npu_status  // {error, done, busy, 1'b0} for quick debug
);

    // ============================================================
    // CPU ↔ Interconnect AXI-Lite
    // ============================================================
    wire        cpu_awvalid, cpu_awready;
    wire [31:0] cpu_awaddr;
    wire [2:0]  cpu_awprot;
    wire        cpu_wvalid, cpu_wready;
    wire [31:0] cpu_wdata;
    wire [3:0]  cpu_wstrb;
    wire        cpu_bvalid, cpu_bready;
    wire [1:0]  cpu_bresp;
    wire        cpu_arvalid, cpu_arready;
    wire [31:0] cpu_araddr;
    wire [2:0]  cpu_arprot;
    wire        cpu_rvalid, cpu_rready;
    wire [31:0] cpu_rdata;
    wire [1:0]  cpu_rresp;

    // ============================================================
    // PicoRV32 CPU (AXI-Lite version)
    // ============================================================
    picorv32_axi #(
        .PROGADDR_RESET(32'h0000_0000),
        .STACKADDR     (32'h0000_1000),
        .ENABLE_MUL    (1),
        .ENABLE_FAST_MUL(1),
        .ENABLE_DIV    (1),
        .COMPRESSED_ISA(1)
    ) u_cpu (
        .clk            (clk),
        .resetn         (rst_n),
        .trap           (cpu_trap),
        .mem_axi_awvalid(cpu_awvalid),
        .mem_axi_awready(cpu_awready),
        .mem_axi_awaddr (cpu_awaddr),
        .mem_axi_awprot (cpu_awprot),
        .mem_axi_wvalid (cpu_wvalid),
        .mem_axi_wready (cpu_wready),
        .mem_axi_wdata  (cpu_wdata),
        .mem_axi_wstrb  (cpu_wstrb),
        .mem_axi_bvalid (cpu_bvalid),
        .mem_axi_bready (cpu_bready),
        .mem_axi_arvalid(cpu_arvalid),
        .mem_axi_arready(cpu_arready),
        .mem_axi_araddr (cpu_araddr),
        .mem_axi_arprot (cpu_arprot),
        .mem_axi_rvalid (cpu_rvalid),
        .mem_axi_rready (cpu_rready),
        .mem_axi_rdata  (cpu_rdata),
        .pcpi_valid     (),
        .pcpi_insn      (),
        .pcpi_rs1       (),
        .pcpi_rs2       (),
        .pcpi_wr        (1'b0),
        .pcpi_rd        (32'h0),
        .pcpi_wait      (1'b0),
        .pcpi_ready     (1'b0),
        .irq            (32'h0),
        .eoi            ()
    );

    // ============================================================
    // Interconnect → NPU registers AXI-Lite
    // ============================================================
    wire        npu_awvalid, npu_awready;
    wire [31:0] npu_awaddr;
    wire        npu_wvalid, npu_wready;
    wire [31:0] npu_wdata;
    wire [3:0]  npu_wstrb;
    wire        npu_bvalid, npu_bready;
    wire [1:0]  npu_bresp;
    wire        npu_arvalid, npu_arready;
    wire [31:0] npu_araddr;
    wire        npu_rvalid, npu_rready;
    wire [31:0] npu_rdata;
    wire [1:0]  npu_rresp;

    // ============================================================
    // Interconnect → Memory AXI-Lite
    // ============================================================
    wire        mem_awvalid, mem_awready;
    wire [31:0] mem_awaddr;
    wire        mem_wvalid, mem_wready;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire        mem_bvalid, mem_bready;
    wire [1:0]  mem_bresp;
    wire        mem_arvalid, mem_arready;
    wire [31:0] mem_araddr;
    wire        mem_rvalid, mem_rready;
    wire [31:0] mem_rdata;
    wire [1:0]  mem_rresp;

    // ============================================================
    // NPU AXI4 master signals (DMA)
    // ============================================================
    wire        npu_m_arvalid, npu_m_arready;
    wire [31:0] npu_m_araddr;
    wire [7:0]  npu_m_arlen;
    wire [2:0]  npu_m_arsize;
    wire [1:0]  npu_m_arburst;
    wire        npu_m_rvalid, npu_m_rready;
    wire [31:0] npu_m_rdata;
    wire        npu_m_rlast;
    wire [1:0]  npu_m_rresp;

    wire        npu_m_awvalid, npu_m_awready;
    wire [31:0] npu_m_awaddr;
    wire [7:0]  npu_m_awlen;
    wire [2:0]  npu_m_awsize;
    wire [1:0]  npu_m_awburst;
    wire        npu_m_wvalid, npu_m_wready;
    wire [31:0] npu_m_wdata;
    wire        npu_m_wlast;
    wire [3:0]  npu_m_wstrb;
    wire        npu_m_bvalid, npu_m_bready;
    wire [1:0]  npu_m_bresp;

    // AXI4 RAM slave signals (from interconnect)
    wire        mem4_awvalid, mem4_awready;
    wire [31:0] mem4_awaddr;
    wire [7:0]  mem4_awlen;
    wire [2:0]  mem4_awsize;
    wire [1:0]  mem4_awburst;
    wire        mem4_wvalid, mem4_wready;
    wire [31:0] mem4_wdata;
    wire        mem4_wlast;
    wire [3:0]  mem4_wstrb;
    wire        mem4_bvalid, mem4_bready;
    wire [1:0]  mem4_bresp;
    wire        mem4_arvalid, mem4_arready;
    wire [31:0] mem4_araddr;
    wire [7:0]  mem4_arlen;
    wire [2:0]  mem4_arsize;
    wire [1:0]  mem4_arburst;
    wire        mem4_rvalid, mem4_rready;
    wire [31:0] mem4_rdata;
    wire        mem4_rlast;
    wire [1:0]  mem4_rresp;

    // NPU status
    wire        npu_busy, npu_done, npu_error;
    wire [7:0]  npu_error_code;

    // ============================================================
    // AXI Interconnect
    // ============================================================
    axi_interconnect u_interconnect (
        .clk          (clk),
        .rst_n        (rst_n),
        // CPU side
        .cpu_awvalid  (cpu_awvalid),
        .cpu_awready  (cpu_awready),
        .cpu_awaddr   (cpu_awaddr),
        .cpu_awprot   (cpu_awprot),
        .cpu_wvalid   (cpu_wvalid),
        .cpu_wready   (cpu_wready),
        .cpu_wdata    (cpu_wdata),
        .cpu_wstrb    (cpu_wstrb),
        .cpu_bvalid   (cpu_bvalid),
        .cpu_bready   (cpu_bready),
        .cpu_bresp    (cpu_bresp),
        .cpu_arvalid  (cpu_arvalid),
        .cpu_arready  (cpu_arready),
        .cpu_araddr   (cpu_araddr),
        .cpu_arprot   (cpu_arprot),
        .cpu_rvalid   (cpu_rvalid),
        .cpu_rready   (cpu_rready),
        .cpu_rdata    (cpu_rdata),
        .cpu_rresp    (cpu_rresp),
        // NPU register side
        .npu_awvalid  (npu_awvalid),
        .npu_awready  (npu_awready),
        .npu_awaddr   (npu_awaddr),
        .npu_wvalid   (npu_wvalid),
        .npu_wready   (npu_wready),
        .npu_wdata    (npu_wdata),
        .npu_wstrb    (npu_wstrb),
        .npu_bvalid   (npu_bvalid),
        .npu_bready   (npu_bready),
        .npu_bresp    (npu_bresp),
        .npu_arvalid  (npu_arvalid),
        .npu_arready  (npu_arready),
        .npu_araddr   (npu_araddr),
        .npu_rvalid   (npu_rvalid),
        .npu_rready   (npu_rready),
        .npu_rdata    (npu_rdata),
        .npu_rresp    (npu_rresp),
        // Memory side
        .mem_awvalid  (mem_awvalid),
        .mem_awready  (mem_awready),
        .mem_awaddr   (mem_awaddr),
        .mem_wvalid   (mem_wvalid),
        .mem_wready   (mem_wready),
        .mem_wdata    (mem_wdata),
        .mem_wstrb    (mem_wstrb),
        .mem_bvalid   (mem_bvalid),
        .mem_bready   (mem_bready),
        .mem_bresp    (mem_bresp),
        .mem_arvalid  (mem_arvalid),
        .mem_arready  (mem_arready),
        .mem_araddr   (mem_araddr),
        .mem_rvalid   (mem_rvalid),
        .mem_rready   (mem_rready),
        .mem_rdata    (mem_rdata),
        .mem_rresp    (mem_rresp),
        // DMA pass-through: NPU AXI4 master → Interconnect → Memory AXI4 slave
        .dma_arvalid  (npu_m_arvalid),
        .dma_araddr   (npu_m_araddr),
        .dma_arlen    (npu_m_arlen),
        .dma_arsize   (npu_m_arsize),
        .dma_arburst  (npu_m_arburst),
        .dma_rready   (npu_m_rready),
        .dma_awvalid  (npu_m_awvalid),
        .dma_awaddr   (npu_m_awaddr),
        .dma_awlen    (npu_m_awlen),
        .dma_awsize   (npu_m_awsize),
        .dma_awburst  (npu_m_awburst),
        .dma_wvalid   (npu_m_wvalid),
        .dma_wdata    (npu_m_wdata),
        .dma_wlast    (npu_m_wlast),
        .dma_wstrb    (npu_m_wstrb),
        .dma_bready   (npu_m_bready),
        .dma_arready  (npu_m_arready),
        .dma_rvalid   (npu_m_rvalid),
        .dma_rdata    (npu_m_rdata),
        .dma_rlast    (npu_m_rlast),
        .dma_rresp    (npu_m_rresp),
        .dma_awready  (npu_m_awready),
        .dma_wready   (npu_m_wready),
        .dma_bvalid   (npu_m_bvalid),
        .dma_bresp    (npu_m_bresp),
        .mem4_awvalid (mem4_awvalid),
        .mem4_awaddr  (mem4_awaddr),
        .mem4_awlen   (mem4_awlen),
        .mem4_awsize  (mem4_awsize),
        .mem4_awburst (mem4_awburst),
        .mem4_wvalid  (mem4_wvalid),
        .mem4_wdata   (mem4_wdata),
        .mem4_wlast   (mem4_wlast),
        .mem4_wstrb   (mem4_wstrb),
        .mem4_bready  (mem4_bready),
        .mem4_arvalid (mem4_arvalid),
        .mem4_araddr  (mem4_araddr),
        .mem4_arlen   (mem4_arlen),
        .mem4_arsize  (mem4_arsize),
        .mem4_arburst (mem4_arburst),
        .mem4_rready  (mem4_rready),
        .mem4_awready (mem4_awready),
        .mem4_wready  (mem4_wready),
        .mem4_bvalid  (mem4_bvalid),
        .mem4_bresp   (mem4_bresp),
        .mem4_arready (mem4_arready),
        .mem4_rvalid  (mem4_rvalid),
        .mem4_rdata   (mem4_rdata),
        .mem4_rlast   (mem4_rlast),
        .mem4_rresp   (mem4_rresp)
    );

    // ============================================================
    // Unified Shared Memory (CPU + NPU DMA access same physical RAM)
    // ============================================================
    shared_ram #(.RAM_DEPTH(16384)) u_shared_ram (
        .clk            (clk),
        .rst_n          (rst_n),
        // CPU AXI-Lite port
        .cpu_awvalid    (mem_awvalid),
        .cpu_awready    (mem_awready),
        .cpu_awaddr     (mem_awaddr),
        .cpu_wvalid     (mem_wvalid),
        .cpu_wready     (mem_wready),
        .cpu_wdata      (mem_wdata),
        .cpu_wstrb      (mem_wstrb),
        .cpu_bvalid     (mem_bvalid),
        .cpu_bready     (mem_bready),
        .cpu_bresp      (mem_bresp),
        .cpu_arvalid    (mem_arvalid),
        .cpu_arready    (mem_arready),
        .cpu_araddr     (mem_araddr),
        .cpu_rvalid     (mem_rvalid),
        .cpu_rready     (mem_rready),
        .cpu_rdata      (mem_rdata),
        .cpu_rresp      (mem_rresp),
        // NPU DMA AXI4 port
        .npu_awvalid    (mem4_awvalid),
        .npu_awready    (mem4_awready),
        .npu_awaddr     (mem4_awaddr),
        .npu_awlen      (mem4_awlen),
        .npu_awsize     (mem4_awsize),
        .npu_awburst    (mem4_awburst),
        .npu_wvalid     (mem4_wvalid),
        .npu_wready     (mem4_wready),
        .npu_wdata      (mem4_wdata),
        .npu_wlast      (mem4_wlast),
        .npu_wstrb      (mem4_wstrb),
        .npu_bvalid     (mem4_bvalid),
        .npu_bready     (mem4_bready),
        .npu_bresp      (mem4_bresp),
        .npu_arvalid    (mem4_arvalid),
        .npu_arready    (mem4_arready),
        .npu_araddr     (mem4_araddr),
        .npu_arlen      (mem4_arlen),
        .npu_arsize     (mem4_arsize),
        .npu_arburst    (mem4_arburst),
        .npu_rvalid     (mem4_rvalid),
        .npu_rready     (mem4_rready),
        .npu_rdata      (mem4_rdata),
        .npu_rlast      (mem4_rlast),
        .npu_rresp      (mem4_rresp)
    );

    // ============================================================
    // NPU Top-Level (register file + task_checker + DMA + buffers + compute)
    // ============================================================
    npu_top u_npu (
        .clk               (clk),
        .rst_n             (rst_n),
        .s_axi_awvalid     (npu_awvalid),
        .s_axi_awready     (npu_awready),
        .s_axi_awaddr      (npu_awaddr),
        .s_axi_wvalid      (npu_wvalid),
        .s_axi_wready      (npu_wready),
        .s_axi_wdata       (npu_wdata),
        .s_axi_wstrb       (npu_wstrb),
        .s_axi_bvalid      (npu_bvalid),
        .s_axi_bready      (npu_bready),
        .s_axi_bresp       (npu_bresp),
        .s_axi_arvalid     (npu_arvalid),
        .s_axi_arready     (npu_arready),
        .s_axi_araddr      (npu_araddr),
        .s_axi_rvalid      (npu_rvalid),
        .s_axi_rready      (npu_rready),
        .s_axi_rdata       (npu_rdata),
        .s_axi_rresp       (npu_rresp),
        .m_axi_arvalid     (npu_m_arvalid),
        .m_axi_arready     (npu_m_arready),
        .m_axi_araddr      (npu_m_araddr),
        .m_axi_arlen       (npu_m_arlen),
        .m_axi_arsize      (npu_m_arsize),
        .m_axi_arburst     (npu_m_arburst),
        .m_axi_rvalid      (npu_m_rvalid),
        .m_axi_rready      (npu_m_rready),
        .m_axi_rdata       (npu_m_rdata),
        .m_axi_rlast       (npu_m_rlast),
        .m_axi_rresp       (npu_m_rresp),
        .m_axi_awvalid     (npu_m_awvalid),
        .m_axi_awready     (npu_m_awready),
        .m_axi_awaddr      (npu_m_awaddr),
        .m_axi_awlen       (npu_m_awlen),
        .m_axi_awsize      (npu_m_awsize),
        .m_axi_awburst     (npu_m_awburst),
        .m_axi_wvalid      (npu_m_wvalid),
        .m_axi_wready      (npu_m_wready),
        .m_axi_wdata       (npu_m_wdata),
        .m_axi_wlast       (npu_m_wlast),
        .m_axi_wstrb       (npu_m_wstrb),
        .m_axi_bvalid      (npu_m_bvalid),
        .m_axi_bready      (npu_m_bready),
        .m_axi_bresp       (npu_m_bresp),
        .npu_busy          (npu_busy),
        .npu_done          (npu_done),
        .npu_error         (npu_error),
        .npu_error_code    (npu_error_code)
    );

    // Status output for debug
    assign npu_status = {24'h0, npu_error, npu_done, npu_busy, 1'b0};

endmodule
