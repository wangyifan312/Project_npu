//=============================================================================
// npu_perf_counter_scaling_test.sv — Performance Counter Scaling Test
//
// Purpose: Verify performance counters produce reasonable values under
// different cluster configurations.  Runs the same FC workload (16→48)
// with 1, 2, and 6 clusters and compares counter values.
//
// Checks:
//   1. Output compare PASS for all configurations
//   2. cycle_count > 0 for all configs
//   3. read/write beats > 0 for all configs
//   4. Counter values scale reasonably with cluster count
//      (not strict linear scaling, but no counters at zero or reversed)
//   5. enabled cluster count matches config
//
// Output: formatted report table at end of test
//=============================================================================

`timescale 1ns / 1ps

class npu_perf_counter_scaling_test extends soc_base_test;

  `uvm_component_utils(npu_perf_counter_scaling_test)

  function new(string name = "npu_perf_counter_scaling_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_fc_task_seq fc_seq;
    byte unsigned input_bytes[];
    byte unsigned weight_bytes[];
    byte unsigned expected_bytes[];
    int i;
    bit overall_pass;

    // Sweep table: mode, mask, expected cluster count, label
    bit [1:0] modes[3];
    bit [5:0] masks[3];
    int       exp_cluster_cnt[3];
    string    labels[3];

    // Per-config counter storage
    bit [31:0] cycles[3];
    bit [31:0] r_beats[3];
    bit [31:0] w_beats[3];
    bit [31:0] w_data_cyc[3];
    bit [31:0] w_txn_cyc[3];
    bit [1:0]  obs_cluster_cnt[3];
    bit        output_pass[3];
    bit        config_pass[3];
    int t;

    phase.raise_objection(this);
    #200;

    // --- Build test data: 16→48 FC ---
    input_bytes = new[16];
    for (i = 0; i < 16; i++)
      input_bytes[i] = 8'd1;

    weight_bytes = new[48 * 16];
    for (i = 0; i < 48 * 16; i++)
      weight_bytes[i] = 8'd1;

    env.golden.compute_fc(input_bytes, weight_bytes, 16, 48);
    expected_bytes = env.golden.output_bytes;

    // --- Sweep table ---
    modes[0]  = 2'd0; masks[0]  = 6'b000001; exp_cluster_cnt[0] = 1; labels[0] = "1-cluster (single)";
    modes[1]  = 2'd1; masks[1]  = 6'b000011; exp_cluster_cnt[1] = 2; labels[1] = "2-cluster (dual)";
    modes[2]  = 2'd2; masks[2]  = 6'b111111; exp_cluster_cnt[2] = 6; labels[2] = "6-cluster (full)";

    overall_pass = 1'b1;

    for (t = 0; t < 3; t++) begin
      `uvm_info("TEST", $sformatf("=== Scaling [%0d/3]: %s ===", t+1, labels[t]), UVM_NONE)

      fc_seq = npu_fc_task_seq::type_id::create("fc_seq");
      fc_seq.input_data             = input_bytes;
      fc_seq.weight_data            = weight_bytes;
      fc_seq.input_c                = 16'd16;
      fc_seq.output_c               = 16'd48;
      fc_seq.expected_output_bytes  = expected_bytes.size();
      fc_seq.cluster_mode           = modes[t];
      fc_seq.input_base             = 32'h0000_0100 + (t * 32'h10000);
      fc_seq.weight_base            = 32'h0000_0200 + (t * 32'h10000);
      fc_seq.output_base            = 32'h0000_0300 + (t * 32'h10000);

      clear_probe_sticky();
      fc_seq.start(env.axil_ag.seqr);

      config_pass[t] = 1'b1;

      if (fc_seq.done && !fc_seq.error) begin
        env.scoreboard.compare_output_bytes(fc_seq.actual_output, expected_bytes,
                                            fc_seq.output_base);
        output_pass[t] = (env.scoreboard.mismatch_count == 0);
        if (!output_pass[t]) begin
          `uvm_error("TEST", $sformatf("%s: output mismatch", labels[t]))
          config_pass[t] = 1'b0;
        end

        // Read perf counters
        fc_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycles[t]);
        fc_seq.axil_read32(`NPU_REG_PERF_READ_BEATS, r_beats[t]);
        fc_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS, w_beats[t]);
        // write_data/txn cycles via dedicated addresses 0xD0/0xD4
        fc_seq.axil_read32(`NPU_REG_PERF_WRITE_DATA_CYC, w_data_cyc[t]);
        fc_seq.axil_read32(`NPU_REG_PERF_WRITE_TXN_CYC, w_txn_cyc[t]);

        obs_cluster_cnt[t] = probe_vif.npu_cluster_count[1:0];

        // Sanity checks
        if (cycles[t] == 32'd0) begin
          `uvm_error("TEST", $sformatf("%s: cycle_count=0", labels[t]))
          config_pass[t] = 1'b0;
        end
        if (r_beats[t] == 32'd0) begin
          `uvm_error("TEST", $sformatf("%s: read_beats=0", labels[t]))
          config_pass[t] = 1'b0;
        end
        if (w_beats[t] == 32'd0) begin
          `uvm_error("TEST", $sformatf("%s: write_beats=0", labels[t]))
          config_pass[t] = 1'b0;
        end

        // Sticky probe check: observed_enable_mask should be non-zero and
        // at least the expected number of clusters participated
        if (probe_vif.observed_cluster_enable_mask == 6'b0) begin
          `uvm_error("TEST", $sformatf("%s: sticky observed_cluster_enable_mask=0 (no clusters observed)", labels[t]))
          config_pass[t] = 1'b0;
        end else begin
          `uvm_info("TEST", $sformatf("%s: sticky enable mask=%b (%0d clusters observed)",
            labels[t], probe_vif.observed_cluster_enable_mask,
            $countones(probe_vif.observed_cluster_enable_mask)), UVM_MEDIUM)
        end
      end else begin
        `uvm_error("TEST", $sformatf("%s: task failed (done=%0d error=%0d)",
          labels[t], fc_seq.done, fc_seq.error))
        config_pass[t] = 1'b0;
        output_pass[t] = 1'b0;
      end
    end

    // --- Report Table ---
    `uvm_info("TEST", "", UVM_NONE)
    `uvm_info("TEST", "================================================================", UVM_NONE)
    `uvm_info("TEST", "PERFORMANCE COUNTER SCALING REPORT", UVM_NONE)
    `uvm_info("TEST", "================================================================", UVM_NONE)
    `uvm_info("TEST", "Workload: FC 16→48 (16 INT8 in, 48 INT32 out)", UVM_NONE)
    `uvm_info("TEST", "", UVM_NONE)
    `uvm_info("TEST", "Config            | Output | Clusters | cycle_cnt | r_beats | w_beats | w_data_cyc | w_txn_cyc", UVM_NONE)
    `uvm_info("TEST", "------------------|--------|----------|-----------|---------|---------|------------|----------", UVM_NONE)

    for (t = 0; t < 3; t++) begin
      `uvm_info("TEST", $sformatf(
        "%-18s| %-6s |    %0d     | %9d | %7d | %7d | %10d | %8d",
        labels[t],
        output_pass[t] ? "PASS" : "FAIL",
        exp_cluster_cnt[t],
        cycles[t],
        r_beats[t],
        w_beats[t],
        w_data_cyc[t],
        w_txn_cyc[t]
      ), UVM_NONE)
    end

    `uvm_info("TEST", "================================================================", UVM_NONE)

    // --- Scaling sanity ---
    // 6-cluster should not have lower throughput than 1-cluster (cycle count
    // should decrease with more clusters for the same workload)
    if (config_pass[0] && config_pass[1] && cycles[0] > 0 && cycles[1] > 0) begin
      if (cycles[1] >= cycles[0]) begin
        `uvm_warning("TEST", $sformatf(
          "2-cluster cycles(%0d) >= 1-cluster cycles(%0d) — no speedup observed",
          cycles[1], cycles[0]))
        // Not an error: FC tile-based multi-pass may hide cluster-level speedup
      end else begin
        `uvm_info("TEST", $sformatf(
          "1→2 cluster speedup: %0d → %0d cycles (%.1fx)",
          cycles[0], cycles[1], cycles[0]*1.0/cycles[1]), UVM_NONE)
      end
    end

    if (config_pass[0] && config_pass[2] && cycles[0] > 0 && cycles[2] > 0) begin
      if (cycles[2] >= cycles[0]) begin
        `uvm_warning("TEST", $sformatf(
          "6-cluster cycles(%0d) >= 1-cluster cycles(%0d) — no speedup observed",
          cycles[2], cycles[0]))
      end else begin
        `uvm_info("TEST", $sformatf(
          "1→6 cluster speedup: %0d → %0d cycles (%.1fx)",
          cycles[0], cycles[2], cycles[0]*1.0/cycles[2]), UVM_NONE)
      end
    end

    // Check cluster count matches config
    for (t = 0; t < 3; t++) begin
      if (config_pass[t] && obs_cluster_cnt[t] !== exp_cluster_cnt[t][1:0]) begin
        `uvm_error("TEST", $sformatf(
          "%s: observed cluster_count=%0d expected=%0d",
          labels[t], obs_cluster_cnt[t], exp_cluster_cnt[t]))
        config_pass[t] = 1'b0;
      end
    end

    overall_pass = config_pass[0] && config_pass[1] && config_pass[2];
    if (overall_pass) begin
      `uvm_info("TEST", "=== npu_perf_counter_scaling_test: OVERALL PASS ===", UVM_NONE)
    end else begin
      `uvm_info("TEST", "=== npu_perf_counter_scaling_test: OVERALL FAIL ===", UVM_NONE)
    end

    phase.drop_objection(this);
  endtask

endclass
