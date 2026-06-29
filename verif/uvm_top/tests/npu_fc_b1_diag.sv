`timescale 1ns/1ps
class npu_fc_b1_diag extends soc_base_test;
  `uvm_component_utils(npu_fc_b1_diag)
  function new(string n="npu_fc_b1_diag", uvm_component p=null); super.new(n,p); endfunction
  task run_phase(uvm_phase phase);
    npu_fc_task_seq fc_seq;
    byte unsigned input_bytes[];
    byte unsigned weight_bytes[];
    byte unsigned expected_bytes[];
    int i, j;
    bit [31:0] actual_w;
    phase.raise_objection(this); #200;

    // FC 4→2 test
    input_bytes = new[4]; for(i=0;i<4;i++) input_bytes[i]=8'(i+1);
    weight_bytes = new[2*4]; for(i=0;i<2;i++) for(j=0;j<4;j++) weight_bytes[i*4+j]=8'(i+1);
    env.golden.compute_fc(input_bytes, weight_bytes, 4, 2);
    expected_bytes = env.golden.output_bytes;
    `uvm_info("T",$sformatf("Golden[0]=%0d Golden[1]=%0d",env.golden.output_int32[0],env.golden.output_int32[1]),UVM_NONE)

    fc_seq = npu_fc_task_seq::type_id::create("fc");
    fc_seq.input_data=input_bytes; fc_seq.weight_data=weight_bytes;
    fc_seq.input_c=4; fc_seq.output_c=2;
    fc_seq.expected_output_bytes=expected_bytes.size();
    fc_seq.cluster_mode=2'd0;
    fc_seq.input_base = 32'h0000_0100;
    fc_seq.weight_base = 32'h0000_0200;
    fc_seq.output_base = 32'h0000_1000;  // avoid overlap
    fc_seq.start(env.axil_ag.seqr);

    if(fc_seq.done && !fc_seq.error) begin
      // Dump actual output
      for(i=0;i<2;i++) begin
        actual_w = {fc_seq.actual_output[i*4+3],fc_seq.actual_output[i*4+2],
                    fc_seq.actual_output[i*4+1],fc_seq.actual_output[i*4]};
        `uvm_info("T",$sformatf("RTL output[%0d]=%0d (0x%08h)  expect=%0d (0x%08h)",
          i, actual_w, actual_w,
          env.golden.output_int32[i], env.golden.output_int32[i]),UVM_NONE)
      end
      env.scoreboard.compare_output_bytes(fc_seq.actual_output, expected_bytes, 32'h300);
      if(env.scoreboard.mismatch_count==0)
        `uvm_info("T","=== PASSED ===",UVM_NONE)
      else
        `uvm_error("T",$sformatf("FAIL: %0d mismatches",env.scoreboard.mismatch_count))
    end else `uvm_error("T","task failed")
    phase.drop_objection(this);
  endtask
endclass
