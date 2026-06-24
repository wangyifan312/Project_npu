//=============================================================================
// npu_requant_extreme_test.sv — Requant Extreme Value Test
//
// Verifies INT32 -> INT8 Requantization clamping behavior at boundary values.
// multiplier=1, shift=0 (identity requant with clamp to [-128, 127]).
//
// Input (13 INT32 values):
//   INT32_MAX  ( 2147483647)            -> 127  (clamped)
//   INT32_MIN  (-2147483648)            -> -128 (clamped)
//   -129                               -> -128 (clamped)
//   -128                               -> -128 (no change)
//   -1                                 -> -1
//   0                                  -> 0
//   1                                  -> 1
//   127                                -> 127
//   128                                -> 127  (clamped)
//   255                                -> 127  (clamped)
//   -255                               -> -128 (clamped)
//   256                                -> 127  (clamped)
//   -256                               -> -128 (clamped)
//
// Uses env.golden.compute_requant() DPI-C ref model for golden comparison.
//=============================================================================

`timescale 1ns / 1ps

class npu_requant_extreme_test extends soc_base_test;

  `uvm_component_utils(npu_requant_extreme_test)

  function new(string name = "npu_requant_extreme_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_requant_task_seq rq_seq;
    int unsigned input_ints[13];
    byte unsigned expected_bytes[];
    byte unsigned expected_values[13];
    int i;
    int mismatches;

    phase.raise_objection(this);
    #200;

    // Build test data: 13 INT32 values covering boundary conditions
    // INT32_MAX / INT32_MIN use hex to avoid SV signed-literal overflow
    input_ints[0]  = 32'h7FFFFFFF;   //  2147483647 (INT32_MAX)
    input_ints[1]  = 32'h80000000;   // -2147483648 (INT32_MIN)
    input_ints[2]  = -129;
    input_ints[3]  = -128;
    input_ints[4]  = -1;
    input_ints[5]  = 0;
    input_ints[6]  = 1;
    input_ints[7]  = 127;
    input_ints[8]  = 128;
    input_ints[9]  = 255;
    input_ints[10] = -255;
    input_ints[11] = 256;
    input_ints[12] = -256;

    // Known-answer expected values for mult=1, shift=0:
    // Each INT32 clamped to signed 8-bit range [-128, 127].
    // Raw byte values: 0x80 = -128 (signed), 0xFF = -1, 0x7F = 127.
    expected_values[0]  = 8'h7F;      //  2147483647  -> 127  (clamped from above)
    expected_values[1]  = 8'h80;      // -2147483648  -> -128 (clamped from below)
    expected_values[2]  = 8'h80;      // -129          -> -128 (clamped)
    expected_values[3]  = 8'h80;      // -128          -> -128 (no change)
    expected_values[4]  = 8'hFF;      // -1            -> -1
    expected_values[5]  = 8'h00;      // 0             -> 0
    expected_values[6]  = 8'h01;      // 1             -> 1
    expected_values[7]  = 8'h7F;      // 127           -> 127
    expected_values[8]  = 8'h7F;      // 128           -> 127  (clamped)
    expected_values[9]  = 8'h7F;      // 255           -> 127  (clamped)
    expected_values[10] = 8'h80;      // -255          -> -128 (clamped)
    expected_values[11] = 8'h7F;      // 256           -> 127  (clamped)
    expected_values[12] = 8'h80;      // -256          -> -128 (clamped)

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden requant reference via DPI-C model...", UVM_NONE)
    env.golden.compute_requant(input_ints, 1, 0);
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden requant extreme computed: %0d output bytes",
      expected_bytes.size()), UVM_NONE)
    `uvm_info("TEST", $sformatf("Input [%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d]",
      $signed(input_ints[0]), $signed(input_ints[1]),
      $signed(input_ints[2]), $signed(input_ints[3]),
      $signed(input_ints[4]), $signed(input_ints[5]),
      $signed(input_ints[6]), $signed(input_ints[7]),
      $signed(input_ints[8]), $signed(input_ints[9]),
      $signed(input_ints[10]), $signed(input_ints[11]),
      $signed(input_ints[12])), UVM_NONE)
    `uvm_info("TEST", $sformatf("Golden output (raw): [%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x]",
      expected_bytes[0], expected_bytes[1], expected_bytes[2], expected_bytes[3],
      expected_bytes[4], expected_bytes[5], expected_bytes[6], expected_bytes[7],
      expected_bytes[8], expected_bytes[9], expected_bytes[10], expected_bytes[11],
      expected_bytes[12]), UVM_NONE)
    `uvm_info("TEST", $sformatf("Golden output (signed): [%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d]",
      $signed(expected_bytes[0]), $signed(expected_bytes[1]),
      $signed(expected_bytes[2]), $signed(expected_bytes[3]),
      $signed(expected_bytes[4]), $signed(expected_bytes[5]),
      $signed(expected_bytes[6]), $signed(expected_bytes[7]),
      $signed(expected_bytes[8]), $signed(expected_bytes[9]),
      $signed(expected_bytes[10]), $signed(expected_bytes[11]),
      $signed(expected_bytes[12])), UVM_NONE)

    // Verify golden against known-answer expected values
    mismatches = 0;
    for (i = 0; i < 13; i++) begin
      if (expected_bytes[i] !== expected_values[i]) begin
        `uvm_error("TEST", $sformatf("Golden model mismatch at idx=%0d: got=%02x expected=%02x",
          i, expected_bytes[i], expected_values[i]))
        mismatches++;
      end
    end
    if (mismatches == 0) begin
      `uvm_info("TEST", "Golden model known-answer check PASSED", UVM_NONE)
    end else begin
      `uvm_error("TEST", $sformatf("Golden model known-answer check FAILED: %0d mismatches", mismatches))
    end

    // Configure and run NPU requant task (mult=1, shift=0)
    rq_seq = npu_requant_task_seq::type_id::create("rq_seq");
    rq_seq.input_ints            = input_ints;
    rq_seq.element_count         = 13;
    rq_seq.multiplier            = 1;
    rq_seq.shift                 = 0;
    rq_seq.expected_output_bytes = expected_bytes.size();
    rq_seq.input_base            = 32'h0000_0100;
    rq_seq.output_base           = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_requant_extreme_test: INT32 -> INT8 boundary clamping ===", UVM_NONE)
    rq_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (rq_seq.done && !rq_seq.error) begin
      env.scoreboard.compare_output_bytes(rq_seq.actual_output, expected_bytes,
                                          rq_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_requant_extreme_test PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "Requant task did not complete successfully")
    end

    phase.drop_objection(this);
  endtask

endclass
