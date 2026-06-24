//=============================================================================
// soc_top_env.sv — Top-Level UVM Environment
//
// Instantiates AXI-Lite agent (always), plus optional status monitor, DMA
// monitor, performance checker, scoreboard, and memory model based on the
// environment config feature toggles.
//=============================================================================

`timescale 1ns / 1ps

class soc_top_env extends uvm_env;

  `uvm_component_utils(soc_top_env)

  soc_top_env_cfg       cfg;
  axil_agent            axil_ag;
  soc_mem_model         mem_model;
  soc_scoreboard        scoreboard;
  soc_golden_model      golden;
  soc_virtual_sequencer vseqr;
  npu_status_monitor    status_mon;
  axi4_dma_monitor      dma_mon;
  soc_perf_checker      perf_chk;

  function new(string name = "soc_top_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    // VCS constraint: declare local class variables BEFORE any statement
    axil_agent_cfg axil_cfg;
    super.build_phase(phase);

    // Retrieve or create environment configuration
    if (!uvm_config_db#(soc_top_env_cfg)::get(this, "", "cfg", cfg)) begin
      cfg = soc_top_env_cfg::type_id::create("cfg");
      `uvm_info("SOC_ENV", "Using default environment config", UVM_MEDIUM)
    end

    // Broadcast cfg to all children
    uvm_config_db#(soc_top_env_cfg)::set(this, "*", "cfg", cfg);

    // --- AXI-Lite Agent (always active) ---
    axil_cfg = axil_agent_cfg::type_id::create("axil_cfg");
    axil_cfg.is_active = 1;
    uvm_config_db#(axil_agent_cfg)::set(this, "axil_ag*", "cfg", axil_cfg);
    axil_ag = axil_agent::type_id::create("axil_ag", this);

    // --- Optional: Memory Model ---
    if (cfg.enable_scoreboard) begin
      mem_model = soc_mem_model::type_id::create("mem_model", this);
    end

    // --- Optional: Scoreboard ---
    if (cfg.enable_scoreboard) begin
      scoreboard = soc_scoreboard::type_id::create("scoreboard", this);
      golden    = soc_golden_model::type_id::create("golden", this);
    end

    // --- Virtual Sequencer ---
    vseqr = soc_virtual_sequencer::type_id::create("vseqr", this);

    // --- Optional: Status Monitor ---
    if (cfg.enable_status_monitor) begin
      status_mon = npu_status_monitor::type_id::create("status_mon", this);
    end

    // --- Optional: DMA Monitor ---
    if (cfg.enable_dma_monitor) begin
      dma_mon = axi4_dma_monitor::type_id::create("dma_mon", this);
    end

    // --- Optional: Performance Checker ---
    if (cfg.enable_perf_check) begin
      perf_chk = soc_perf_checker::type_id::create("perf_chk", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // Connect virtual sequencer to AXI-Lite sequencer
    vseqr.axil_seqr = axil_ag.seqr;

    // Connect AXIL monitor to memory model
    if (cfg.enable_scoreboard && mem_model != null) begin
      axil_ag.mon.ap.connect(mem_model.axil_imp);
    end

    // Connect AXIL monitor to scoreboard
    if (cfg.enable_scoreboard && scoreboard != null) begin
      axil_ag.mon.ap.connect(scoreboard.axil_imp);
    end

    // Connect DMA monitor to performance checker
    if (cfg.enable_dma_monitor && dma_mon != null && cfg.enable_perf_check && perf_chk != null) begin
      dma_mon.ap.connect(perf_chk.dma_imp);
    end
  endfunction

endclass
