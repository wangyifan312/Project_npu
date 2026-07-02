//=============================================================================
// npu_gemm_kchunk_stress_test.sv — Phase U5-a Task A: K>64 K-chunk accumulation
//
// Covers K=65,127,128,129,192,255 with M=1,4,8 and N=1,8,63,64,65.
// All-1 data pattern → golden: C[m][n] = K (signed INT8 multiply, INT32 sum).
//
// Key checks:
//   1. partial sum preserved across K-chunks
//   2. last K-chunk correct
//   3. result_tile_bank not spuriously cleared
//   4. signed INT8 accumulation matches all-1 golden
//   5. guard bands not corrupted
//=============================================================================
`timescale 1ns / 1ps

class npu_gemm_kchunk_stress_test extends soc_base_test;
  `uvm_component_utils(npu_gemm_kchunk_stress_test)
  function new(string name="npu_gemm_kchunk_stress_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  //----------------------------------------------------------------------------
  // compute_row_stride: row stride in bytes, 32B-aligned for INT32 output
  //----------------------------------------------------------------------------
  function int compute_row_stride(int N);
    return ((N * 4 + 31) / 32) * 32;
  endfunction

  //----------------------------------------------------------------------------
  // run_kchunk_case: run a single GEMM K-chunk test case
  //----------------------------------------------------------------------------
  task run_kchunk_case(int M_v, int K_v, int N_v, string label);
    soc_base_seq m_seq;
    bit [31:0] rdata, ctrl_val, cycle_lo, cycle_hi;
    bit [31:0] read_beats, write_beats, write_data_cyc, bus_active_cyc;
    bit [31:0] array_active_cyc, compute_cyc, store_cyc;
    int i, j, r, c, errs, row_stride, guard_pre, guard_post;
    int exp_val;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    // ------ preload A (input) at 0x0000_0100: all-1 INT8 ------
    for (i = 0; i < M_v * K_v; i = i + 4)
      m_seq.axil_write32(32'h0000_0100 + i, 32'h01010101);

    // ------ preload B (weight) at 0x0001_0000: all-1 INT8 ------
    for (i = 0; i < K_v * N_v; i = i + 4)
      m_seq.axil_write32(32'h0001_0000 + i, 32'h01010101);

    // ------ pre-guard word ------
    m_seq.axil_write32(32'h0001_FFE0, 32'hCAFE_BABE);

    row_stride = compute_row_stride(N_v);

    // ------ clear output region + post-guard ------
    for (i = 0; i < M_v * row_stride + 64; i = i + 4)
      m_seq.axil_write32(32'h0002_0000 + i, 32'hDEADBEEF);
    m_seq.axil_write32(32'h0002_0000 + M_v * row_stride, 32'hFEED_F00D);

    // ------ program NPU registers ------
    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);        // TASK_GEMM
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v * K_v);
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v * N_v);
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v * N_v * 4);
    m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
    m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
    m_seq.axil_write32(`NPU_REG_CONV_CFG,     32'h20);       // streaming
    m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

    // ------ start and poll ------
    m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
    repeat (500000) begin
      m_seq.axil_read32(`NPU_REG_CTRL, ctrl_val);
      if (ctrl_val[2] || ctrl_val[3]) break;
      #100;
    end

    // ------ read perf counters ------
    m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO,      cycle_lo);
    m_seq.axil_read32(`NPU_REG_PERF_CYCLE_HI,      cycle_hi);
    m_seq.axil_read32(`NPU_REG_PERF_READ_BEATS,    read_beats);
    m_seq.axil_read32(`NPU_REG_PERF_WRITE_BEATS,   write_beats);
    m_seq.axil_read32(`NPU_REG_PERF_WRITE_DATA_CYC,write_data_cyc);
    m_seq.axil_read32(`NPU_REG_PERF_BUS_ACTIVE,    bus_active_cyc);
    m_seq.axil_read32(`NPU_REG_PERF_ARRAY_ACTIVE,  array_active_cyc);
    m_seq.axil_read32(`NPU_REG_PERF_COMPUTE_CYCLES,compute_cyc);
    m_seq.axil_read32(`NPU_REG_PERF_STORE_CYCLES,  store_cyc);

    // ------ check for error ------
    if (ctrl_val[3]) begin
      m_seq.axil_read32(`NPU_REG_STATUS, rdata);
      `uvm_error("KCHUNK", $sformatf("%s ERROR code=0x%02x M=%0d K=%0d N=%0d",
        label, rdata[7:0], M_v, K_v, N_v))
      return;
    end

    // ------ verify outputs ------
    exp_val = K_v;   // all-1: each output element = sum of K products of 1*1 = K
    errs = 0;
    for (r = 0; r < M_v; r++) begin
      for (c = 0; c < N_v; c++) begin
        m_seq.axil_read32(32'h0002_0000 + r * row_stride + c * 4, rdata);
        if ($signed(rdata) != exp_val) begin
          if (errs < 8)
            `uvm_error("KCHUNK", $sformatf("%s C[%0d][%0d]=%0d expected %0d",
              label, r, c, $signed(rdata), exp_val))
          errs++;
        end
      end
    end

    // ------ verify guard bands ------
    m_seq.axil_read32(32'h0001_FFE0, rdata);
    guard_pre = rdata;
    if (guard_pre != 32'hCAFE_BABE)
      `uvm_error("KCHUNK", $sformatf("%s pre-guard corrupted: 0x%08x", label, guard_pre))

    m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
    guard_post = rdata;
    if (guard_post != 32'hFEED_F00D)
      `uvm_error("KCHUNK", $sformatf("%s post-guard corrupted: 0x%08x", label, guard_post))

    // ------ summary ------
    if (errs == 0 && guard_pre == 32'hCAFE_BABE && guard_post == 32'hFEED_F00D)
      `uvm_info("KCHUNK", $sformatf(
        "%s: M=%0d K=%0d N=%0d cycles=%0d arr_act=%0d comp=%0d store=%0d bus_act=%0d rd_beats=%0d wr_beats=%0d wr_data_cyc=%0d PASS",
        label, M_v, K_v, N_v, cycle_lo, array_active_cyc, compute_cyc, store_cyc,
        bus_active_cyc, read_beats, write_beats, write_data_cyc), UVM_NONE)
    else
      `uvm_error("KCHUNK", $sformatf("%s: M=%0d K=%0d N=%0d FAIL errs=%0d",
        label, M_v, K_v, N_v, errs))
  endtask

  //----------------------------------------------------------------------------
  // run_phase
  //----------------------------------------------------------------------------
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    #200;

    `uvm_info("KCHUNK", "=== GEMM K>64 K-CHUNK ACCUMULATION STRESS (Phase U5-a) ===", UVM_NONE)

    // ---- K=65 (first K-chunk boundary) ----
    run_kchunk_case(1, 65,  1, "KC_M1K65N1");
    run_kchunk_case(1, 65, 64, "KC_M1K65N64");
    run_kchunk_case(1, 65, 65, "KC_M1K65N65");
    run_kchunk_case(4, 65,  8, "KC_M4K65N8");
    run_kchunk_case(8, 65,  8, "KC_M8K65N8");
    run_kchunk_case(8, 65, 64, "KC_M8K65N64");

    // ---- K=127 (odd, near two chunks) ----
    run_kchunk_case(1, 127,  1, "KC_M1K127N1");
    run_kchunk_case(1, 127, 63, "KC_M1K127N63");
    run_kchunk_case(1, 127, 64, "KC_M1K127N64");
    run_kchunk_case(4, 127,  8, "KC_M4K127N8");
    run_kchunk_case(8, 127,  8, "KC_M8K127N8");
    run_kchunk_case(8, 127, 65, "KC_M8K127N65");

    // ---- K=128 (exact two chunks) ----
    run_kchunk_case(1, 128,  1, "KC_M1K128N1");
    run_kchunk_case(1, 128, 63, "KC_M1K128N63");
    run_kchunk_case(1, 128, 64, "KC_M1K128N64");
    run_kchunk_case(1, 128, 65, "KC_M1K128N65");
    run_kchunk_case(4, 128,  8, "KC_M4K128N8");
    run_kchunk_case(8, 128,  8, "KC_M8K128N8");
    run_kchunk_case(8, 128, 64, "KC_M8K128N64");

    // ---- K=129 (just past two chunks) ----
    run_kchunk_case(1, 129,  1, "KC_M1K129N1");
    run_kchunk_case(1, 129, 63, "KC_M1K129N63");
    run_kchunk_case(1, 129, 64, "KC_M1K129N64");
    run_kchunk_case(1, 129, 65, "KC_M1K129N65");
    run_kchunk_case(4, 129,  8, "KC_M4K129N8");
    run_kchunk_case(8, 129,  8, "KC_M8K129N8");
    run_kchunk_case(8, 129, 64, "KC_M8K129N64");

    // ---- K=192 (three chunks) ----
    run_kchunk_case(1, 192,  1, "KC_M1K192N1");
    run_kchunk_case(1, 192, 64, "KC_M1K192N64");
    run_kchunk_case(1, 192, 65, "KC_M1K192N65");
    run_kchunk_case(4, 192,  8, "KC_M4K192N8");
    run_kchunk_case(8, 192,  8, "KC_M8K192N8");
    run_kchunk_case(8, 192, 64, "KC_M8K192N64");

    // ---- K=255 (odd, near four chunks) ----
    run_kchunk_case(1, 255,  1, "KC_M1K255N1");
    run_kchunk_case(1, 255, 64, "KC_M1K255N64");
    run_kchunk_case(1, 255, 65, "KC_M1K255N65");
    run_kchunk_case(4, 255,  8, "KC_M4K255N8");
    run_kchunk_case(8, 255,  8, "KC_M8K255N8");
    run_kchunk_case(8, 255, 64, "KC_M8K255N64");

    `uvm_info("KCHUNK", "=== K>64 K-CHUNK STRESS COMPLETE ===", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
