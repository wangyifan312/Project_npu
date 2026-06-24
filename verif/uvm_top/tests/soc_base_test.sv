//=============================================================================
// soc_base_test.sv — Base UVM Test Class
//
// Creates the soc_top_env and prints the UVM topology at end_of_elaboration.
// All concrete tests extend this class.
//=============================================================================

`timescale 1ns / 1ps

class soc_base_test extends uvm_test;

  `uvm_component_utils(soc_base_test)

  soc_top_env env;

  function new(string name = "soc_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    soc_top_env_cfg env_cfg;
    super.build_phase(phase);

    // Create environment configuration with all monitors enabled for debuggability
    env_cfg = soc_top_env_cfg::type_id::create("env_cfg");
    env_cfg.enable_scoreboard     = 1;
    env_cfg.enable_status_monitor = 1;
    env_cfg.enable_dma_monitor    = 1;
    env_cfg.enable_perf_check     = 1;
    uvm_config_db#(soc_top_env_cfg)::set(this, "*", "cfg", env_cfg);

    env = soc_top_env::type_id::create("env", this);
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    `uvm_info("TEST", "UVM testbench topology:", UVM_NONE)
    uvm_top.print_topology();
  endfunction

endclass
