//=============================================================================
// npu_conv_1x1_dual_32oc_diag_test.sv — Diagnostic: Dual-Cluster 3x3 Conv (32 OC)
//
// Purpose: FINGERPRINT dual-cluster Conv mismatch.
// If single-cluster (test 1) passes, this isolates multi-cluster Conv bug.
//
// Configuration:
//   input:  3x3 spatial, Cin=1, all 0x01 (9 bytes)
//   weight: 3x3 kernel, Cin=1, Cout=32, all 0x01 (9*32 = 288 bytes)
//   conv_cfg = 32'd2 (3x3 kernel, stride1, valid)
//   cluster_mode = dual (2'd1) — uses clusters 0 and 1
//   Cluster 0 → output channels 0-15
//   Cluster 1 → output channels 16-31
//   Output: 1x1x32 = 32 INT32
//   Golden: each output = 9*1*1 = 9
//
// Checks:
//   1. Output compare — detailed mismatch fingerprint
//   2. Per-channel correctness pattern classification
//   3. Sticky probes: cluster0 AND cluster1 activity
//
// Expected result: FAIL with identifiable mismatch pattern
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_1x1_dual_32oc_diag_test extends soc_base_test;

  `uvm_component_utils(npu_conv_1x1_dual_32oc_diag_test)

  function new(string name = "npu_conv_1x1_dual_32oc_diag_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[];
    byte unsigned weight_bytes[];
    byte unsigned expected_bytes[];
    int i;
    int mismatches;
    int ch0_correct, ch0_mismatch;
    int ch1_correct, ch1_mismatch;
    int ch1_zero, ch1_nonzero;
    int total_ints;
    bit [31:0] rd_val;

    phase.raise_objection(this);
    #200;

    // --- Build test data ---
    // Input: 3x3 spatial, Cin=1, all 0x01 (9 bytes)
    input_bytes = new[9];
    for (i = 0; i < 9; i++)
      input_bytes[i] = 8'h01;

    // Weight: 3x3 kernel, Cin=1, Cout=32, all 0x01 (9*32 = 288 bytes)
    weight_bytes = new[288];
    for (i = 0; i < 288; i++)
      weight_bytes[i] = 8'h01;

    `uvm_info("TEST", "=== TEST 2: Dual-Cluster 3x3 Conv, 3x3x32 ===", UVM_NONE)
    `uvm_info("TEST", $sformatf("Input: %0d bytes (3x3x1 all-1s)", input_bytes.size()), UVM_NONE)
    `uvm_info("TEST", $sformatf("Weight: %0d bytes (3x3x1x32 all-1s)", weight_bytes.size()), UVM_NONE)
    `uvm_info("TEST", "Cluster0 -> output ch[0:15], Cluster1 -> output ch[16:31]", UVM_NONE)

    // --- Golden reference ---
    env.golden.compute_conv(input_bytes, weight_bytes,
                            3, 3,           // H=3, W=3
                            1, 32,          // Cin=1, Cout=32
                            3, 3,           // kernel 3x3
                            1, 0);          // stride=1, valid
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden: %0d output bytes (%0d INT32)", expected_bytes.size(), expected_bytes.size()/4), UVM_NONE)
    for (i = 0; i < 4; i++)
      `uvm_info("TEST", $sformatf("  Golden INT32[%0d] = %0d", i, env.golden.output_int32[i]), UVM_MEDIUM)

    // --- Configure and run ---
    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd3;
    conv_seq.input_w               = 16'd3;
    conv_seq.input_c               = 16'd1;
    conv_seq.output_c              = 16'd32;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd1;   // dual cluster (clusters 0,1)
    conv_seq.conv_cfg              = 32'd2;  // 3x3 kernel, valid
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    clear_probe_sticky();
    conv_seq.start(env.axil_ag.seqr);

    // --- Check 1: Output compare ---
    ch0_correct = 0; ch0_mismatch = 0;
    ch1_correct = 0; ch1_mismatch = 0;
    ch1_zero = 0; ch1_nonzero = 0;
    mismatches = 0;

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
      for (i = 0; i < total_ints && mismatches < 30; i++) begin
        int unsigned exp_val, act_val;
        int ch, spatial_hw, h, w;
        exp_val = {expected_bytes[i*4+3], expected_bytes[i*4+2], expected_bytes[i*4+1], expected_bytes[i*4+0]};
        act_val = {conv_seq.actual_output[i*4+3], conv_seq.actual_output[i*4+2], conv_seq.actual_output[i*4+1], conv_seq.actual_output[i*4+0]};
        if (exp_val !== act_val) begin
          ch = i % 32;
          spatial_hw = i / 32;
          h = spatial_hw / 1;
          w = spatial_hw % 1;
          `uvm_info("TEST", $sformatf("  M[%0d]: off=%0d (h=%0d,w=%0d) ch=%0d exp=%0d act=%0d",
            mismatches, i*4, h, w, ch, exp_val, act_val), UVM_NONE)
          mismatches++;
        end
      end

      // --- Per-channel-range classification ---
      `uvm_info("TEST", "=== Per-Cluster Channel-Range Classification ===", UVM_NONE)
      for (i = 0; i < total_ints; i++) begin
        int unsigned exp_val, act_val;
        int ch;
        exp_val = {expected_bytes[i*4+3], expected_bytes[i*4+2], expected_bytes[i*4+1], expected_bytes[i*4+0]};
        act_val = {conv_seq.actual_output[i*4+3], conv_seq.actual_output[i*4+2], conv_seq.actual_output[i*4+1], conv_seq.actual_output[i*4+0]};
        ch = i % 32;
        if (ch < 16) begin  // Cluster 0 output channels
          if (exp_val === act_val)
            ch0_correct++;
          else
            ch0_mismatch++;
        end else begin      // Cluster 1 output channels
          if (exp_val === act_val)
            ch1_correct++;
          else begin
            ch1_mismatch++;
            if (act_val == 32'd0)
              ch1_zero++;
            else
              ch1_nonzero++;
          end
        end
      end

      `uvm_info("TEST", $sformatf("Cluster0 channels (0-15): correct=%0d mismatch=%0d", ch0_correct, ch0_mismatch), UVM_NONE)
      `uvm_info("TEST", $sformatf("Cluster1 channels (16-31): correct=%0d mismatch=%0d (zero=%0d nonzero=%0d)",
        ch1_correct, ch1_mismatch, ch1_zero, ch1_nonzero), UVM_NONE)

      // --- Pattern classification ---
      `uvm_info("TEST", "=== PATTERN CLASSIFICATION ===", UVM_NONE)
      if (ch0_mismatch == 0 && ch1_mismatch > 0)
        `uvm_info("TEST", "PATTERN: Cluster0 CORRECT, Cluster1 WRONG -> cluster1-specific issue", UVM_NONE)
      if (ch1_zero == ch1_mismatch && ch1_mismatch > 0)
        `uvm_info("TEST", "PATTERN: All cluster1 outputs ZERO -> cluster1 not producing output", UVM_NONE)
      else if (ch1_nonzero > 0)
        `uvm_info("TEST", "PATTERN: Cluster1 outputs non-zero wrong -> weight/data routing issue", UVM_NONE)

      // Check for duplication pattern
      if (ch1_mismatch > 0 && ch1_nonzero > 0) begin
        `uvm_info("TEST", "Checking duplication: cluster1 values vs cluster0 expected...", UVM_NONE)
        for (i = 0; i < total_ints; i++) begin
          int unsigned act_val, exp_val_c0;
          int ch;
          act_val = {conv_seq.actual_output[i*4+3], conv_seq.actual_output[i*4+2], conv_seq.actual_output[i*4+1], conv_seq.actual_output[i*4+0]};
          ch = i % 32;
          if (ch >= 16) begin
            exp_val_c0 = {expected_bytes[(i-16)*4+3], expected_bytes[(i-16)*4+2], expected_bytes[(i-16)*4+1], expected_bytes[(i-16)*4+0]};
            if (exp_val_c0 === act_val)
              `uvm_info("TEST", $sformatf("  DUPLICATION: ch=%0d act=%0d == ch%0d golden=%0d", ch, act_val, ch-16, exp_val_c0), UVM_MEDIUM)
          end
        end
      end

    end else begin
      `uvm_error("TEST", $sformatf("Conv task failed: done=%0d error=%0d", conv_seq.done, conv_seq.error))
      mismatches = -1;
    end

    // --- Check 2: Sticky probes ---
    `uvm_info("TEST", "=== Cluster Activity Probe ===", UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_enable = %b (exp 000011)", probe_vif.npu_cluster_enable), UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_count  = %0d (exp 2)", probe_vif.npu_cluster_count), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_cluster_busy_mask   = %b (exp 000011)", probe_vif.observed_cluster_busy_mask), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_cluster_valid_mask  = %b", probe_vif.observed_cluster_valid_mask), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_cluster_done_mask   = %b", probe_vif.observed_cluster_done_mask), UVM_NONE)

    if (probe_vif.observed_cluster_busy_mask[0] && probe_vif.observed_cluster_busy_mask[1])
      `uvm_info("TEST", "PASS: Both cluster0 AND cluster1 observed busy", UVM_NONE)
    else
      `uvm_info("TEST", $sformatf("WARNING: cluster0_busy=%b cluster1_busy=%b",
        probe_vif.observed_cluster_busy_mask[0], probe_vif.observed_cluster_busy_mask[1]), UVM_NONE)

    // --- Check 3: Perf counters ---
    conv_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS, rd_val);
    `uvm_info("TEST", $sformatf("write_beats = %0d (exp >= 4 for 32 INT32 = 128 bytes)", rd_val), UVM_NONE)

    // --- Final verdict ---
    `uvm_info("TEST", $sformatf("=== TEST 2: DUAL-CLUSTER 32OC DIAGNOSTIC COMPLETE (mismatches=%0d) ===", mismatches), UVM_NONE)

    phase.drop_objection(this);
  endtask

endclass
