//=============================================================================
// soc_top_uvm_pkg.sv — UVM Package for SoC Top-Level Verification
//
// Includes all UVM components in dependency order.  Files not bundled here
// (interfaces, defines, testbench top) are compiled separately before the
// package via the filelist.
//=============================================================================

`ifndef SOC_TOP_UVM_PKG_SV
`define SOC_TOP_UVM_PKG_SV

package soc_top_uvm_pkg;

  import uvm_pkg::*;

  //---------------------------------------------------------------------------
  // Register address macros — needed by sequences
  //---------------------------------------------------------------------------
  `include "soc_top_defines.svh"

  //---------------------------------------------------------------------------
  // DPI-C reference model imports
  //---------------------------------------------------------------------------
  `include "npu_ref_dpi.sv"

  //---------------------------------------------------------------------------
  // Agent configuration — no dependencies beyond uvm
  //---------------------------------------------------------------------------
  `include "axil_agent_cfg.sv"

  //---------------------------------------------------------------------------
  // Sequence item — no dependencies beyond uvm
  //---------------------------------------------------------------------------
  `include "axil_seq_item.sv"

  //---------------------------------------------------------------------------
  // Status transaction — no dependencies beyond uvm
  //---------------------------------------------------------------------------
  `include "npu_status_txn.sv"

  //---------------------------------------------------------------------------
  // DMA transaction — no dependencies beyond uvm
  //---------------------------------------------------------------------------
  `include "axi4_dma_txn.sv"

  //---------------------------------------------------------------------------
  // Sequencer — depends on seq_item
  //---------------------------------------------------------------------------
  `include "axil_sequencer.sv"

  //---------------------------------------------------------------------------
  // Driver — depends on seq_item, interface virtual if
  //---------------------------------------------------------------------------
  `include "axil_driver.sv"

  //---------------------------------------------------------------------------
  // Monitor — depends on seq_item, interface virtual if
  //---------------------------------------------------------------------------
  `include "axil_monitor.sv"

  //---------------------------------------------------------------------------
  // Agent — depends on all above
  //---------------------------------------------------------------------------
  `include "axil_agent.sv"

  //---------------------------------------------------------------------------
  // Environment configuration
  //---------------------------------------------------------------------------
  `include "soc_top_env_cfg.sv"

  //---------------------------------------------------------------------------
  // Status monitor — depends on npu_status_txn, soc_probe_if
  //---------------------------------------------------------------------------
  `include "npu_status_monitor.sv"

  //---------------------------------------------------------------------------
  // DMA monitor — depends on axi4_dma_txn, soc_probe_if
  //---------------------------------------------------------------------------
  `include "axi4_dma_monitor.sv"

  //---------------------------------------------------------------------------
  // Performance checker — depends on axi4_dma_txn
  //---------------------------------------------------------------------------
  `include "soc_perf_checker.sv"

  //---------------------------------------------------------------------------
  // Memory model — receives AXI-Lite transactions from monitor
  // (must be before soc_top_env which references it)
  //---------------------------------------------------------------------------
  `include "soc_mem_model.sv"

  //---------------------------------------------------------------------------
  // Scoreboard — checks AXI-Lite responses + output golden compare
  // (must be before soc_top_env which references it)
  //---------------------------------------------------------------------------
  `include "soc_scoreboard.sv"

  //---------------------------------------------------------------------------
  // Golden reference model — DPI-C based bit-accurate reference
  // (must be before soc_top_env which may reference it)
  //---------------------------------------------------------------------------
  `include "soc_golden_model.sv"

  //---------------------------------------------------------------------------
  // Virtual sequencer — holds handles to sub-sequencers
  // (must be before soc_top_env which references it)
  //---------------------------------------------------------------------------
  `include "soc_virtual_sequencer.sv"

  //---------------------------------------------------------------------------
  // Environment — depends on all component types above
  //---------------------------------------------------------------------------
  `include "soc_top_env.sv"

  //---------------------------------------------------------------------------
  // Base sequence — convenience AXI-Lite helper tasks
  //---------------------------------------------------------------------------
  `include "soc_base_seq.sv"

  //---------------------------------------------------------------------------
  // Common sequences — reusable building blocks
  //---------------------------------------------------------------------------
  `include "shared_ram_preload_seq.sv"
  `include "npu_config_seq.sv"
  `include "npu_start_poll_seq.sv"
  `include "npu_output_read_seq.sv"

  //---------------------------------------------------------------------------
  // Task sequences — composed from common sequences
  //---------------------------------------------------------------------------
  `include "npu_conv_task_seq.sv"
  `include "npu_pool_task_seq.sv"
  `include "npu_requant_task_seq.sv"
  `include "npu_cluster_mode_seq.sv"
  `include "npu_fc_task_seq.sv"
  `include "npu_add_task_seq.sv"
  `include "npu_gap_task_seq.sv"

  //---------------------------------------------------------------------------
  // Network sequences — full end-to-end pipelines
  //---------------------------------------------------------------------------
  `include "npu_lenet_seq.sv"

  //---------------------------------------------------------------------------
  // Tests
  //---------------------------------------------------------------------------
  `include "soc_base_test.sv"
  `include "soc_shared_ram_rw_test.sv"
  `include "npu_conv_smoke_test.sv"
  `include "npu_conv_1x1_smoke_test.sv"
  `include "npu_conv_3x3_same_test.sv"
  `include "npu_conv_stride2_test.sv"
  `include "npu_pool_smoke_test.sv"
  `include "npu_pool_multichannel_test.sv"
  `include "npu_requant_smoke_test.sv"
  `include "npu_requant_extreme_test.sv"
  `include "npu_requant_partial_beat_test.sv"
  `include "npu_cluster_mode_test.sv"
  `include "npu_fc_smoke_test.sv"
  `include "npu_add_smoke_test.sv"
  `include "npu_gap_smoke_test.sv"

  //---------------------------------------------------------------------------
  // Channel / bias / add variant tests
  //---------------------------------------------------------------------------
  `include "npu_conv_multichannel_test.sv"
  `include "npu_conv_bias_requant_test.sv"
  `include "npu_add_requant_test.sv"

  //---------------------------------------------------------------------------
  // Error-path tests
  //---------------------------------------------------------------------------
  `include "npu_error_misaligned_addr_test.sv"
  `include "npu_error_invalid_task_test.sv"
  `include "npu_start_while_busy_test.sv"

  //---------------------------------------------------------------------------
  // Bandwidth / performance tests
  //---------------------------------------------------------------------------
  `include "npu_bandwidth_test.sv"

  //---------------------------------------------------------------------------
  // Structural UVM tests — cluster array, mask, perf scaling, back-to-back
  //---------------------------------------------------------------------------
  `include "npu_fc_16x16_full_array_test.sv"
  `include "npu_fc_full_cluster_96out_test.sv"
  `include "npu_fc_b1_diag.sv"
  `include "npu_cluster_mask_sweep_test.sv"
  `include "npu_peak_throughput_test.sv"
  `include "npu_fc_128x128_peak_test.sv"
  `include "npu_perf_counter_scaling_test.sv"
  `include "npu_back_to_back_task_test.sv"

  //---------------------------------------------------------------------------
  // Network pipeline tests
  //---------------------------------------------------------------------------
  `include "npu_lenet_1_test.sv"

  //---------------------------------------------------------------------------
  // Diagnostic tests — Conv multi-cluster mismatch fingerprinting
  //---------------------------------------------------------------------------
  `include "npu_conv_1x1_single_16oc_diag_test.sv"
  `include "npu_conv_1x1_dual_32oc_diag_test.sv"
  `include "npu_conv_1x1_full_96oc_diag_test.sv"

  //---------------------------------------------------------------------------
  // System-level bandwidth utilization test
  //---------------------------------------------------------------------------

  //---------------------------------------------------------------------------
  // Bandwidth 60% stress test — standalone Requant 65536-element workload
  //---------------------------------------------------------------------------
  `include "npu_bandwidth_60pct_stress_test.sv"

  //---------------------------------------------------------------------------
  // Agent B: Conv frontend hang diagnostic tests
  //---------------------------------------------------------------------------
  `include "npu_conv_1x1_multiwindow_diag_test.sv"
  `include "npu_conv_3x3_multiwindow_diag_test.sv"
  `include "npu_conv_5x5_singlewindow_diag_test.sv"
  `include "npu_conv_1x1_fullcluster_multiwindow_diag_test.sv"
  `include "npu_conv_multiblock_test.sv"
  `include "npu_conv_bandwidth_test.sv"

  //---------------------------------------------------------------------------
  // TASK_GEMM functional correctness test
  //---------------------------------------------------------------------------
  `include "npu_task_gemm_func_test.sv"
  `include "npu_task_gemm_row_streaming_test.sv"

  //---------------------------------------------------------------------------
  // AXI-fed NPU GEMM Peak Microbenchmark — full subsystem matrix multiply
  //---------------------------------------------------------------------------
  `include "npu_axi_gemm_peak_test.sv"

  //---------------------------------------------------------------------------
  // Joint TOPS + Bandwidth performance test — GEMM 512→256 workload (EXPERIMENTAL)
  //---------------------------------------------------------------------------
  `include "npu_gemm_pipeline_bw_tops_test.sv"

  //---------------------------------------------------------------------------
  // Phase U1: FC streaming MatrixOp tests
  //---------------------------------------------------------------------------
  `include "npu_fc_streaming_smoke_test.sv"
  `include "npu_fc_streaming_fallback_test.sv"

  //---------------------------------------------------------------------------
  // Phase U2: FC streaming robustness tests
  //---------------------------------------------------------------------------
  `include "npu_fc_streaming_robustness_test.sv"

endpackage

`endif // SOC_TOP_UVM_PKG_SV
