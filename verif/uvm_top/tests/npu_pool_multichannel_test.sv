//=============================================================================
// npu_pool_multichannel_test.sv — 4-Channel Pool Test
//
// Verifies 2x2 MaxPool (stride 2) on a 4x4 INT32 tensor with 4 channels.
//
// 通道 0: {1,5,3,8, 2,6,4,7, 3,1,9,2, 4,8,5,3}
// 通道 1: all 10s
// 通道 2: {8,1,3,5, 7,2,4,6, 2,9,1,3, 5,3,8,4}
// 通道 3: all 5s
//
// NHWC layout: input[spatial_idx * C + ch] = value
//
// Expected 2x2 output per channel:
//   ch0: {6, 8, 8, 9}
//   ch1: {10,10,10,10}
//   ch2: {8, 6, 9, 8}
//   ch3: {5, 5, 5, 5}
//
// Uses env.golden.compute_pool() DPI-C ref model for golden comparison.
// cluster_mode=2'd2
//=============================================================================

`timescale 1ns / 1ps

class npu_pool_multichannel_test extends soc_base_test;

  `uvm_component_utils(npu_pool_multichannel_test)

  function new(string name = "npu_pool_multichannel_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_pool_task_seq pool_seq;
    int unsigned input_ints[64];
    byte unsigned expected_bytes[];
    int i;

    phase.raise_objection(this);
    #200;

    // 构建测试数据: 4x4x4 NHWC INT32 tensor
    // 通道 0 per position: {1,5,3,8, 2,6,4,7, 3,1,9,2, 4,8,5,3}
    // 通道 1 per position: all 10
    // 通道 2 per position: {8,1,3,5, 7,2,4,6, 2,9,1,3, 5,3,8,4}
    // 通道 3 per position: all 5

    // Initialize all to zero first
    for (i = 0; i < 64; i++)
      input_ints[i] = 0;

    // 通道 0 data
    begin
      int unsigned ch0_data[16] = '{1,5,3,8, 2,6,4,7, 3,1,9,2, 4,8,5,3};
      for (i = 0; i < 16; i++)
        input_ints[i * 4 + 0] = ch0_data[i];
    end

    // 通道 1: all 10s
    begin
      for (i = 0; i < 16; i++)
        input_ints[i * 4 + 1] = 10;
    end

    // 通道 2 data
    begin
      int unsigned ch2_data[16] = '{8,1,3,5, 7,2,4,6, 2,9,1,3, 5,3,8,4};
      for (i = 0; i < 16; i++)
        input_ints[i * 4 + 2] = ch2_data[i];
    end

    // 通道 3: all 5s
    begin
      for (i = 0; i < 16; i++)
        input_ints[i * 4 + 3] = 5;
    end

    // --- Use DPI-C reference model to compute golden output ---
    `uvm_info("TEST", "Computing golden pool reference via DPI-C model (4 channels)...", UVM_NONE)
    env.golden.compute_pool(input_ints, 4, 4, 4);
    expected_bytes = env.golden.output_bytes;

    `uvm_info("TEST", $sformatf("Golden pool computed: %0d output bytes (2x2x4 = 16 INT32)",
      expected_bytes.size()), UVM_NONE)
    `uvm_info("TEST", $sformatf("Channel 0: [%0d,%0d,%0d,%0d]",
      env.golden.output_int32[0],
      env.golden.output_int32[1],
      env.golden.output_int32[2],
      env.golden.output_int32[3]), UVM_NONE)
    `uvm_info("TEST", $sformatf("Channel 1: [%0d,%0d,%0d,%0d]",
      env.golden.output_int32[4],
      env.golden.output_int32[5],
      env.golden.output_int32[6],
      env.golden.output_int32[7]), UVM_NONE)
    `uvm_info("TEST", $sformatf("Channel 2: [%0d,%0d,%0d,%0d]",
      env.golden.output_int32[8],
      env.golden.output_int32[9],
      env.golden.output_int32[10],
      env.golden.output_int32[11]), UVM_NONE)
    `uvm_info("TEST", $sformatf("Channel 3: [%0d,%0d,%0d,%0d]",
      env.golden.output_int32[12],
      env.golden.output_int32[13],
      env.golden.output_int32[14],
      env.golden.output_int32[15]), UVM_NONE)

    // 配置 and run NPU pool task
    pool_seq = npu_pool_task_seq::type_id::create("pool_seq");
    pool_seq.input_ints   = input_ints;
    pool_seq.input_h      = 16'd4;
    pool_seq.input_w      = 16'd4;
    pool_seq.channels     = 16'd4;
    pool_seq.expected_output_bytes = expected_bytes.size();
    pool_seq.cluster_mode = 2'd2;   // full cluster (6 clusters)
    pool_seq.input_base   = 32'h0000_0100;
    pool_seq.output_base  = 32'h0000_0300;

    `uvm_info("TEST", "=== npu_pool_multichannel_test: 2x2 MaxPool 4ch ===", UVM_NONE)
    pool_seq.start(env.axil_ag.seqr);

    // 与黄金参考比对 DUT 输出 model
    if (pool_seq.done && !pool_seq.error) begin
      env.scoreboard.compare_output_bytes(pool_seq.actual_output, expected_bytes,
                                          pool_seq.output_base);

      if (env.scoreboard.mismatch_count == 0) begin
        `uvm_info("TEST", "=== npu_pool_multichannel_test PASSED (golden model verified) ===", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Output mismatch vs golden: %0d bytes differ",
          env.scoreboard.mismatch_count))
      end
    end else begin
      `uvm_error("TEST", "Pool task did not complete successfully")
    end

    phase.drop_objection(this);
  endtask

endclass
