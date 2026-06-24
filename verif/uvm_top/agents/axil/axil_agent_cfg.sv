`timescale 1ns / 1ps

class axil_agent_cfg extends uvm_object;

  bit is_active = 1;
  int unsigned max_wait_cycles = 10000;

  `uvm_object_utils_begin(axil_agent_cfg)
    `uvm_field_int(is_active, UVM_ALL_ON)
    `uvm_field_int(max_wait_cycles, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "axil_agent_cfg");
    super.new(name);
  endfunction

endclass
