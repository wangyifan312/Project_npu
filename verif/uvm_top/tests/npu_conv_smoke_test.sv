`timescale 1ns / 1ps

class npu_conv_smoke_test extends soc_base_test;

  `uvm_component_utils(npu_conv_smoke_test)

  function new(string name = "npu_conv_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[25];
    byte unsigned weight_bytes[9];   // 3x3 kernel = 9 weights
    byte unsigned expected_bytes[];
    int i;
    bit match;

    phase.raise_objection(this);
    #200;

    // Build test data: 5x5 input of 0x01, 3x3 weight of 0x02
    for (i = 0; i < 25; i++) begin
      input_bytes[i]  = 8'h01;
    end
    for (i = 0; i < 9; i++) begin
      weight_bytes[i] = 8'h02;
    end

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden reference via DPI-C model...", UVM_NONE)
    env.golden.compute_conv(input_bytes, weight_bytes,
                            5, 5,          // H=5, W=5
                            1, 1,          // Cin=1, Cout=1
                            3, 3,          // kernel 3x3
                            1, 0);         // stride=1, padding=0 (valid)
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden model computed: %0d output bytes (first 4 = [%02x %02x %02x %02x])",
      expected_bytes.size(),
      expected_bytes[0], expected_bytes[1], expected_bytes[2], expected_bytes[3]), UVM_NONE)

    // Configure and run NPU task
    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd5;
    conv_seq.input_w               = 16'd5;
    conv_seq.input_c               = 16'd1;
    conv_seq.output_c              = 16'd1;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd2;   // full cluster (6 clusters)
    conv_seq.conv_cfg              = 32'h2;   // kernel_sel=2 → 3x3, stride=1, valid
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_conv_smoke_test: Full 6-Cluster Conv ===", UVM_NONE)
    conv_seq.start(env.axil_ag.seqr);

    // Compare DUT output with golden model
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_conv_smoke_test PASSED (golden model verified) ===", UVM_NONE)
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
