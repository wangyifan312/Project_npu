`timescale 1ns / 1ps

interface soc_probe_if(input logic clk, input logic rst_n);

  // NPU status from DUT port
  logic [31:0] npu_status;

  // NPU DMA AXI4 read address channel (passive probe)
  logic         npu_m_arvalid;
  logic         npu_m_arready;
  logic [31:0]  npu_m_araddr;
  logic [7:0]   npu_m_arlen;
  logic [2:0]   npu_m_arsize;
  logic [1:0]   npu_m_arburst;

  // NPU DMA AXI4 read data channel (passive probe)
  logic         npu_m_rvalid;
  logic         npu_m_rready;
  logic [255:0] npu_m_rdata;
  logic         npu_m_rlast;
  logic [1:0]   npu_m_rresp;

  // NPU DMA AXI4 write address channel (passive probe)
  logic         npu_m_awvalid;
  logic         npu_m_awready;
  logic [31:0]  npu_m_awaddr;
  logic [7:0]   npu_m_awlen;
  logic [2:0]   npu_m_awsize;
  logic [1:0]   npu_m_awburst;

  // NPU DMA AXI4 write data channel (passive probe)
  logic         npu_m_wvalid;
  logic         npu_m_wready;
  logic [255:0] npu_m_wdata;
  logic         npu_m_wlast;
  logic [31:0]  npu_m_wstrb;

  // NPU DMA AXI4 write response channel (passive probe)
  logic         npu_m_bvalid;
  logic         npu_m_bready;
  logic [1:0]   npu_m_bresp;

  // NPU DMA writer internal state (for dual utilization metrics)
  logic         npu_dma_wr_busy;          // writer FSM not idle (includes S_WAIT_DATA)
  logic         npu_dma_wr_txn_active;    // S_AW|S_WDATA|S_WAIT_B window

endinterface
