//=============================================================================
// npu_conv_1x1_smoke_test.sv — 1x1 Kernel Convolution Smoke Test
//
// Test coverage:
//   - 3x3 input, 1x1 kernel, Cin=1, Cout=1, stride=1, valid padding
//   - comv_cfg[1:0]=1 (1x1 kernel)
//   - Single cluster mode
//   - Numeric check: element-wise multiply against golden model
//
// Input:  {1,2,3, 4,5,6, 7,8,9} (3x3)
// Weight: {2}                     (1x1, single value)
// Output: {2,4,6, 8,10,12, 14,16,18} (9 INT32 values)
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_1x1_smoke_test extends soc_base_test;

  `uvm_component_utils(npu_conv_1x1_smoke_test)

  function new(string name = "npu_conv_1x1_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[9];
    byte unsigned weight_bytes[1];
    byte unsigned expected_bytes[];
    int i;

    phase.raise_objection(this);
    #200;

    // Build test data: 3x3 input = {1,2,3, 4,5,6, 7,8,9}
    input_bytes[0] = 8'd1;
    input_bytes[1] = 8'd2;
    input_bytes[2] = 8'd3;
    input_bytes[3] = 8'd4;
    input_bytes[4] = 8'd5;
    input_bytes[5] = 8'd6;
    input_bytes[6] = 8'd7;
    input_bytes[7] = 8'd8;
    input_bytes[8] = 8'd9;

    // 1x1 kernel weight = {2}
    weight_bytes[0] = 8'd2;

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden reference via DPI-C model (1x1 kernel)...", UVM_NONE)
    env.golden.compute_conv(input_bytes, weight_bytes,
                            3, 3,          // H=3, W=3
                            1, 1,          // Cin=1, Cout=1
                            1, 1,          // kernel 1x1
                            1, 0);         // stride=1, padding=0 (valid)
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden model computed: %0d output bytes (first 4 = [%02x %02x %02x %02x])",
      expected_bytes.size(),
      expected_bytes[0], expected_bytes[1], expected_bytes[2], expected_bytes[3]), UVM_NONE)

    // Configure and run NPU task
    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd3;
    conv_seq.input_w               = 16'd3;
    conv_seq.input_c               = 16'd1;
    conv_seq.output_c              = 16'd1;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd0;   // single cluster
    conv_seq.conv_cfg              = 32'd1;  // 1x1 kernel
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_conv_1x1_smoke_test: Single-Cluster 1x1 Conv ===", UVM_NONE)
    conv_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_conv_1x1_smoke_test PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "Conv task did not complete successfully")
    end

    phase.drop_objection(this);
  endtask

endclass
