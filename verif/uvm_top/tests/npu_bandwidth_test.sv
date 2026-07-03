//=============================================================================
// npu_bandwidth_test.sv — DMA Bus Bandwidth Utilization Test
//
// Runs a small Conv task (16x16 input, 5x5 valid, Cin=1, Cout=1,
// 12x12 output = 576 bytes = 18 beats) to generate DMA read/write traffic,
// then verifies that AXI4 INCR burst utilization is >= 60% for both read and
// 写 directions.
//
// The DMA monitor (axi4_dma_monitor) tracks per-burst data_cycles vs
// txn_cycles and aggregates totals.  This test reads those aggregate
// 计数器s after the Conv task completes and asserts the thresholds.
//=============================================================================

`timescale 1ns / 1ps

class npu_bandwidth_test extends soc_base_test;

  `uvm_component_utils(npu_bandwidth_test)

  function new(string name = "npu_bandwidth_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    // --- VCS constraint: ALL class/local vars declared BEFORE first statement ---
    npu_conv_task_seq  conv_seq;
    byte unsigned       input_bytes[];
    byte unsigned       weight_bytes[];
    byte unsigned       expected_bytes[];
    real                read_util;
    real                write_util;
    int                 input_size;
    int                 weight_size;
    int                 i;
    int                 rd_data_cyc;
    int                 rd_total_cyc;
    int                 wr_data_cyc;
    int                 wr_total_cyc;
    int                 rd_txn;
    int                 wr_txn;
    bit                 mismatch_seen;

    phase.raise_objection(this);
    #200;

    //-----------------------------------------------------------------------
    // Build 16x16 Conv test data: 16x16 input, 3x3 valid, Cin=1, Cout=4
    // 输出: 14x14x4 = 784 INT32 = 3136 bytes = 98 beats (256-bit)
    // Random-but-known: ensures no all-zero/trivial traffic
    //-----------------------------------------------------------------------
    // 16x16 input, 3x3 valid, Cin=1, Cout=4 -> 14x14x4x4=3136 bytes = 98 beats
    input_size  = 16 * 16;           // 256 uint8 pixels (HWC layout, C=1)
    weight_size = 3 * 3 * 1 * 4;     // 36 INT8 weights (Cout=4 x Kh=3 x Kw=3)
    input_bytes  = new[input_size];
    weight_bytes = new[weight_size];

    for (i = 0; i < input_size; i++)
      input_bytes[i] = 8'((i * 7 + 13) & 8'hFF);
    for (i = 0; i < weight_size; i++)
      weight_bytes[i] = 8'd1;

    env.golden.compute_conv(input_bytes, weight_bytes,
                            16, 16, 1, 4, 3, 3, 1, 0);
    expected_bytes = env.golden.output_bytes;

    conv_seq = npu_conv_task_seq::type_id::create("conv_seq");
    conv_seq.input_data            = input_bytes;
    conv_seq.weight_data           = weight_bytes;
    conv_seq.input_h               = 16'd16;
    conv_seq.input_w               = 16'd16;
    conv_seq.input_c               = 16'd1;
    conv_seq.output_c              = 16'd4;
    conv_seq.expected_output_bytes = expected_bytes.size();
    conv_seq.expected_output       = expected_bytes;
    conv_seq.cluster_mode          = 2'd0;
    conv_seq.conv_cfg              = 32'h2;   // 3x3 valid (kernel_sel=2)
    conv_seq.requant_multiplier    = 32'd0;
    conv_seq.requant_shift         = 32'd0;
    conv_seq.input_base            = 32'h0000_0100;
    conv_seq.weight_base           = 32'h0000_0200;
    conv_seq.output_base           = 32'h0000_0300;

    `uvm_info("BANDWIDTH_TEST", "=== Starting NPU Conv task (16x16 3x3 valid Cin=1 Cout=4) ===", UVM_NONE)
    conv_seq.start(env.axil_ag.seqr);

    //-----------------------------------------------------------------------
    // Correctness check against golden model
    //-----------------------------------------------------------------------
    mismatch_seen = 1'b0;
    if (conv_seq.done && !conv_seq.error) begin
      env.scoreboard.compare_output_bytes(conv_seq.actual_output, expected_bytes,
                                          conv_seq.output_base);
      if (env.scoreboard.mismatch_count > 0) begin
        `uvm_error("BANDWIDTH_TEST", $sformatf(
          "Output mismatch vs golden: %0d bytes differ (first at byte %0d)",
          env.scoreboard.mismatch_count, env.scoreboard.first_mismatch_offset))
        mismatch_seen = 1'b1;
      end else begin
        `uvm_info("BANDWIDTH_TEST", $sformatf(
          "Output verify PASS: %0d bytes matched golden reference", expected_bytes.size()), UVM_NONE)
      end
    end else begin
      `uvm_error("BANDWIDTH_TEST", "Conv task did not complete successfully")
    end

    // Wait for all DMA bursts to settle (last write B-handshake may still be in flight)
    #20000;

    //-----------------------------------------------------------------------
    // Bandwidth Utilization Check
    //
    // The DMA monitor aggregates read/write data_cycles and total_cycles
    // across all bursts.  Utilization = data_cycles / total_cycles * 100%.
    //
    // 数据_cycles: clock cycles where RVALID&RREADY (read) or WVALID&WREADY
    //              (write) were both asserted during an active transaction.
    // total_cycles: clock cycles from AR/AW handshake to RLAST/BVALID for
    //               each burst, summed across all bursts.
    //
    // Threshold: >= 60% for both directions.  This is conservative for
    // INCR bursts to shared RAM at 200 MHz; well-designed systems typically
    // achieve >80% on long bursts.
    //-----------------------------------------------------------------------
    rd_data_cyc  = env.dma_mon.total_read_data_cycles;
    rd_total_cyc = env.dma_mon.total_read_cycles;
    wr_data_cyc  = env.dma_mon.total_write_data_cycles;
    wr_total_cyc = env.dma_mon.total_write_cycles;
    rd_txn       = env.dma_mon.read_txn_count;
    wr_txn       = env.dma_mon.write_txn_count;

    read_util  = (rd_total_cyc > 0) ?
                 (rd_data_cyc * 100.0 / rd_total_cyc) : 0.0;
    write_util = (wr_total_cyc > 0) ?
                 (wr_data_cyc * 100.0 / wr_total_cyc) : 0.0;

    //-----------------------------------------------------------------------
    // Bandwidth Report
    //-----------------------------------------------------------------------
    `uvm_info("BANDWIDTH_TEST", "========================================", UVM_NONE)
    `uvm_info("BANDWIDTH_TEST", "BUS BANDWIDTH UTILIZATION REPORT", UVM_NONE)
    `uvm_info("BANDWIDTH_TEST", "========================================", UVM_NONE)
    `uvm_info("BANDWIDTH_TEST", $sformatf(
      "Read  DMA: %0d data_cycles / %0d total_cycles = %.1f%%  (%0d bursts)",
      rd_data_cyc, rd_total_cyc, read_util, rd_txn), UVM_NONE)
    `uvm_info("BANDWIDTH_TEST", $sformatf(
      "Write DMA: %0d data_cycles / %0d total_cycles = %.1f%%  (%0d bursts)",
      wr_data_cyc, wr_total_cyc, write_util, wr_txn), UVM_NONE)
    `uvm_info("BANDWIDTH_TEST", "========================================", UVM_NONE)
    `uvm_info("BANDWIDTH_TEST", $sformatf(
      "Requant state: multiplier=%0d shift=%0d (0 = disabled/INT32 output)",
      conv_seq.requant_multiplier, conv_seq.requant_shift), UVM_NONE)
    `uvm_info("BANDWIDTH_TEST", $sformatf(
      "Conv config: kernel=3x3 stride=1 valid  |  output: 14x14x4 = 784 INT32 -> %0d bytes (%0d beats)",
      expected_bytes.size(), expected_bytes.size() / 32), UVM_NONE)

    //-----------------------------------------------------------------------
    // Assert bandwidth thresholds
    //-----------------------------------------------------------------------
    if (read_util >= 60.0) begin
      `uvm_info("BANDWIDTH_TEST", $sformatf(
        "PASS: Read  DMA utilization %.1f%% >= 60%% threshold", read_util), UVM_NONE)
    end else begin
      `uvm_error("BANDWIDTH_TEST", $sformatf(
        "FAIL: Read  DMA utilization %.1f%% < 60%% threshold", read_util))
    end

    if (write_util >= 60.0) begin
      `uvm_info("BANDWIDTH_TEST", $sformatf(
        "PASS: Write DMA utilization %.1f%% >= 60%% threshold", write_util), UVM_NONE)
    end else begin
      `uvm_error("BANDWIDTH_TEST", $sformatf(
        "FAIL: Write DMA utilization %.1f%% < 60%% threshold", write_util))
    end

    if ((read_util >= 60.0) && (write_util >= 60.0) && !mismatch_seen) begin
      `uvm_info("BANDWIDTH_TEST", "=== npu_bandwidth_test OVERALL PASS ===", UVM_NONE)
    end else begin
      `uvm_info("BANDWIDTH_TEST", "=== npu_bandwidth_test OVERALL FAIL ===", UVM_NONE)
    end

    phase.drop_objection(this);
  endtask

endclass
