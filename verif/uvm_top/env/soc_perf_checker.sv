`timescale 1ns / 1ps

class soc_perf_checker extends uvm_component;

  `uvm_component_utils(soc_perf_checker)

  // Analysis import from DMA monitor
  uvm_analysis_imp #(axi4_dma_txn, soc_perf_checker) dma_imp;

  // Statistics
  int unsigned total_read_beats;
  int unsigned total_write_beats;

  function new(string name = "soc_perf_checker", uvm_component parent = null);
    super.new(name, parent);
    total_read_beats  = 0;
    total_write_beats = 0;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    dma_imp = new("dma_imp", this);
  endfunction

  // Receive DMA transactions via analysis port
  function void write(axi4_dma_txn txn);
    if (txn.dir == axi4_dma_txn::DMA_READ)
      total_read_beats  += txn.len_beats;
    else
      total_write_beats += txn.len_beats;
  endfunction

  // Called by the test with HW perf counter values read via AXI-Lite
  function void check_counters(bit [31:0] cycle_lo, bit [31:0] read_beats,
                               bit [31:0] write_beats, bit [31:0] read_active,
                               bit [31:0] write_active,
                               bit [31:0] write_data_cycles = 32'd0,
                               bit [31:0] write_txn_cycles  = 32'd0,
                               string tag = "");
    real old_write_util, new_write_txn_util;
    old_write_util     = (write_active > 0) ? (write_beats * 100.0 / write_active) : 0.0;
    new_write_txn_util = (write_txn_cycles > 0) ? (write_data_cycles * 100.0 / write_txn_cycles) : 0.0;
    `uvm_info("PERF_CHK", $sformatf(
      "[%0s] cycles=%0d | read_beats=%0d r_active=%0d | write_beats=%0d w_active=%0d | w_data_cyc=%0d w_txn_cyc=%0d",
      tag, cycle_lo, read_beats, read_active, write_beats, write_active, write_data_cycles, write_txn_cycles), UVM_NONE)
    `uvm_info("PERF_CHK", $sformatf(
      "[%0s] old_write_util=%.1f%% | write_transaction_util=%.1f%%",
      tag, old_write_util, new_write_txn_util), UVM_NONE)

    // Sanity checks
    if (cycle_lo == 32'd0) begin
      `uvm_warning("PERF_CHK", "Cycle count is zero - perf counters may not be enabled")
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("PERF_CHK", $sformatf(
      "DMA beat totals: read=%0d write=%0d", total_read_beats, total_write_beats), UVM_NONE)
  endfunction

endclass
