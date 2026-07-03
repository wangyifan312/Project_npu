`timescale 1ns / 1ps

class axi4_dma_monitor extends uvm_monitor;

  `uvm_component_utils(axi4_dma_monitor)

  uvm_analysis_port #(axi4_dma_txn) ap;
  virtual soc_probe_if probe_vif;

  // 读 transaction tracking
  bit        rd_active;
  int unsigned rd_txn_cycles;
  int unsigned rd_data_cycles;
  int unsigned rd_beat_count;
  int unsigned rd_expected_beats;
  bit [31:0] rd_addr;
  bit [7:0]  rd_arlen;
  bit [2:0]  rd_arsize;
  bit [1:0]  rd_arburst;

  // 写 transaction tracking
  bit        wr_active;
  int unsigned wr_txn_cycles;
  int unsigned wr_data_cycles;
  int unsigned wr_beat_count;
  int unsigned wr_expected_beats;
  bit [31:0] wr_addr;
  bit [7:0]  wr_awlen;
  bit [2:0]  wr_awsize;
  bit [1:0]  wr_awburst;

  // Statistics
  int unsigned read_txn_count;
  int unsigned write_txn_count;
  int unsigned read_protocol_errors;
  int unsigned write_protocol_errors;
  int unsigned total_read_cycles;
  int unsigned total_write_cycles;
  int unsigned total_read_data_cycles;
  int unsigned total_write_data_cycles;

  // System-level (old) write busy tracking
  int unsigned wr_busy_total_cycles;         // npu_dma_wr_busy total cycles
  int unsigned wr_busy_data_cycles;          // WVALID && WREADY (same as total_write_data_cycles)
  bit        wr_busy_prev;
  int unsigned wr_busy_start_cycle;

  function new(string name = "axi4_dma_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual soc_probe_if)::get(this, "", "probe_vif", probe_vif))
      `uvm_fatal("DMA_MON", "Virtual soc_probe_if not found in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    axi4_dma_txn txn;
    rd_active = 1'b0;
    wr_active = 1'b0;
    read_txn_count = 0;
    write_txn_count = 0;
    read_protocol_errors = 0;
    write_protocol_errors = 0;
    total_read_cycles = 0;
    total_write_cycles = 0;
    total_read_data_cycles = 0;
    total_write_data_cycles = 0;
    wr_busy_total_cycles = 0;
    wr_busy_data_cycles  = 0;
    wr_busy_prev = 1'b0;

    forever begin
      @(posedge probe_vif.clk);

      // === System-level write busy tracking (old_write_util) ===
      // Counts ALL cycles where the DMA writer FSM is not idle,
      // including S_WAIT_DATA (waiting for FIFO to fill).
      if (probe_vif.npu_dma_wr_busy)
        wr_busy_total_cycles++;
      // Also count W data beats within the full busy window
      if (probe_vif.npu_dma_wr_busy && probe_vif.npu_m_wvalid && probe_vif.npu_m_wready)
        wr_busy_data_cycles++;

      // === Read Transaction Monitor ===
      // AR handshake: start of read burst
      if (probe_vif.npu_m_arvalid && probe_vif.npu_m_arready && !rd_active) begin
        rd_active = 1'b1;
        rd_txn_cycles = 0;
        rd_data_cycles = 0;
        rd_beat_count = 0;
        rd_addr    = probe_vif.npu_m_araddr;
        rd_arlen   = probe_vif.npu_m_arlen;
        rd_arsize  = probe_vif.npu_m_arsize;
        rd_arburst = probe_vif.npu_m_arburst;
        rd_expected_beats = rd_arlen + 1;

        // Protocol checks
        if (rd_arsize != 3'd5) begin
          `uvm_warning("DMA_MON", $sformatf("Read ARSIZE=%0d expected 5 (32-byte beats)", rd_arsize))
          read_protocol_errors++;
        end
        if (rd_arburst != 2'b01) begin
          `uvm_warning("DMA_MON", $sformatf("Read ARBURST=%0b expected INCR (01)", rd_arburst))
          read_protocol_errors++;
        end
        if (rd_addr[4:0] != 5'd0) begin
          `uvm_warning("DMA_MON", $sformatf("Read ARADDR=0x%08h not 32-byte aligned", rd_addr))
          read_protocol_errors++;
        end

        `uvm_info("DMA_MON", $sformatf("READ burst start: addr=0x%08h len=%0d", rd_addr, rd_expected_beats), UVM_MEDIUM)
      end

      if (rd_active) begin
        rd_txn_cycles++;
        // R data beat
        if (probe_vif.npu_m_rvalid && probe_vif.npu_m_rready) begin
          rd_data_cycles++;
          rd_beat_count++;
          if (probe_vif.npu_m_rresp != 2'b00) begin
            `uvm_warning("DMA_MON", $sformatf("Read RRESP=%0d (error) on beat %0d", probe_vif.npu_m_rresp, rd_beat_count))
            read_protocol_errors++;
          end
          // End of burst
          if (probe_vif.npu_m_rlast) begin
            txn = axi4_dma_txn::type_id::create("txn");
            txn.dir      = axi4_dma_txn::DMA_READ;
            txn.addr     = rd_addr;
            txn.len_beats = rd_expected_beats;
            txn.size_val = rd_arsize;
            txn.burst_type = rd_arburst;
            txn.resp     = probe_vif.npu_m_rresp;
            txn.error_seen = (probe_vif.npu_m_rresp != 2'b00) || (rd_beat_count != rd_expected_beats);
            txn.txn_cycles  = rd_txn_cycles;
            txn.data_cycles = rd_data_cycles;
            txn.utilization = (rd_txn_cycles > 0) ? (rd_data_cycles * 1.0 / rd_txn_cycles) : 0.0;
            ap.write(txn);

            if (rd_beat_count != rd_expected_beats) begin
              `uvm_warning("DMA_MON", $sformatf("Read beat count mismatch: got %0d expected %0d", rd_beat_count, rd_expected_beats))
              read_protocol_errors++;
            end

            `uvm_info("DMA_MON", $sformatf("READ burst end: %0d/%0d beats, util=%.2f", rd_data_cycles, rd_txn_cycles, txn.utilization), UVM_MEDIUM)

            total_read_cycles += rd_txn_cycles;
            total_read_data_cycles += rd_data_cycles;
            read_txn_count++;
            rd_active = 1'b0;
          end
        end
      end

      // === Write Transaction Monitor ===
      // AW handshake: start of write burst
      if (probe_vif.npu_m_awvalid && probe_vif.npu_m_awready && !wr_active) begin
        wr_active = 1'b1;
        wr_txn_cycles = 0;
        wr_data_cycles = 0;
        wr_beat_count = 0;
        wr_addr    = probe_vif.npu_m_awaddr;
        wr_awlen   = probe_vif.npu_m_awlen;
        wr_awsize  = probe_vif.npu_m_awsize;
        wr_awburst = probe_vif.npu_m_awburst;
        wr_expected_beats = wr_awlen + 1;

        // Protocol checks
        if (wr_awsize != 3'd5) begin
          `uvm_warning("DMA_MON", $sformatf("Write AWSIZE=%0d expected 5 (32-byte beats)", wr_awsize))
          write_protocol_errors++;
        end
        if (wr_awburst != 2'b01) begin
          `uvm_warning("DMA_MON", $sformatf("Write AWBURST=%0b expected INCR (01)", wr_awburst))
          write_protocol_errors++;
        end
        if (wr_addr[4:0] != 5'd0) begin
          `uvm_warning("DMA_MON", $sformatf("Write AWADDR=0x%08h not 32-byte aligned", wr_addr))
          write_protocol_errors++;
        end

        `uvm_info("DMA_MON", $sformatf("WRITE burst start: addr=0x%08h len=%0d", wr_addr, wr_expected_beats), UVM_MEDIUM)
      end

      if (wr_active) begin
        wr_txn_cycles++;
        // W data beat
        if (probe_vif.npu_m_wvalid && probe_vif.npu_m_wready) begin
          wr_data_cycles++;
          wr_beat_count++;
          if (probe_vif.npu_m_wstrb == 32'h0) begin
            `uvm_warning("DMA_MON", $sformatf("Write WSTRB=0 on beat %0d", wr_beat_count))
            write_protocol_errors++;
          end
        end

        // B response: end of write burst
        if (probe_vif.npu_m_bvalid && probe_vif.npu_m_bready) begin
          txn = axi4_dma_txn::type_id::create("txn");
          txn.dir      = axi4_dma_txn::DMA_WRITE;
          txn.addr     = wr_addr;
          txn.len_beats = wr_expected_beats;
          txn.size_val = wr_awsize;
          txn.burst_type = wr_awburst;
          txn.resp     = probe_vif.npu_m_bresp;
          txn.error_seen = (probe_vif.npu_m_bresp != 2'b00) || (wr_beat_count != wr_expected_beats);
          txn.txn_cycles  = wr_txn_cycles;
          txn.data_cycles = wr_data_cycles;
          txn.utilization = (wr_txn_cycles > 0) ? (wr_data_cycles * 1.0 / wr_txn_cycles) : 0.0;
          ap.write(txn);

          if (wr_beat_count != wr_expected_beats) begin
            `uvm_warning("DMA_MON", $sformatf("Write beat count mismatch: got %0d expected %0d", wr_beat_count, wr_expected_beats))
            write_protocol_errors++;
          end

          `uvm_info("DMA_MON", $sformatf("WRITE burst end: %0d/%0d beats, util=%.2f", wr_data_cycles, wr_txn_cycles, txn.utilization), UVM_MEDIUM)

          total_write_cycles += wr_txn_cycles;
          total_write_data_cycles += wr_data_cycles;
          write_txn_count++;
          wr_active = 1'b0;
        end
      end
    end
  endtask

  function void report_phase(uvm_phase phase);
    real avg_read_util;
    real avg_write_txn_util;
    real avg_write_sys_util;
    avg_read_util      = (total_read_cycles  > 0) ? (total_read_data_cycles  * 100.0 / total_read_cycles)  : 0.0;
    avg_write_txn_util = (total_write_cycles > 0) ? (total_write_data_cycles * 100.0 / total_write_cycles) : 0.0;
    avg_write_sys_util = (wr_busy_total_cycles > 0) ? (wr_busy_data_cycles * 100.0 / wr_busy_total_cycles) : 0.0;
    `uvm_info("DMA_MON", $sformatf(
      "DMA: read_txns=%0d write_txns=%0d | read_txn_util=%.1f%%",
      read_txn_count, write_txn_count, avg_read_util), UVM_NONE)
    `uvm_info("DMA_MON", $sformatf(
      "WRITE util: transaction-level=%.1f%% (%0d data / %0d txn_cycles) | system-level=%.1f%% (%0d data / %0d busy_cycles)",
      avg_write_txn_util, total_write_data_cycles, total_write_cycles,
      avg_write_sys_util, wr_busy_data_cycles, wr_busy_total_cycles), UVM_NONE)
    `uvm_info("DMA_MON", $sformatf(
      "Errors: read=%0d write=%0d", read_protocol_errors, write_protocol_errors), UVM_NONE)
  endfunction

endclass
