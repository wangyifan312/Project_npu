//=============================================================================
// npu_conv_multichannel_test.sv — Multi-Channel Conv Smoke Test
//
// Test coverage:
//   - 3x3 input, Cin=2, Cout=2, 3x3 kernel, stride=1, valid padding
//   - conv_cfg[1:0]=2 (3x3 kernel)
//   - Single cluster mode (cluster_mode=2'd0)
//   - Multi-channel numeric check against DPI-C golden model
//
// Input:  channel 0 = all 1s, channel 1 = all 2s (NHWC: 18 bytes)
// Weight: 2 input ch * 2 output ch * 9 spatial = 36 bytes, all 1s (HWIO)
// Golden: For each output channel, sum over all inputs and input channels
//         = 9*1*1 + 9*2*1 = 27 for both output channels
// Output: 2 INT32 values = 8 bytes (little-endian)
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_multichannel_test extends soc_base_test;

  `uvm_component_utils(npu_conv_multichannel_test)

  function new(string name = "npu_conv_multichannel_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[18];
    byte unsigned weight_bytes[36];
    byte unsigned expected_bytes[];
    int i;

    phase.raise_objection(this);
    #200;

    // Build input data: NHWC, 3x3 spatial, Cin=2
    // Channel 0 = all 1s, Channel 1 = all 2s
    // At each of 9 positions: [ch0=1, ch1=2]
    for (i = 0; i < 9; i++) begin
      input_bytes[i*2 + 0] = 8'h01;
      input_bytes[i*2 + 1] = 8'h02;
    end

    // Build weight data: HWIO, 3x3x2x2 = 36 bytes, all 1s
    for (i = 0; i < 36; i++) begin
      weight_bytes[i] = 8'h01;
    end

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden reference via DPI-C model (multi-channel 3x3 valid)...", UVM_NONE)
    env.golden.compute_conv(input_bytes, weight_bytes,
                            3, 3,          // H=3, W=3
                            2, 2,          // Cin=2, Cout=2
                            3, 3,          // kernel 3x3
                            1, 0);         // stride=1, padding=0 (valid)
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden model computed: %0d output bytes (first 8 = [%02x %02x %02x %02x %02x %02x %02x %02x])",
      expected_bytes.size(),
      expected_bytes[0], expected_bytes[1], expected_bytes[2], expected_bytes[3],
      expected_bytes[4], expected_bytes[5], expected_bytes[6], expected_bytes[7]), UVM_NONE)

    `uvm_info("TEST", $sformatf("Expected INT32 output: [%0d, %0d]",
      $signed({expected_bytes[3], expected_bytes[2], expected_bytes[1], expected_bytes[0]}),
      $signed({expected_bytes[7], expected_bytes[6], expected_bytes[5], expected_bytes[4]})), UVM_NONE)

    // Configure and run NPU task
    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd3;
    conv_seq.input_w               = 16'd3;
    conv_seq.input_c               = 16'd2;
    conv_seq.output_c              = 16'd2;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd0;   // single cluster
    conv_seq.conv_cfg              = 32'd2;  // 3x3 kernel, stride1, valid, no bias
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_conv_multichannel_test: Single-Cluster Multi-Channel Conv ===", UVM_NONE)
    conv_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_conv_multichannel_test PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "Multi-channel conv task did not complete successfully")
    end

    phase.drop_objection(this);
  endtask

endclass
