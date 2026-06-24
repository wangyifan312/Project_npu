//=============================================================================
// npu_add_smoke_test.sv — ADD Operator Smoke Test
//
// Simple element-wise INT8 ADD test:
//   src0: {10, 20, 30, 40}
//   src1: {5, 10, 15, 20}
//   All multipliers = 1, all shifts = 0 (identity requant, just clamp)
//   Expected: {15, 30, 45, 60}
//
// Verifies: ADD task_type=4, config, start/poll, output read, DPI-C golden
//=============================================================================

`timescale 1ns / 1ps

class npu_add_smoke_test extends soc_base_test;

  `uvm_component_utils(npu_add_smoke_test)

  function new(string name = "npu_add_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_add_task_seq add_seq;
    byte unsigned src0_bytes[4];
    byte unsigned src1_bytes[4];
    byte unsigned expected_bytes[];
    int i;

    phase.raise_objection(this);
    #200;

    // Build test data: 4-element INT8 tensors
    src0_bytes[0] = 8'd10;
    src0_bytes[1] = 8'd20;
    src0_bytes[2] = 8'd30;
    src0_bytes[3] = 8'd40;

    src1_bytes[0] = 8'd5;
    src1_bytes[1] = 8'd10;
    src1_bytes[2] = 8'd15;
    src1_bytes[3] = 8'd20;

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden ADD reference via DPI-C model...", UVM_NONE)
    env.golden.compute_add(src0_bytes, src1_bytes,
                           1, 0,    // src0_mult=1, src0_shift=0
                           1, 0,    // src1_mult=1, src1_shift=0
                           1, 0);   // out_mult=1, out_shift=0
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden ADD computed: %0d output bytes (expected = [%0d, %0d, %0d, %0d])",
      expected_bytes.size(),
      expected_bytes[0], expected_bytes[1], expected_bytes[2], expected_bytes[3]), UVM_NONE)

    // Configure and run NPU ADD task
    add_seq = npu_add_task_seq::type_id::create("add_seq");
    add_seq.src0_data      = src0_bytes;
    add_seq.src1_data      = src1_bytes;
    add_seq.element_count  = 4;
    add_seq.src0_mult      = 32'd1;
    add_seq.src0_shift     = 32'd0;
    add_seq.src1_mult      = 32'd1;
    add_seq.src1_shift     = 32'd0;
    add_seq.out_mult       = 32'd1;
    add_seq.out_shift      = 32'd0;
    add_seq.cluster_mode   = 2'd2;   // full cluster (6 clusters)
    add_seq.src0_base      = 32'h0000_0100;
    add_seq.src1_base      = 32'h0000_0200;
    add_seq.output_base    = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_add_smoke_test: Full 6-Cluster ADD ===", UVM_NONE)
    add_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (add_seq.done && !add_seq.error) begin
      env.scoreboard.compare_output_bytes(add_seq.actual_output, expected_bytes,
                                          add_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_add_smoke_test PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "ADD task did not complete successfully")
    end

    phase.drop_objection(this);
  endtask

endclass
