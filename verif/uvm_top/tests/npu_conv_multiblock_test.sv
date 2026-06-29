//=============================================================================
// npu_conv_multiblock_test.sv — Multi-Block Conv P3 Pipeline Verification
//
// Minimal multi-block: 8x8 input, 3x3 kernel valid → 6x6 output, 64 channels.
// conv_rows_per_block = 1024 / (6 * 64) = 2 rows/block → 3 blocks.
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_multiblock_test extends soc_base_test;

  `uvm_component_utils(npu_conv_multiblock_test)

  function new(string name = "npu_conv_multiblock_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[];
    byte unsigned weight_bytes[];
    byte unsigned expected_bytes[];
    bit [31:0] cycle_lo, arr_active, r_beats, w_beats, bus_active;
    real       effective_tops, bus_util;
    int i, j;
    int input_h, input_w, input_c, output_c, kernel;

    phase.raise_objection(this);
    #200;

    input_h   = 8;
    input_w   = 8;
    input_c   = 1;
    output_c  = 64;
    kernel    = 3;

    `uvm_info("TEST", $sformatf("=== Multi-Block Conv: %0d×%0d×%0d → %0dch k=%0d ===",
      input_h, input_w, input_c, output_c, kernel), UVM_NONE)

    // Build test data
    input_bytes  = new[input_h * input_w * input_c];
    weight_bytes = new[kernel * kernel * input_c * output_c];

    for (i = 0; i < input_h * input_w * input_c; i++)
      input_bytes[i] = 8'((i % 32) + 1);

    for (i = 0; i < kernel * kernel * input_c * output_c; i++)
      weight_bytes[i] = 8'((i % 16) + 1);

    // Golden reference
    env.golden.compute_conv(input_bytes, weight_bytes,
      input_h, input_w, input_c, output_c, kernel, kernel, 1, 0);

    expected_bytes = env.golden.output_bytes;
    `uvm_info("TEST", $sformatf("Golden: %0d bytes, first INT32=%0d",
      expected_bytes.size(), env.golden.output_int32[0]), UVM_NONE)

    // Run NPU Conv task
    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data             = input_bytes;
    conv_seq.weight_data            = weight_bytes;
    conv_seq.input_h                = input_h;
    conv_seq.input_w                = input_w;
    conv_seq.input_c                = input_c;
    conv_seq.output_c               = output_c;
    conv_seq.conv_cfg               = 32'h0000_0002;  // 3×3, stride=1, valid
    conv_seq.expected_output_bytes  = expected_bytes.size();
    conv_seq.cluster_mode           = 2'd0;
    conv_seq.input_base             = 32'h0000_0100;
    conv_seq.weight_base            = 32'h0000_1000;
    conv_seq.output_base            = 32'h0001_0000;

    conv_seq.start(env.axil_ag.seqr);

    // Check output
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);
      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", $sformatf("PASS: %0d bytes matched", expected_bytes.size()), UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("FAIL: %0d mismatches, first at byte %0d",
          env.scoreboard.mismatch_count, env.scoreboard.first_mismatch_offset))
      end
    end else begin
      `uvm_error("TEST", $sformatf("Conv failed: done=%0d error=%0d",
        conv_seq.done, conv_seq.error))
    end

    // Perf counters
    conv_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO,      cycle_lo);
    conv_seq.axil_read32(`NPU_REG_PERF_ARRAY_ACTIVE,  arr_active);
    conv_seq.axil_read32(`NPU_REG_PERF_READ_BEATS,    r_beats);
    conv_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS,   w_beats);
    conv_seq.axil_read32(`NPU_REG_PERF_BUS_ACTIVE,    bus_active);

    effective_tops = (cycle_lo > 0)
      ? (4096.0 * 2.0 * $itor(arr_active) * 200.0e6) / ($itor(cycle_lo) * 1.0e12) : 0.0;
    bus_util = (cycle_lo > 0) ? (bus_active * 100.0 / cycle_lo) : 0.0;

    `uvm_info("TEST", $sformatf("cycles=%0d arr_act=%0d(%.0f%%) read=%0d write=%0d bus=%0d(%.0f%%) TOPS=%.4f",
      cycle_lo, arr_active, (cycle_lo>0)?(arr_active*100.0/cycle_lo):0.0,
      r_beats, w_beats, bus_active, bus_util, effective_tops), UVM_NONE)

    if (arr_active == 0) `uvm_error("TEST", "arr_active=0")
    if (cycle_lo == 0)  `uvm_error("TEST", "cycle=0")

    phase.drop_objection(this);
  endtask

endclass
