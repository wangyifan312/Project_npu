//=============================================================================
// npu_conv_stride2_test.sv — 3x3 Kernel Stride-2 Conv Smoke Test
//
// 测试覆盖：
//   - 6x6 input, 3x3 kernel, Cin=1, Cout=1, stride=2, valid padding
//   - conv_cfg[1:0]=2 (3x3 kernel), conv_cfg[2]=1 (stride2)
//   - Single cluster mode
//   - Numeric check: sum-of-products against golden model with stride=2
//
// Input:  6x6 all ones  (36 bytes)
// Weight: 3x3 all twos  (9 bytes)
// Output: 2x2 INT32 values, each = 9 * 1 * 2 = 18
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_stride2_test extends soc_base_test;

  `uvm_component_utils(npu_conv_stride2_test)

  function new(string name = "npu_conv_stride2_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[36];
    byte unsigned weight_bytes[9];
    byte unsigned expected_bytes[];
    int i;

    phase.raise_objection(this);
    #200;

    // Build test data: 6x6 input of all ones
    for (i = 0; i < 36; i++) begin
      input_bytes[i] = 8'h01;
    end

    // 3x3 weight of all twos
    for (i = 0; i < 9; i++) begin
      weight_bytes[i] = 8'h02;
    end

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden reference via DPI-C model (3x3 stride2)...", UVM_NONE)
    env.golden.compute_conv(input_bytes, weight_bytes,
                            6, 6,          // H=6, W=6
                            1, 1,          // Cin=1, Cout=1
                            3, 3,          // kernel 3x3
                            2, 0);         // stride=2, padding=0 (valid)
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden model computed: %0d output bytes (first 4 = [%02x %02x %02x %02x])",
      expected_bytes.size(),
      expected_bytes[0], expected_bytes[1], expected_bytes[2], expected_bytes[3]), UVM_NONE)

    // Configure and run NPU task
    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd6;
    conv_seq.input_w               = 16'd6;
    conv_seq.input_c               = 16'd1;
    conv_seq.output_c              = 16'd1;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd0;   // single cluster
    conv_seq.conv_cfg              = 32'h6;  // 3x3 kernel + stride2 (conv_cfg[2]=1, conv_cfg[1:0]=2)
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_conv_stride2_test: Single-Cluster 3x3 Stride-2 Conv ===", UVM_NONE)
    conv_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_conv_stride2_test PASSED (golden model verified) ===", UVM_NONE)
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
