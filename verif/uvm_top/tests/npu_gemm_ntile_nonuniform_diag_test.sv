//=============================================================================
// npu_gemm_ntile_nonuniform_diag_test.sv — Phase U5-b Bug B1 Diagnosis
//
// Minimal reproduction + diagnostic patterns for GEMM N>64 nonuniform data.
//
// Patterns:
//   D0: checkerboard (reproducing U5-a failure)
//   D1: column-coded B — B[k,n] = n
//        Expected: C[0,n] = K*n → identifies which column was read
//   D2: k-column-coded B — B[k,n] = 1000*n + k
//        Expected: C[0,n] = K*1000*n + K*(K-1)/2
//        → identifies n_base loss / K-stride error / total_N vs tile_N
//=============================================================================
`timescale 1ns / 1ps

class npu_gemm_ntile_nonuniform_diag_test extends soc_base_test;
  `uvm_component_utils(npu_gemm_ntile_nonuniform_diag_test)
  function new(string name="npu_gemm_ntile_nonuniform_diag_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  function int compute_row_stride(int N);
    return ((N * 4 + 31) / 32) * 32;
  endfunction

  //----------------------------------------------------------------------------
  // D0: checkerboard — A alternates +127/-128, B alternates -128/+127
  //----------------------------------------------------------------------------
  task run_checkerboard(int M_v, int K_v, int N_v);
    soc_base_seq m_seq;
    byte signed a_vals[], b_vals[];
    int golden[];
    bit [31:0] rdata, ctrl_val, cycle_lo, word;
    int i, r, c, k, errs, row_stride, exp_val;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    // Generate pattern data
    a_vals = new[M_v * K_v];
    b_vals = new[K_v * N_v];
    golden = new[M_v * N_v];
    for (i = 0; i < M_v * K_v; i++) a_vals[i] = (i[0]) ? 8'sd127 : -8'sd128;
    for (i = 0; i < K_v * N_v; i++) b_vals[i] = (i[0]) ? -8'sd128 : 8'sd127;

    // Compute golden
    for (r = 0; r < M_v; r++) begin
      for (c = 0; c < N_v; c++) begin
        golden[r * N_v + c] = 0;
        for (k = 0; k < K_v; k++)
          golden[r * N_v + c] = golden[r * N_v + c] +
            int'(a_vals[r * K_v + k]) * int'(b_vals[k * N_v + c]);
      end
    end

    // 写 to RAM
    for (i = 0; i < M_v * K_v; i = i + 4) begin
      word = 32'h0;
      for (int j = 0; j < 4; j++) if (i+j < M_v*K_v) word[j*8 +: 8] = a_vals[i+j];
      m_seq.axil_write32(32'h0000_0100 + i, word);
    end
    for (i = 0; i < K_v * N_v; i = i + 4) begin
      word = 32'h0;
      for (int j = 0; j < 4; j++) if (i+j < K_v*N_v) word[j*8 +: 8] = b_vals[i+j];
      m_seq.axil_write32(32'h0001_0000 + i, word);
    end

    row_stride = compute_row_stride(N_v);
    for (i = 0; i < M_v * row_stride + 64; i = i + 4)
      m_seq.axil_write32(32'h0002_0000 + i, 32'hDEADBEEF);

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
      `uvm_error("NTLDIAG", $sformatf("D0 ERROR code=0x%02x", rdata[7:0]))
      return;
    end

    // 输出 mismatch fingerprint
    errs = 0;
    `uvm_info("NTLDIAG", $sformatf("D0 CHECKERBOARD M=%0d K=%0d N=%0d:", M_v, K_v, N_v), UVM_NONE)
    for (r = 0; r < M_v; r++) begin
      for (c = 0; c < N_v; c++) begin
        m_seq.axil_read32(32'h0002_0000 + r * row_stride + c * 4, rdata);
        exp_val = golden[r * N_v + c];
        if ($signed(rdata) != exp_val) begin
          `uvm_info("NTLDIAG", $sformatf("  MISMATCH: row=%0d col=%0d tile=%0s got=%0d exp=%0d @addr=0x%08x",
            r, c, (c < 64 ? "T0" : "T1"), $signed(rdata), exp_val,
            32'h0002_0000 + r * row_stride + c * 4), UVM_NONE)
          errs++;
        end
      end
    end
    `uvm_info("NTLDIAG", $sformatf("D0 total mismatches=%0d/%0d cycles=%0d %s",
      errs, M_v*N_v, cycle_lo, errs == 0 ? "PASS" : "FAIL"), UVM_NONE)
  endtask

  //----------------------------------------------------------------------------
  // D1: column-coded B — B[k,n] = n
  //     Expected: C[m,n] = K * n
  //----------------------------------------------------------------------------
  task run_column_coded(int M_v, int K_v, int N_v);
    soc_base_seq m_seq;
    byte signed a_vals[], b_vals[];
    int golden[];
    bit [31:0] rdata, ctrl_val, cycle_lo, word;
    int i, r, c, k, errs, row_stride, exp_val;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    a_vals = new[M_v * K_v];
    b_vals = new[K_v * N_v];
    golden = new[M_v * N_v];
    for (i = 0; i < M_v * K_v; i++) a_vals[i] = 8'sd1;
    for (k = 0; k < K_v; k++)
      for (c = 0; c < N_v; c++)
        b_vals[k * N_v + c] = byte'(c);   // B[k,n] = n

    for (r = 0; r < M_v; r++)
      for (c = 0; c < N_v; c++) begin
        golden[r * N_v + c] = 0;
        for (k = 0; k < K_v; k++)
          golden[r * N_v + c] = golden[r * N_v + c] +
            int'(a_vals[r * K_v + k]) * int'(b_vals[k * N_v + c]);
      end

    for (i = 0; i < M_v * K_v; i = i + 4) begin
      word = 32'h0;
      for (int j = 0; j < 4; j++) if (i+j < M_v*K_v) word[j*8 +: 8] = a_vals[i+j];
      m_seq.axil_write32(32'h0000_0100 + i, word);
    end
    for (i = 0; i < K_v * N_v; i = i + 4) begin
      word = 32'h0;
      for (int j = 0; j < 4; j++) if (i+j < K_v*N_v) word[j*8 +: 8] = b_vals[i+j];
      m_seq.axil_write32(32'h0001_0000 + i, word);
    end

    row_stride = compute_row_stride(N_v);
    for (i = 0; i < M_v * row_stride + 64; i = i + 4)
      m_seq.axil_write32(32'h0002_0000 + i, 32'hDEADBEEF);

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
      `uvm_error("NTLDIAG", $sformatf("D1 ERROR code=0x%02x", rdata[7:0]))
      return;
    end

    errs = 0;
    `uvm_info("NTLDIAG", $sformatf("D1 COL-CODED M=%0d K=%0d N=%0d:", M_v, K_v, N_v), UVM_NONE)
    `uvm_info("NTLDIAG", $sformatf("  Golden: C[0,n] = %0d * n = 0, %0d, %0d, ..., %0d",
      K_v, K_v, 2*K_v, K_v*(N_v-1)), UVM_NONE)
    for (r = 0; r < M_v; r++) begin
      for (c = 0; c < N_v; c++) begin
        m_seq.axil_read32(32'h0002_0000 + r * row_stride + c * 4, rdata);
        exp_val = golden[r * N_v + c];
        if ($signed(rdata) != exp_val) begin
          // Decode: if actual = K * x, then B column x was read instead of c
          int col_read;
          col_read = ($signed(rdata) % K_v == 0 && $signed(rdata) >= 0) ?
                     $signed(rdata) / K_v : -1;
          `uvm_info("NTLDIAG", $sformatf(
            "  MISMATCH: row=%0d col=%0d tile=%0s got=%0d exp=%0d col_read=%0d @addr=0x%08x",
            r, c, (c < 64 ? "T0" : "T1"), $signed(rdata), exp_val, col_read,
            32'h0002_0000 + r * row_stride + c * 4), UVM_NONE)
          errs++;
        end
      end
    end
    `uvm_info("NTLDIAG", $sformatf("D1 total mismatches=%0d/%0d cycles=%0d %s",
      errs, M_v*N_v, cycle_lo, errs == 0 ? "PASS" : "FAIL"), UVM_NONE)
  endtask

  //----------------------------------------------------------------------------
  // D2: k-column-coded B — B[k,n] = 1000*n + k
  //     Expected: C[m,n] = K*1000*n + K*(K-1)/2
  //----------------------------------------------------------------------------
  task run_kcol_coded(int M_v, int K_v, int N_v);
    soc_base_seq m_seq;
    byte signed a_vals[], b_vals[];
    int golden[];
    bit [31:0] rdata, ctrl_val, cycle_lo, word;
    int i, r, c, k, errs, row_stride, exp_val, exp_n_part, exp_k_part;
    int n_read, k_base_read;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    a_vals = new[M_v * K_v];
    b_vals = new[K_v * N_v];
    golden = new[M_v * N_v];
    for (i = 0; i < M_v * K_v; i++) a_vals[i] = 8'sd1;
    for (k = 0; k < K_v; k++)
      for (c = 0; c < N_v; c++)
        b_vals[k * N_v + c] = byte'((1000 * c + k) & 8'hFF);  // B[k,n] = low8(1000*n + k)

    for (r = 0; r < M_v; r++)
      for (c = 0; c < N_v; c++) begin
        golden[r * N_v + c] = 0;
        for (k = 0; k < K_v; k++)
          golden[r * N_v + c] = golden[r * N_v + c] +
            int'(a_vals[r * K_v + k]) * int'(b_vals[k * N_v + c]);
      end

    for (i = 0; i < M_v * K_v; i = i + 4) begin
      word = 32'h0;
      for (int j = 0; j < 4; j++) if (i+j < M_v*K_v) word[j*8 +: 8] = a_vals[i+j];
      m_seq.axil_write32(32'h0000_0100 + i, word);
    end
    for (i = 0; i < K_v * N_v; i = i + 4) begin
      word = 32'h0;
      for (int j = 0; j < 4; j++) if (i+j < K_v*N_v) word[j*8 +: 8] = b_vals[i+j];
      m_seq.axil_write32(32'h0001_0000 + i, word);
    end

    row_stride = compute_row_stride(N_v);
    for (i = 0; i < M_v * row_stride + 64; i = i + 4)
      m_seq.axil_write32(32'h0002_0000 + i, 32'hDEADBEEF);

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
      `uvm_error("NTLDIAG", $sformatf("D2 ERROR code=0x%02x", rdata[7:0]))
      return;
    end

    errs = 0;
    `uvm_info("NTLDIAG", $sformatf("D2 KCOL-CODED M=%0d K=%0d N=%0d:", M_v, K_v, N_v), UVM_NONE)
    exp_k_part = K_v * (K_v - 1) / 2;
    for (r = 0; r < M_v; r++) begin
      for (c = 0; c < N_v; c++) begin
        m_seq.axil_read32(32'h0002_0000 + r * row_stride + c * 4, rdata);
        exp_val = golden[r * N_v + c];
        exp_n_part = K_v * 1000 * c;
        if ($signed(rdata) != exp_val) begin
          // Try to decode: got = K*1000*n_read + k_sum
          // k_sum should be K*(K-1)/2 ≈ K*63.5 for K=64
          n_read = ($signed(rdata) - exp_k_part) / (K_v * 1000);
          k_base_read = $signed(rdata) - K_v * 1000 * n_read;
          `uvm_info("NTLDIAG", $sformatf(
            "  MISMATCH: row=%0d col=%0d tile=%0s got=%0d exp=%0d n_read~=%0d k_sum=%0d(exp=%0d) @addr=0x%08x",
            r, c, (c < 64 ? "T0" : "T1"), $signed(rdata), exp_val, n_read,
            k_base_read, exp_k_part, 32'h0002_0000 + r * row_stride + c * 4), UVM_NONE)
          errs++;
        end
      end
    end
    `uvm_info("NTLDIAG", $sformatf("D2 total mismatches=%0d/%0d cycles=%0d %s",
      errs, M_v*N_v, cycle_lo, errs == 0 ? "PASS" : "FAIL"), UVM_NONE)
  endtask

  //----------------------------------------------------------------------------
  // run_phase
  //----------------------------------------------------------------------------
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    #200;

    `uvm_info("NTLDIAG", "=== GEMM N-TILE NONUNIFORM DIAGNOSTIC (Phase U5-b) ===", UVM_NONE)

    // D0: checkerboard minimal repro
    `uvm_info("NTLDIAG", "--- D0: Checkerboard M=1,K=64,N=65 ---", UVM_NONE)
    run_checkerboard(1, 64, 65);

    // D1: column-coded B — which column is read for col 64?
    `uvm_info("NTLDIAG", "--- D1: Column-coded B M=1,K=64,N=65 ---", UVM_NONE)
    run_column_coded(1, 64, 65);

    // D2: k-column-coded B — n_base, K-stride, total_N vs tile_N
    `uvm_info("NTLDIAG", "--- D2: K-col-coded B M=1,K=64,N=65 ---", UVM_NONE)
    run_kcol_coded(1, 64, 65);

    // D1 with K=65 (K-chunk boundary)
    `uvm_info("NTLDIAG", "--- D1: Column-coded B M=1,K=65,N=65 ---", UVM_NONE)
    run_column_coded(1, 65, 65);

    // D2 with K=65
    `uvm_info("NTLDIAG", "--- D2: K-col-coded B M=1,K=65,N=65 ---", UVM_NONE)
    run_kcol_coded(1, 65, 65);

    // D1 with larger N-tile gap
    `uvm_info("NTLDIAG", "--- D1: Column-coded B M=1,K=64,N=129 ---", UVM_NONE)
    run_column_coded(1, 64, 129);

    `uvm_info("NTLDIAG", "=== N-TILE DIAGNOSTIC COMPLETE ===", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
