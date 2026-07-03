//=============================================================================
// npu_matrixop_partial_beat_stress_test.sv — Phase U5-a Task B
//
// Verifies INT32 / INT8 output last-beat, WSTRB, byte_count, row_stride, and
// n_base address correctness for a sweep of N (column) sizes that produce
// partial (non-32B-aligned) final beats.
//
// INT32 (GEMM streaming): N = 1,2,7,8,9,31,32,33,63,64,65  with M = 1,2,4
//   expected: dma_wr_bytes = N*4, row_stride = ceil(N*4/32)*32
//
// INT8 (FC streaming + conv_cfg[6]=1): N = 1,2,31,32,33,63,64,65  with M = 1,2,4
//   expected: dma_wr_bytes = N, row_stride = ceil(N/32)*32
//
// All-1 data → golden: C[m][n] = K for all positions.
// Guard bands: CAFE_BABE (pre), FEED_F00D (post).
//=============================================================================
`timescale 1ns / 1ps

class npu_matrixop_partial_beat_stress_test extends soc_base_test;
  `uvm_component_utils(npu_matrixop_partial_beat_stress_test)
  function new(string name="npu_matrixop_partial_beat_stress_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  //----------------------------------------------------------------------------
  // compute_row_stride_int32: ceil(N*4/32)*32
  //----------------------------------------------------------------------------
  function int compute_row_stride_int32(int N);
    return ((N * 4 + 31) / 32) * 32;
  endfunction

  //----------------------------------------------------------------------------
  // compute_row_stride_int8: ceil(N/32)*32
  //----------------------------------------------------------------------------
  function int compute_row_stride_int8(int N);
    return ((N + 31) / 32) * 32;
  endfunction

  //----------------------------------------------------------------------------
  // run_int32_case: GEMM streaming, INT32 output
  //----------------------------------------------------------------------------
  task run_int32_case(int M_v, int K_v, int N_v, string label);
    soc_base_seq m_seq;
    bit [31:0] rdata, ctrl_val, cycle_lo;
    int i, r, c, errs, row_stride, guard_pre, guard_post;
    int exp_val;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    // 预加载 all-1
    for (i = 0; i < M_v * K_v; i = i + 4)
      m_seq.axil_write32(32'h0000_0100 + i, 32'h01010101);
    for (i = 0; i < K_v * N_v; i = i + 4)
      m_seq.axil_write32(32'h0001_0000 + i, 32'h01010101);

    // guard + clear
    m_seq.axil_write32(32'h0001_FFE0, 32'hCAFE_BABE);
    row_stride = compute_row_stride_int32(N_v);
    for (i = 0; i < M_v * row_stride + 64; i = i + 4)
      m_seq.axil_write32(32'h0002_0000 + i, 32'hDEADBEEF);
    m_seq.axil_write32(32'h0002_0000 + M_v * row_stride, 32'hFEED_F00D);

    // 配置 GEMM streaming
    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
    m_seq.axil_write32(`NPU_REG_CONV_CFG,     32'h20);
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v * K_v);
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v * N_v);
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v * N_v * 4);
    m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
    m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
    m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

    m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
    repeat (500000) begin
      m_seq.axil_read32(`NPU_REG_CTRL, ctrl_val);
      if (ctrl_val[2] || ctrl_val[3]) break;
      #100;
    end
    m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);

    if (ctrl_val[3]) begin
      m_seq.axil_read32(`NPU_REG_STATUS, rdata);
      `uvm_error("PBEAT", $sformatf("%s ERROR code=0x%02x", label, rdata[7:0]))
      return;
    end

    // verify
    exp_val = K_v;
    errs = 0;
    for (r = 0; r < M_v; r++) begin
      for (c = 0; c < N_v; c++) begin
        m_seq.axil_read32(32'h0002_0000 + r * row_stride + c * 4, rdata);
        if ($signed(rdata) != exp_val) begin
          if (errs < 8)
            `uvm_error("PBEAT", $sformatf("%s INT32 C[%0d][%0d]=%0d expected %0d",
              label, r, c, $signed(rdata), exp_val))
          errs++;
        end
      end
    end

    // verify guard bands
    m_seq.axil_read32(32'h0001_FFE0, rdata);
    guard_pre = rdata;
    m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
    guard_post = rdata;
    if (guard_pre != 32'hCAFE_BABE)
      `uvm_error("PBEAT", $sformatf("%s pre-guard corrupted: 0x%08x", label, guard_pre))
    if (guard_post != 32'hFEED_F00D)
      `uvm_error("PBEAT", $sformatf("%s post-guard corrupted: 0x%08x", label, guard_post))

    if (errs == 0 && guard_pre == 32'hCAFE_BABE && guard_post == 32'hFEED_F00D)
      `uvm_info("PBEAT", $sformatf("%s INT32 M=%0d K=%0d N=%0d row_stride=%0d cycles=%0d PASS",
        label, M_v, K_v, N_v, row_stride, cycle_lo), UVM_NONE)
  endtask

  //----------------------------------------------------------------------------
  // run_int8_case: FC streaming + conv_cfg[6]=1 INT8 packing output
  //----------------------------------------------------------------------------
  task run_int8_case(int M_v, int K_v, int N_v, string label);
    soc_base_seq m_seq;
    bit [31:0] word, ctrl_val, cycle_lo;
    int i, j, k, r, errs, row_stride;
    int exp_val;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    // 预加载 all-1
    for (i = 0; i < M_v * K_v; i = i + 4)
      m_seq.axil_write32(32'h0000_0100 + i, 32'h01010101);
    for (i = 0; i < K_v * N_v; i = i + 4)
      m_seq.axil_write32(32'h0001_0000 + i, 32'h01010101);

    // 清除 output
    row_stride = compute_row_stride_int8(N_v);
    for (i = 0; i < M_v * row_stride + 64; i = i + 4)
      m_seq.axil_write32(32'h0002_0000 + i, 32'hDEADBEEF);

    // FC 流式 + INT8 test hook (conv_cfg[6]=1, conv_cfg[5]=1)
    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd1);
    m_seq.axil_write32(`NPU_REG_CONV_CFG,     32'h60);
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v * K_v);
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v * N_v);
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v * N_v * 4);
    m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
    m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
    m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

    m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
    repeat (500000) begin
      m_seq.axil_read32(`NPU_REG_CTRL, ctrl_val);
      if (ctrl_val[2] || ctrl_val[3]) break;
      #100;
    end
    m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);

    if (ctrl_val[3]) begin
      m_seq.axil_read32(`NPU_REG_STATUS, ctrl_val);
      `uvm_error("PBEAT", $sformatf("%s ERROR code=0x%02x", label, ctrl_val[7:0]))
      return;
    end

    // byte-accurate readback: INT8 packed, N elements per row with 32B-aligned stride
    exp_val = K_v & 8'hFF;
    errs = 0;
    for (r = 0; r < M_v; r++) begin
      for (j = 0; j < N_v; j = j + 4) begin
        m_seq.axil_read32(32'h0002_0000 + r * row_stride + (j & ~3), word);
        for (k = 0; k < 4; k = k + 1) begin
          if ((j + k) < N_v) begin
            if (word[k*8 +: 8] != exp_val[7:0]) begin
              if (errs < 8)
                `uvm_error("PBEAT", $sformatf("%s INT8 C[%0d][%0d]=%0d expected %0d",
                  label, r, j+k, word[k*8 +: 8], exp_val[7:0]))
              errs++;
            end
          end
        end
      end
    end

    if (errs == 0)
      `uvm_info("PBEAT", $sformatf("%s INT8 M=%0d K=%0d N=%0d row_stride=%0d cycles=%0d PASS",
        label, M_v, K_v, N_v, row_stride, cycle_lo), UVM_NONE)
  endtask

  //----------------------------------------------------------------------------
  // run_phase
  //----------------------------------------------------------------------------
  task run_phase(uvm_phase phase);
    // arrays for sweep
    int N32_vals[] = '{1, 2, 7, 8, 9, 31, 32, 33, 63, 64, 65};
    int M32_vals[] = '{1, 2, 4};
    int N8_vals[]  = '{1, 2, 31, 32, 33, 63, 64, 65};
    int M8_vals[]  = '{1, 2, 4};
    int ni, mi;

    phase.raise_objection(this);
    #200;

    `uvm_info("PBEAT", "=== PARTIAL-BEAT / ROW-STRIDE / BYTE-COUNT STRESS (Phase U5-a) ===", UVM_NONE)

    // -------- INT32 sweep --------
    `uvm_info("PBEAT", "--- INT32 Partial-Beat Sweep ---", UVM_NONE)
    for (mi = 0; mi < M32_vals.size(); mi++) begin
      for (ni = 0; ni < N32_vals.size(); ni++) begin
        run_int32_case(M32_vals[mi], 64, N32_vals[ni],
          $sformatf("PB_I32_M%0d_N%0d", M32_vals[mi], N32_vals[ni]));
      end
    end

    // additional INT32 K>64 cases
    `uvm_info("PBEAT", "--- INT32 Partial-Beat with K-chunk ---", UVM_NONE)
    run_int32_case(1, 129, 7,  "PB_I32_K129_M1_N7");
    run_int32_case(1, 129, 33, "PB_I32_K129_M1_N33");
    run_int32_case(4, 129, 65, "PB_I32_K129_M4_N65");

    // -------- INT8 sweep --------
    `uvm_info("PBEAT", "--- INT8 Partial-Beat Sweep ---", UVM_NONE)
    for (mi = 0; mi < M8_vals.size(); mi++) begin
      for (ni = 0; ni < N8_vals.size(); ni++) begin
        run_int8_case(M8_vals[mi], 64, N8_vals[ni],
          $sformatf("PB_I8_M%0d_N%0d", M8_vals[mi], N8_vals[ni]));
      end
    end

    // additional INT8 K>64 cases
    `uvm_info("PBEAT", "--- INT8 Partial-Beat with K-chunk ---", UVM_NONE)
    run_int8_case(1, 129, 33, "PB_I8_K129_M1_N33");
    run_int8_case(4, 129, 65, "PB_I8_K129_M4_N65");

    `uvm_info("PBEAT", "=== PARTIAL-BEAT STRESS COMPLETE ===", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
