//=============================================================================
// soc_base_test.sv — UVM 基础测试类
//
// 创建 soc_top_env 并打印 UVM 拓扑 at end_of_elaboration.
// 所有具体测试类继承此类。
//=============================================================================

`timescale 1ns / 1ps

class soc_base_test extends uvm_test;

  `uvm_component_utils(soc_base_test)

  soc_top_env env;
  virtual soc_probe_if probe_vif;

  function new(string name = "soc_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    soc_top_env_cfg env_cfg;
    super.build_phase(phase);

    // Retrieve probe virtual interface for hierarchical observation
    if (!uvm_config_db#(virtual soc_probe_if)::get(this, "", "probe_vif", probe_vif))
      `uvm_fatal("BASE_TEST", "Virtual soc_probe_if not found in config_db")

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

  // 清除 sticky 探针观测字段 before starting a new task.
  // Delegates to the interface's built-in clear function for simulator portability.
  task clear_probe_sticky();
    probe_vif.clear_sticky();
  endtask

endclass
