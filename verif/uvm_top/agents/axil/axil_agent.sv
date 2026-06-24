`timescale 1ns / 1ps

class axil_agent extends uvm_agent;

  `uvm_component_utils(axil_agent)

  axil_agent_cfg cfg;
  axil_sequencer seqr;
  axil_driver    drv;
  axil_monitor   mon;

  function new(string name = "axil_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(axil_agent_cfg)::get(this, "", "cfg", cfg)) begin
      cfg = axil_agent_cfg::type_id::create("cfg");
      `uvm_info("AXIL_AGENT", "Using default agent config (is_active=1)", UVM_MEDIUM)
    end
    mon = axil_monitor::type_id::create("mon", this);
    if (cfg.is_active) begin
      seqr = axil_sequencer::type_id::create("seqr", this);
      drv  = axil_driver::type_id::create("drv", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg.is_active) begin
      drv.seq_item_port.connect(seqr.seq_item_export);
    end
  endfunction

endclass
