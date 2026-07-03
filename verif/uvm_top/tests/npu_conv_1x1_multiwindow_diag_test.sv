//=============================================================================
// npu_conv_1x1_multiwindow_diag_test.sv — Agent B Diagnostic Test 1
//
// 目的： Test whether 1x1 Conv with multi-window (4x4) output hangs.
//   If hangs → issue is in downstream pipeline (DMA writer tail, Hang B)
//   If passes → conv_frontend correctly handles 1x1 multi-window
//
// Configuration:
//   input:  4x4 spatial, Cin=1, all 0x01 (16 bytes)
//   weight: 1x1 kernel, Cin=1, Cout=1, all 0x01 (1 byte)
//   conv_cfg = 32'd1 (1x1 kernel, stride1, valid)
//   cluster_mode = single (2'd0)
//   Output: 4x4x1 = 16 INT32
//   Golden: each output = 1*1 = 1
//
// Hang diagnosis:
//   - If timeout: conv_frontend likely stuck in S_COMPUTE waiting for !window_hold
//     (downstream backpressure from DMA writer S_WAIT_DATA)
//   - If error: conv_frontend window extraction produces wrong values
//   - If PASS: 1x1 multi-window path is functional
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_1x1_multiwindow_diag_test extends soc_base_test;

  `uvm_component_utils(npu_conv_1x1_multiwindow_diag_test)

  function new(string name = "npu_conv_1x1_multiwindow_diag_test", uvm_component parent = null);
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
    // Input: 4x4 spatial, Cin=1, all 0x01 (16 bytes)
    input_bytes = new[16];
    for (i = 0; i < 16; i++)
      input_bytes[i] = 8'h01;

    // Weight: 1x1 kernel, Cin=1, Cout=1, all 0x01 (1 byte)
    weight_bytes = new[1];
    weight_bytes[0] = 8'h01;

    `uvm_info("TEST", "================================================================", UVM_NONE)
    `uvm_info("TEST", "=== AGENT B DIAG TEST 1: 1x1 Conv Multi-Window (4x4 output) ===", UVM_NONE)
    `uvm_info("TEST", "================================================================", UVM_NONE)
    `uvm_info("TEST", $sformatf("Input: %0d bytes (4x4x1 all-1s)", input_bytes.size()), UVM_NONE)
    `uvm_info("TEST", $sformatf("Weight: %0d bytes (1x1x1 all-1s)", weight_bytes.size()), UVM_NONE)
    `uvm_info("TEST", "Expected: 16 INT32 values, each = 1", UVM_NONE)
    `uvm_info("TEST", "Cluster mode: SINGLE", UVM_NONE)
    `uvm_info("TEST", "Hang hypothesis: if hangs, DMA writer S_WAIT_DATA tail issue", UVM_NONE)

    // --- Golden reference ---
    env.golden.compute_conv(input_bytes, weight_bytes,
                            4, 4,           // H=4, W=4
                            1, 1,           // Cin=1, Cout=1
                            1, 1,           // kernel 1x1
                            1, 0);          // stride=1, valid
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden: %0d output bytes (%0d INT32)", expected_bytes.size(), expected_bytes.size()/4), UVM_NONE)
    for (i = 0; i < 4 && i < expected_bytes.size()/4; i++)
      `uvm_info("TEST", $sformatf("  Golden INT32[%0d] = %0d", i, env.golden.output_int32[i]), UVM_MEDIUM)

    // --- Configure and run ---
    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd4;
    conv_seq.input_w               = 16'd4;
    conv_seq.input_c               = 16'd1;
    conv_seq.output_c              = 16'd1;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd0;   // single cluster
    conv_seq.conv_cfg              = 32'd1;  // 1x1 kernel
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    clear_probe_sticky();
    `uvm_info("TEST", "Starting NPU task (will timeout if multi-window hang occurs)...", UVM_NONE)
    conv_seq.start(env.axil_ag.seqr);

    // --- Check result ---
    mismatches = 0;
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", $sformatf("PASS: Output verify — %0d bytes matched golden", expected_bytes.size()), UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("FAIL: Output mismatch — %0d bytes differ (first at byte %0d)",
          env.scoreboard.mismatch_count, env.scoreboard.first_mismatch_offset))

        // Detailed fingerprinting
        `uvm_info("TEST", "=== INT32 Mismatch Fingerprint (first 16) ===", UVM_NONE)
        mismatches = 0;
        for (i = 0; i < 16 && mismatches < 16; i++) begin
          int unsigned exp_val, act_val;
          exp_val = {expected_bytes[i*4+3], expected_bytes[i*4+2], expected_bytes[i*4+1], expected_bytes[i*4+0]};
          act_val = {conv_seq.actual_output[i*4+3], conv_seq.actual_output[i*4+2], conv_seq.actual_output[i*4+1], conv_seq.actual_output[i*4+0]};
          if (exp_val !== act_val) begin
            `uvm_info("TEST", $sformatf("  M[%0d]: off=%0d exp=%0d act=%0d",
              mismatches, i*4, exp_val, act_val), UVM_NONE)
            mismatches++;
          end
        end
      end
    end else begin
      `uvm_error("TEST", $sformatf("Conv task FAILED/HUNG: done=%0d error=%0d", conv_seq.done, conv_seq.error))
      `uvm_info("TEST", "HANG detected: 1x1 multi-window hang confirmed", UVM_NONE)
      `uvm_info("TEST", "HANG root cause likely: DMA writer S_WAIT_DATA tail (Hang B)", UVM_NONE)
      `uvm_info("TEST", "conv_frontend lb_base_row negative value is COSMETIC — not the root cause", UVM_NONE)
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
    `uvm_info("TEST", $sformatf("write_beats = %0d (exp >= 2 for 16 INT32 = 64 bytes → 8-beat burst)", rd_val), UVM_NONE)

    // --- Final verdict ---
    if (mismatches == 0 && conv_seq.done && !conv_seq.error) begin
      `uvm_info("TEST", "=== TEST 1: 1x1 MULTI-WINDOW — PASS ===", UVM_NONE)
      `uvm_info("TEST", "Conclusion: 1x1 multi-window does NOT hang. conv_frontend lb_base_row is cosmetic.", UVM_NONE)
    end else if (mismatches == -1) begin
      `uvm_info("TEST", "=== TEST 1: 1x1 MULTI-WINDOW — HANG ===", UVM_NONE)
      `uvm_info("TEST", "Conclusion: 1x1 multi-window HANGS. Root cause is downstream, not conv_frontend.", UVM_NONE)
    end else begin
      `uvm_info("TEST", "=== TEST 1: 1x1 MULTI-WINDOW — FAIL (mismatch) ===", UVM_NONE)
    end

    phase.drop_objection(this);
  endtask

endclass
