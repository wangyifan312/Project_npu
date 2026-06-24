`timescale 1ns / 1ps

class npu_status_txn extends uvm_sequence_item;

  typedef enum {STATUS_IDLE, STATUS_BUSY_RISE, STATUS_BUSY_FALL,
                STATUS_DONE_RISE, STATUS_ERROR_RISE} status_event_e;

  status_event_e event_type;
  bit        busy;
  bit        done;
  bit        error;
  longint unsigned cycle;

  `uvm_object_utils_begin(npu_status_txn)
    `uvm_field_enum(status_event_e, event_type, UVM_ALL_ON)
    `uvm_field_int(busy, UVM_ALL_ON)
    `uvm_field_int(done, UVM_ALL_ON)
    `uvm_field_int(error, UVM_ALL_ON)
    `uvm_field_int(cycle, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "npu_status_txn");
    super.new(name);
  endfunction

endclass
