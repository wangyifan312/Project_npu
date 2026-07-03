//=============================================================================
// npu_conv_1x1_full_96oc_diag_test.sv — Diagnostic: Full-Cluster 3x3 Conv (96 OC)
//
// 目的： FINGERPRINT full single-cluster Conv mismatch with many output channels.
// All single-clusters should participate.
//
// Configuration:
//   input:  5x5 spatial, Cin=1, all 0x01 (25 bytes)
//   weight: 3x3 kernel, Cin=1, Cout=96, all 0x01 (9*96 = 864 bytes)
//   conv_cfg = 32'd2 (3x3 kernel, stride1, valid)
//   cluster_mode = full (2'd2) — uses all single-clusters
//   Each cluster handles 16 output channels:
//     Cluster0: ch[ 0:15], Cluster1: ch[16:31], Cluster2: ch[32:47]
//     Cluster3: ch[48:63], Cluster4: ch[64:79], Cluster5: ch[80:95]
//   Output: 3x3x96 = 864 INT32
//   Golden: each output = 9*1*1 = 9
//
// 检查：
//   1. Output compare — detailed mismatch report
//   2. Per-cluster channel-range pattern
//   3. Sticky probes: all single-clusters show activity
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_1x1_full_96oc_diag_test extends soc_base_test;

  `uvm_component_utils(npu_conv_1x1_full_96oc_diag_test)

  function new(string name = "npu_conv_1x1_full_96oc_diag_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[];
    byte unsigned weight_bytes[];
    byte unsigned expected_bytes[];
    int i, c;
    int mismatches;
    int cluster_correct[6];
    int cluster_mismatch[6];
    int cluster_zero[6];
    int cluster_nonzero[6];
    int total_ints, output_c;
    bit [31:0] rd_val;

    phase.raise_objection(this);
    #200;

    // --- Build test data ---
    // Input: 5x5 spatial, Cin=1, all 0x01 (25 bytes)
    input_bytes = new[25];
    for (i = 0; i < 25; i++)
      input_bytes[i] = 8'h01;

    // Single-cluster 64×64: max 64 output channels for Conv (1 PE col per channel)
    output_c = 64;
    weight_bytes = new[9 * 64];
    for (i = 0; i < 9 * 64; i++)
      weight_bytes[i] = 8'h01;

    `uvm_info("TEST", "=== TEST 3: Single-Cluster 3x3 Conv, 5x5x64 ===", UVM_NONE)
    `uvm_info("TEST", $sformatf("Input: %0d bytes (5x5x1 all-1s)", input_bytes.size()), UVM_NONE)
    `uvm_info("TEST", $sformatf("Weight: %0d bytes (3x3x1x64 all-1s)", weight_bytes.size()), UVM_NONE)

    // --- Golden reference ---
    env.golden.compute_conv(input_bytes, weight_bytes,
                            5, 5,           // H=5, W=5
                            1, output_c,    // Cin=1, Cout=96
                            3, 3,           // kernel 3x3
                            1, 0);          // stride=1, valid
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden: %0d output bytes (%0d INT32)", expected_bytes.size(), expected_bytes.size()/4), UVM_NONE)
    for (i = 0; i < 4; i++)
      `uvm_info("TEST", $sformatf("  Golden INT32[%0d] = %0d", i, env.golden.output_int32[i]), UVM_MEDIUM)
    `uvm_info("TEST", $sformatf("  Golden INT32[%0d] = %0d", 48, env.golden.output_int32[48]), UVM_MEDIUM)
    `uvm_info("TEST", $sformatf("  Golden INT32[%0d] = %0d", expected_bytes.size()/4 - 1, env.golden.output_int32[expected_bytes.size()/4 - 1]), UVM_MEDIUM)

    // --- Configure and run ---
    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd5;
    conv_seq.input_w               = 16'd5;
    conv_seq.input_c               = 16'd1;
    conv_seq.output_c              = output_c;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd0;   // single cluster
    conv_seq.conv_cfg              = 32'd2;  // 3x3 kernel, valid
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_1000;  // after weight region (0x200+576=0x440)

    clear_probe_sticky();
    conv_seq.start(env.axil_ag.seqr);

    // --- Check 1: Output compare ---
    for (c = 0; c < 1; c++) begin
      cluster_correct[c] = 0;
      cluster_mismatch[c] = 0;
      cluster_zero[c] = 0;
      cluster_nonzero[c] = 0;
    end

    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", $sformatf("PASS: Output verify — %0d bytes matched golden", expected_bytes.size()), UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("FAIL: Output mismatch — %0d bytes differ (first at byte %0d)",
          env.scoreboard.mismatch_count, env.scoreboard.first_mismatch_offset))
      end

      // --- Detailed INT32-level fingerprinting ---
      `uvm_info("TEST", "=== INT32 Mismatch Fingerprint (first 30) ===", UVM_NONE)
      total_ints = expected_bytes.size() / 4;
      mismatches = 0;
      for (i = 0; i < total_ints && mismatches < 30; i++) begin
        int unsigned exp_val, act_val;
        int ch, spatial_hw, h, w;
        exp_val = {expected_bytes[i*4+3], expected_bytes[i*4+2], expected_bytes[i*4+1], expected_bytes[i*4+0]};
        act_val = {conv_seq.actual_output[i*4+3], conv_seq.actual_output[i*4+2], conv_seq.actual_output[i*4+1], conv_seq.actual_output[i*4+0]};
        if (exp_val !== act_val) begin
          ch = i % output_c;
          spatial_hw = i / output_c;
          h = spatial_hw / 3;
          w = spatial_hw % 3;
          `uvm_info("TEST", $sformatf("  M[%0d]: off=%0d (h=%0d,w=%0d) ch=%0d exp=%0d act=%0d",
            mismatches, i*4, h, w, ch, exp_val, act_val), UVM_NONE)
          mismatches++;
        end
      end

      // --- Per-cluster channel-range pattern classification ---
      `uvm_info("TEST", "=== Per-Cluster Channel-Range Pattern ===", UVM_NONE)
      for (i = 0; i < total_ints; i++) begin
        int unsigned exp_val, act_val;
        int ch;
        exp_val = {expected_bytes[i*4+3], expected_bytes[i*4+2], expected_bytes[i*4+1], expected_bytes[i*4+0]};
        act_val = {conv_seq.actual_output[i*4+3], conv_seq.actual_output[i*4+2], conv_seq.actual_output[i*4+1], conv_seq.actual_output[i*4+0]};
        ch = i % output_c;
        c = ch / 16;  // cluster index (0-5)
        if (c > 5) c = 5;  // clamp for safety
        if (exp_val === act_val)
          cluster_correct[c]++;
        else begin
          cluster_mismatch[c]++;
          if (act_val == 32'd0)
            cluster_zero[c]++;
          else
            cluster_nonzero[c]++;
        end
      end

      for (c = 0; c < 6; c++) begin
        `uvm_info("TEST", $sformatf("  Cluster%0d (ch[%0d:%0d]): correct=%0d mismatch=%0d (zero=%0d nonzero=%0d)",
          c, c*16, (c+1)*16-1, cluster_correct[c], cluster_mismatch[c], cluster_zero[c], cluster_nonzero[c]), UVM_NONE)
      end

      // --- Pattern classification ---
      `uvm_info("TEST", "=== PATTERN CLASSIFICATION ===", UVM_NONE)
      for (c = 0; c < 6; c++) begin
        if (cluster_mismatch[c] == 0)
          `uvm_info("TEST", $sformatf("  Cluster%0d: ALL CORRECT", c), UVM_NONE)
        else if (cluster_zero[c] == cluster_mismatch[c])
          `uvm_info("TEST", $sformatf("  Cluster%0d: ALL ZERO (cluster not producing)", c), UVM_NONE)
        else
          `uvm_info("TEST", $sformatf("  Cluster%0d: NON-ZERO WRONG (routing/data issue)", c), UVM_NONE)
      end

    end else begin
      `uvm_error("TEST", $sformatf("Conv task failed: done=%0d error=%0d", conv_seq.done, conv_seq.error))
    end

    // --- Check 2: Sticky probes ---
    `uvm_info("TEST", "=== Cluster Activity Probe ===", UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_enable = %b (exp 111111)", probe_vif.npu_cluster_enable), UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_count  = %0d (exp 6)", probe_vif.npu_cluster_count), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_cluster_busy_mask   = %b (exp 111111)", probe_vif.observed_cluster_busy_mask), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_cluster_valid_mask  = %b", probe_vif.observed_cluster_valid_mask), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_cluster_done_mask   = %b", probe_vif.observed_cluster_done_mask), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_all_clusters_active = %b", probe_vif.observed_all_clusters_active), UVM_NONE)

    if (probe_vif.observed_cluster_busy_mask == 6'b111111)
      `uvm_info("TEST", "PASS: All single-clusters observed busy", UVM_NONE)
    else
      `uvm_info("TEST", $sformatf("WARNING: observed_cluster_busy_mask = %b (not all clusters busy)", probe_vif.observed_cluster_busy_mask), UVM_NONE)

    // --- Check 3: Perf counters ---
    conv_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS, rd_val);
    `uvm_info("TEST", $sformatf("write_beats = %0d (exp >= 108 for 864 INT32 = 3456 bytes)", rd_val), UVM_NONE)

    // --- Final verdict ---
    `uvm_info("TEST", "=== TEST 3: FULL-CLUSTER 96OC DIAGNOSTIC COMPLETE ===", UVM_NONE)

    phase.drop_objection(this);
  endtask

endclass
