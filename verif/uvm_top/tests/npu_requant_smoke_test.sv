//=============================================================================
// npu_requant_smoke_test.sv — Requant Smoke Test
//
// Verifies INT32 -> INT8 Requantization with configurable multiplier/shift.
//
// Test 1: multiplier=1, shift=0 (identity requant with clamp to INT8)
//   Input: 8 INT32 values = {100, 200, -50, -100, 0, 255, -200, 50}
//   Expected INT8: {100, 127, -50, -100, 0, 127, -128, 50}
//   (clamped to [-128, 127])
//
// Test 2: multiplier=2, shift=1 (effectively identity: (val*2)>>1 = val)
//   Same input and expected output as Test 1.
//
// Uses env.golden.compute_requant() DPI-C ref model for golden comparison.
//=============================================================================

`timescale 1ns / 1ps

class npu_requant_smoke_test extends soc_base_test;

  `uvm_component_utils(npu_requant_smoke_test)

  function new(string name = "npu_requant_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_requant_task_seq rq_seq;
    int unsigned input_ints[8];
    byte unsigned expected_bytes[];
    int i;
    bit overall_pass;

    phase.raise_objection(this);
    #200;

    overall_pass = 1;

    // Build test data: 8 INT32 values
    input_ints[0] = 100;
    input_ints[1] = 200;
    input_ints[2] = -50;
    input_ints[3] = -100;
    input_ints[4] = 0;
    input_ints[5] = 255;
    input_ints[6] = -200;
    input_ints[7] = 50;

    //===================================================================
    // Test 1: multiplier=1, shift=0 (identity requant with clamp)
    //===================================================================
    `uvm_info("TEST", "=== Test 1: multiplier=1, shift=0 (identity with clamp) ===", UVM_NONE)

    env.golden.compute_requant(input_ints, 1, 0);
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden requant [T1] computed: %0d output bytes (first 8 = [%02x %02x %02x %02x %02x %02x %02x %02x])",
      expected_bytes.size(),
      expected_bytes[0], expected_bytes[1], expected_bytes[2], expected_bytes[3],
      expected_bytes[4], expected_bytes[5], expected_bytes[6], expected_bytes[7]), UVM_NONE)

    `uvm_info("TEST", $sformatf("Golden requant [T1] signed values: [%0d %0d %0d %0d %0d %0d %0d %0d]",
      $signed(expected_bytes[0]), $signed(expected_bytes[1]),
      $signed(expected_bytes[2]), $signed(expected_bytes[3]),
      $signed(expected_bytes[4]), $signed(expected_bytes[5]),
      $signed(expected_bytes[6]), $signed(expected_bytes[7])), UVM_NONE)

    rq_seq = npu_requant_task_seq::type_id::create("rq_seq1");
    rq_seq.input_ints            = input_ints;
    rq_seq.element_count         = 8;
    rq_seq.multiplier            = 1;
    rq_seq.shift                 = 0;
    rq_seq.expected_output_bytes = expected_bytes.size();
    rq_seq.input_base            = 32'h0000_0100;
    rq_seq.output_base           = 32'h0000_0300;

    rq_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (rq_seq.done && !rq_seq.error) begin
      env.scoreboard.compare_output_bytes(rq_seq.actual_output, expected_bytes,
                                          rq_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== Test 1 PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        overall_pass = 0;
        `uvm_error("TEST", $sformatf("Test 1 output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "Test 1 Requant task did not complete successfully")
    end

    // Clear done/error state from Test 1 before starting Test 2
    begin
      axil_seq_item tr;
      tr = axil_seq_item::type_id::create("clear_tr");
      tr.cmd  = axil_seq_item::AXIL_WRITE;
      tr.addr = `NPU_REG_CTRL;
      tr.data = 32'h10;      // CTRL[4]=1 to clear done/error
      tr.strb = 4'hF;
      env.axil_ag.seqr.execute_item(tr);
    end

    //===================================================================
    // Test 2: multiplier=2, shift=1 (effectively identity)
    //===================================================================
    `uvm_info("TEST", "=== Test 2: multiplier=2, shift=1 (effectively identity via (val*2)>>1) ===", UVM_NONE)

    env.golden.compute_requant(input_ints, 2, 1);
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden requant [T2] computed: %0d output bytes (first 8 = [%02x %02x %02x %02x %02x %02x %02x %02x])",
      expected_bytes.size(),
      expected_bytes[0], expected_bytes[1], expected_bytes[2], expected_bytes[3],
      expected_bytes[4], expected_bytes[5], expected_bytes[6], expected_bytes[7]), UVM_NONE)

    `uvm_info("TEST", $sformatf("Golden requant [T2] signed values: [%0d %0d %0d %0d %0d %0d %0d %0d]",
      $signed(expected_bytes[0]), $signed(expected_bytes[1]),
      $signed(expected_bytes[2]), $signed(expected_bytes[3]),
      $signed(expected_bytes[4]), $signed(expected_bytes[5]),
      $signed(expected_bytes[6]), $signed(expected_bytes[7])), UVM_NONE)

    rq_seq = npu_requant_task_seq::type_id::create("rq_seq2");
    rq_seq.input_ints            = input_ints;
    rq_seq.element_count         = 8;
    rq_seq.multiplier            = 2;
    rq_seq.shift                 = 1;
    rq_seq.expected_output_bytes = expected_bytes.size();
    rq_seq.input_base            = 32'h0000_0200;    // Use different base to avoid conflict
    rq_seq.output_base           = 32'h0000_0400;

    rq_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (rq_seq.done && !rq_seq.error) begin
      env.scoreboard.compare_output_bytes(rq_seq.actual_output, expected_bytes,
                                          rq_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== Test 2 PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        overall_pass = 0;
        `uvm_error("TEST", $sformatf("Test 2 output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "Test 2 Requant task did not complete successfully")
    end

    if (overall_pass) begin
      `uvm_info("TEST", "=== npu_requant_smoke_test PASSED ===", UVM_NONE)
    end else begin
      `uvm_error("TEST", "=== npu_requant_smoke_test FAILED (one or more subtests mismatch) ===")
    end

    phase.drop_objection(this);
  endtask

endclass
