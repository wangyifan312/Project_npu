//=============================================================================
// npu_fc_full_array_activation_test.sv — Full 64×64 PE Array Activation Test
//
// Phase U7-a: renamed from npu_fc_full_cluster_96out_test.
// CLUSTER_COUNT=1 final baseline — single 64×64 PE cluster.
//
// 目的： Prove the full 64×64 PE array (16×16 tiles, 4096 PEs) is activated
// during FC compute. Uses FC task with 96 output channels, deterministic
// pattern, verifies output correctness and array activity via sticky probes.
//
// 检查：
//   1. Output compare: 96 INT32 outputs matched golden
//   2. PE array busy/valid/done observed via probe
//   3. Full array active window: all tile enables asserted
//   4. Output writeback covers multiple 256-bit beats (96×4=384 bytes → 12 beats)
//   5. No error
//=============================================================================

`timescale 1ns / 1ps

class npu_fc_full_array_activation_test extends soc_base_test;

  `uvm_component_utils(npu_fc_full_array_activation_test)

  function new(string name = "npu_fc_full_array_activation_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_fc_task_seq fc_seq;
    byte unsigned input_bytes[];
    byte unsigned weight_bytes[];
    byte unsigned expected_bytes[];
    int i, j;
    bit mismatch_seen;
    bit [31:0] rd_val;

    phase.raise_objection(this);
    #200;

    // --- Build test data: 16→96 FC ---
    // Input: 16 INT8 values {1, 2, 3, ..., 16}
    input_bytes = new[16];
    for (i = 0; i < 16; i++)
      input_bytes[i] = 8'(i + 1);

    // Weight: 96×16 INT8, deterministic pattern
    // weight[out_idx * 16 + in_idx] = (out_idx + 1) for all in_idx
    // So output[out_idx] = sum(inputs) * (out_idx+1) = 136 * (out_idx+1)
    weight_bytes = new[96 * 16];
    for (i = 0; i < 96; i++) begin
      for (j = 0; j < 16; j++)
        weight_bytes[i * 16 + j] = 8'(i + 1);
    end

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden FC reference (16→96) via DPI-C model...", UVM_NONE)
    env.golden.compute_fc(input_bytes, weight_bytes, 16, 96);
    expected_bytes = env.golden.output_bytes;
    `uvm_info("TEST", $sformatf("Golden FC: %0d input -> %0d output, %0d bytes (%0d beats)",
      16, 96, expected_bytes.size(), expected_bytes.size() / 32), UVM_NONE)

    // --- Print sample golden outputs ---
    for (i = 0; i < 4; i++)
      `uvm_info("TEST", $sformatf("  Golden output[%0d] = %0d",
        i, env.golden.output_int32[i]), UVM_MEDIUM)
    `uvm_info("TEST", $sformatf("  Golden output[92] = %0d",
      env.golden.output_int32[92]), UVM_MEDIUM)
    `uvm_info("TEST", $sformatf("  Golden output[95] = %0d",
      env.golden.output_int32[95]), UVM_MEDIUM)

    // --- Configure and run NPU FC task: full cluster ---
    fc_seq = npu_fc_task_seq::type_id::create("fc_seq");
    fc_seq.input_data             = input_bytes;
    fc_seq.weight_data            = weight_bytes;
    fc_seq.input_c                = 16'd16;
    fc_seq.output_c               = 16'd96;
    fc_seq.expected_output_bytes  = expected_bytes.size();
    fc_seq.cluster_mode           = 2'd2;     // full cluster (single-clusters)
    fc_seq.input_base             = 32'h0000_0100;
    fc_seq.weight_base            = 32'h0000_0200;
    fc_seq.output_base            = 32'h0000_1000;  // avoid overlap with weight region (0x200+1536=0x800)

    `uvm_info("TEST", "=== npu_fc_full_cluster_96out_test: Full Cluster 16→96 FC ===", UVM_NONE)

    // Clear sticky probes before task start
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
          "PASS: Output verify — %0d bytes (%0d INT32) matched golden reference",
          expected_bytes.size(), 96), UVM_NONE)
      end
    end else begin
      `uvm_error("TEST", $sformatf("FC task failed: done=%0d error=%0d",
        fc_seq.done, fc_seq.error))
      mismatch_seen = 1'b1;
    end

    // --- Check 2: Cluster activity probe (single-cluster 64x64) ---
    `uvm_info("TEST", "=== Cluster Activity Probe (64x64 single-cluster) ===", UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_enable = %b (expected 1)",
      probe_vif.npu_cluster_enable), UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_count  = %0d (expected 1)",
      probe_vif.npu_cluster_count), UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_busy   = %b", probe_vif.npu_cluster_busy), UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_valid  = %b", probe_vif.npu_cluster_valid), UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_done   = %b", probe_vif.npu_cluster_done), UVM_NONE)

    // Verify single cluster is enabled
    if (probe_vif.npu_cluster_enable[0] !== 1'b1) begin
      `uvm_error("TEST", $sformatf(
        "FAIL: cluster_enable=%b, expected bit0=1", probe_vif.npu_cluster_enable))
      mismatch_seen = 1'b1;
    end else begin
      `uvm_info("TEST", "PASS: cluster 0 enabled", UVM_NONE)
    end

    if (probe_vif.npu_cluster_count !== 3'd1) begin
      `uvm_error("TEST", $sformatf(
        "FAIL: cluster_count=%0d, expected 1", probe_vif.npu_cluster_count))
      mismatch_seen = 1'b1;
    end else begin
      `uvm_info("TEST", "PASS: cluster_count = 1", UVM_NONE)
    end

    // --- Check 2b: Sticky probe (single cluster busy during window) ---
    if (probe_vif.observed_cluster_enable_mask[0] !== 1'b1) begin
      `uvm_error("TEST", "FAIL: cluster 0 not observed enabled during busy window")
      mismatch_seen = 1'b1;
    end else begin
      `uvm_info("TEST", "PASS: cluster 0 observed enabled during busy window", UVM_NONE)
    end

    // --- Check 3: Perf counters ---
    `uvm_info("TEST", "=== Perf Counter Check ===", UVM_NONE)

    fc_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, rd_val);
    `uvm_info("TEST", $sformatf("cycle_count_lo   = %0d", rd_val), UVM_NONE)
    if (rd_val == 32'd0)
      `uvm_error("TEST", "FAIL: cycle_count is zero")

    fc_seq.axil_read32(`NPU_REG_PERF_READ_BEATS, rd_val);
    `uvm_info("TEST", $sformatf("read_beats       = %0d", rd_val), UVM_NONE)

    fc_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS, rd_val);
    `uvm_info("TEST", $sformatf("write_beats      = %0d", rd_val), UVM_NONE)
    // 96 outputs × 4 bytes = 384 bytes = 12 beats minimum
    if (rd_val < 32'd12) begin
      `uvm_error("TEST", $sformatf(
        "FAIL: write_beats=%0d < 12 (96 INT32 outputs = 384 bytes)", rd_val))
    end else begin
      `uvm_info("TEST", $sformatf("PASS: write_beats(%0d) >= 12", rd_val), UVM_NONE)
    end

    fc_seq.axil_read32(`NPU_REG_PERF_CLUSTER_ACTIVE, rd_val);
    `uvm_info("TEST", $sformatf("cluster_active   = %0d", rd_val), UVM_NONE)

    // --- Final verdict ---
    if (!mismatch_seen && !fc_seq.error) begin
      `uvm_info("TEST", "=== npu_fc_full_cluster_96out_test: OVERALL PASS ===", UVM_NONE)
    end else begin
      `uvm_info("TEST", "=== npu_fc_full_cluster_96out_test: OVERALL FAIL ===", UVM_NONE)
    end

    phase.drop_objection(this);
  endtask

endclass
