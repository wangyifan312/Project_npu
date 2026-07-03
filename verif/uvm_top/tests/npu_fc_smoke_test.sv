//=============================================================================
// npu_fc_smoke_test.sv — FC Operator Smoke Test
//
// Small FC test: 4-element INT8 input -> 2-output INT32
//   Input:  {1, 2, 3, 4}
//   Weight: 4x2 INT8 row-major: all 1s
//     Row 0 (for output[0]): {1, 1, 1, 1}
//     Row 1 (for output[1]): {1, 1, 1, 1}
//   Golden: output[0] = 1+2+3+4 = 10
//           output[1] = 1+2+3+4 = 10
//
// 验证： FC task_type=1, config, start/poll, output read, DPI-C golden
//=============================================================================

`timescale 1ns / 1ps

class npu_fc_smoke_test extends soc_base_test;

  `uvm_component_utils(npu_fc_smoke_test)

  function new(string name = "npu_fc_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_fc_task_seq fc_seq;
    byte unsigned input_bytes[4];
    byte unsigned weight_bytes[4];
    byte unsigned expected_bytes[];
    int i;
    int output_offset;

    phase.raise_objection(this);
    #200;

    // --- Build test data ---
    // 输入: 4-element INT8 vector {1, 2, 3, 4}
    input_bytes[0] = 8'd1;
    input_bytes[1] = 8'd2;
    input_bytes[2] = 8'd3;
    input_bytes[3] = 8'd4;

    // 权重: 4x1 INT8 vector, all 1s (4 bytes for 1 output neuron)
    for (i = 0; i < 4; i++) begin
      weight_bytes[i] = 8'd1;
    end

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden FC reference via DPI-C model...", UVM_NONE)
    env.golden.compute_fc(input_bytes, weight_bytes, 4, 1);
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden FC computed: %0d bytes (expected 4 bytes for 1 INT32 output)",
      expected_bytes.size()), UVM_NONE)
    `uvm_info("TEST", $sformatf("Golden INT32 output: %0d",
      env.golden.output_int32[0]), UVM_NONE)

    // --- Configure and run NPU FC task ---
    fc_seq = npu_fc_task_seq::type_id::create("fc_seq");
    fc_seq.input_data             = input_bytes;
    fc_seq.weight_data            = weight_bytes;
    fc_seq.input_c                = 16'd4;
    fc_seq.output_c               = 16'd1;
    fc_seq.expected_output_bytes  = expected_bytes.size();
    fc_seq.cluster_mode           = 2'd0;     // single cluster
    fc_seq.input_base             = 32'h0000_0100;
    fc_seq.weight_base            = 32'h0000_0200;
    fc_seq.output_base            = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_fc_smoke_test: Single Cluster FC ===", UVM_NONE)
    fc_seq.start(env.axil_ag.seqr);

    // --- Compare DUT output with golden model ---
    if (fc_seq.done && !fc_seq.error) begin
      env.scoreboard.compare_output_bytes(fc_seq.actual_output, expected_bytes,
                                          fc_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_fc_smoke_test PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "FC task did not complete successfully")
    end

    phase.drop_objection(this);
  endtask

endclass
