`timescale 1ns / 1ps

class npu_cluster_mode_test extends soc_base_test;

  `uvm_component_utils(npu_cluster_mode_test)

  function new(string name = "npu_cluster_mode_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[25];
    byte unsigned weight_bytes[9];   // 3x3 kernel = 9 weights
    byte unsigned expected_bytes[];
    bit [1:0] modes[4];
    string    labels[4];
    int i, t;
    bit match;

    phase.raise_objection(this);
    #200;

    // Build test data: 5x5 input of 0x01, 3x3 weight of 0x02
    for (i = 0; i < 25; i++)
      input_bytes[i]  = 8'h01;
    for (i = 0; i < 9; i++)
      weight_bytes[i] = 8'h02;

    // Use DPI-C golden model for 3x3 Conv
    env.golden.compute_conv(input_bytes, weight_bytes,
                            5, 5, 1, 1,    // H=5, W=5, Cin=1, Cout=1
                            3, 3,           // kernel 3x3
                            1, 0);          // stride=1, padding=0 (valid)
    expected_bytes = env.golden.output_bytes;

    modes[0]  = 2'd0; labels[0]  = "single (mode=0, 1 cluster)";
    modes[1]  = 2'd1; labels[1]  = "dual   (mode=1, 2 clusters)";
    modes[2]  = 2'd2; labels[2]  = "full   (mode=2, 6 clusters)";
    modes[3]  = 2'd3; labels[3]  = "mask   (mode=3, mask=0x0F)";

    for (t = 0; t < 4; t++) begin
      `uvm_info("TEST", $sformatf("=== Cluster mode: %s ===", labels[t]), UVM_NONE)

      conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
      conv_seq.input_data            = input_bytes;
      conv_seq.weight_data           = weight_bytes;
      conv_seq.input_h               = 16'd5;
      conv_seq.input_w               = 16'd5;
      conv_seq.input_c               = 16'd1;
      conv_seq.output_c              = 16'd1;
      conv_seq.conv_cfg              = 32'h2;   // kernel_sel=2 → 3x3, stride=1, valid
      conv_seq.expected_output_bytes = expected_bytes.size();
      conv_seq.expected_output       = expected_bytes;
      conv_seq.cluster_mode          = modes[t];
      // Use unique addresses per test to avoid interference
      conv_seq.input_base           = 32'h0000_0100 + (t * 32'h1000);
      conv_seq.weight_base          = 32'h0000_0200 + (t * 32'h1000);
      conv_seq.output_base          = 32'h0000_0300 + (t * 32'h1000);
      conv_seq.start(env.axil_ag.seqr);

      if (conv_seq.done && !conv_seq.error) begin
        match = 1'b1;
        for (i = 0; i < expected_bytes.size(); i++) begin
          if (conv_seq.actual_output[i] !== expected_bytes[i]) match = 1'b0;
        end
        if (match)
          `uvm_info("TEST", $sformatf("  %s: PASS", labels[t]), UVM_NONE)
        else
          `uvm_error("TEST", $sformatf("  %s: FAIL (output data mismatch)", labels[t]))
      end else begin
        `uvm_error("TEST", $sformatf("  %s: FAIL (done=%0d error=%0d)", labels[t], conv_seq.done, conv_seq.error))
      end
    end

    `uvm_info("TEST", "=== npu_cluster_mode_test COMPLETE ===", UVM_NONE)
    phase.drop_objection(this);
  endtask

endclass
