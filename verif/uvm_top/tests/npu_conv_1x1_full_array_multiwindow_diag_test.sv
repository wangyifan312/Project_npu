//=============================================================================
// npu_conv_1x1_full_array_multiwindow_diag_test.sv — Agent B Diagnostic Test 1b
//
// Phase U7-a: renamed from npu_conv_1x1_fullcluster_multiwindow_diag_test.
// CLUSTER_COUNT=1 final baseline — single 64×64 PE cluster.
//
// Purpose: Test 1x1 Conv with multi-window (4x4) output in full-array mode.
//   Single-cluster single-window variant PASSED (Test 1).
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_1x1_full_array_multiwindow_diag_test extends soc_base_test;

  `uvm_component_utils(npu_conv_1x1_full_array_multiwindow_diag_test)

  function new(string name = "npu_conv_1x1_full_array_multiwindow_diag_test", uvm_component parent = null);
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

    input_bytes = new[16];
    for (i = 0; i < 16; i++)
      input_bytes[i] = 8'h01;

    weight_bytes = new[1];
    weight_bytes[0] = 8'h01;

    `uvm_info("TEST", "================================================================", UVM_NONE)
    `uvm_info("TEST", "=== AGENT B DIAG TEST 1b: 1x1 Conv Multi-Window, FULL-CLUSTER ===", UVM_NONE)
    `uvm_info("TEST", "================================================================", UVM_NONE)
    `uvm_info("TEST", "Input: 4x4x1 all-1s, Weight: 1x1x1 all-1s", UVM_NONE)
    `uvm_info("TEST", "Expected: 16 INT32 values, each = 1", UVM_NONE)
    `uvm_info("TEST", "Cluster mode: FULL (6-cluster)", UVM_NONE)
    `uvm_info("TEST", "Hang hypothesis: if hangs in full-cluster but NOT single-cluster,", UVM_NONE)
    `uvm_info("TEST", "   root cause is in cluster_scheduler/output_arbiter multi-cluster path", UVM_NONE)

    env.golden.compute_conv(input_bytes, weight_bytes,
                            4, 4, 1, 1, 1, 1, 1, 0);
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden: %0d output bytes (%0d INT32)", expected_bytes.size(), expected_bytes.size()/4), UVM_NONE)

    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd4;
    conv_seq.input_w               = 16'd4;
    conv_seq.input_c               = 16'd1;
    conv_seq.output_c              = 16'd1;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd2;   // FULL cluster
    conv_seq.conv_cfg              = 32'd1;  // 1x1 kernel
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    clear_probe_sticky();
    `uvm_info("TEST", "Starting NPU task in FULL-CLUSTER mode...", UVM_NONE)
    conv_seq.start(env.axil_ag.seqr);

    mismatches = 0;
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);
      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", $sformatf("PASS: Output verify — %0d bytes matched golden", expected_bytes.size()), UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("FAIL: %0d bytes differ", env.scoreboard.mismatch_count))
        mismatches = env.scoreboard.mismatch_count;
      end
    end else begin
      `uvm_error("TEST", $sformatf("FAILED/HUNG: done=%0d error=%0d", conv_seq.done, conv_seq.error))
      mismatches = -1;
    end

    `uvm_info("TEST", "=== Probes ===", UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_enable = %b", probe_vif.npu_cluster_enable), UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_busy   = %b", probe_vif.npu_cluster_busy), UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_done   = %b", probe_vif.npu_cluster_done), UVM_NONE)
    `uvm_info("TEST", $sformatf("dma_wr_busy    = %b", probe_vif.npu_dma_wr_busy), UVM_NONE)

    conv_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS, rd_val);
    `uvm_info("TEST", $sformatf("write_beats = %0d", rd_val), UVM_NONE)

    if (mismatches == 0 && conv_seq.done && !conv_seq.error) begin
      `uvm_info("TEST", "=== TEST 1b: FULL-CLUSTER MULTI-WINDOW — PASS ===", UVM_NONE)
      `uvm_info("TEST", "Conclusion: multi-window works in BOTH single and full-cluster modes.", UVM_NONE)
      `uvm_info("TEST", "The reported hang must be caused by a different configuration/dataset.", UVM_NONE)
    end else if (mismatches == -1) begin
      `uvm_info("TEST", "=== TEST 1b: FULL-CLUSTER MULTI-WINDOW — HANG ===", UVM_NONE)
      `uvm_info("TEST", "Conclusion: hang is CLUSTER-MODE SPECIFIC (full-cluster only).", UVM_NONE)
      `uvm_info("TEST", "Root cause: output_arbiter multi-cluster deadlock or empty-cluster stall.", UVM_NONE)
    end

    phase.drop_objection(this);
  endtask

endclass
