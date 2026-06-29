//=============================================================================
// npu_conv_bandwidth_test.sv — FC/Conv Bus Bandwidth ≥60% Target
//
// Strategy: 1×1 Conv, 128 output channels, 16×16 input → 16 blocks.
// Each block: COMPUTE ≈ 129 cycles, STORE ≈ 512 cycles.
// With P3 pipeline overlap: bus_util ≥ 90% during steady state.
//=============================================================================

`timescale 1ns / 1ps

class npu_conv_bandwidth_test extends soc_base_test;

  `uvm_component_utils(npu_conv_bandwidth_test)

  function new(string name = "npu_conv_bandwidth_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_conv_task_seq conv_seq;
    byte unsigned input_bytes[];
    byte unsigned weight_bytes[];
    byte unsigned expected_bytes[];
    bit [31:0] cycle_lo, arr_active, r_beats, w_beats, bus_active;
    real       bus_util, effective_tops;
    int i, j;
    int input_h, input_w, input_c, output_c, kernel;

    phase.raise_objection(this);
    #200;

    // ── 1×1 Conv: large output, small compute ──────────────────
    input_h   = 8;
    input_w   = 8;
    input_c   = 1;
    output_c  = 256;
    kernel    = 1;
    // rows_per_block=1024/(8*256)=0.5→1 → 8 blocks
    // STORE/block: 8*256*4=8192B=256beats(256b)→~512cycles
    // COMPUTE/block: 1row×8cols=8windows, 1×1→FEED(1)+DRAIN(68)=69/wdw
    //   total COMPUTE=8*69=552, plus c_in loop overhead. STORE≈COMPUTE.

    `uvm_info("TEST", $sformatf("=== Conv BW: %0d×%0d×%0d, 1×1→%0dch ===",
      input_h, input_w, input_c, output_c), UVM_NONE)

    input_bytes  = new[input_h * input_w * input_c];
    weight_bytes = new[kernel * kernel * input_c * output_c];

    for (i = 0; i < input_h * input_w * input_c; i++)
      input_bytes[i] = 8'((i % 64) + 1);
    for (i = 0; i < kernel * kernel * input_c * output_c; i++)
      weight_bytes[i] = 8'((i % 32) + 1);

    env.golden.compute_conv(input_bytes, weight_bytes,
      input_h, input_w, input_c, output_c, kernel, kernel, 1, 0);
    expected_bytes = env.golden.output_bytes;

    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data             = input_bytes;
    conv_seq.weight_data            = weight_bytes;
    conv_seq.input_h                = input_h;
    conv_seq.input_w                = input_w;
    conv_seq.input_c                = input_c;
    conv_seq.output_c               = output_c;
    conv_seq.conv_cfg               = 32'h0000_0001;  // kernel_sel=1→1×1
    conv_seq.expected_output_bytes  = expected_bytes.size();
    conv_seq.cluster_mode           = 2'd0;
    conv_seq.input_base             = 32'h0000_0100;
    conv_seq.weight_base            = 32'h0000_1000;
    conv_seq.output_base            = 32'h0001_0000;

    conv_seq.start(env.axil_ag.seqr);

    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);
      if (env.scoreboard.mismatch_count == 0)
        `uvm_info("TEST", $sformatf("PASS: %0d bytes matched", expected_bytes.size()), UVM_NONE)
      else
        `uvm_error("TEST", $sformatf("FAIL: %0d mismatches", env.scoreboard.mismatch_count))
    end else
      `uvm_error("TEST", $sformatf("Conv failed: done=%0d error=%0d",
        conv_seq.done, conv_seq.error))

    conv_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO,      cycle_lo);
    conv_seq.axil_read32(`NPU_REG_PERF_ARRAY_ACTIVE,  arr_active);
    conv_seq.axil_read32(`NPU_REG_PERF_READ_BEATS,    r_beats);
    conv_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS,   w_beats);
    conv_seq.axil_read32(`NPU_REG_PERF_BUS_ACTIVE,    bus_active);

    bus_util = (cycle_lo > 0) ? (bus_active * 100.0 / cycle_lo) : 0.0;
    effective_tops = (cycle_lo > 0)
      ? (4096.0 * 2.0 * $itor(arr_active) * 200.0e6) / ($itor(cycle_lo) * 1.0e12) : 0.0;

    `uvm_info("TEST", $sformatf("cycles=%0d arr=%0d(%.0f%%) r=%0d w=%0d bus=%0d(%.1f%%) TOPS=%.4f %s",
      cycle_lo, arr_active, (cycle_lo>0)?(arr_active*100.0/cycle_lo):0.0,
      r_beats, w_beats, bus_active, bus_util, effective_tops,
      (bus_util >= 60.0) ? "BW>=60% PASS" : "BW<60%"), UVM_NONE)

    if (bus_util < 60.0)
      `uvm_error("TEST", $sformatf("Bus %.1f%% < 60%% target", bus_util))

    phase.drop_objection(this);
  endtask

endclass
