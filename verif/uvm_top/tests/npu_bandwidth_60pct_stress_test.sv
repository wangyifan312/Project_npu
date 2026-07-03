//=============================================================================
// npu_bandwidth_60pct_stress_test.sv — NPU 60% Bus Utilization Stress Test
//
// Uses the new VECTOR_RELU_256B task (task_type=6) — a 256-bit streaming
// vector INT8 ReLU that bypasses the 32-bit acc_buffer/store_pack slow path.
//
// 数据 flow:
//   DMA read 256-bit beat → act_buffer
//   act_buffer read → 32-lane INT8 ReLU → write_beat_fifo → DMA write
//
// Primary metric: system_task_bus_active_ratio
//   = (read_data_cycles + write_data_cycles) / task_cycles * 100
//
//   read_data_cycles  = PERF_READ_BEATS       (RVALID && RREADY)
//   write_data_cycles = PERF_WRITE_DATA_CYC   (WVALID && WREADY)
//   task_cycles       = PERF_CYCLE_LO         (NPU busy window)
//
// Competition target: system_task_bus_active_ratio >= 60%
//=============================================================================

`timescale 1ns / 1ps

class npu_bandwidth_60pct_stress_test extends soc_base_test;

  `uvm_component_utils(npu_bandwidth_60pct_stress_test)

  // 512B sanity — single burst, fully verified
  localparam int INPUT_BYTES = 16384;  // 16KB
  localparam int EXPECTED_BEATS = INPUT_BYTES / 32;

  // 测试bench sequencer handle
  soc_base_seq m_seq;

  function new(string name = "npu_bandwidth_60pct_stress_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  //---------------------------------------------------------------------------
  // Main run phase
  //---------------------------------------------------------------------------
  task run_phase(uvm_phase phase);
    bit [31:0] rdata;
    bit [31:0] task_cycles;
    bit [31:0] read_data_cycles;
    bit [31:0] write_data_cycles;
    bit [31:0] bus_active_cycles;
    bit [31:0] comp_cyc, load_cyc, store_cyc, coll_cyc;
    bit [31:0] r_valid_bytes, w_valid_bytes;
    bit [31:0] read_beats, write_beats;
    real       system_task_bus_active_ratio;
    real       read_task_bw, write_task_bw;
    bit        output_compare_passed;
    bit        target_met;
    bit        functional_pass;
    bit        bandwidth_pass_bit;
    bit        pass_target;

    byte unsigned input_bytes_arr[];
    byte unsigned golden_bytes_arr[];
    byte unsigned output_bytes_arr[];
    int i, j;
    int expected_read_beats;
    int expected_write_beats;
    int output_bytes;

    phase.raise_objection(this);

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    #200;

    // =====================================================================
    // Generate deterministic INT8 test pattern with negative values
    //
    // Pattern: input[i] = (i * 13 + 7) & 0xFF
    // This produces signed values in [-128, 127], ensuring ~50% negative.
    //
    // 黄金参考: golden[i] = input[i] < 0 ? 0 : input[i]
    // =====================================================================
    input_bytes_arr  = new[INPUT_BYTES];
    golden_bytes_arr = new[INPUT_BYTES];
    output_bytes_arr = new[INPUT_BYTES];
    output_bytes = INPUT_BYTES;
    expected_read_beats  = INPUT_BYTES / 32;
    expected_write_beats = (INPUT_BYTES + 31) / 32;

    for (i = 0; i < INPUT_BYTES; i++) begin
      // Deterministic pattern with negative values
      bit [7:0] val = (i * 13 + 7) & 8'hFF;
      input_bytes_arr[i] = val;
      // INT8 ReLU: if signed bit[7]=1 → output 0, else pass through
      golden_bytes_arr[i] = val[7] ? 8'h00 : val;
    end

    `uvm_info("SYS_BUS_60", "", UVM_NONE)
    `uvm_info("SYS_BUS_60", "############################################################################", UVM_NONE)
    `uvm_info("SYS_BUS_60", "#  NPU BANDWIDTH 60% STRESS TEST — Vector INT8 ReLU 256b", UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("#  Input:  %0d bytes (expected read beats: %0d)", INPUT_BYTES, expected_read_beats), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("#  Output: %0d bytes (expected write beats: %0d)", output_bytes, expected_write_beats), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("#  Negative values in input: ~50%% deterministic pattern"), UVM_NONE)
    `uvm_info("SYS_BUS_60", "############################################################################", UVM_NONE)

    // =====================================================================
    // 写 input data to shared RAM via AXI-Lite
    //
    // 内存 layout (shared RAM 1 MB, base 0x0000_0000):
    //   input_base  = 0x0000_0100
    //   output_base = 0x0001_0000 (far enough past input: 64KB apart)
    // =====================================================================
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] Writing input data to shared RAM...", UVM_NONE)

    for (i = 0; i < INPUT_BYTES; i += 4) begin
      bit [31:0] word_val;
      word_val = {input_bytes_arr[i+3], input_bytes_arr[i+2],
                  input_bytes_arr[i+1], input_bytes_arr[i]};
      m_seq.axil_write32(32'h0000_0100 + i, word_val);
    end

    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60] Wrote %0d bytes input to 0x0000_0100", INPUT_BYTES), UVM_NONE)

    // =====================================================================
    // 配置 NPU for VECTOR_RELU_256B task (task_type=6)
    //
    // 寄存器 setup:
    //   TASK_TYPE    = 6
    //   INPUT_ADDR   = 0x0000_0100
    //   OUTPUT_ADDR  = 0x0001_0000
    //   INPUT_BYTES  = 16384
    //   OUTPUT_BYTES = 16384
    //   DIM_IN       = {16'd1, 16'd1}  (H=1, W=1 → single "row")
    //   DIM_OUT      = {16'd1, 16'd1}  (C_IN=1, C_OUT=1 → single channel)
    // =====================================================================
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] Configuring NPU for Vector INT8 ReLU 256b...", UVM_NONE)

    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd6);          // task_type = 6 (VECTOR_RELU)
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);   // input_addr
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'd0);           // weight_addr (unused)
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0001_0000);   // output_addr
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  INPUT_BYTES);     // input_bytes
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd0);           // weight_bytes (unused)
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, INPUT_BYTES);     // output_bytes = input_bytes
    m_seq.axil_write32(`NPU_REG_DIM_IN,       32'h0001_0001);   // H=1, W=1
    m_seq.axil_write32(`NPU_REG_DIM_OUT,      32'h0001_0001);   // C_IN=1, C_OUT=1
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);           // no postproc

    // =====================================================================
    // DEBUG: Read back NPU registers to verify configuration
    // =====================================================================
    m_seq.axil_read32(`NPU_REG_INPUT_BYTES, rdata);
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60] DEBUG: readback input_bytes=%0d", rdata), UVM_NONE)
    m_seq.axil_read32(`NPU_REG_OUTPUT_BYTES, rdata);
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60] DEBUG: readback output_bytes=%0d", rdata), UVM_NONE)
    m_seq.axil_read32(`NPU_REG_TASK_TYPE, rdata);
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60] DEBUG: readback task_type=%0d", rdata), UVM_NONE)

    // =====================================================================
    // 启动 NPU task
    //   CTRL[0]=1 starts the task; back-to-back fix auto-clears done/error
    // =====================================================================
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] Starting NPU task (CTRL=0x01)...", UVM_NONE)
    m_seq.axil_write32(`NPU_REG_CTRL, 32'h1);

    // =====================================================================
    // 轮询等待完成 (done=bit[2]=1, error=bit[3]=1)
    // =====================================================================
    fork
      begin
        int timeout_cnt = 0;
        bit done_flag = 1'b0;
        bit error_flag = 1'b0;
        while (!done_flag && !error_flag && timeout_cnt < 500000) begin
          m_seq.axil_read32(`NPU_REG_CTRL, rdata);
          done_flag  = rdata[2];
          error_flag = rdata[3];
          if (!done_flag && !error_flag) begin
            #100;
            timeout_cnt++;
          end
        end
        if (timeout_cnt >= 500000) begin
          `uvm_error("SYS_BUS_60", "[SYS_BUS_60] Task TIMEOUT: done/error not asserted within 500K polls")
        end
      end
    join

    // =====================================================================
    // 读 performance counters
    // =====================================================================
    m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO,      task_cycles);
    m_seq.axil_read32(`NPU_REG_PERF_READ_BEATS,    read_data_cycles);
    m_seq.axil_read32(`NPU_REG_PERF_WRITE_DATA_CYC, write_data_cycles);
    // Enhanced counters (new registers 0xE8-0xFC)
    m_seq.axil_read32(`NPU_REG_PERF_COMPUTE_CYCLES,    comp_cyc);
    m_seq.axil_read32(`NPU_REG_PERF_LOAD_CYCLES,       load_cyc);
    m_seq.axil_read32(`NPU_REG_PERF_STORE_CYCLES,      store_cyc);
    m_seq.axil_read32(`NPU_REG_PERF_COLLECT_CYCLES,    coll_cyc);
    m_seq.axil_read32(`NPU_REG_PERF_READ_VALID_BYTES,  r_valid_bytes);
    m_seq.axil_read32(`NPU_REG_PERF_WRITE_VALID_BYTES, w_valid_bytes);
    m_seq.axil_read32(`NPU_REG_PERF_READ_BEATS,    read_beats);
    m_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS,   write_beats);

    bus_active_cycles = read_data_cycles + write_data_cycles;

    if (task_cycles > 0) begin
      system_task_bus_active_ratio = (bus_active_cycles * 100.0) / task_cycles;
    end else begin
      system_task_bus_active_ratio = 0.0;
    end

    // =====================================================================
    // 读取输出 from shared RAM
    // =====================================================================
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] Reading output data from shared RAM...", UVM_NONE)

    for (i = 0; i < output_bytes; i += 4) begin
      m_seq.axil_read32(32'h0001_0000 + i, rdata);
      for (j = 0; j < 4 && (i + j < output_bytes); j++) begin
        output_bytes_arr[i + j] = rdata[8*j +: 8];
      end
    end

    // =====================================================================
    // 比对输出 vs golden
    // =====================================================================
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] Comparing output vs golden...", UVM_NONE)

    output_compare_passed = 1'b1;
    for (i = 0; i < output_bytes; i++) begin
      if (output_bytes_arr[i] != golden_bytes_arr[i]) begin
        `uvm_error("SYS_BUS_60", $sformatf("[SYS_BUS_60] MISMATCH at byte %0d: RTL=%0d golden=%0d (input=%0d)",
          i, output_bytes_arr[i], golden_bytes_arr[i], input_bytes_arr[i]))
        output_compare_passed = 1'b0;
        break;
      end
    end

    if (output_compare_passed) begin
      `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60] Output compare PASS: %0d bytes matched", output_bytes), UVM_NONE)
    end

    // =====================================================================
    // P1-2: strict three-tier verdict — functional, bandwidth, PASS_TARGET
    //   functional_pass requires: output_compare + read_beats exact + write_beats exact
    //   bandwidth_pass requires: ratio >= 60%
    //   PASS_TARGET  requires: functional_pass AND bandwidth_pass
    // =====================================================================
    `uvm_info("SYS_BUS_60", "", UVM_NONE)
    `uvm_info("SYS_BUS_60", "============================================================", UVM_NONE)
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] NPU Bandwidth 60% Stress Test — Results", UVM_NONE)
    `uvm_info("SYS_BUS_60", "============================================================", UVM_NONE)
    `uvm_info("SYS_BUS_60", "", UVM_NONE)
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] --- Task Configuration ---", UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   task_type           = 6 (Vector INT8 ReLU 256b)"), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   workload            = vector_int8_relu_256b"), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   input_bytes         = %0d", INPUT_BYTES), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   output_bytes        = %0d", output_bytes), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   expected_read_beats  = %0d", expected_read_beats), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   expected_write_beats = %0d", expected_write_beats), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   datapath            = DMA-read → act_buffer → 32-lane ReLU → write_beat_fifo → DMA-write"), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   slow_path_bypassed  = 32-bit acc_buffer + store_pack"), UVM_NONE)
    `uvm_info("SYS_BUS_60", "", UVM_NONE)
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] --- Performance Counters ---", UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   task_cycles (0x30)       = %0d", task_cycles), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   actual_read_beats (0x38)  = %0d  (RVALID && RREADY)", read_data_cycles), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   actual_write_beats (0xD0) = %0d  (WVALID && WREADY)", write_data_cycles), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   bus_active_cycles         = %0d  (read + write)", bus_active_cycles), UVM_NONE)
    `uvm_info("SYS_BUS_60", "", UVM_NONE)
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] --- Primary Metric ---", UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   system_task_bus_active_ratio = %0.2f%%", system_task_bus_active_ratio), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   Formula: (read_data_cycles + write_data_cycles) / task_cycles * 100"), UVM_NONE)
    `uvm_info("SYS_BUS_60", "", UVM_NONE)
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] --- Burst-Level Bandwidth Metrics ---", UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   read_beats (0x38)        = %0d", read_beats), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   write_beats (0x3C)       = %0d", write_beats), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   r_valid_bytes (0xF8)      = %0d", r_valid_bytes), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   w_valid_bytes (0xFC)      = %0d", w_valid_bytes), UVM_NONE)
    `uvm_info("SYS_BUS_60", "", UVM_NONE)
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] --- Task-Level Bandwidth (engineering reference) ---", UVM_NONE)
    read_task_bw  = (task_cycles>0) ? ($itor(r_valid_bytes)*100.0/($itor(task_cycles)*32.0)) : 0.0;
    write_task_bw = (task_cycles>0) ? ($itor(w_valid_bytes)*100.0/($itor(task_cycles)*32.0)) : 0.0;
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   read_task_bw_util         = %.2f%%", read_task_bw), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   write_task_bw_util        = %.2f%%", write_task_bw), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   total_task_bw_util        = %.2f%%", read_task_bw+write_task_bw), UVM_NONE)
    `uvm_info("SYS_BUS_60", "", UVM_NONE)
    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] --- Enhanced Counter Verification (0xE8-0xFC) ---", UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   compute_cycles (0xE8)      = %0d %s", comp_cyc, (comp_cyc>0)?"OK":"ZERO(VecReLU has no compute phase)"), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   load_cycles (0xEC)         = %0d %s", load_cyc, (load_cyc>0)?"OK":"ZERO(verify)"), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   store_cycles (0xF0)        = %0d %s", store_cyc, (store_cyc>0)?"OK":"ZERO(VecReLU streaming)"), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   collect_cycles (0xF4)      = %0d %s", coll_cyc, (coll_cyc>0)?"OK":"ZERO(VecReLU has no collect)"), UVM_NONE)
    `uvm_info("SYS_BUS_60", "", UVM_NONE)

    // --- P1-2: Three-tier verdict ---
    functional_pass = output_compare_passed &&
                      (read_data_cycles == expected_read_beats) &&
                      (write_data_cycles == expected_write_beats);
    bandwidth_pass_bit = (system_task_bus_active_ratio >= 60.0);
    pass_target     = functional_pass && bandwidth_pass_bit;

    `uvm_info("SYS_BUS_60", "[SYS_BUS_60] --- Verdict ---", UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   functional_pass = %0s  (output_compare=%0s read_beats=%0d/%0d write_beats=%0d/%0d)",
        functional_pass ? "YES" : "NO",
        output_compare_passed ? "PASS" : "FAIL",
        read_data_cycles, expected_read_beats,
        write_data_cycles, expected_write_beats), UVM_NONE)
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60]   bandwidth_pass  = %0s  (ratio=%.2f%% target>=60%%)",
        bandwidth_pass_bit ? "YES" : "NO", system_task_bus_active_ratio), UVM_NONE)

    if (!output_compare_passed) begin
        `uvm_error("SYS_BUS_60", "[SYS_BUS_60] FAIL: output_compare FAILED — data mismatch vs golden")
    end
    if (read_data_cycles != expected_read_beats) begin
        `uvm_error("SYS_BUS_60", $sformatf("[SYS_BUS_60] FAIL: read_beats %0d != expected %0d", read_data_cycles, expected_read_beats))
    end
    if (write_data_cycles != expected_write_beats) begin
        `uvm_error("SYS_BUS_60", $sformatf("[SYS_BUS_60] FAIL: write_beats %0d != expected %0d", write_data_cycles, expected_write_beats))
    end

    if (pass_target) begin
        `uvm_info("SYS_BUS_60", "[SYS_BUS_60] PASS_TARGET: functional + bandwidth both met", UVM_NONE)
    end else if (functional_pass && !bandwidth_pass_bit) begin
        `uvm_info("SYS_BUS_60", "[SYS_BUS_60] BELOW_TARGET: functional OK but bandwidth < 60%", UVM_NONE)
    end else begin
        `uvm_info("SYS_BUS_60", "[SYS_BUS_60] FAIL: functional correctness not met — bandwidth ratio invalid", UVM_NONE)
    end

    `uvm_info("SYS_BUS_60", "============================================================", UVM_NONE)

    // DEBUG: read final NPU status
    m_seq.axil_read32(`NPU_REG_CTRL, rdata);
    `uvm_info("SYS_BUS_60", $sformatf("[SYS_BUS_60] DEBUG: final CTRL=0x%08h (done=%0d error=%0d busy=%0d)", rdata, rdata[2], rdata[3], rdata[1]), UVM_NONE)

    phase.drop_objection(this);
  endtask

endclass
