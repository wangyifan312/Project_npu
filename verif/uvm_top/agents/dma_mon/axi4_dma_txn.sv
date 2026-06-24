`timescale 1ns / 1ps

class axi4_dma_txn extends uvm_sequence_item;

  typedef enum {DMA_READ, DMA_WRITE} dma_dir_e;

  dma_dir_e dir;
  bit [31:0] addr;
  int unsigned len_beats;       // burst length in beats (arlen+1 or awlen+1)
  bit [2:0]  size_val;
  bit [1:0]  burst_type;
  bit [1:0]  resp;
  bit        error_seen;

  // Transaction-level utilization
  int unsigned txn_cycles;      // total cycles from first handshake to last
  int unsigned data_cycles;     // cycles where VALID&READY for data beats

  real       utilization;       // data_cycles / txn_cycles

  `uvm_object_utils_begin(axi4_dma_txn)
    `uvm_field_enum(dma_dir_e, dir, UVM_ALL_ON)
    `uvm_field_int(addr, UVM_ALL_ON)
    `uvm_field_int(len_beats, UVM_ALL_ON)
    `uvm_field_int(size_val, UVM_ALL_ON)
    `uvm_field_int(burst_type, UVM_ALL_ON)
    `uvm_field_int(resp, UVM_ALL_ON)
    `uvm_field_int(error_seen, UVM_ALL_ON)
    `uvm_field_int(txn_cycles, UVM_ALL_ON)
    `uvm_field_int(data_cycles, UVM_ALL_ON)
    `uvm_field_real(utilization, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "axi4_dma_txn");
    super.new(name);
  endfunction

endclass
