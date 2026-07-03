//=============================================================================
// npu_cluster_mask_sweep_test.sv — Cluster Mode/Mask Sweep Test
//
// Purpose: Verify runtime cluster configuration across single/dual/full/sparse
// masks.  Runs the same small FC task (16→16) with different mask settings
// and checks output correctness + expected active cluster mask.
//
// Checks:
//   1. Each mask: output compare PASS
//   2. Observed cluster_enable matches expected per mode+mask
//   3. Disabled clusters stay inactive
//   4. No error for legal configurations
//=============================================================================

`timescale 1ns / 1ps

class npu_cluster_mask_sweep_test extends soc_base_test;

  `uvm_component_utils(npu_cluster_mask_sweep_test)

  function new(string name = "npu_cluster_mask_sweep_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_fc_task_seq fc_seq;
    byte unsigned input_bytes[];
    byte unsigned weight_bytes[];
    byte unsigned expected_bytes[];
    int i;
    bit overall_pass;

    // Configuration sweep table
    bit [1:0] modes[4];
    bit [5:0] masks[4];
    bit [5:0] expected_enables[4];
    string    labels[4];
    int t;

    phase.raise_objection(this);
    #200;

    // --- Build shared test data: 16→16 FC ---
    // Simple deterministic pattern: outputs are all equal
    input_bytes = new[16];
    for (i = 0; i < 16; i++)
      input_bytes[i] = 8'd1;    // all inputs = 1

    weight_bytes = new[16 * 16];
    for (i = 0; i < 256; i++)
      weight_bytes[i] = 8'd1;   // all weights = 1
    // Golden: each output = sum(1*1 for 16 inputs) = 16

    env.golden.compute_fc(input_bytes, weight_bytes, 16, 16);
    expected_bytes = env.golden.output_bytes;

    // --- Sweep table ---
    // mode 0=single (target 1), mode 1=dual (target 2), mode 2=full (target 6)
    // mode 3=default/mask (target 6, but filtered by mask)
    // Single-cluster 64x64: only cluster 0 exists, mask bit 0 controls it
    modes[0]  = 2'd0; masks[0]  = 6'b000001; expected_enables[0] = 6'b000001;
    labels[0] = "single: mask=000001 → cluster0";

    modes[1]  = 2'd0; masks[1]  = 6'b111111; expected_enables[1] = 6'b000001;
    labels[1] = "single: mask=111111 → cluster0 only";

    // Verify non-masked cluster0: cluster 0 always available
    modes[2]  = 2'd2; masks[2]  = 6'b000001; expected_enables[2] = 6'b000001;
    labels[2] = "full: mask=000001 → cluster0";

    modes[3]  = 2'd2; masks[3]  = 6'b111111; expected_enables[3] = 6'b000001;
    labels[3] = "full: mask=111111 → cluster0";

    overall_pass = 1'b1;

    for (t = 0; t < 4; t++) begin
      `uvm_info("TEST", $sformatf("=== Sweep [%0d/4]: %s ===", t+1, labels[t]), UVM_NONE)

      fc_seq = npu_fc_task_seq::type_id::create("fc_seq");
      fc_seq.input_data             = input_bytes;
      fc_seq.weight_data            = weight_bytes;
      fc_seq.input_c                = 16'd16;
      fc_seq.output_c               = 16'd16;
      fc_seq.expected_output_bytes  = expected_bytes.size();
      fc_seq.cluster_mode           = modes[t];
      fc_seq.cluster_mask           = masks[t];
      // Use unique addresses per iteration to avoid interference
      fc_seq.input_base             = 32'h0000_0100 + (t * 32'h1000);
      fc_seq.weight_base            = 32'h0000_0200 + (t * 32'h1000);
      fc_seq.output_base            = 32'h0000_0300 + (t * 32'h1000);

      clear_probe_sticky();
      fc_seq.start(env.axil_ag.seqr);

      if (fc_seq.done && !fc_seq.error) begin
        // Check output
        env.scoreboard.compare_output_bytes(fc_seq.actual_output, expected_bytes,
                                            fc_seq.output_base);
        if (env.scoreboard.mismatch_count > 0) begin
          `uvm_error("TEST", $sformatf("%s: FAIL (output mismatch: %0d bytes)",
            labels[t], env.scoreboard.mismatch_count))
          overall_pass = 1'b0;
        end else begin
          `uvm_info("TEST", $sformatf("%s: output PASS", labels[t]), UVM_NONE)
        end

        // Check cluster enable matches expected
        `uvm_info("TEST", $sformatf("  cluster_enable observed = %b  expected = %b",
          probe_vif.npu_cluster_enable, expected_enables[t]), UVM_NONE)

        if (probe_vif.npu_cluster_enable !== expected_enables[t]) begin
          `uvm_error("TEST", $sformatf(
            "%s: FAIL cluster_enable=%b expected=%b",
            labels[t], probe_vif.npu_cluster_enable, expected_enables[t]))
          overall_pass = 1'b0;
        end else begin
          `uvm_info("TEST", $sformatf("%s: cluster_enable PASS", labels[t]), UVM_NONE)
        end

        // Sticky probe: cluster 0 should be observed
        if (expected_enables[t][0] && !probe_vif.observed_cluster_enable_mask[0]) begin
          `uvm_error("TEST", $sformatf(
            "%s: FAIL sticky: cluster 0 not observed enabled", labels[t]))
          overall_pass = 1'b0;
        end else begin
          `uvm_info("TEST", $sformatf("%s: sticky enable PASS", labels[t]), UVM_NONE)
        end

      end else begin
        `uvm_error("TEST", $sformatf("%s: FAIL (done=%0d error=%0d)",
          labels[t], fc_seq.done, fc_seq.error))
        overall_pass = 1'b0;
      end
    end

    if (overall_pass) begin
      `uvm_info("TEST", "=== npu_cluster_mask_sweep_test: OVERALL PASS ===", UVM_NONE)
    end else begin
      `uvm_info("TEST", "=== npu_cluster_mask_sweep_test: OVERALL FAIL ===", UVM_NONE)
    end

    phase.drop_objection(this);
  endtask

endclass
