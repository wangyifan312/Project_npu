//=============================================================================
// npu_requant_bandwidth_test.sv — Large Requant for Bus Bandwidth ≥60%
//
// Requant: read INT32 → requant → write INT8. Minimal compute, large I/O.
// With multi-block (data > acc_buffer), P3 overlaps STORE with next LOAD.
// Target: bus_active ≥ 60% of total cycles.
//=============================================================================

`timescale 1ns / 1ps

class npu_requant_bandwidth_test extends soc_base_test;

  `uvm_component_utils(npu_requant_bandwidth_test)

  function new(string name = "npu_requant_bandwidth_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_requant_task_seq rq_seq;
    int unsigned input_ints[];
    byte unsigned expected_bytes[];
    bit [31:0] cycle_lo, arr_active, r_beats, w_beats, bus_active;
    real       bus_util;
    int i, total_ints;

    phase.raise_objection(this);
    #200;

    // ── Large Requant: 65536 INT32 = 256KB input → many blocks ──
    total_ints = 65536;
    input_ints = new[total_ints];
    for (i = 0; i < total_ints; i++)
      input_ints[i] = i;  // deterministic pattern

    // Golden: pass-through (multiplier=1, shift=0, no relu)
    env.golden.compute_requant_i32(input_ints, 32'h0000_0001, 6'd0, 1'b0);
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("=== Requant BW: %0d INT32 → %0d INT8 bytes ===",
      total_ints, expected_bytes.size()), UVM_NONE)

    rq_seq = npu_requant_task_seq::type_id::create("rq_seq");
    rq_seq.input_ints             = input_ints;
    rq_seq.element_count          = total_ints;
    rq_seq.multiplier             = 32'h0000_0001;
    rq_seq.shift                  = 6'd0;
    rq_seq.expected_output_bytes  = expected_bytes.size();
    rq_seq.input_base             = 32'h0000_0100;
    rq_seq.output_base            = 32'h0008_0000;

    rq_seq.start(env.axil_ag.seqr);

    if (rq_seq.done && !rq_seq.error) begin
      env.scoreboard.compare_output_bytes(rq_seq.actual_output, expected_bytes,
                                          rq_seq.output_base);
      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", $sformatf("PASS: %0d bytes matched", expected_bytes.size()), UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("FAIL: %0d mismatches, first at byte %0d",
          env.scoreboard.mismatch_count, env.scoreboard.first_mismatch_offset))
      end
    end else begin
      `uvm_error("TEST", $sformatf("Requant failed: done=%0d error=%0d",
        rq_seq.done, rq_seq.error))
    end

    rq_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO,      cycle_lo);
    rq_seq.axil_read32(`NPU_REG_PERF_ARRAY_ACTIVE,  arr_active);
    rq_seq.axil_read32(`NPU_REG_PERF_READ_BEATS,    r_beats);
    rq_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS,   w_beats);
    rq_seq.axil_read32(`NPU_REG_PERF_BUS_ACTIVE,    bus_active);

    bus_util = (cycle_lo > 0) ? (bus_active * 100.0 / cycle_lo) : 0.0;

    `uvm_info("TEST", $sformatf("cycles=%0d arr_act=%0d read=%0d write=%0d bus=%0d(%.1f%%) %s",
      cycle_lo, arr_active, r_beats, w_beats, bus_active, bus_util,
      (bus_util >= 60.0) ? ">=60% PASS" : "<60%"), UVM_NONE)

    if (bus_util < 60.0) begin
      `uvm_error("TEST", $sformatf("Bus utilization %.1f%% < 60%% target", bus_util))
    end

    phase.drop_objection(this);
  endtask

endclass
