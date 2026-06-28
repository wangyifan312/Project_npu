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

  // ---------------------------------------------------------------------------
  // AXI bus cycle counters (accumulated during NPU task window, TB-managed)
  // Cleared by test via clear_bus_counters() before each new task.
  // ---------------------------------------------------------------------------
  logic [31:0]  bus_ar_cycles;     // ARVALID && ARREADY cycles
  logic [31:0]  bus_aw_cycles;     // AWVALID && AWREADY cycles
  logic [31:0]  bus_b_cycles;      // BVALID && BREADY cycles

  function void clear_bus_counters();
    bus_ar_cycles = 32'd0;
    bus_aw_cycles = 32'd0;
    bus_b_cycles  = 32'd0;
  endfunction

  // ---------------------------------------------------------------------------
  // Cluster / tile activity probes (passive, read-only hierarchical observation)
  // ---------------------------------------------------------------------------

  // Per-cluster busy/valid/done (6 clusters)
  logic [5:0]   npu_cluster_busy;
  logic [5:0]   npu_cluster_valid;
  logic [5:0]   npu_cluster_done;

  // Which clusters are enabled this task (from cluster_scheduler)
  logic [5:0]   npu_cluster_enable;
  logic [2:0]   npu_cluster_count;

  // NPU FSM state for activity window detection
  logic [4:0]   npu_fsm_state;

  // Tile clock enables: flat vector [CLUSTER_COUNT*N_TILES-1:0]
  // For parameterization, use a large max width. Actual width depends on
  // TILE_ROWS/TILE_COLS; probes outside the valid range read as 0.
  logic [1535:0] npu_cluster_tile_clk_en_flat;  // max: 6 clusters * 256 tiles

  // NPU task type for context (0=Conv,1=FC,2=Pool,3=Requant,4=GAP,5=ADD)
  logic [2:0]   npu_task_type;

  // ---------------------------------------------------------------------------
  // Sticky activity observation (set by sampling, cleared by test)
  // These accumulate over the NPU busy window via OR-sampling.
  // ---------------------------------------------------------------------------
  bit [5:0]   observed_cluster_busy_mask;
  bit [5:0]   observed_cluster_valid_mask;
  bit [5:0]   observed_cluster_done_mask;
  bit [5:0]   observed_cluster_enable_mask;
  bit         observed_tile_all_on;      // any tile within cluster0 active at some point
  bit         observed_all_clusters_active;

  // Clear all sticky fields. Called by the test before starting a new task.
  function void clear_sticky();
    observed_cluster_busy_mask   = 6'b0;
    observed_cluster_valid_mask  = 6'b0;
    observed_cluster_done_mask   = 6'b0;
    observed_cluster_enable_mask = 6'b0;
    observed_tile_all_on         = 1'b0;
    observed_all_clusters_active = 1'b0;
  endfunction

endinterface
