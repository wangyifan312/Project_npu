`timescale 1ns / 1ps

class soc_virtual_sequencer extends uvm_sequencer;

  `uvm_component_utils(soc_virtual_sequencer)

  // Handles to sub-sequencers (assigned at connect_phase in env)
  axil_sequencer axil_seqr;

  function new(string name = "soc_virtual_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass
