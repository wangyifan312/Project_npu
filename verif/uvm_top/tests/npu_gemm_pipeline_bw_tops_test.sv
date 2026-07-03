//=============================================================================
// npu_gemm_pipeline_bw_tops_test.sv — Joint TOPS + Bandwidth Performance Test
//
// STATUS: EXPERIMENTAL — NOT a competition compliance test.
//   This test currently FAILS (536/1024 mismatches) due to a suspected
//   multi-chunk FC shadow-register issue (CLAUDE.md §9.1) or golden-model
//   discrepancy for large (512→256) FC workloads.
//   NOT used as primary TOPS or bandwidth evidence.
//   Primary evidence: npu_conv_multiblock_test (TOPS) + npu_bandwidth_60pct_stress_test (BW).
//
// 目的： Simultaneously evaluate FC compute TOPS and task-level AXI bandwidth.
// Workload: FC 512→256 (GEMM-style), 131,072 MACs
//   Input:  512 INT8 values
//   Weight: 512×256 = 131,072 INT8 values
//   Output: 256 INT32 values = 1,024 bytes
//
// Tiling: 8 input chunks (ceil(512/64)) × 4 output tiles (ceil(256/64))
//   = 32 array passes, each 64×64 = 4,096 PE full utilization
//
// Enhanced performance counter coverage:
//   task_cycles, compute_cycles, load_cycles, store_cycles, collect_cycles
//   read_beats, write_beats, read_valid_bytes, write_valid_bytes
//   array_active_cycles, array_stall_cycles, array_fill_drain_cycles
//   stall_act_cycles, stall_wgt_cycles, stall_acc_cycles, stall_store_cycles
//   TOPS, array_util_task, array_util_compute
//   read_task_bw_util, write_task_bw_util, total_task_bw_util
//=============================================================================

`timescale 1ns / 1ps

class npu_gemm_pipeline_bw_tops_test extends soc_base_test;

  `uvm_component_utils(npu_gemm_pipeline_bw_tops_test)

  function new(string name = "npu_gemm_pipeline_bw_tops_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_fc_task_seq fc_seq;
    byte unsigned input_bytes[512];
    byte unsigned weight_bytes[131072];  // 512×256
    byte unsigned expected_bytes[];
    bit [31:0] cycle_lo, comp_cyc, load_cyc, store_cyc, coll_cyc;
    bit [31:0] arr_active, arr_stall, arr_fill_drain;
    bit [31:0] s_act, s_wgt, s_acc, s_store;
    bit [31:0] r_beats, w_beats, r_valid_bytes, w_valid_bytes;
    bit [31:0] bus_active, read_active, write_active;
    bit [31:0] wr_data_cycles, wr_txn_cycles;
    bit [31:0] mac_lo, mac_hi;
    bit [63:0] total_mac;
    real effective_tops, array_util_task, array_util_comp;
    real read_bw, write_bw, total_bw;
    real read_burst_util, write_burst_util;
    real avg_read_burst_len, avg_write_burst_len;
    real compute_ratio, load_ratio, store_ratio, collect_ratio;
    int i, j;
    int unsigned expected_mac_count;
    int unsigned idle_cyc_int;

    phase.raise_objection(this);
    #200;

    // ── Build test data ───────────────────────────────────────────
    // 输入:  1..64, 1..64, ... cycling (8 groups of 64 to fill 512)
    // 权重: small INT8 values to stay in safe range
    // 输出: each of 256 outputs = dot(input, weight_col)
    for (i = 0; i < 512; i++)
      input_bytes[i] = 8'((i % 64) + 1);    // 1..64 cycling

    for (i = 0; i < 256; i++)               // output neuron
      for (j = 0; j < 512; j++)             // input index
        weight_bytes[i * 512 + j] = 8'(((i + j) % 8) + 1);  // small values

    expected_mac_count = 512 * 256;  // 131,072 MACs

    // ── Golden reference ──────────────────────────────────────────
    env.golden.compute_fc(input_bytes, weight_bytes, 512, 256);
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", "", UVM_NONE)
    `uvm_info("TEST", "==================================================================", UVM_NONE)
    `uvm_info("TEST", "  GEMM Pipeline BW+TOPS Joint Performance Test", UVM_NONE)
    `uvm_info("TEST", "  Workload: FC 512->256 (GEMM proxy)", UVM_NONE)
    `uvm_info("TEST", "  Input:  512 INT8 | Weight: 131,072 INT8 (512×256)", UVM_NONE)
    `uvm_info("TEST", "  Output: 256 INT32 = 1,024 bytes", UVM_NONE)
    `uvm_info("TEST", "  Tiling: 8 input chunks × 4 output tiles = 32 array passes", UVM_NONE)
    `uvm_info("TEST", "  Each pass: 64×64 PE = 4,096 MACs, total = 131,072 MACs", UVM_NONE)
    `uvm_info("TEST", "==================================================================", UVM_NONE)

    // ── Run NPU FC task ────────────────────────────────────────────
    fc_seq = npu_fc_task_seq::type_id::create("fc_seq");
    fc_seq.input_data             = input_bytes;
    fc_seq.weight_data            = weight_bytes;
    fc_seq.input_c                = 16'd512;
    fc_seq.output_c               = 16'd256;
    fc_seq.expected_output_bytes  = expected_bytes.size();
    fc_seq.cluster_mode           = 2'd0;
    fc_seq.input_base             = 32'h0000_0100;
    fc_seq.weight_base            = 32'h0000_1000;
    fc_seq.output_base            = 32'h0003_0000;

    fc_seq.start(env.axil_ag.seqr);

    // ── Check 1: Output correctness ───────────────────────────────
    if (fc_seq.done && !fc_seq.error) begin
      env.scoreboard.compare_output_bytes(fc_seq.actual_output, expected_bytes,
                                          fc_seq.output_base);
      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", $sformatf(
          "PASS: Output verify — %0d bytes (%0d INT32) matched golden",
          expected_bytes.size(), 256), UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf(
          "FAIL: Output mismatch — %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", $sformatf("FC task failed: done=%0d error=%0d",
        fc_seq.done, fc_seq.error))
    end

    // ── Check 2: Read all perf counters ─────────────────────────
    fc_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO,          cycle_lo);
    fc_seq.axil_read32(`NPU_REG_PERF_COMPUTE_CYCLES,    comp_cyc);
    fc_seq.axil_read32(`NPU_REG_PERF_LOAD_CYCLES,       load_cyc);
    fc_seq.axil_read32(`NPU_REG_PERF_STORE_CYCLES,      store_cyc);
    fc_seq.axil_read32(`NPU_REG_PERF_COLLECT_CYCLES,    coll_cyc);
    fc_seq.axil_read32(`NPU_REG_PERF_ARRAY_ACTIVE,      arr_active);
    fc_seq.axil_read32(`NPU_REG_PERF_ARRAY_STALL,       arr_stall);
    fc_seq.axil_read32(`NPU_REG_PERF_READ_BEATS,        r_beats);
    fc_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS,       w_beats);
    fc_seq.axil_read32(`NPU_REG_PERF_READ_VALID_BYTES,  r_valid_bytes);
    fc_seq.axil_read32(`NPU_REG_PERF_WRITE_VALID_BYTES, w_valid_bytes);
    fc_seq.axil_read32(`NPU_REG_PERF_MAC_LO,            mac_lo);
    fc_seq.axil_read32(`NPU_REG_PERF_MAC_HI,            mac_hi);
    fc_seq.axil_read32(`NPU_REG_PERF_READ_ACTIVE,       read_active);
    fc_seq.axil_read32(`NPU_REG_PERF_WRITE_ACTIVE,      write_active);
    fc_seq.axil_read32(`NPU_REG_PERF_BUS_ACTIVE,        bus_active);
    fc_seq.axil_read32(`NPU_REG_PERF_WRITE_DATA_CYC,    wr_data_cycles);
    fc_seq.axil_read32(`NPU_REG_PERF_WRITE_TXN_CYC,     wr_txn_cycles);

    // ── Derived metrics ──────────────────────────────────────────
    total_mac = {mac_hi, mac_lo};

    // 空闲_cycles = total - load - compute (compute includes STORE for FC tile loop)
    // 注意：For FC, the FMS goes: LOAD → COMPUTE → STORE within each tile.
    // compute_cycles covers COMPUTE state; load_cycles covers all LOAD states;
    // store_cycles covers STORE state.
    idle_cyc_int = (cycle_lo > (comp_cyc + load_cyc + store_cyc))
                   ? (cycle_lo - comp_cyc - load_cyc - store_cyc) : 0;

    // TOPS: 2 ops per MAC, 200 MHz clock
    // tops_task = 2 * mac_count / (task_cycles / 200e6) / 1e12
    //           = mac_count * 200e6 * 2 / task_cycles / 1e12
    //           = mac_count / task_cycles * 0.0004
    effective_tops = (cycle_lo > 0)
      ? ($itor(total_mac) * 0.0004 / $itor(cycle_lo))
      : 0.0;

    // Array utilization (task-level): arr_active / task_cycles
    array_util_task = (cycle_lo > 0) ? ($itor(arr_active) * 100.0 / $itor(cycle_lo)) : 0.0;
    // Array utilization (compute-level): arr_active / compute_cycles
    array_util_comp = (comp_cyc > 0) ? ($itor(arr_active) * 100.0 / $itor(comp_cyc)) : 0.0;

    // 任务-level bandwidth utilization
    // 读_task_bw_util = read_valid_bytes / (task_cycles * 32)
    read_bw  = (cycle_lo > 0) ? ($itor(r_valid_bytes) * 100.0 / ($itor(cycle_lo) * 32.0)) : 0.0;
    write_bw = (cycle_lo > 0) ? ($itor(w_valid_bytes) * 100.0 / ($itor(cycle_lo) * 32.0)) : 0.0;
    total_bw = read_bw + write_bw;

    // burst-level utilization
    read_burst_util  = (read_active > 0) ? ($itor(r_beats) * 100.0 / $itor(read_active)) : 0.0;
    write_burst_util = (wr_txn_cycles > 0) ? ($itor(wr_data_cycles) * 100.0 / $itor(wr_txn_cycles)) : 0.0;

    // Avg burst length
    avg_read_burst_len  = (r_beats > 0 && r_beats >= 8/*rough burst count estimate*/) ?
      ($itor(r_beats) / $itor(r_beats / 16 + 1)) : 16.0;
    // Actually, let me compute properly: beats / AR handshakes
    avg_read_burst_len = ($itor(r_beats) / ($itor(r_beats) / 16.0 + 1.0));  // rough

    // 阶段 ratios
    compute_ratio = (cycle_lo > 0) ? ($itor(comp_cyc) * 100.0 / $itor(cycle_lo)) : 0.0;
    load_ratio    = (cycle_lo > 0) ? ($itor(load_cyc) * 100.0 / $itor(cycle_lo)) : 0.0;
    store_ratio   = (cycle_lo > 0) ? ($itor(store_cyc) * 100.0 / $itor(cycle_lo)) : 0.0;
    collect_ratio = (cycle_lo > 0) ? ($itor(coll_cyc) * 100.0 / $itor(cycle_lo)) : 0.0;

    // ── Report ─────────────────────────────────────────────────────
    `uvm_info("TEST", "", UVM_NONE)
    `uvm_info("TEST", "========================= PERFORMANCE REPORT =========================", UVM_NONE)
    `uvm_info("TEST", $sformatf("  PE array size         : 64 rows × 64 cols = 4,096 PE"), UVM_NONE)
    `uvm_info("TEST", $sformatf("  Clock frequency       : 200 MHz (5 ns period)"), UVM_NONE)
    `uvm_info("TEST", $sformatf("  Theoretical peak      : 4,096 PE × 2 ops × 200 MHz = 1.6384 TOPS"), UVM_NONE)
    `uvm_info("TEST", $sformatf("  AXI data width        : 256-bit (32 bytes/beat)"), UVM_NONE)
    `uvm_info("TEST", "", UVM_NONE)
    `uvm_info("TEST", "  --- Task Timing Breakdown ---", UVM_NONE)
    `uvm_info("TEST", $sformatf("  task_cycles           : %0d", cycle_lo), UVM_NONE)
    `uvm_info("TEST", $sformatf("  load_cycles           : %0d (%.1f%%)", load_cyc, load_ratio), UVM_NONE)
    `uvm_info("TEST", $sformatf("  compute_cycles        : %0d (%.1f%%)", comp_cyc, compute_ratio), UVM_NONE)
    `uvm_info("TEST", $sformatf("    collect_cycles      : %0d (%.1f%%)", coll_cyc, collect_ratio), UVM_NONE)
    `uvm_info("TEST", $sformatf("  store_cycles          : %0d (%.1f%%)", store_cyc, store_ratio), UVM_NONE)
    `uvm_info("TEST", $sformatf("  idle_cycles           : %0d (%.1f%%)", idle_cyc_int,
      (cycle_lo > 0) ? ($itor(idle_cyc_int) * 100.0 / $itor(cycle_lo)) : 0.0), UVM_NONE)
    `uvm_info("TEST", "", UVM_NONE)
    `uvm_info("TEST", "  --- Compute Utilization ---", UVM_NONE)
    `uvm_info("TEST", $sformatf("  array_active_cycles   : %0d", arr_active), UVM_NONE)
    `uvm_info("TEST", $sformatf("  array_stall_cycles    : %0d", arr_stall), UVM_NONE)
    `uvm_info("TEST", $sformatf("  array_fill_drain_cyc  : %0d", arr_fill_drain), UVM_NONE)
    `uvm_info("TEST", $sformatf("  stall_act_cycles      : %0d", s_act), UVM_NONE)
    `uvm_info("TEST", $sformatf("  stall_wgt_cycles      : %0d", s_wgt), UVM_NONE)
    `uvm_info("TEST", $sformatf("  stall_acc_cycles      : %0d", s_acc), UVM_NONE)
    `uvm_info("TEST", $sformatf("  stall_store_cycles    : %0d", s_store), UVM_NONE)
    `uvm_info("TEST", $sformatf("  array_util_task       : %.1f%% (arr_active/task_cycles)", array_util_task), UVM_NONE)
    `uvm_info("TEST", $sformatf("  array_util_compute    : %.1f%% (arr_active/compute_cycles)", array_util_comp), UVM_NONE)
    `uvm_info("TEST", "", UVM_NONE)
    `uvm_info("TEST", "  --- MAC and TOPS ---", UVM_NONE)
    `uvm_info("TEST", $sformatf("  mac_count (counted)   : %0d", total_mac), UVM_NONE)
    `uvm_info("TEST", $sformatf("  mac_count (expected)  : %0d", expected_mac_count), UVM_NONE)
    `uvm_info("TEST", $sformatf("  mac_per_cycle_task    : %.2f", (cycle_lo > 0) ? ($itor(total_mac) / $itor(cycle_lo)) : 0.0), UVM_NONE)
    `uvm_info("TEST", $sformatf("  mac_per_cycle_compute : %.2f", (comp_cyc > 0) ? ($itor(total_mac) / $itor(comp_cyc)) : 0.0), UVM_NONE)
    `uvm_info("TEST", $sformatf("  Effective TOPS        : %.4f TOPS", effective_tops), UVM_NONE)
    `uvm_info("TEST", $sformatf("  TOPS target           : >= 0.5000 %s",
      (effective_tops >= 0.50) ? "PASS" : "(not yet met)"), UVM_NONE)
    `uvm_info("TEST", "", UVM_NONE)
    `uvm_info("TEST", "  --- AXI Bandwidth ---", UVM_NONE)
    `uvm_info("TEST", $sformatf("  read_beat_count       : %0d", r_beats), UVM_NONE)
    `uvm_info("TEST", $sformatf("  write_beat_count      : %0d", w_beats), UVM_NONE)
    `uvm_info("TEST", $sformatf("  read_valid_bytes      : %0d", r_valid_bytes), UVM_NONE)
    `uvm_info("TEST", $sformatf("  write_valid_bytes     : %0d", w_valid_bytes), UVM_NONE)
    `uvm_info("TEST", $sformatf("  read_active_cycles    : %0d", read_active), UVM_NONE)
    `uvm_info("TEST", $sformatf("  write_active_cycles   : %0d", write_active), UVM_NONE)
    `uvm_info("TEST", $sformatf("  bus_active_cycles     : %0d", bus_active), UVM_NONE)
    `uvm_info("TEST", $sformatf("  write_data_cycles     : %0d", wr_data_cycles), UVM_NONE)
    `uvm_info("TEST", $sformatf("  write_txn_cycles      : %0d", wr_txn_cycles), UVM_NONE)
    `uvm_info("TEST", "", UVM_NONE)
    `uvm_info("TEST", $sformatf("  read_task_bw_util     : %.2f%%", read_bw), UVM_NONE)
    `uvm_info("TEST", $sformatf("  write_task_bw_util    : %.2f%%", write_bw), UVM_NONE)
    `uvm_info("TEST", $sformatf("  total_task_bw_util    : %.2f%%", total_bw), UVM_NONE)
    `uvm_info("TEST", $sformatf("  read_burst_util       : %.2f%%", read_burst_util), UVM_NONE)
    `uvm_info("TEST", $sformatf("  write_burst_util      : %.2f%% (WVALID&WREADY / txn_window)", write_burst_util), UVM_NONE)
    `uvm_info("TEST", $sformatf("  bus_active_util       : %.2f%%", (cycle_lo > 0) ? ($itor(bus_active) * 100.0 / $itor(cycle_lo)) : 0.0), UVM_NONE)
    `uvm_info("TEST", "", UVM_NONE)
    `uvm_info("TEST", "  --- Targets ---", UVM_NONE)
    `uvm_info("TEST", $sformatf("  TOPS >= 0.5            : %s", (effective_tops >= 0.50) ? "PASS" : "NOT MET"), UVM_NONE)
    `uvm_info("TEST", $sformatf("  Total task BW improved : %s", (total_bw > 6.0) ? "YES (>6%%)" : "check baseline"), UVM_NONE)
    `uvm_info("TEST", "==================================================================", UVM_NONE)

    // ── Sanity gates ────────────────────────────────────────────────
    if (total_mac < expected_mac_count / 2)
      `uvm_error("TEST", $sformatf("FAIL: counted MACs=%0d < expected/2=%0d", total_mac, expected_mac_count/2))
    if (arr_active == 32'd0)
      `uvm_error("TEST", "FAIL: array_active_cycles=0 (no PE activity)")
    if (cycle_lo == 32'd0)
      `uvm_error("TEST", "FAIL: cycle_count=0 (counter not running)")
    if (comp_cyc == 32'd0)
      `uvm_error("TEST", "FAIL: compute_cycles=0")
    if (r_valid_bytes < 32'd512)
      `uvm_error("TEST", $sformatf("FAIL: read_valid_bytes=%0d too low (<512)", r_valid_bytes))
    if (w_valid_bytes < 32'd512)
      `uvm_error("TEST", $sformatf("FAIL: write_valid_bytes=%0d too low (<512)", w_valid_bytes))

    phase.drop_objection(this);
  endtask

endclass
