//=============================================================================
// npu_conv_bias_requant_test.sv — Conv Bias + Requant Smoke Test
//
// Test coverage:
//   - 5x5 input, 5x5 kernel, Cin=1, Cout=2, stride=1, valid padding
//   - conv_cfg[4]=1 (bias enabled), conv_cfg[1:0]=0 (5x5 kernel)
//   - INT32 bias = {10, 20} added to raw MAC output
//   - Requant mult=1 shift=0 (identity, clamp to INT8)
//   - Single cluster mode
//
// Input:  5x5 all 2s (25 bytes)
// Weight: 5x5x1x2 all 1s (50 bytes, HWIO)
// Bias:   INT32 {10, 20} packed as 8 bytes LE
// Raw MAC: 25*2*1 = 50 for each output channel
// With bias: {50+10=60, 50+20=70}
// Requant identity: {60, 70} clamped to INT8
//
// Golden flow:
//   1. compute_conv  → raw MAC INT32s [50, 50]
//   2. compute_bias  → biased+requant INT8 [60, 70]
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_bias_requant_test extends soc_base_test;

  `uvm_component_utils(npu_conv_bias_requant_test)

  function new(string name = "npu_conv_bias_requant_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq         conv_seq;
    shared_ram_preload_seq    preload_seq;
    byte unsigned             input_bytes[25];
    byte unsigned             weight_bytes[50];
    byte unsigned             bias_data[8];
    byte unsigned             expected_bytes[];
    int unsigned              mac_ints[2];
    int unsigned              bias_ints[2];
    int                       i;

    phase.raise_objection(this);
    #200;

    // Build input data: 5x5 all 2s, Cin=1 (25 bytes)
    for (i = 0; i < 25; i++) begin
      input_bytes[i] = 8'h02;
    end

    // Build weight data: 5x5x1x2, all 1s, HWIO (50 bytes)
    for (i = 0; i < 50; i++) begin
      weight_bytes[i] = 8'h01;
    end

    // Build bias data: INT32 {10, 20} packed as little-endian bytes (8 bytes)
    // 10 = 0x0000000A, 20 = 0x00000014
    bias_data[0] = 8'h0A;
    bias_data[1] = 8'h00;
    bias_data[2] = 8'h00;
    bias_data[3] = 8'h00;
    bias_data[4] = 8'h14;
    bias_data[5] = 8'h00;
    bias_data[6] = 8'h00;
    bias_data[7] = 8'h00;

    // --- Use DPI-C reference model: Step 1 — raw MAC ---
    `uvm_info("TEST", "Computing raw MAC golden reference via DPI-C model...", UVM_NONE)
    env.golden.compute_conv(input_bytes, weight_bytes,
                            5, 5,          // H=5, W=5
                            1, 2,          // Cin=1, Cout=2
                            5, 5,          // kernel 5x5
                            1, 0);         // stride=1, padding=0 (valid)

    // Capture raw MAC INT32s from golden
    mac_ints[0] = env.golden.output_int32[0];
    mac_ints[1] = env.golden.output_int32[1];

    `uvm_info("TEST", $sformatf("Raw MAC INT32: [%0d, %0d]", mac_ints[0], mac_ints[1]), UVM_NONE)

    // --- Use DPI-C reference model: Step 2 — bias + requant ---
    bias_ints[0] = 10;
    bias_ints[1] = 20;
    env.golden.compute_bias(mac_ints, bias_ints, 2,
                            1'b0,         // relu_en = 0
                            1'b1,         // requant_en = 1
                            32'd1,        // multiplier = 1
                            32'd0);       // shift = 0 (identity requant)
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Bias+Requant expected INT8: [%0d, %0d] (%0d bytes)",
      $signed(expected_bytes[0]), $signed(expected_bytes[1]),
      expected_bytes.size()), UVM_NONE)

    // --- Preload bias data to shared RAM ---
    `uvm_info("TEST", "Preloading bias data via shared_ram_preload_seq...", UVM_NONE)
    preload_seq = shared_ram_preload_seq::type_id::create("bias_preload");
    preload_seq.base_addr = 32'h0000_0400;
    preload_seq.data       = bias_data;
    preload_seq.start(env.axil_ag.seqr);

    // --- Configure and run NPU conv task with bias ---
    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd5;
    conv_seq.input_w               = 16'd5;
    conv_seq.input_c               = 16'd1;
    conv_seq.output_c              = 16'd2;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd0;      // single cluster
    conv_seq.conv_cfg              = 32'h10;    // bias_en[4]=1, kernel[1:0]=0 (5x5), valid, stride1
    conv_seq.bias_addr             = 32'h0000_0400;
    conv_seq.bias_bytes            = 32'd8;     // 2 x INT32 = 8 bytes
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_conv_bias_requant_test: Single-Cluster Conv w/ Bias+Requant ===", UVM_NONE)
    conv_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_conv_bias_requant_test PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "Conv bias+requant task did not complete successfully")
    end

    phase.drop_objection(this);
  endtask

endclass
