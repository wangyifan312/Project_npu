//=============================================================================
// npu_gap_smoke_test.sv — GAP debug: verify preload, then run GAP
//=============================================================================

`timescale 1ns / 1ps

class npu_gap_smoke_test extends soc_base_test;

  `uvm_component_utils(npu_gap_smoke_test)

  function new(string name = "npu_gap_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_gap_task_seq gap_seq;
    soc_base_seq seq;
    byte unsigned input_bytes[64];
    byte unsigned expected_bytes[];
    bit [31:0] rd;
    int i;

    phase.raise_objection(this);
    #200;

    // 构建测试数据: all 100
    for (i = 0; i < 64; i++) begin
      input_bytes[i] = 8'd100;
    end

    // 预加载 directly and verify
    seq = soc_base_seq::type_id::create("seq");
    seq.start(env.axil_ag.seqr);

    // Manually write to shared RAM like the preload sequence would
    for (i = 0; i < 16; i++) begin
      seq.axil_write32(32'h0000_0100 + i*4, 32'h64646464);
    end

    // 读 back to verify
    seq.axil_read32(32'h0000_0100, rd);
    `uvm_info("TEST", $sformatf("Preload verify: addr=0x100 data=0x%08h (expect 0x64646464)", rd), UVM_NONE)
    seq.axil_read32(32'h0000_013C, rd);
    `uvm_info("TEST", $sformatf("Preload verify: addr=0x13C data=0x%08h (expect 0x64646464)", rd), UVM_NONE)

    // 黄金参考 via DPI-C — copy to local to avoid reference issues
    env.golden.compute_gap(input_bytes, 1, 1, 0);
    expected_bytes = new[env.golden.output_bytes.size()];
    for (i = 0; i < env.golden.output_bytes.size(); i++)
      expected_bytes[i] = env.golden.output_bytes[i];
    `uvm_info("TEST", $sformatf("Golden GAP expects: %0d", $signed(expected_bytes[0])), UVM_NONE)

    // Run GAP task
    gap_seq = npu_gap_task_seq::type_id::create("gap_seq");
    gap_seq.input_data   = input_bytes;
    gap_seq.channels     = 16'd1;
    gap_seq.multiplier   = 32'd1;
    gap_seq.shift        = 32'd0;
    gap_seq.cluster_mode = 2'd0;
    gap_seq.input_base   = 32'h0000_0100;
    gap_seq.output_base  = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_gap_smoke_test ===", UVM_NONE)
    gap_seq.start(env.axil_ag.seqr);

    if (gap_seq.done && !gap_seq.error) begin
      `uvm_info("TEST", $sformatf("DUT GAP output byte = %0d", $signed(gap_seq.actual_output[0])), UVM_NONE)
      env.scoreboard.compare_output_bytes(gap_seq.actual_output, expected_bytes,
                                          gap_seq.output_base);
      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_gap_smoke_test PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Output mismatch: %0d bytes differ", env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "GAP task did not complete successfully")
    end

    phase.drop_objection(this);
  endtask

endclass
