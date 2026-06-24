`timescale 1ns / 1ps

class npu_cluster_mode_test extends soc_base_test;

  `uvm_component_utils(npu_cluster_mode_test)

  function new(string name = "npu_cluster_mode_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[25];
    byte unsigned weight_bytes[25];
    byte unsigned expected_bytes[4];
    bit [1:0] modes[4];
    string    labels[4];
    int i, t;
    bit match;

    phase.raise_objection(this);
    #200;

    for (i = 0; i < 25; i++) begin
      input_bytes[i]  = 8'h01;
      weight_bytes[i] = 8'h02;
    end
    expected_bytes[0] = 8'h32;
    expected_bytes[1] = 8'h00;
    expected_bytes[2] = 8'h00;
    expected_bytes[3] = 8'h00;

    modes[0]  = 2'd0; labels[0]  = "single (mode=0, 1 cluster)";
    modes[1]  = 2'd1; labels[1]  = "dual   (mode=1, 2 clusters)";
    modes[2]  = 2'd2; labels[2]  = "full   (mode=2, 6 clusters)";
    modes[3]  = 2'd3; labels[3]  = "mask   (mode=3, mask=0x0F)";

    for (t = 0; t < 4; t++) begin
      `uvm_info("TEST", $sformatf("=== Cluster mode: %s ===", labels[t]), UVM_NONE)

      conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
      conv_seq.input_data           = input_bytes;
      conv_seq.weight_data          = weight_bytes;
      conv_seq.input_h              = 16'd5;
      conv_seq.input_w              = 16'd5;
      conv_seq.input_c              = 16'd1;
      conv_seq.output_c             = 16'd1;
      conv_seq.expected_output_bytes = 4;
      conv_seq.expected_output      = expected_bytes;
      conv_seq.cluster_mode          = modes[t];
      // Use unique addresses per test to avoid interference
      conv_seq.input_base           = 32'h0000_0100 + (t * 32'h1000);
      conv_seq.weight_base          = 32'h0000_0200 + (t * 32'h1000);
      conv_seq.output_base          = 32'h0000_0300 + (t * 32'h1000);
      conv_seq.start(env.axil_ag.seqr);

      if (conv_seq.done && !conv_seq.error) begin
        match = 1'b1;
        for (i = 0; i < 4; i++) begin
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
