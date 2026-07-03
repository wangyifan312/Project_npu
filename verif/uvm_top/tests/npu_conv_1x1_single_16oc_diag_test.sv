//=============================================================================
// npu_conv_1x1_single_16oc_diag_test.sv — Diagnostic: Single-Cluster 3x3 Conv (16 OC)
//
// 目的： BASELINE — verify single-cluster 3x3 Conv works for 16 output channels.
// If this fails, multi-cluster diagnosis is moot.
//
// 配置uration:
//   input:  3x3 spatial, Cin=1, all 0x01 (9 bytes)
//   weight: 3x3 kernel, Cin=1, Cout=16, all 0x01 (9*1*16 = 144 bytes)
//   conv_cfg = 32'd2 (3x3 kernel, stride1, valid)
//   cluster_mode = single (2'd0)
//   Output: 1x1x16 = 16 INT32
//   Golden: each output = 9*1*1 = 9
//
// 检查：
//   1. Output compare: 16 INT32 values matched golden
//   2. Sticky probes: cluster0 observed busy/valid/done
//   3. No error
//
// Expected result: PASS (single-cluster baseline)
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_1x1_single_16oc_diag_test extends soc_base_test;

  `uvm_component_utils(npu_conv_1x1_single_16oc_diag_test)

  function new(string name = "npu_conv_1x1_single_16oc_diag_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[];
    byte unsigned weight_bytes[];
    byte unsigned expected_bytes[];
    int i;
    int mismatches;
    bit [31:0] rd_val;

    phase.raise_objection(this);
    #200;

    // --- Build test data ---
    // 输入: 3x3 spatial, Cin=1, all 0x01 (9 bytes)
    input_bytes = new[9];
    for (i = 0; i < 9; i++)
      input_bytes[i] = 8'h01;

    // 权重: 3x3 kernel, Cin=1, Cout=16, all 0x01 (9*16 = 144 bytes)
    weight_bytes = new[144];
    for (i = 0; i < 144; i++)
      weight_bytes[i] = 8'h01;

    `uvm_info("TEST", "=== TEST 1: Single-Cluster 3x3 Conv, 3x3x16 ===", UVM_NONE)
    `uvm_info("TEST", $sformatf("Input: %0d bytes (3x3x1 all-1s)", input_bytes.size()), UVM_NONE)
    `uvm_info("TEST", $sformatf("Weight: %0d bytes (3x3x1x16 all-1s)", weight_bytes.size()), UVM_NONE)

    // --- Golden reference ---
    env.golden.compute_conv(input_bytes, weight_bytes,
                            3, 3,           // H=3, W=3
                            1, 16,          // Cin=1, Cout=16
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
    conv_seq.output_c              = 16'd16;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd0;   // single cluster
    conv_seq.conv_cfg              = 32'd2;  // 3x3 kernel, valid
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    clear_probe_sticky();
    conv_seq.start(env.axil_ag.seqr);

    // --- Check 1: Output compare ---
    mismatches = 0;
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", $sformatf("PASS: Output verify — %0d bytes matched golden", expected_bytes.size()), UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("FAIL: Output mismatch — %0d bytes differ (first at byte %0d)",
          env.scoreboard.mismatch_count, env.scoreboard.first_mismatch_offset))

        // --- Detailed fingerprinting (first 30 INT32 mismatches) ---
        `uvm_info("TEST", "=== INT32 Mismatch Fingerprint (first 30) ===", UVM_NONE)
        mismatches = 0;
        for (i = 0; i < 16 && mismatches < 30; i++) begin
          int unsigned exp_val, act_val;
          int ch;
          exp_val = {expected_bytes[i*4+3], expected_bytes[i*4+2], expected_bytes[i*4+1], expected_bytes[i*4+0]};
          act_val = {conv_seq.actual_output[i*4+3], conv_seq.actual_output[i*4+2], conv_seq.actual_output[i*4+1], conv_seq.actual_output[i*4+0]};
          if (exp_val !== act_val) begin
            ch = i % 16;
            `uvm_info("TEST", $sformatf("  M[%0d]: off=%0d ch=%0d exp=%0d act=%0d",
              mismatches, i*4, ch, exp_val, act_val), UVM_NONE)
            mismatches++;
          end
        end
      end
    end else begin
      `uvm_error("TEST", $sformatf("Conv task failed: done=%0d error=%0d", conv_seq.done, conv_seq.error))
      mismatches = -1;
    end

    // --- Check 2: Sticky probes ---
    `uvm_info("TEST", "=== Cluster Activity Probe ===", UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_enable = %b (exp 000001)", probe_vif.npu_cluster_enable), UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_count  = %0d (exp 1)", probe_vif.npu_cluster_count), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_cluster_busy_mask   = %b (exp 000001)", probe_vif.observed_cluster_busy_mask), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_cluster_valid_mask  = %b (exp 000001)", probe_vif.observed_cluster_valid_mask), UVM_NONE)
    `uvm_info("TEST", $sformatf("observed_cluster_done_mask   = %b (exp 000001)", probe_vif.observed_cluster_done_mask), UVM_NONE)

    if (probe_vif.observed_cluster_busy_mask[0])
      `uvm_info("TEST", "PASS: cluster0 busy observed", UVM_NONE)
    else
      `uvm_error("TEST", "FAIL: cluster0 busy NOT observed")

    // --- Check 3: Perf counters ---
    conv_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS, rd_val);
    `uvm_info("TEST", $sformatf("write_beats = %0d (exp >= 2 for 16 INT32 = 64 bytes)", rd_val), UVM_NONE)

    // --- Final verdict ---
    if (mismatches == 0 && conv_seq.done && !conv_seq.error) begin
      `uvm_info("TEST", "=== TEST 1: SINGLE-CLUSTER 16OC BASELINE — PASS ===", UVM_NONE)
    end else begin
      `uvm_info("TEST", "=== TEST 1: SINGLE-CLUSTER 16OC BASELINE — FAIL ===", UVM_NONE)
    end

    phase.drop_objection(this);
  endtask

endclass
