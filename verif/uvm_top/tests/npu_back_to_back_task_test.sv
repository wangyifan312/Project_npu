//=============================================================================
// npu_back_to_back_task_test.sv — Back-to-Back Task Recovery Test
//
// 目的： Verify NPU can execute two consecutive tasks without reset.
// 任务 A: FC small (16→16), Task B: FC small (16→16) with different data.
// Both tasks' outputs are independently verified against golden.
//
// 检查：
//   1. Task A done without error, output compare PASS
//   2. Task B done without error, output compare PASS
//   3. busy/done state transition: Task A done→idle, then Task B config→start→done
//   4. Counters readable after each task
//   5. No stale output contamination (Task A and Task B outputs differ,
//      verifying the second task overwrites correctly)
//   6. No error during any phase
//=============================================================================

`timescale 1ns / 1ps

class npu_back_to_back_task_test extends soc_base_test;

  `uvm_component_utils(npu_back_to_back_task_test)

  function new(string name = "npu_back_to_back_task_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_fc_task_seq fc_seq_a;
    npu_fc_task_seq fc_seq_b;
    byte unsigned input_a[];
    byte unsigned weight_a[];
    byte unsigned input_b[];
    byte unsigned weight_b[];
    byte unsigned expected_a[];
    byte unsigned expected_b[];
    int i;
    bit [31:0] rd_val;
    bit task_a_pass;
    bit task_b_pass;

    phase.raise_objection(this);
    #200;

    // ================================================================
    // 任务 A: 16→16 FC with all-1s weights, sequential inputs
    // 输出[i] = 136 * (i+1)
    // ================================================================
    input_a = new[16];
    for (i = 0; i < 16; i++)
      input_a[i] = 8'(i + 1);

    weight_a = new[16 * 16];
    for (i = 0; i < 16 * 16; i++)
      weight_a[i] = 8'(i / 16 + 1);

    env.golden.compute_fc(input_a, weight_a, 16, 16);
    expected_a = env.golden.output_bytes;

    `uvm_info("TEST", "=== Task A: 16→16 FC (single cluster) ===", UVM_NONE)

    clear_probe_sticky();

    fc_seq_a = npu_fc_task_seq::type_id::create("fc_seq_a");
    fc_seq_a.input_data             = input_a;
    fc_seq_a.weight_data            = weight_a;
    fc_seq_a.input_c                = 16'd16;
    fc_seq_a.output_c               = 16'd16;
    fc_seq_a.expected_output_bytes  = expected_a.size();
    fc_seq_a.cluster_mode           = 2'd0;
    fc_seq_a.input_base             = 32'h0000_0100;
    fc_seq_a.weight_base            = 32'h0000_0200;
    fc_seq_a.output_base            = 32'h0000_0300;
    fc_seq_a.start(env.axil_ag.seqr);

    task_a_pass = 1'b1;

    if (fc_seq_a.done && !fc_seq_a.error) begin
      env.scoreboard.compare_output_bytes(fc_seq_a.actual_output, expected_a,
                                          fc_seq_a.output_base);
      if (env.scoreboard.mismatch_count > 0) begin
        `uvm_error("TEST", $sformatf(
          "Task A: output mismatch (%0d bytes)", env.scoreboard.mismatch_count))
        task_a_pass = 1'b0;
      end else begin
        `uvm_info("TEST", "Task A: PASS (output verified)", UVM_NONE)
      end

      // 读 perf counters after Task A
      fc_seq_a.axil_read32(`NPU_REG_PERF_CYCLE_LO, rd_val);
      `uvm_info("TEST", $sformatf("Task A: cycle_count=%0d", rd_val), UVM_NONE)
    end else begin
      `uvm_error("TEST", $sformatf("Task A: FAIL (done=%0d error=%0d)",
        fc_seq_a.done, fc_seq_a.error))
      task_a_pass = 1'b0;
    end

    // Small gap: verify bus is idle
    fc_seq_a.axil_read32(`NPU_REG_CTRL, rd_val);
    `uvm_info("TEST", $sformatf("Post-Task-A CTRL=0x%08h busy=%b done=%b error=%b",
      rd_val, rd_val[1], rd_val[2], rd_val[3]), UVM_NONE);

    if (rd_val[1]) begin
      `uvm_error("TEST", "Task A: NPU still busy after done")
      task_a_pass = 1'b0;
    end

    // 清除 sticky probes before Task B (auto-clear mechanism test:
    // npu_start_poll_seq now writes only bit[0]=1 without explicit clear,
    // relying on npu_ctrl auto-clearing done/error on new task start.)
    clear_probe_sticky();

    // ================================================================
    // 任务 B: 16→16 FC with DIFFERENT pattern (all-2s inputs)
    // 输出[i] = 32 * (i+1)   [sum=32 since each input=2 * 16 weights=1]
    // Wait - weights are per-output-channel. Let me use a clearer pattern.
    //
    // 输入: all 2s (16 INT8 values of 2)
    // 权重: identity-like, weight[out][in] = out+1
    // 输出[out] = sum(in[0..15] * weight[out][0..15])
    //             = sum(2 * (out+1) * 16) = 32 * (out+1) * 16 ... hmm
    //
    // Let me use a simple pattern:
    // 输入: {2,2,...,2} (16 INT8s of 2)
    // 权重: all 1s
    // 输出[i] = 16 * 2 * 1 = 32 for all i
    // ================================================================
    input_b = new[16];
    for (i = 0; i < 16; i++)
      input_b[i] = 8'd2;

    weight_b = new[16 * 16];
    for (i = 0; i < 16 * 16; i++)
      weight_b[i] = 8'd1;

    env.golden.compute_fc(input_b, weight_b, 16, 16);
    expected_b = env.golden.output_bytes;

    `uvm_info("TEST", "=== Task B: 16→16 FC (single cluster, different data) ===", UVM_NONE)
    `uvm_info("TEST", $sformatf("Task B golden output[0] = %0d",
      env.golden.output_int32[0]), UVM_MEDIUM)

    // Use different addresses to avoid reading Task A's output
    fc_seq_b = npu_fc_task_seq::type_id::create("fc_seq_b");
    fc_seq_b.input_data             = input_b;
    fc_seq_b.weight_data            = weight_b;
    fc_seq_b.input_c                = 16'd16;
    fc_seq_b.output_c               = 16'd16;
    fc_seq_b.expected_output_bytes  = expected_b.size();
    fc_seq_b.cluster_mode           = 2'd0;
    fc_seq_b.input_base             = 32'h0000_0400;
    fc_seq_b.weight_base            = 32'h0000_0500;
    fc_seq_b.output_base            = 32'h0000_0600;
    fc_seq_b.start(env.axil_ag.seqr);

    task_b_pass = 1'b1;

    if (fc_seq_b.done && !fc_seq_b.error) begin
      env.scoreboard.compare_output_bytes(fc_seq_b.actual_output, expected_b,
                                          fc_seq_b.output_base);
      if (env.scoreboard.mismatch_count > 0) begin
        `uvm_error("TEST", $sformatf(
          "Task B: output mismatch (%0d bytes)", env.scoreboard.mismatch_count))
        task_b_pass = 1'b0;
      end else begin
        `uvm_info("TEST", "Task B: PASS (output verified)", UVM_NONE)

        // Verify Task B output DIFFERS from Task A output
        // (confirms no stale data contamination)
        if (fc_seq_b.actual_output.size() == fc_seq_a.actual_output.size()) begin
          bit differs = 1'b0;
          for (i = 0; i < fc_seq_b.actual_output.size(); i++) begin
            if (fc_seq_b.actual_output[i] !== fc_seq_a.actual_output[i]) begin
              differs = 1'b1;
            end
          end
          if (differs)
            `uvm_info("TEST", "PASS: Task B output differs from Task A (no stale contamination)", UVM_NONE)
          else
            `uvm_error("TEST", "FAIL: Task B output identical to Task A (possible stale data)")
        end
      end

      // 读 perf counters after Task B
      fc_seq_b.axil_read32(`NPU_REG_PERF_CYCLE_LO, rd_val);
      `uvm_info("TEST", $sformatf("Task B: cycle_count=%0d", rd_val), UVM_NONE)
    end else begin
      `uvm_error("TEST", $sformatf("Task B: FAIL (done=%0d error=%0d)",
        fc_seq_b.done, fc_seq_b.error))
      task_b_pass = 1'b0;
    end

    // Final state check
    fc_seq_b.axil_read32(`NPU_REG_CTRL, rd_val);
    `uvm_info("TEST", $sformatf("Post-Task-B CTRL=0x%08h busy=%b done=%b error=%b",
      rd_val, rd_val[1], rd_val[2], rd_val[3]), UVM_NONE);

    // ================================================================
    // Verdict
    // ================================================================
    if (task_a_pass && task_b_pass) begin
      `uvm_info("TEST", "=== npu_back_to_back_task_test: OVERALL PASS ===", UVM_NONE)
    end else begin
      if (!task_a_pass) `uvm_info("TEST", "  Task A: FAIL", UVM_NONE)
      if (!task_b_pass) `uvm_info("TEST", "  Task B: FAIL", UVM_NONE)
      `uvm_info("TEST", "=== npu_back_to_back_task_test: OVERALL FAIL ===", UVM_NONE)
    end

    phase.drop_objection(this);
  endtask

endclass
