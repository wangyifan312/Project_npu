`timescale 1ns / 1ps

class npu_cluster_mode_seq extends npu_conv_task_seq;

  `uvm_object_utils(npu_cluster_mode_seq)

  function new(string name = "npu_cluster_mode_seq");
    super.new(name);
  endfunction

endclass
