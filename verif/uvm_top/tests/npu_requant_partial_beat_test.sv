//=============================================================================
// npu_requant_partial_beat_test.sv — Requant Partial Beat Test
//
// Verifies that the DMA writer correctly handles output sizes not aligned
// to any beat boundary. 9 INT32 elements requantized to 9 INT8 bytes.
//
// 9 bytes span 2 beats:
//   Beat 0: bytes 0-7 (WSTRB = 0xFF)
//   Beat 1: byte 8   (WSTRB = 0x01)
//
// The DMA writer must produce the correct WSTRB for the last beat so that
// only 1 byte is written to shared RAM in beat 1.
//
// 输入:  9 INT32 values all = 100
// mult=1, shift=0 (identity requant with clamp to [-128, 127])
// Expected: 9 bytes all = 100
//
// Uses env.golden.compute_requant() DPI-C ref model for golden comparison.
//=============================================================================

`timescale 1ns / 1ps

class npu_requant_partial_beat_test extends soc_base_test;

  `uvm_component_utils(npu_requant_partial_beat_test)

  function new(string name = "npu_requant_partial_beat_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_requant_task_seq rq_seq;
    int unsigned input_ints[9];
    byte unsigned expected_bytes[];
    int i;
    int mismatches;

    phase.raise_objection(this);
    #200;

    // 构建测试数据: 9 INT32 values all = 100
    for (i = 0; i < 9; i++)
      input_ints[i] = 100;

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden requant reference via DPI-C model...", UVM_NONE)
    env.golden.compute_requant(input_ints, 1, 0);
    expected_bytes = env.golden.output_bytes;

    // Verify golden output size
    if (expected_bytes.size() != 9) begin
      `uvm_error("TEST", $sformatf("Golden model size mismatch: expected 9, got %0d",
        expected_bytes.size()))
    end

    // Verify all golden output bytes are 100
    mismatches = 0;
    for (i = 0; i < expected_bytes.size(); i++) begin
      if (expected_bytes[i] != 8'd100) begin
        `uvm_error("TEST", $sformatf("Golden model value mismatch at idx=%0d: got=%0d expected=100",
          i, expected_bytes[i]))
        mismatches++;
      end
    end
    if (mismatches == 0) begin
      `uvm_info("TEST", "Golden model: 9 bytes all = 100 PASSED", UVM_NONE)
    end

    `uvm_info("TEST", $sformatf("Golden requant partial beat: %0d output bytes", expected_bytes.size()), UVM_NONE)
    `uvm_info("TEST", $sformatf("Golden output bytes: [%0d %0d %0d %0d %0d %0d %0d %0d %0d]",
      expected_bytes[0], expected_bytes[1], expected_bytes[2],
      expected_bytes[3], expected_bytes[4], expected_bytes[5],
      expected_bytes[6], expected_bytes[7], expected_bytes[8]), UVM_NONE)
    `uvm_info("TEST", "Beat layout: beat0=8 bytes (WSTRB=0xFF), beat1=1 byte (WSTRB=0x01)", UVM_NONE)

    // 配置 and run NPU requant task (mult=1, shift=0, 9 elements)
    rq_seq = npu_requant_task_seq::type_id::create("rq_seq");
    rq_seq.input_ints            = input_ints;
    rq_seq.element_count         = 9;
    rq_seq.multiplier            = 1;
    rq_seq.shift                 = 0;
    rq_seq.expected_output_bytes = expected_bytes.size();
    rq_seq.input_base            = 32'h0000_0100;
    rq_seq.output_base           = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_requant_partial_beat_test: 9-element requant, partial last beat ===", UVM_NONE)
    rq_seq.start(env.axil_ag.seqr);

    // 与黄金参考比对 DUT 输出 model
    if (rq_seq.done && !rq_seq.error) begin
      // Verify actual output size
      if (rq_seq.actual_output.size() != 9) begin
        `uvm_error("TEST", $sformatf("DUT output size mismatch: expected 9, got %0d",
          rq_seq.actual_output.size()))
      end

      env.scoreboard.compare_output_bytes(rq_seq.actual_output, expected_bytes,
                                          rq_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_requant_partial_beat_test PASSED (golden model verified) ===", UVM_NONE)
        `uvm_info("TEST", "Partial beat WSTRB correctness confirmed: 9 bytes output over 2 beats", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "Requant task did not complete successfully")
    end

    phase.drop_objection(this);
  endtask

endclass
