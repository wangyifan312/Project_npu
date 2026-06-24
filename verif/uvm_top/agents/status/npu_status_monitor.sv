`timescale 1ns / 1ps

class npu_status_monitor extends uvm_monitor;

  `uvm_component_utils(npu_status_monitor)

  uvm_analysis_port #(npu_status_txn) ap;
  virtual soc_probe_if probe_vif;

  // Previous state for edge detection
  bit prev_busy;
  bit prev_done;
  bit prev_error;
  longint unsigned cycle_count;
  bit timeout_fired;

  // Timeout threshold
  int unsigned timeout_cycles;

  function new(string name = "npu_status_monitor", uvm_component parent = null);
    super.new(name, parent);
    prev_busy  = 1'b0;
    prev_done  = 1'b0;
    prev_error = 1'b0;
    cycle_count = 0;
    timeout_fired = 1'b0;
    timeout_cycles = 5000000;
  endfunction

  function void build_phase(uvm_phase phase);
    soc_top_env_cfg env_cfg;
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual soc_probe_if)::get(this, "", "probe_vif", probe_vif))
      `uvm_fatal("STATUS_MON", "Virtual soc_probe_if not found in config_db")
    // Get timeout from env config if available
    if (uvm_config_db#(soc_top_env_cfg)::get(this, "", "cfg", env_cfg)) begin
      timeout_cycles = env_cfg.timeout_cycles;
    end
  endfunction

  task run_phase(uvm_phase phase);
    npu_status_txn txn;
    bit cur_busy, cur_done, cur_error;
    longint unsigned busy_start_cycle;
    bit busy_timed_out;
    busy_start_cycle = 0;
    busy_timed_out = 1'b0;

    forever begin
      @(posedge probe_vif.clk);
      cycle_count++;

      cur_busy  = probe_vif.npu_status[1];
      cur_done  = probe_vif.npu_status[2];
      cur_error = probe_vif.npu_status[3];

      // Busy rising edge
      if (cur_busy && !prev_busy) begin
        txn = npu_status_txn::type_id::create("txn");
        txn.event_type = npu_status_txn::STATUS_BUSY_RISE;
        txn.busy  = 1'b1;
        txn.done  = cur_done;
        txn.error = cur_error;
        txn.cycle = cycle_count;
        ap.write(txn);
        `uvm_info("STATUS_MON", $sformatf("BUSY rise at cycle %0d", cycle_count), UVM_MEDIUM)
        busy_start_cycle = cycle_count;
        busy_timed_out = 1'b0;
      end

      // Busy falling edge
      if (!cur_busy && prev_busy) begin
        txn = npu_status_txn::type_id::create("txn");
        txn.event_type = npu_status_txn::STATUS_BUSY_FALL;
        txn.busy  = 1'b0;
        txn.done  = cur_done;
        txn.error = cur_error;
        txn.cycle = cycle_count;
        ap.write(txn);
        `uvm_info("STATUS_MON", $sformatf("BUSY fall at cycle %0d (duration %0d)", cycle_count, cycle_count - busy_start_cycle), UVM_MEDIUM)
        busy_timed_out = 1'b1; // prevent duplicate timeout
      end

      // Done rising edge
      if (cur_done && !prev_done) begin
        txn = npu_status_txn::type_id::create("txn");
        txn.event_type = npu_status_txn::STATUS_DONE_RISE;
        txn.busy  = cur_busy;
        txn.done  = 1'b1;
        txn.error = cur_error;
        txn.cycle = cycle_count;
        ap.write(txn);
        `uvm_info("STATUS_MON", $sformatf("DONE rise at cycle %0d", cycle_count), UVM_MEDIUM)
      end

      // Error rising edge
      if (cur_error && !prev_error) begin
        txn = npu_status_txn::type_id::create("txn");
        txn.event_type = npu_status_txn::STATUS_ERROR_RISE;
        txn.busy  = cur_busy;
        txn.done  = cur_done;
        txn.error = 1'b1;
        txn.cycle = cycle_count;
        ap.write(txn);
        `uvm_info("STATUS_MON", $sformatf("ERROR rise at cycle %0d", cycle_count), UVM_MEDIUM)
      end

      // Timeout detection: busy stuck high
      if (cur_busy && !busy_timed_out && (cycle_count - busy_start_cycle) > timeout_cycles) begin
        `uvm_error("STATUS_MON", $sformatf("NPU busy timeout: %0d cycles", cycle_count - busy_start_cycle))
        busy_timed_out = 1'b1;
      end

      prev_busy  = cur_busy;
      prev_done  = cur_done;
      prev_error = cur_error;
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("STATUS_MON", $sformatf("Status monitor: %0d cycles observed", cycle_count), UVM_NONE)
  endfunction

endclass
