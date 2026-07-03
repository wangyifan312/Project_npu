//=============================================================================
// npu_conv_3x3_same_test.sv — 3x3 Kernel Same Padding Conv Smoke Test
//
// 测试覆盖：
//   - 4x4 input, 3x3 kernel, Cin=1, Cout=1, stride=1, same padding
//   - conv_cfg[1:0]=2 (3x3 kernel), conv_cfg[3]=1 (same padding)
//   - Single cluster mode
//   - Numeric check: sum-of-products against golden model with padding=1
//
// Input:  4x4 all ones (16 bytes)
// Weight: 3x3 all ones (9 bytes)
// Output: 4x4 INT32 values.
//   With same padding (pad=1), each output position sums valid window elements:
//   - Corner (0,0): only 2x2 valid with pad → 4
//   - Edge (0,1): 2x3 valid with pad → 6
//   - Center (1,1): full 3x3 window → 9
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_3x3_same_test extends soc_base_test;

  `uvm_component_utils(npu_conv_3x3_same_test)

  function new(string name = "npu_conv_3x3_same_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[16];
    byte unsigned weight_bytes[9];
    byte unsigned expected_bytes[];
    int i;

    phase.raise_objection(this);
    #200;

    // Build test data: 4x4 input of all ones
    for (i = 0; i < 16; i++) begin
      input_bytes[i] = 8'h01;
    end

    // 3x3 weight of all ones
    for (i = 0; i < 9; i++) begin
      weight_bytes[i] = 8'h01;
    end

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden reference via DPI-C model (3x3 same padding)...", UVM_NONE)
    env.golden.compute_conv(input_bytes, weight_bytes,
                            4, 4,          // H=4, W=4
                            1, 1,          // Cin=1, Cout=1
                            3, 3,          // kernel 3x3
                            1, 1);         // stride=1, padding=1 (same)
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden model computed: %0d output bytes (first 8 = [%02x %02x %02x %02x %02x %02x %02x %02x])",
      expected_bytes.size(),
      expected_bytes[0], expected_bytes[1], expected_bytes[2], expected_bytes[3],
      expected_bytes[4], expected_bytes[5], expected_bytes[6], expected_bytes[7]), UVM_NONE)

    // Configure and run NPU task
    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd4;
    conv_seq.input_w               = 16'd4;
    conv_seq.input_c               = 16'd1;
    conv_seq.output_c              = 16'd1;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd0;   // single cluster
    conv_seq.conv_cfg              = 32'hA;  // 3x3 kernel + same padding (conv_cfg[3]=1, conv_cfg[1:0]=2)
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_conv_3x3_same_test: Single-Cluster 3x3 Same-Pad Conv ===", UVM_NONE)
    conv_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_conv_3x3_same_test PASSED (golden model verified) ===", UVM_NONE)
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
