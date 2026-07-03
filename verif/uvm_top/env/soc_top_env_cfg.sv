//=============================================================================
// soc_top_env_cfg.sv — Environment Configuration Object
//=============================================================================

`timescale 1ns / 1ps

class soc_top_env_cfg extends uvm_object;

  // Feature toggles: enable sub-components when ready
  bit enable_scoreboard     = 0;
  bit enable_status_monitor = 0;
  bit enable_dma_monitor    = 0;
  bit enable_perf_check     = 0;

  // Global timeout in clock cycles (5M cycles @ 200 MHz = 25 ms)
  int unsigned timeout_cycles = 5000000;

  // 数据 directory for golden-reference files
  string data_dir = ".";

  // Human-readable test name for log filtering
  string test_name = "unknown";

  `uvm_object_utils_begin(soc_top_env_cfg)
    `uvm_field_int(enable_scoreboard,     UVM_ALL_ON)
    `uvm_field_int(enable_status_monitor, UVM_ALL_ON)
    `uvm_field_int(enable_dma_monitor,    UVM_ALL_ON)
    `uvm_field_int(enable_perf_check,     UVM_ALL_ON)
    `uvm_field_int(timeout_cycles,        UVM_ALL_ON)
    `uvm_field_string(data_dir,           UVM_ALL_ON)
    `uvm_field_string(test_name,          UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "soc_top_env_cfg");
    super.new(name);
  endfunction

endclass
