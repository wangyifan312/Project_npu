//=============================================================================
// npu_system_bus_util_test.sv — System-Level NPU Bus Active Utilization Test
//
// Primary metric: system_task_bus_active_ratio
//   = bus_data_active_cycles / task_cycles
//   bus_data_active_cycles = read_data_cycles + write_data_cycles
//   read_data_cycles  = PERF_READ_BEATS       (RVALID && RREADY)
//   write_data_cycles = PERF_WRITE_DATA_CYC   (WVALID && WREADY)
//   task_cycles       = PERF_CYCLE_LO         (NPU busy window)
//
// Secondary metrics:
//   AR/AW/B request handshake cycles (from probe_vif.bus_ar/aw/b_cycles)
//   compute_active_ratio = PERF_ARRAY_ACTIVE / task_cycles
//   payload_bandwidth_util, beat_bandwidth_util (retained for reference)
//
// Workloads:
//   A: FC full-cluster 96-output (baseline, kept for comparison)
//   B: FC large bandwidth-stress (input_c=1024, output_c=96, full cluster)
//
// Zero RTL changes.  All data-channel metrics from existing NPU perf counters.
// AR/AW/B counts from TB-level accumulators in tb_soc_top_uvm.sv.
//=============================================================================

`timescale 1ns / 1ps

class npu_system_bus_util_test extends soc_base_test;

  `uvm_component_utils(npu_system_bus_util_test)

  function new(string name = "npu_system_bus_util_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  //---------------------------------------------------------------------------
  // collect_metrics: read all counters and compute system-level bus metrics
  //---------------------------------------------------------------------------
  task collect_metrics(
    input  string       label,
    input  int unsigned input_b,
    input  int unsigned weight_b,
    input  int unsigned bias_b,
    input  int unsigned output_b,
    input  soc_base_seq seq_h,
    output bit  [31:0]  task_cyc,
    output bit  [31:0]  rd_data_cyc,
    output bit  [31:0]  wr_data_cyc,
    output bit  [31:0]  bus_active_cyc,
    output bit  [31:0]  compute_cyc,
    output bit  [31:0]  ar_cyc, aw_cyc, b_cyc,
    output real          bus_active_ratio,
    output real          compute_ratio,
    output real          payload_bw,
    output real          beat_bw,
    output real          txn_util
  );
    bit [31:0] tmp, rd_beats, wr_beats, wr_txn;

    // --- HW perf counters (AXI-Lite reads via sequence handle) ---
    seq_h.axil_read32(`NPU_REG_PERF_CYCLE_LO,        task_cyc);
    seq_h.axil_read32(`NPU_REG_PERF_READ_BEATS,      rd_beats);
    seq_h.axil_read32(`NPU_REG_PERF_WRITE_BEATS,     wr_beats);
    seq_h.axil_read32(`NPU_REG_PERF_WRITE_DATA_CYC,  wr_data_cyc);
    seq_h.axil_read32(`NPU_REG_PERF_WRITE_TXN_CYC,   wr_txn);
    seq_h.axil_read32(`NPU_REG_PERF_ARRAY_ACTIVE,    compute_cyc);

    // --- AXI address/response counters from probe interface ---
    ar_cyc = probe_vif.bus_ar_cycles;
    aw_cyc = probe_vif.bus_aw_cycles;
    b_cyc  = probe_vif.bus_b_cycles;

    // --- Derived metrics ---
    rd_data_cyc    = rd_beats;               // PERF_READ_BEATS = RVALID&&RREADY cycles
    bus_active_cyc = rd_data_cyc + wr_data_cyc;

    if (task_cyc > 0) begin
      bus_active_ratio = (bus_active_cyc * 100.0) / task_cyc;
      compute_ratio    = (compute_cyc * 100.0) / task_cyc;
    end else begin
      bus_active_ratio = 0.0;
      compute_ratio    = 0.0;
    end

    // Payload/beat bandwidth (retained for reference)
    if (task_cyc > 0) begin
      payload_bw = ((input_b + weight_b + bias_b + output_b) * 100.0) / (task_cyc * 32.0);
      beat_bw    = ((rd_beats + wr_beats) * 32.0 * 100.0) / (task_cyc * 32.0);
    end else begin
      payload_bw = 0.0; beat_bw = 0.0;
    end

    if (wr_txn > 0)
      txn_util = (wr_data_cyc * 100.0) / wr_txn;
    else
      txn_util = 0.0;

    // --- Print metrics ---
    `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("=== %s ===", label), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("task_cycles             = %0d", task_cyc), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("read_data_cycles (R&R)  = %0d", rd_data_cyc), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("write_data_cycles(W&W)  = %0d", wr_data_cyc), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("bus_data_active_cycles  = %0d  (R||W data handshake)", bus_active_cyc), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("--- address/response (waveform visibility) ---"), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("AR handshake cycles     = %0d", ar_cyc), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("AW handshake cycles     = %0d", aw_cyc), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("B handshake cycles      = %0d", b_cyc), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("--- compute ---"), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("array_active_cycles     = %0d", compute_cyc), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf("overhead_cycles         = %0d",
      task_cyc - bus_active_cyc - compute_cyc), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf(">> system_task_bus_active_ratio  = %0.2f%%", bus_active_ratio), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf(">> compute_active_ratio          = %0.2f%%", compute_ratio), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf(">> payload_bandwidth_util        = %0.2f%%", payload_bw), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf(">> beat_bandwidth_util           = %0.2f%%", beat_bw), UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", $sformatf(">> write_transaction_util (ref)  = %0.2f%%", txn_util), UVM_NONE)

    // Competition target check
    `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
    if (bus_active_ratio >= 60.0) begin
      `uvm_info("SYS_BUS_UTIL", "PASS_TARGET: system_task_bus_active_ratio >= 60%", UVM_NONE)
    end else begin
      `uvm_info("SYS_BUS_UTIL", "BELOW_TARGET: system_task_bus_active_ratio < 60%", UVM_NONE)
      `uvm_info("SYS_BUS_UTIL", "  Reason: task_cycles includes compute + FSM overhead.", UVM_NONE)
      `uvm_info("SYS_BUS_UTIL", "  Bus transfers complete in a fraction of total task window.", UVM_NONE)
    end
  endtask

  //---------------------------------------------------------------------------
  // Main run phase
  //---------------------------------------------------------------------------
  task run_phase(uvm_phase phase);
    npu_fc_task_seq fc_seq;
    byte unsigned input_bytes[];
    byte unsigned weight_bytes[];
    byte unsigned expected_bytes[];
    int i, j;
    bit mismatch_seen;
    bit overall_pass;

    // Per-workload storage
    string   labels[2];
    bit [31:0] w_task_cyc[2], w_rd_cyc[2], w_wr_cyc[2], w_bus_cyc[2];
    bit [31:0] w_comp_cyc[2], w_ar_cyc[2], w_aw_cyc[2], w_b_cyc[2];
    real w_bus_r[2], w_comp_r[2], w_pbw[2], w_bbw[2], w_txnu[2];
    bit w_pass[2];

    phase.raise_objection(this);
    #200;
    overall_pass = 1'b1;

    // =====================================================================
    // Workload A: FC full-cluster 96-output (baseline, retained for comparison)
    // =====================================================================
    labels[0] = "A: FC-96out-baseline";

    `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "##########################################################", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "#  WORKLOAD A: FC Full-Cluster 96-Output (Baseline)", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "##########################################################", UVM_NONE)

    input_bytes = new[16];
    for (i = 0; i < 16; i++) input_bytes[i] = 8'(i + 1);
    weight_bytes = new[96 * 16];
    for (i = 0; i < 96; i++)
      for (j = 0; j < 16; j++)
        weight_bytes[i * 16 + j] = 8'(i + 1);

    env.golden.compute_fc(input_bytes, weight_bytes, 16, 96);
    expected_bytes = env.golden.output_bytes;

    fc_seq = npu_fc_task_seq::type_id::create("fc_a");
    fc_seq.input_data             = input_bytes;
    fc_seq.weight_data            = weight_bytes;
    fc_seq.input_c                = 16'd16;
    fc_seq.output_c               = 16'd96;
    fc_seq.expected_output_bytes  = expected_bytes.size();
    fc_seq.cluster_mode           = 2'd0;
    fc_seq.input_base             = 32'h0000_0100;
    fc_seq.weight_base            = 32'h0000_0200;
    fc_seq.output_base            = 32'h0000_0300;

    probe_vif.clear_bus_counters();
    fc_seq.start(env.axil_ag.seqr);

    if (fc_seq.done && !fc_seq.error) begin
      env.scoreboard.compare_output_bytes(fc_seq.actual_output, expected_bytes,
                                          fc_seq.output_base);
      mismatch_seen = (env.scoreboard.mismatch_count > 0);
      if (mismatch_seen) begin
        `uvm_error("SYS_BUS_UTIL", "Workload A: output mismatch")
        overall_pass = 1'b0;
      end else begin
        `uvm_info("SYS_BUS_UTIL", "Workload A: output compare PASS", UVM_NONE)
      end

      collect_metrics(labels[0],
        input_bytes.size(), weight_bytes.size(), 0, expected_bytes.size(),
        fc_seq,
        w_task_cyc[0], w_rd_cyc[0], w_wr_cyc[0], w_bus_cyc[0],
        w_comp_cyc[0], w_ar_cyc[0], w_aw_cyc[0], w_b_cyc[0],
        w_bus_r[0], w_comp_r[0], w_pbw[0], w_bbw[0], w_txnu[0]);
      w_pass[0] = !mismatch_seen;
    end else begin
      `uvm_error("SYS_BUS_UTIL", $sformatf("Workload A: task failed (done=%0d err=%0d)",
        fc_seq.done, fc_seq.error))
      overall_pass = 1'b0; w_pass[0] = 1'b0;
    end

    // =====================================================================
    // Workload B: FC large bandwidth-stress (input_c=1024, output_c=96, full cluster)
    //
    // Design rationale: large weight matrix = sustained DMA read burst.
    // 1024 x 96 = 98304 bytes weight => ~3072 read beats.
    // 16 x 1024 input + 1024x96 weight + 96x4 output = 16416 payload bytes.
    // Bus-active duty cycle should approach read-dominated window.
    // =====================================================================
    labels[1] = "B: FC-1Kx96-stress";

    `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "##########################################################", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "#  WORKLOAD B: FC Large Bandwidth-Stress (1K→96)", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "##########################################################", UVM_NONE)

    input_bytes = new[1024];
    for (i = 0; i < 1024; i++) input_bytes[i] = 8'((i & 8'h3F) + 1);

    weight_bytes = new[96 * 1024];
    for (i = 0; i < 96; i++)
      for (j = 0; j < 1024; j++)
        weight_bytes[i * 1024 + j] = 8'((i & 8'h0F) + 1);

    env.golden.compute_fc(input_bytes, weight_bytes, 1024, 96);
    expected_bytes = env.golden.output_bytes;
    `uvm_info("SYS_BUS_UTIL", $sformatf("Workload B: input=%0d B, weight=%0d B, output=%0d B, total_payload=%0d B",
      input_bytes.size(), weight_bytes.size(), expected_bytes.size(),
      input_bytes.size() + weight_bytes.size() + expected_bytes.size()), UVM_NONE)

    fc_seq = npu_fc_task_seq::type_id::create("fc_b");
    fc_seq.input_data             = input_bytes;
    fc_seq.weight_data            = weight_bytes;
    fc_seq.input_c                = 16'd1024;
    fc_seq.output_c               = 16'd96;
    fc_seq.expected_output_bytes  = expected_bytes.size();
    fc_seq.cluster_mode           = 2'd0;
    fc_seq.input_base             = 32'h0001_0000;
    fc_seq.weight_base            = 32'h0002_0000;
    fc_seq.output_base            = 32'h0004_0000;

    probe_vif.clear_bus_counters();
    fc_seq.start(env.axil_ag.seqr);

    if (fc_seq.done && !fc_seq.error) begin
      env.scoreboard.compare_output_bytes(fc_seq.actual_output, expected_bytes,
                                          fc_seq.output_base);
      mismatch_seen = (env.scoreboard.mismatch_count > 0);
      if (mismatch_seen) begin
        `uvm_error("SYS_BUS_UTIL", "Workload B: output mismatch")
        overall_pass = 1'b0;
      end else begin
        `uvm_info("SYS_BUS_UTIL", "Workload B: output compare PASS", UVM_NONE)
      end

      collect_metrics(labels[1],
        input_bytes.size(), weight_bytes.size(), 0, expected_bytes.size(),
        fc_seq,
        w_task_cyc[1], w_rd_cyc[1], w_wr_cyc[1], w_bus_cyc[1],
        w_comp_cyc[1], w_ar_cyc[1], w_aw_cyc[1], w_b_cyc[1],
        w_bus_r[1], w_comp_r[1], w_pbw[1], w_bbw[1], w_txnu[1]);
      w_pass[1] = !mismatch_seen;
    end else begin
      `uvm_error("SYS_BUS_UTIL", $sformatf("Workload B: task failed (done=%0d err=%0d)",
        fc_seq.done, fc_seq.error))
      overall_pass = 1'b0; w_pass[1] = 1'b0;
    end

    // =====================================================================
    // Summary Table
    // =====================================================================
    `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "======================================================================================", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "  SYSTEM-LEVEL NPU BUS ACTIVE UTILIZATION — SUMMARY", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "======================================================================================", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "  Primary metric:", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "    system_task_bus_active_ratio = bus_data_active_cycles / task_cycles", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "    bus_data_active_cycles = read_data_cycles + write_data_cycles", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "    read_data_cycles  = count(RVALID && RREADY) — from PERF_READ_BEATS", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "    write_data_cycles = count(WVALID && WREADY) — from PERF_WRITE_DATA_CYC", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "    task_cycles       = NPU busy window — from PERF_CYCLE_LO", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "  Workload     |Cycles |AR  |Rdat|AW  |Wdat|B   |BusAct|Comp%|BusAct%|PldBW%|BeatBW%|WrTxn%", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "  -------------|-------|----|----|----|----|----|------|-----|-------|------|-------|------", UVM_NONE)

    for (i = 0; i < 2; i++) begin
      `uvm_info("SYS_BUS_UTIL", $sformatf(
        "  %-13s|%7d|%4d|%4d|%4d|%4d|%4d|%6d|%4.0f%%|%6.2f%%|%5.2f%%|%6.2f%%|%5.2f%%",
        labels[i], w_task_cyc[i], w_ar_cyc[i], w_rd_cyc[i], w_aw_cyc[i], w_wr_cyc[i], w_b_cyc[i],
        w_bus_cyc[i], w_comp_r[i], w_bus_r[i], w_pbw[i], w_bbw[i], w_txnu[i]
      ), UVM_NONE)
    end

    `uvm_info("SYS_BUS_UTIL", "  -------------|-------|----|----|----|----|----|------|-----|-------|------|-------|------", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "  Key observations:", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "    1. system_task_bus_active_ratio is the primary competition metric.", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "       It measures the fraction of task cycles where AXI data channels are active.", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "    2. AR/AW/B counts are provided for waveform visibility only.", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "       Bandwidth utilization is calculated from R/W data-channel handshakes.", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "    3. compute_active_ratio shows the fraction of cycles in systolic compute.", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "    4. payload/beat bandwidth utils are retained as secondary reference metrics.", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "    5. dma_axi_writer 80.00% long-burst transaction util is a write-channel sub-metric.", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "       It is NOT the system-level bus utilization.", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "    6. System bus util < 60% is expected for small workloads dominated by compute.", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "       Larger workloads with sustained DMA bursts achieve higher bus-active ratios.", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
    `uvm_info("SYS_BUS_UTIL", "  Competition target: system_task_bus_active_ratio >= 60%", UVM_NONE)

    // Overall verdict
    if (overall_pass && w_pass[0] && w_pass[1]) begin
      `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
      `uvm_info("SYS_BUS_UTIL", "  === npu_system_bus_util_test: FUNCTIONAL PASS ===", UVM_NONE)
    end else begin
      `uvm_info("SYS_BUS_UTIL", "", UVM_NONE)
      `uvm_info("SYS_BUS_UTIL", "  === npu_system_bus_util_test: FUNCTIONAL FAIL ===", UVM_NONE)
    end
    `uvm_info("SYS_BUS_UTIL", "======================================================================================", UVM_NONE)

    phase.drop_objection(this);
  endtask

endclass
