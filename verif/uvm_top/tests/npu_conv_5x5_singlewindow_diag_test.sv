//=============================================================================
// npu_conv_5x5_singlewindow_diag_test.sv — Agent B Diagnostic Test 3
//
// 目的： Verify 5x5 kernel single-window (1x1 output) still works in
//   single-cluster mode. This is the existing working shape (5x5 input,
//   5x5 kernel, valid conv → 1x1 output), tested in single-cluster to
//   establish a baseline.
//
//   single-window output is known to work (existing npu_conv_smoke_test).
//   This test confirms it works in single-cluster mode as a control.
//
// Configuration:
//   input:  5x5 spatial, Cin=1, all 0x01 (25 bytes)
//   weight: 5x5 kernel, Cin=1, Cout=1, all 0x01 (25 bytes)
//   conv_cfg = 32'd0 (5x5 kernel, stride1, valid)
//   cluster_mode = single (2'd0)
//   Output: 1x1x1 = 1 INT32
//   Golden: output = 25 (25 * 1 * 1 = 25)
//
// Expected: PASS (single-window baseline)
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_5x5_singlewindow_diag_test extends soc_base_test;

  `uvm_component_utils(npu_conv_5x5_singlewindow_diag_test)

  function new(string name = "npu_conv_5x5_singlewindow_diag_test", uvm_component parent = null);
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
    // Input: 5x5 spatial, Cin=1, all 0x01 (25 bytes)
    input_bytes = new[25];
    for (i = 0; i < 25; i++)
      input_bytes[i] = 8'h01;

    // Weight: 5x5 kernel, Cin=1, Cout=1, all 0x01 (25 bytes)
    weight_bytes = new[25];
    for (i = 0; i < 25; i++)
      weight_bytes[i] = 8'h01;

    `uvm_info("TEST", "================================================================", UVM_NONE)
    `uvm_info("TEST", "=== AGENT B DIAG TEST 3: 5x5 Conv Single-Window BASELINE (1x1 output) ===", UVM_NONE)
    `uvm_info("TEST", "================================================================", UVM_NONE)
    `uvm_info("TEST", $sformatf("Input: %0d bytes (5x5x1 all-1s)", input_bytes.size()), UVM_NONE)
    `uvm_info("TEST", $sformatf("Weight: %0d bytes (5x5x1x1 all-1s)", weight_bytes.size()), UVM_NONE)
    `uvm_info("TEST", "Expected: 1 INT32 value = 25 (5x5 dot product of all 1s)", UVM_NONE)
    `uvm_info("TEST", "Cluster mode: SINGLE", UVM_NONE)
    `uvm_info("TEST", "This is BASELINE: single-window output, known working shape", UVM_NONE)

    // --- Golden reference ---
    env.golden.compute_conv(input_bytes, weight_bytes,
                            5, 5,           // H=5, W=5
                            1, 1,           // Cin=1, Cout=1
                            5, 5,           // kernel 5x5
                            1, 0);          // stride=1, valid
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden: %0d output bytes (%0d INT32)", expected_bytes.size(), expected_bytes.size()/4), UVM_NONE)
    `uvm_info("TEST", $sformatf("  Golden INT32[0] = %0d", env.golden.output_int32[0]), UVM_NONE)

    // --- Configure and run ---
    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd5;
    conv_seq.input_w               = 16'd5;
    conv_seq.input_c               = 16'd1;
    conv_seq.output_c              = 16'd1;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd0;   // single cluster
    conv_seq.conv_cfg              = 32'd0;  // 5x5 kernel (default)
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    clear_probe_sticky();
    `uvm_info("TEST", "Starting NPU task (BASELINE: should PASS quickly)...", UVM_NONE)
    conv_seq.start(env.axil_ag.seqr);

    // --- Check result ---
    mismatches = 0;
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", $sformatf("PASS: Output verify — %0d bytes matched golden (value=%0d)",
          expected_bytes.size(), env.golden.output_int32[0]), UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("FAIL: Output mismatch — %0d bytes differ (first at byte %0d)",
          env.scoreboard.mismatch_count, env.scoreboard.first_mismatch_offset))
        mismatches = env.scoreboard.mismatch_count;
      end
    end else begin
      `uvm_error("TEST", $sformatf("Conv task FAILED/HUNG: done=%0d error=%0d", conv_seq.done, conv_seq.error))
      `uvm_info("TEST", "UNEXPECTED: single-window baseline should NOT hang!", UVM_NONE)
      mismatches = -1;
    end

    // --- Probe diagnostics ---
    `uvm_info("TEST", "=== Probe Diagnostics ===", UVM_NONE)
    `uvm_info("TEST", $sformatf("npu_fsm_state = %0d (5'd2=S_COMPUTE, 5'd7=S_DONE)", probe_vif.npu_fsm_state), UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_busy = %b", probe_vif.npu_cluster_busy), UVM_NONE)
    `uvm_info("TEST", $sformatf("cluster_done = %b", probe_vif.npu_cluster_done), UVM_NONE)
    `uvm_info("TEST", $sformatf("dma_wr_busy = %b, dma_wr_txn_active = %b",
      probe_vif.npu_dma_wr_busy, probe_vif.npu_dma_wr_txn_active), UVM_NONE)

    // Perf counters
    conv_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS, rd_val);
    `uvm_info("TEST", $sformatf("write_beats = %0d (exp >= 1 for 1 INT32 = 4 bytes)", rd_val), UVM_NONE)

    // --- Final verdict ---
    if (mismatches == 0 && conv_seq.done && !conv_seq.error) begin
      `uvm_info("TEST", "=== TEST 3: 5x5 SINGLE-WINDOW BASELINE — PASS ===", UVM_NONE)
      `uvm_info("TEST", "Conclusion: single-window baseline works. Multi-window hang is the differential.", UVM_NONE)
    end else begin
      `uvm_info("TEST", "=== TEST 3: 5x5 SINGLE-WINDOW BASELINE — FAIL ===", UVM_NONE)
      `uvm_info("TEST", "WARNING: Baseline broken — broader regression issue!", UVM_NONE)
    end

    phase.drop_objection(this);
  endtask

endclass
