//=============================================================================
// tb_soc_top_uvm.sv — Top-level UVM Testbench Module for SoC (top.v)
//=============================================================================

`timescale 1ns / 1ps
`include "soc_top_defines.svh"

module tb_soc_top_uvm;

  import uvm_pkg::*;
  import soc_top_uvm_pkg::*;

  // Clock and reset
  reg clk;
  reg rst_n;

  // Interfaces
  axil_if      axil_vif(.clk(clk), .rst_n(rst_n));
  soc_probe_if probe_vif(.clk(clk), .rst_n(rst_n));
  backdoor_if  bd_if();

  //-----------------------------------------------------------------------------
  // DUT instantiation
  //-----------------------------------------------------------------------------
  top #(
    .NPU_TILE_ROWS(16),
    .NPU_TILE_COLS(16),
    .NPU_CLUSTER_MODE(2'd0),
    .NPU_CLUSTER_MASK_REQ(6'b111111)
  ) u_top (
    .clk            (clk),
    .rst_n          (rst_n),
    .tb_axil_enable (1'b1),

    // AXI-Lite TB interface — write address
    .tb_awvalid     (axil_vif.awvalid),
    .tb_awready     (axil_vif.awready),
    .tb_awaddr      (axil_vif.awaddr),

    // AXI-Lite TB interface — write data
    .tb_wvalid      (axil_vif.wvalid),
    .tb_wready      (axil_vif.wready),
    .tb_wdata       (axil_vif.wdata),
    .tb_wstrb       (axil_vif.wstrb),

    // AXI-Lite TB interface — write response
    .tb_bvalid      (axil_vif.bvalid),
    .tb_bready      (axil_vif.bready),
    .tb_bresp       (axil_vif.bresp),

    // AXI-Lite TB interface — read address
    .tb_arvalid     (axil_vif.arvalid),
    .tb_arready     (axil_vif.arready),
    .tb_araddr      (axil_vif.araddr),

    // AXI-Lite TB interface — read data
    .tb_rvalid      (axil_vif.rvalid),
    .tb_rready      (axil_vif.rready),
    .tb_rdata       (axil_vif.rdata),
    .tb_rresp       (axil_vif.rresp),

    .cpu_trap       (),
    .npu_status     (probe_vif.npu_status)
  );

  //-----------------------------------------------------------------------------
  // Hierarchical probe connections: observe internal DMA wires (read-only)
  // These wires are declared inside top.v; hierarchical references are used
  // for passive observation only.  No signals are driven back into the DUT.
  //-----------------------------------------------------------------------------

  // DMA read address channel
  assign probe_vif.npu_m_arvalid = u_top.npu_m_arvalid;
  assign probe_vif.npu_m_arready = u_top.npu_m_arready;
  assign probe_vif.npu_m_araddr  = u_top.npu_m_araddr;
  assign probe_vif.npu_m_arlen   = u_top.npu_m_arlen;
  assign probe_vif.npu_m_arsize  = u_top.npu_m_arsize;
  assign probe_vif.npu_m_arburst = u_top.npu_m_arburst;

  // DMA read data channel
  assign probe_vif.npu_m_rvalid  = u_top.npu_m_rvalid;
  assign probe_vif.npu_m_rready  = u_top.npu_m_rready;
  assign probe_vif.npu_m_rdata   = u_top.npu_m_rdata;
  assign probe_vif.npu_m_rlast   = u_top.npu_m_rlast;
  assign probe_vif.npu_m_rresp   = u_top.npu_m_rresp;

  // DMA write address channel
  assign probe_vif.npu_m_awvalid = u_top.npu_m_awvalid;
  assign probe_vif.npu_m_awready = u_top.npu_m_awready;
  assign probe_vif.npu_m_awaddr  = u_top.npu_m_awaddr;
  assign probe_vif.npu_m_awlen   = u_top.npu_m_awlen;
  assign probe_vif.npu_m_awsize  = u_top.npu_m_awsize;
  assign probe_vif.npu_m_awburst = u_top.npu_m_awburst;

  // DMA write data channel
  assign probe_vif.npu_m_wvalid  = u_top.npu_m_wvalid;
  assign probe_vif.npu_m_wready  = u_top.npu_m_wready;
  assign probe_vif.npu_m_wdata   = u_top.npu_m_wdata;
  assign probe_vif.npu_m_wlast   = u_top.npu_m_wlast;
  assign probe_vif.npu_m_wstrb   = u_top.npu_m_wstrb;

  // DMA write response channel
  assign probe_vif.npu_m_bvalid  = u_top.npu_m_bvalid;
  assign probe_vif.npu_m_bready  = u_top.npu_m_bready;
  assign probe_vif.npu_m_bresp   = u_top.npu_m_bresp;

  // Write DMA internal state (for dual utilization metrics)
  assign probe_vif.npu_dma_wr_busy       = u_top.u_npu.dma_wr_busy;
  assign probe_vif.npu_dma_wr_txn_active = u_top.u_npu.dma_wr_txn_active;

  //-----------------------------------------------------------------------------
  // Cluster / tile activity probes (passive hierarchical observation)
  //-----------------------------------------------------------------------------
  assign probe_vif.npu_cluster_busy   = u_top.u_npu.cluster_busy;
  assign probe_vif.npu_cluster_valid  = u_top.u_npu.cluster_valid;
  assign probe_vif.npu_cluster_done   = u_top.u_npu.cluster_done;
  assign probe_vif.npu_cluster_enable = u_top.u_npu.perf_cluster_enable;
  assign probe_vif.npu_cluster_count  = u_top.u_npu.perf_cluster_count;
  assign probe_vif.npu_fsm_state      = u_top.u_npu.fsm_state;
  assign probe_vif.npu_task_type      = u_top.u_npu.task_type;

  // Tile clock enables: CLUSTER_COUNT * N_TILES = 1 * 256 = 256
  assign probe_vif.npu_cluster_tile_clk_en_flat =
    u_top.u_npu.cluster_tile_clk_en_all_flat;

  //-----------------------------------------------------------------------------
  // Sticky cluster activity sampling during NPU busy window
  // Read-only: OR-accumulates probe signals into sticky observation fields.
  // Cleared by test via probe_vif.clear_sticky() before each new task.
  //-----------------------------------------------------------------------------
  always @(posedge clk) begin
    if (u_top.u_npu.dma_wr_busy || (|u_top.u_npu.cluster_busy)) begin
      probe_vif.observed_cluster_busy_mask   <= probe_vif.observed_cluster_busy_mask   | probe_vif.npu_cluster_busy;
      probe_vif.observed_cluster_valid_mask  <= probe_vif.observed_cluster_valid_mask  | probe_vif.npu_cluster_valid;
      probe_vif.observed_cluster_done_mask   <= probe_vif.observed_cluster_done_mask   | probe_vif.npu_cluster_done;
      probe_vif.observed_cluster_enable_mask <= probe_vif.observed_cluster_enable_mask | probe_vif.npu_cluster_enable;
      // Check if any tiles in cluster0 are clock-enabled (OR of 256 bits)
      if (|u_top.u_npu.cluster_tile_clk_en_all_flat[255:0])
        probe_vif.observed_tile_all_on <= 1'b1;
      // Check if all 6 clusters busy simultaneously
      if (&u_top.u_npu.cluster_busy[5:0])
        probe_vif.observed_all_clusters_active <= 1'b1;
    end
  end

  //-----------------------------------------------------------------------------
  // AXI bus address/response cycle counters during full NPU task window
  // Gate: npu_status[1] (ctrl_busy) — covers the entire task from start to done.
  // Read data (RVALID&&RREADY) and write data (WVALID&&WREADY) are counted by
  // NPU perf counters (PERF_READ_BEATS and PERF_WRITE_DATA_CYC respectively).
  // These AR/AW/B counters supplement the perf counters for waveform visibility.
  // Cleared by test via probe_vif.clear_bus_counters() before each new task.
  //-----------------------------------------------------------------------------
  always @(posedge clk) begin
    if (u_top.npu_status[1]) begin
      probe_vif.bus_ar_cycles <= probe_vif.bus_ar_cycles + (u_top.npu_m_arvalid && u_top.npu_m_arready);
      probe_vif.bus_aw_cycles <= probe_vif.bus_aw_cycles + (u_top.npu_m_awvalid && u_top.npu_m_awready);
      probe_vif.bus_b_cycles  <= probe_vif.bus_b_cycles  + (u_top.npu_m_bvalid  && u_top.npu_m_bready);
    end
  end

  //-----------------------------------------------------------------------------
  // Clock generation: 200 MHz => 2.5 ns half-period
  //-----------------------------------------------------------------------------
  always #2.5 clk = ~clk;

  //-----------------------------------------------------------------------------
  // Reset generation (separate from run_test to avoid consuming time before UVM)
  //-----------------------------------------------------------------------------
  initial begin
    rst_n = 1'b0;
    #100;
    rst_n = 1'b1;
  end

  //-----------------------------------------------------------------------------
  // UVM test launch — must be at time 0, no delays before run_test()
  //-----------------------------------------------------------------------------
  initial begin
    clk   = 1'b0;

    // Put virtual interfaces in config_db for agents/components
    uvm_config_db#(virtual axil_if)::set(null, "*", "axil_vif", axil_vif);
    uvm_config_db#(virtual soc_probe_if)::set(null, "*", "probe_vif", probe_vif);
    uvm_config_db#(virtual backdoor_if)::set(null, "*", "bd_if", bd_if);

    // Waveform dumping — disabled by default (enable with +WAVES plusarg)
    if ($test$plusargs("WAVES")) begin
      $dumpfile("sim/tb_soc_top_uvm.vcd");
      $dumpvars(0, tb_soc_top_uvm);
    end

    run_test();
  end

  //-----------------------------------------------------------------------------
  // GAP debug monitor: trace internal signals during GAP compute
  //-----------------------------------------------------------------------------
  `ifdef GAP_DEBUG
  localparam [4:0] FSM_GAP_COMPUTE = 5'd29;
  integer gap_dbg_cnt = 0;
  always @(posedge clk) begin
    if (u_top.u_npu.fsm_state == FSM_GAP_COMPUTE) begin
      if (gap_dbg_cnt < 80) begin
        if (!u_top.u_npu.gap_src_wait) begin
          $display("[GAP_DBG] t=%0t sp=%0d sum=%0d sample_i8=%0d sample_i32=%0d sum_next=%0d beat=%0d byte_sel=%0d",
            $time, u_top.u_npu.gap_sp_idx, u_top.u_npu.gap_sum,
            u_top.u_npu.gap_sample_i8, u_top.u_npu.gap_sample_i32,
            u_top.u_npu.gap_sum_next,
            u_top.u_npu.gap_src_beat_addr, u_top.u_npu.gap_byte_sel);
        end else begin
          $display("[GAP_DBG] t=%0t WAIT sp=%0d sum=%0d", $time, u_top.u_npu.gap_sp_idx, u_top.u_npu.gap_sum);
        end
      end
      gap_dbg_cnt = gap_dbg_cnt + 1;
    end else if (u_top.u_npu.fsm_state == 5'd15) begin // FSM_DONE
      $display("[GAP_DBG] t=%0t FSM_DONE sum=%0d gap_q=%0d", $time, u_top.u_npu.gap_sum, u_top.u_npu.gap_q);
    end else if (u_top.u_npu.fsm_state == 5'd11) begin // FSM_STORE
      $display("[GAP_DBG] t=%0t FSM_STORE: wr_valid=%0d started=%0d rd_ptr=%0d words=%0d lane=%0d acc=0x%08h pack_data=0x%08h",
        $time, u_top.u_npu.dma_wr_valid, u_top.u_npu.dma_wr_started,
        u_top.u_npu.dma_rd_ptr, u_top.u_npu.store_words_active,
        u_top.u_npu.store_pack_lane, u_top.u_npu.acc_rd_data,
        u_top.u_npu.store_pack_data);
    end
  end
  `endif

endmodule
