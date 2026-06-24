`timescale 1ns / 1ps

class axil_seq_item extends uvm_sequence_item;

  typedef enum {AXIL_READ, AXIL_WRITE} axil_cmd_e;

  rand axil_cmd_e cmd;
  rand bit [31:0] addr;
  rand bit [31:0] data;
  rand bit [3:0]  strb;

  bit [31:0] rdata;
  bit [1:0]  resp;

  constraint word_aligned_c {
    addr[1:0] == 2'b00;
  }

  constraint strb_valid_c {
    strb inside {4'h1, 4'h3, 4'h7, 4'hF, 4'h8, 4'hC, 4'hE};
  }

  `uvm_object_utils_begin(axil_seq_item)
    `uvm_field_enum(axil_cmd_e, cmd, UVM_ALL_ON)
    `uvm_field_int(addr, UVM_ALL_ON)
    `uvm_field_int(data, UVM_ALL_ON)
    `uvm_field_int(strb, UVM_ALL_ON)
    `uvm_field_int(rdata, UVM_ALL_ON)
    `uvm_field_int(resp, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "axil_seq_item");
    super.new(name);
  endfunction

endclass
