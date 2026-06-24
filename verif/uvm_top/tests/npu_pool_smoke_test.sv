//=============================================================================
// npu_pool_smoke_test.sv — Pool Smoke Test
//
// Verifies 2x2 MaxPool (stride 2) on a 4x4 INT32 tensor with 1 channel.
//
// Input (4x4):
//   [1, 5, 3, 8,
//    2, 6, 4, 7,
//    3, 1, 9, 2,
//    4, 8, 5, 3]
//
// Expected 2x2 max pool output (stride=2):
//   [6, 8,
//    8, 9]
//
// Uses env.golden.compute_pool() DPI-C ref model for golden comparison.
//=============================================================================

`timescale 1ns / 1ps

class npu_pool_smoke_test extends soc_base_test;

  `uvm_component_utils(npu_pool_smoke_test)

  function new(string name = "npu_pool_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_pool_task_seq pool_seq;
    int unsigned input_ints[16];
    byte unsigned expected_bytes[];
    int i;

    phase.raise_objection(this);
    #200;

    // Build test data: 4x4 INT32 tensor
    // [1, 5, 3, 8,
    //  2, 6, 4, 7,
    //  3, 1, 9, 2,
    //  4, 8, 5, 3]
    input_ints[0]  = 1;
    input_ints[1]  = 5;
    input_ints[2]  = 3;
    input_ints[3]  = 8;
    input_ints[4]  = 2;
    input_ints[5]  = 6;
    input_ints[6]  = 4;
    input_ints[7]  = 7;
    input_ints[8]  = 3;
    input_ints[9]  = 1;
    input_ints[10] = 9;
    input_ints[11] = 2;
    input_ints[12] = 4;
    input_ints[13] = 8;
    input_ints[14] = 5;
    input_ints[15] = 3;

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden pool reference via DPI-C model...", UVM_NONE)
    env.golden.compute_pool(input_ints, 4, 4, 1);
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden pool computed: %0d output bytes (INT32 = [%0d, %0d, %0d, %0d])",
      expected_bytes.size(),
      env.golden.output_int32[0],
      env.golden.output_int32[1],
      env.golden.output_int32[2],
      env.golden.output_int32[3]), UVM_NONE)

    // Configure and run NPU pool task
    pool_seq = npu_pool_task_seq::type_id::create("pool_seq");
    pool_seq.input_ints   = input_ints;
    pool_seq.input_h      = 16'd4;
    pool_seq.input_w      = 16'd4;
    pool_seq.channels     = 16'd1;
    pool_seq.expected_output_bytes = expected_bytes.size();
    pool_seq.cluster_mode = 2'd2;   // full cluster (6 clusters)
    pool_seq.input_base   = 32'h0000_0100;
    pool_seq.output_base  = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_pool_smoke_test: 2x2 MaxPool ===", UVM_NONE)
    pool_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (pool_seq.done && !pool_seq.error) begin
      env.scoreboard.compare_output_bytes(pool_seq.actual_output, expected_bytes,
                                          pool_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_pool_smoke_test PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "Pool task did not complete successfully")
    end

    phase.drop_objection(this);
  endtask

endclass
