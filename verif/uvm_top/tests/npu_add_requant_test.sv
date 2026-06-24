//=============================================================================
// npu_add_requant_test.sv — ADD with Non-Identity Requant Smoke Test
//
// Test coverage:
//   - 8-element INT8 ADD with pre-requant and output requant
//   - Pre-multipliers = 256, pre-shifts = 8  (effectively *256>>8 = identity)
//   - Output multiplier = 128, output shift = 7  (effectively *128>>7 = identity)
//   - All values pass through unchanged (within INT8 range)
//   - Single cluster mode
//
// src0: {10, 20, 30, 40, 50, 60, 70, 80}  INT8
// src1: {5,  10, 15, 20, 25, 30, 35, 40}  INT8
// Expected: {15, 30, 45, 60, 75, 90, 105, 120}  INT8
//
// Uses env.golden.compute_add() with explicit relu_en/requant_en parameters.
//=============================================================================

`timescale 1ns / 1ps

class npu_add_requant_test extends soc_base_test;

  `uvm_component_utils(npu_add_requant_test)

  function new(string name = "npu_add_requant_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_add_task_seq add_seq;
    byte unsigned    src0_bytes[8];
    byte unsigned    src1_bytes[8];
    byte unsigned    expected_bytes[];
    int              i;

    phase.raise_objection(this);
    #200;

    // Build src0: {10, 20, 30, 40, 50, 60, 70, 80}
    src0_bytes[0] = 8'd10;
    src0_bytes[1] = 8'd20;
    src0_bytes[2] = 8'd30;
    src0_bytes[3] = 8'd40;
    src0_bytes[4] = 8'd50;
    src0_bytes[5] = 8'd60;
    src0_bytes[6] = 8'd70;
    src0_bytes[7] = 8'd80;

    // Build src1: {5, 10, 15, 20, 25, 30, 35, 40}
    src1_bytes[0] = 8'd5;
    src1_bytes[1] = 8'd10;
    src1_bytes[2] = 8'd15;
    src1_bytes[3] = 8'd20;
    src1_bytes[4] = 8'd25;
    src1_bytes[5] = 8'd30;
    src1_bytes[6] = 8'd35;
    src1_bytes[7] = 8'd40;

    // --- Use DPI-C reference model with explicit relu_en/requant_en ---
    `uvm_info("TEST", "Computing golden ADD reference via DPI-C model (non-identity requant)...", UVM_NONE)
    env.golden.compute_add(src0_bytes, src1_bytes,
                           256, 8,       // src0_mult=256, src0_shift=8 (identity)
                           256, 8,       // src1_mult=256, src1_shift=8 (identity)
                           128, 7,       // out_mult=128, out_shift=7 (identity)
                           0, 1);        // relu_en=0, requant_en=1
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden ADD computed: %0d output bytes (values = [%0d, %0d, %0d, %0d, %0d, %0d, %0d, %0d])",
      expected_bytes.size(),
      $signed(expected_bytes[0]), $signed(expected_bytes[1]),
      $signed(expected_bytes[2]), $signed(expected_bytes[3]),
      $signed(expected_bytes[4]), $signed(expected_bytes[5]),
      $signed(expected_bytes[6]), $signed(expected_bytes[7])), UVM_NONE)

    // Configure and run NPU ADD task
    add_seq = npu_add_task_seq::type_id::create("add_seq");
    add_seq.src0_data      = src0_bytes;
    add_seq.src1_data      = src1_bytes;
    add_seq.element_count  = 8;
    add_seq.src0_mult      = 32'd256;
    add_seq.src0_shift     = 32'd8;
    add_seq.src1_mult      = 32'd256;
    add_seq.src1_shift     = 32'd8;
    add_seq.out_mult       = 32'd128;
    add_seq.out_shift      = 32'd7;
    add_seq.cluster_mode   = 2'd0;   // single cluster
    add_seq.src0_base      = 32'h0000_0100;
    add_seq.src1_base      = 32'h0000_0200;
    add_seq.output_base    = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_add_requant_test: Single-Cluster ADD w/ Requant ===", UVM_NONE)
    add_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (add_seq.done && !add_seq.error) begin
      env.scoreboard.compare_output_bytes(add_seq.actual_output, expected_bytes,
                                          add_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_add_requant_test PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "ADD requant task did not complete successfully")
    end

    phase.drop_objection(this);
  endtask

endclass
