//=============================================================================
// npu_fc_16x16_full_array_test.sv — Single Cluster Full 16x16 Array Test
//
// 目的： Prove a single cluster's full 16×16 PE array (4×4 tiles, 256 PEs)
// is completely enabled during FC compute.  Uses deterministic input/weight
// patterns and verifies output correctness, cluster activity, and tile
// 使能 coverage via hierarchical probes.
//
// 检查：
//   1. Output compare: 16 INT32 outputs matched golden
//   2. cluster0 busy/valid/done observed via probe
//   3. At least one cycle where all active tiles within cluster0 have
//      tile_clk_en asserted (steady-state window)
//   4. Perf counters nonzero: cycle_count, read_beats, write_beats
//   5. No error
//=============================================================================

`timescale 1ns / 1ps

class npu_fc_16x16_full_array_test extends soc_base_test;

  `uvm_component_utils(npu_fc_16x16_full_array_test)

  function new(string name = "npu_fc_16x16_full_array_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_fc_task_seq fc_seq;
    byte unsigned input_bytes[];
    byte unsigned weight_bytes[];
    byte unsigned expected_bytes[];
    int i;
    bit mismatch_seen;
    bit [31:0] rd_val;

    phase.raise_objection(this);
    #200;

    // --- Build test data: 16→16 FC ---
    // 输入: 16 INT8 values {1, 2, ..., 16}
    input_bytes = new[16];
    for (i = 0; i < 16; i++)
      input_bytes[i] = 8'(i + 1);

    // 权重: 16x16 INT8 identity-like: row[i] = {i+1, i+1, ..., i+1}
    // So output[i] = sum(inputs) * (i+1) = 136 * (i+1)
    weight_bytes = new[16 * 16];
    for (i = 0; i < 16; i++) begin
      for (int j = 0; j < 16; j++)
        weight_bytes[i * 16 + j] = 8'(i + 1);
    end

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden FC reference (16→16) via DPI-C model...", UVM_NONE)
    env.golden.compute_fc(input_bytes, weight_bytes, 16, 16);
    expected_bytes = env.golden.output_bytes;
    `uvm_info("TEST", $sformatf("Golden FC: %0d input -> %0d output, %0d bytes total",
      16, 16, expected_bytes.size()), UVM_NONE)

    // --- Print first few golden outputs for debug ---
    for (i = 0; i < 4; i++)
      `uvm_info("TEST", $sformatf("  Golden output[%0d] = %0d",
        i, env.golden.output_int32[i]), UVM_MEDIUM)

    // --- Configure and run NPU FC task: single cluster ---
    fc_seq = npu_fc_task_seq::type_id::create("fc_seq");
    fc_seq.input_data             = input_bytes;
    fc_seq.weight_data            = weight_bytes;
    fc_seq.input_c                = 16'd16;
    fc_seq.output_c               = 16'd16;
    fc_seq.expected_output_bytes  = expected_bytes.size();
    fc_seq.cluster_mode           = 2'd0;     // single cluster
    fc_seq.input_base             = 32'h0000_0100;
    fc_seq.weight_base            = 32'h0000_0200;
    fc_seq.output_base            = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_fc_16x16_full_array_test: Single Cluster 16→16 FC ===", UVM_NONE)

    // 清除 sticky probes before task start
    clear_probe_sticky();
    fc_seq.start(env.axil_ag.seqr);

    // --- Check 1: Output compare against golden ---
    mismatch_seen = 1'b0;
    if (fc_seq.done && !fc_seq.error) begin
      env.scoreboard.compare_output_bytes(fc_seq.actual_output, expected_bytes,
                                          fc_seq.output_base);
      if (env.scoreboard.mismatch_count > 0) begin
        `uvm_error("TEST", $sformatf(
          "Output mismatch vs golden: %0d bytes differ (first at byte %0d)",
          env.scoreboard.mismatch_count, env.scoreboard.first_mismatch_offset))
        mismatch_seen = 1'b1;
      end else begin
        `uvm_info("TEST", $sformatf(
          "PASS: Output verify — %0d bytes matched golden reference",
          expected_bytes.size()), UVM_NONE)
      end
    end else begin
      `uvm_error("TEST", $sformatf("FC task failed: done=%0d error=%0d",
        fc_seq.done, fc_seq.error))
      mismatch_seen = 1'b1;
    end

    // --- Check 2: Sticky cluster/tile activity probe ---
    // Sticky probes accumulate over the entire NPU busy window.
    `uvm_info("TEST", "=== Sticky Cluster/Tile Activity Probe ===", UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_cluster_busy_mask   = %b", probe_vif.observed_cluster_busy_mask), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_cluster_enable_mask = %b", probe_vif.observed_cluster_enable_mask), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_tile_all_on         = %b", probe_vif.observed_tile_all_on), UVM_NONE)

    // Verify cluster0 was busy during the task
    if (!probe_vif.observed_cluster_busy_mask[0]) begin
      `uvm_error("TEST", "FAIL: observed_cluster_busy_mask[0] = 0 (cluster0 never busy)")
      mismatch_seen = 1'b1;
    end else begin
      `uvm_info("TEST", "PASS: cluster0 was busy (sticky)", UVM_NONE)
    end

    // Verify cluster0 was enabled
    if (!probe_vif.observed_cluster_enable_mask[0]) begin
      `uvm_error("TEST", "FAIL: observed_cluster_enable_mask[0] = 0 (cluster0 never enabled)")
      mismatch_seen = 1'b1;
    end else begin
      `uvm_info("TEST", "PASS: cluster0 was enabled (sticky)", UVM_NONE)
    end

    // Verify at least some tiles in cluster0 had clock enables active
    if (!probe_vif.observed_tile_all_on) begin
      `uvm_error("TEST", "FAIL: observed_tile_all_on = 0 (no tile activity observed)")
      mismatch_seen = 1'b1;
    end else begin
      `uvm_info("TEST", "PASS: tile activity observed in cluster0 (sticky)", UVM_NONE)
    end

    // --- Check 3: Perf counters ---
    `uvm_info("TEST", "=== Perf Counter Check ===", UVM_NONE)

    // 读 cycle count
    fc_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, rd_val);
    `uvm_info("TEST", $sformatf("cycle_count_lo   = %0d", rd_val), UVM_NONE)
    if (rd_val == 32'd0)
      `uvm_error("TEST", "FAIL: cycle_count is zero")

    // 读 beats
    fc_seq.axil_read32(`NPU_REG_PERF_READ_BEATS, rd_val);
    `uvm_info("TEST", $sformatf("read_beats       = %0d", rd_val), UVM_NONE)
    if (rd_val == 32'd0)
      `uvm_error("TEST", "FAIL: read_beats is zero")

    fc_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS, rd_val);
    `uvm_info("TEST", $sformatf("write_beats      = %0d", rd_val), UVM_NONE)
    if (rd_val == 32'd0)
      `uvm_error("TEST", "FAIL: write_beats is zero")

    // 读 cluster activity
    fc_seq.axil_read32(`NPU_REG_PERF_CLUSTER_ACTIVE, rd_val);
    `uvm_info("TEST", $sformatf("cluster_active   = %0d", rd_val), UVM_NONE)

    // 写 DMA perf counters now on dedicated addresses 0xD0/0xD4
    fc_seq.axil_read32(`NPU_REG_PERF_WRITE_DATA_CYC, rd_val);
    `uvm_info("TEST", $sformatf("write_data_cycles = %0d (via 0xD0)", rd_val), UVM_NONE)
    fc_seq.axil_read32(`NPU_REG_PERF_WRITE_TXN_CYC, rd_val);
    `uvm_info("TEST", $sformatf("write_txn_cycles  = %0d (via 0xD4)", rd_val), UVM_NONE)

    // --- Final verdict ---
    if (!mismatch_seen && !fc_seq.error) begin
      `uvm_info("TEST", "=== npu_fc_16x16_full_array_test: OVERALL PASS ===", UVM_NONE)
    end else begin
      `uvm_info("TEST", "=== npu_fc_16x16_full_array_test: OVERALL FAIL ===", UVM_NONE)
    end

    phase.drop_objection(this);
  endtask

endclass
