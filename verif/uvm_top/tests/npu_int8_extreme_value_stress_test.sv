//=============================================================================
// npu_int8_extreme_value_stress_test.sv — Phase U5-a Task C
//
// Signed INT8 extreme value stress — verifies signed multiply and INT32
// accumulation with extreme/corner-case data patterns.
//
// 数据 patterns:
//   P1: all +127
//   P2: all -128
//   P3: A=+127, B=-128
//   P4: A=-128, B=+127
//   P5: checkerboard signs
//   P6: sparse zeros (every other element = 0)
//   P7: alternating +127 / -128
//   P8: fixed-seed pseudo-random signed
//
// Coverage: K = 64, 65, 128, 129; M = 1, 4, 8; N = 1, 8, 64, 65
//
// 黄金参考: computed analytically in testbench (sum of signed products).
//=============================================================================
`timescale 1ns / 1ps

class npu_int8_extreme_value_stress_test extends soc_base_test;
  `uvm_component_utils(npu_int8_extreme_value_stress_test)
  function new(string name="npu_int8_extreme_value_stress_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  //----------------------------------------------------------------------------
  // compute_row_stride
  //----------------------------------------------------------------------------
  function int compute_row_stride(int N);
    return ((N * 4 + 31) / 32) * 32;
  endfunction

  //----------------------------------------------------------------------------
  // fill_pattern: fills byte array with a named pattern
  //   Returns the signed byte value at each index via output.
  //----------------------------------------------------------------------------
  task fill_pattern_A(output byte signed a_vals[], input int M, input int K,
                     input int pat, input int seed);
    int idx, r, c;
    a_vals = new[M * K];
    case (pat)
      1: begin for (idx=0; idx<M*K; idx++) a_vals[idx] = 8'sd127;  end
      2: begin for (idx=0; idx<M*K; idx++) a_vals[idx] = -8'sd128; end
      3: begin for (idx=0; idx<M*K; idx++) a_vals[idx] = 8'sd127;  end
      4: begin for (idx=0; idx<M*K; idx++) a_vals[idx] = -8'sd128; end
      5: begin for (idx=0; idx<M*K; idx++) a_vals[idx] = (idx[0]) ? 8'sd127 : -8'sd128; end
      6: begin for (idx=0; idx<M*K; idx++) a_vals[idx] = (idx[0]) ? 8'sd0 : 8'sd127; end
      7: begin for (idx=0; idx<M*K; idx++) a_vals[idx] = (idx[0]) ? 8'sd127 : -8'sd128; end
      8: begin  // fixed-seed LFSR-like pseudo-random
        int lfsr;
        lfsr = seed;
        for (idx=0; idx<M*K; idx++) begin
          lfsr = (lfsr >> 1) ^ ((lfsr[0]) ? 8'hB8 : 8'h00);
          a_vals[idx] = $signed(lfsr[7:0]);
        end
      end
    endcase
  endtask

  task fill_pattern_B(output byte signed b_vals[], input int K, input int N,
                     input int pat, input int seed);
    int idx;
    b_vals = new[K * N];
    case (pat)
      1: begin for (idx=0; idx<K*N; idx++) b_vals[idx] = 8'sd127;  end
      2: begin for (idx=0; idx<K*N; idx++) b_vals[idx] = -8'sd128; end
      3: begin for (idx=0; idx<K*N; idx++) b_vals[idx] = -8'sd128; end
      4: begin for (idx=0; idx<K*N; idx++) b_vals[idx] = 8'sd127;  end
      5: begin for (idx=0; idx<K*N; idx++) b_vals[idx] = (idx[0]) ? -8'sd128 : 8'sd127; end
      6: begin for (idx=0; idx<K*N; idx++) b_vals[idx] = (idx[1]) ? 8'sd0 : 8'sd127; end
      7: begin for (idx=0; idx<K*N; idx++) b_vals[idx] = (idx[1]) ? -8'sd128 : 8'sd127; end
      8: begin
        int lfsr;
        lfsr = seed + 137;
        for (idx=0; idx<K*N; idx++) begin
          lfsr = (lfsr >> 1) ^ ((lfsr[0]) ? 8'hB8 : 8'h00);
          b_vals[idx] = $signed(lfsr[7:0]);
        end
      end
    endcase
  endtask

  //----------------------------------------------------------------------------
  // compute_golden: C[m][n] = Σ_k A[m][k] * B[k][n]
  //----------------------------------------------------------------------------
  function void compute_golden(input byte signed a[], input byte signed b[],
                               output int golden[], input int M, input int K,
                               input int N);
    int m, k, n;
    golden = new[M * N];
    for (m = 0; m < M; m++) begin
      for (n = 0; n < N; n++) begin
        golden[m * N + n] = 0;
        for (k = 0; k < K; k++) begin
          golden[m * N + n] = golden[m * N + n] +
            int'(a[m * K + k]) * int'(b[k * N + n]);
        end
      end
    end
  endfunction

  //----------------------------------------------------------------------------
  // 写_bytes_to_ram: write byte array as 32-bit words to shared RAM
  //----------------------------------------------------------------------------
  task write_bytes_to_ram(soc_base_seq m_seq, input bit [31:0] base_addr,
                          input byte signed vals[], input int count);
    int i, j;
    bit [31:0] word;
    for (i = 0; i < count; i = i + 4) begin
      word = 32'h0;
      for (j = 0; j < 4; j++)
        if ((i + j) < count)
          word[j*8 +: 8] = vals[i + j];
      m_seq.axil_write32(base_addr + i, word);
    end
  endtask

  //----------------------------------------------------------------------------
  // run_extreme_case: single extreme-value test case
  //----------------------------------------------------------------------------
  task run_extreme_case(int M_v, int K_v, int N_v, int pat, string label);
    soc_base_seq m_seq;
    byte signed a_vals[], b_vals[];
    int golden[];
    bit [31:0] rdata, ctrl_val, cycle_lo;
    int i, r, c, errs, row_stride, guard_pre, guard_post;
    int exp_val;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    // generate pattern data
    fill_pattern_A(a_vals, M_v, K_v, pat, 42);
    fill_pattern_B(b_vals, K_v, N_v, pat, 42);
    compute_golden(a_vals, b_vals, golden, M_v, K_v, N_v);

    // 写 A to 0x0000_0100
    write_bytes_to_ram(m_seq, 32'h0000_0100, a_vals, M_v * K_v);

    // 写 B to 0x0001_0000
    write_bytes_to_ram(m_seq, 32'h0001_0000, b_vals, K_v * N_v);

    // guard + clear
    m_seq.axil_write32(32'h0001_FFE0, 32'hCAFE_BABE);
    row_stride = compute_row_stride(N_v);
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
      `uvm_error("EXTRM", $sformatf("%s ERROR code=0x%02x", label, rdata[7:0]))
      return;
    end

    // verify vs golden
    errs = 0;
    for (r = 0; r < M_v; r++) begin
      for (c = 0; c < N_v; c++) begin
        exp_val = golden[r * N_v + c];
        m_seq.axil_read32(32'h0002_0000 + r * row_stride + c * 4, rdata);
        if ($signed(rdata) != exp_val) begin
          if (errs < 8)
            `uvm_error("EXTRM", $sformatf("%s C[%0d][%0d]=%0d expected %0d",
              label, r, c, $signed(rdata), exp_val))
          errs++;
        end
      end
    end

    // guard bands
    m_seq.axil_read32(32'h0001_FFE0, rdata);
    guard_pre = rdata;
    m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
    guard_post = rdata;
    if (guard_pre != 32'hCAFE_BABE)
      `uvm_error("EXTRM", $sformatf("%s pre-guard corrupted: 0x%08x", label, guard_pre))
    if (guard_post != 32'hFEED_F00D)
      `uvm_error("EXTRM", $sformatf("%s post-guard corrupted: 0x%08x", label, guard_post))

    if (errs == 0 && guard_pre == 32'hCAFE_BABE && guard_post == 32'hFEED_F00D)
      `uvm_info("EXTRM", $sformatf("%s M=%0d K=%0d N=%0d cycles=%0d PASS",
        label, M_v, K_v, N_v, cycle_lo), UVM_NONE)
    else
      `uvm_error("EXTRM", $sformatf("%s M=%0d K=%0d N=%0d FAIL errs=%0d",
        label, M_v, K_v, N_v, errs))
  endtask

  //----------------------------------------------------------------------------
  // run_phase
  //----------------------------------------------------------------------------
  task run_phase(uvm_phase phase);
    int K_vals[] = '{64, 65, 128, 129};
    int pat;
    string pat_names[] = '{"ALL+127","ALL-128","A127_Bm128","Am128_B127",
                           "CHKRBRD","SPARSE0","ALT127m128","RANDOM"};
    int ki;

    phase.raise_objection(this);
    #200;

    `uvm_info("EXTRM", "=== SIGNED INT8 EXTREME VALUE STRESS (Phase U5-a) ===", UVM_NONE)

    for (pat = 1; pat <= 8; pat++) begin
      `uvm_info("EXTRM", $sformatf("--- Pattern %0d: %s ---", pat, pat_names[pat-1]), UVM_NONE)
      for (ki = 0; ki < K_vals.size(); ki++) begin
        run_extreme_case(1, K_vals[ki],  1, pat,
          $sformatf("EX_P%0d_K%0d_M1N1", pat, K_vals[ki]));
        run_extreme_case(1, K_vals[ki], 64, pat,
          $sformatf("EX_P%0d_K%0d_M1N64", pat, K_vals[ki]));
        run_extreme_case(1, K_vals[ki], 65, pat,
          $sformatf("EX_P%0d_K%0d_M1N65", pat, K_vals[ki]));
        run_extreme_case(4, K_vals[ki],  8, pat,
          $sformatf("EX_P%0d_K%0d_M4N8", pat, K_vals[ki]));
        run_extreme_case(8, K_vals[ki],  8, pat,
          $sformatf("EX_P%0d_K%0d_M8N8", pat, K_vals[ki]));
        run_extreme_case(8, K_vals[ki], 64, pat,
          $sformatf("EX_P%0d_K%0d_M8N64", pat, K_vals[ki]));
      end
    end

    `uvm_info("EXTRM", "=== EXTREME VALUE STRESS COMPLETE ===", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
