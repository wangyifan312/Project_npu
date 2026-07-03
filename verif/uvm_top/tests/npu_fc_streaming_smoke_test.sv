//=============================================================================
// npu_fc_streaming_smoke_test.sv — FC Streaming as MatrixOp Phase U1
//
// 阶段 U1: FC routed through streaming GEMM pipeline when:
//   is_fc_mode && conv_cfg[5] && !bias_enabled
//
// 测试 levels:
//   FCS0:  M=1, K=4,  N=4   — minimal smoke (all-1 data)
//   FCS1:  M=1, K=16, N=16  — full PE array, non-uniform data
//   FCS2:  M=1, K=128,N=16  — K>64 cross-chunk accumulation
//   FCS3:  M=1, K=64, N=128 — N-tiling (N>64 → 2 tiles)
//   FCS4:  M=4, K=64, N=64  — batch M>1 (input_h=4)
//   FCS5:  M=1, K=8,  N=8   — signed INT8 A/B
//
// 权重 layout: K-major B[k][n] (streaming MatrixOp layout).
// 传统 N-major W[n][k] is NOT compatible with streaming FC.
//=============================================================================
`timescale 1ns / 1ps

class npu_fc_streaming_smoke_test extends soc_base_test;
  `uvm_component_utils(npu_fc_streaming_smoke_test)
  function new(string name="npu_fc_streaming_smoke_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq m_seq;
    bit [31:0] rdata, cycle_lo;
    int M_v, K_v, N_v, lvl;
    int i, j, k, total_errs;
    int exp_val;
    int M_arr[6], K_arr[6], N_arr[6];
    int levels_run;
    bit [31:0] word;

    phase.raise_objection(this);
    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);
    #200;

    // FC 流式 levels
    M_arr[0]=1;  K_arr[0]=4;   N_arr[0]=4;    // FCS0: smoke
    M_arr[1]=1;  K_arr[1]=16;  N_arr[1]=16;   // FCS1: non-uniform
    M_arr[2]=1;  K_arr[2]=128; N_arr[2]=16;   // FCS2: K>64 chunking
    M_arr[3]=1;  K_arr[3]=64;  N_arr[3]=128;  // FCS3: N-tiling
    M_arr[4]=4;  K_arr[4]=64;  N_arr[4]=64;   // FCS4: batch M>1
    M_arr[5]=1;  K_arr[5]=8;   N_arr[5]=8;    // FCS5: signed

    `uvm_info("TEST","=== FC_STREAMING SMOKE (Phase U1) ===",UVM_NONE)

    for(lvl=0; lvl<6; lvl++) begin
      M_v=M_arr[lvl]; K_v=K_arr[lvl]; N_v=N_arr[lvl];
      total_errs=0;

      `uvm_info("TEST",$sformatf("-- FCS%d: M=%0d K=%0d N=%0d --",
        lvl, M_v,K_v,N_v),UVM_NONE)

      // --- Preload input A[M][K] — K-major: A[m*K + k] ---
      // 写 32-bit words; data is packed little-endian in memory
      if (lvl == 5) begin
        // FCS5: signed — A=alternating +1/-1, B=all +2
        // Pack 4 bytes per 32-bit word
        for (i=0; i<M_v*K_v; i=i+4) begin
          word = 32'h00000000;
          for (k=0; k<4; k=k+1) begin
            if ((i+k) < M_v*K_v) begin
              if (((i+k) % 2) == 0)
                word[k*8 +: 8] = 8'd1;
              else
                word[k*8 +: 8] = 8'hFF; // -1 signed
            end
          end
          m_seq.axil_write32(32'h0000_0100 + i, word);
        end
        // B: all +2
        for (i=0; i<K_v*N_v; i=i+4)
          m_seq.axil_write32(32'h0001_0000 + i, 32'h02020202);
        // Expected: A=[+1,-1,+1,-1...], B=all 2 → K even: sum=0, K odd: sum=2
        exp_val = (K_v % 2 == 0) ? 0 : 2;
      end else if (lvl == 1) begin
        // FCS1: non-uniform — A[m][k]=k+1, B[k][n]=n+1
        // Pack 4 bytes/word
        for (i=0; i<M_v; i++) begin
          for (k=0; k<K_v; k=k+4) begin
            word = 32'h00000000;
            for (j=0; j<4; j=j+1) begin
              if ((k+j) < K_v)
                word[j*8 +: 8] = k+j+1;
            end
            m_seq.axil_write32(32'h0000_0100 + i*K_v + k, word);
          end
        end
        // B[k][n] = n+1 (K-major)
        for (k=0; k<K_v; k=k+1) begin
          for (j=0; j<N_v; j=j+4) begin
            word = 32'h00000000;
            for (i=0; i<4; i=i+1) begin
              if ((j+i) < N_v)
                word[i*8 +: 8] = j+i+1;
            end
            m_seq.axil_write32(32'h0001_0000 + k*N_v + j, word);
          end
        end
        exp_val = K_v*(K_v+1)/2; // per-column: exp_val * (n+1)
      end else begin
        // FCS0/FCS2/FCS3/FCS4: all-1 data
        for (i=0; i<M_v*K_v; i=i+4)
          m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
        for (i=0; i<K_v*N_v; i=i+4)
          m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);
        exp_val = K_v; // each C[m][n] = sum_k 1*1 = K
      end

      // 清除 output region
      for (i=0; i<M_v*N_v*4; i=i+4)
        m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);

      // --- Configure NPU ---
      m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd1);          // FC mode
      m_seq.axil_write32(`NPU_REG_CONV_CFG,     32'h20);        // bit[5]=1 streaming
      m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
      m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
      m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
      m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});   // W=1, H=M
      m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]}); // C_OUT=N, C_IN=K
      m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);           // no post-op
      m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

      // --- Start and poll ---
      m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
      repeat(500000) begin
        m_seq.axil_read32(`NPU_REG_CTRL, rdata);
        if (rdata[2] || rdata[3]) break;
        #100;
      end

      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);

      if (rdata[3]) begin
        m_seq.axil_read32(`NPU_REG_STATUS, rdata);
        `uvm_error("TEST",$sformatf("FCS%d ERROR code=0x%02x",lvl,rdata[7:0]))
        break;
      end

      // --- Verify output ---
      begin
        int row_stride;
        row_stride = ((N_v*4 + 31) / 32) * 32;  // 32B-aligned row stride
        for (i=0; i<M_v; i++) begin
          for (j=0; j<N_v; j++) begin
            int expected_val;
            if (lvl == 1)
              expected_val = exp_val * (j+1);  // non-uniform: (n+1)*K*(K+1)/2
            else
              expected_val = exp_val;

            m_seq.axil_read32(32'h0002_0000 + i*row_stride + j*4, rdata);
            if ($signed(rdata) != expected_val) begin
              if (total_errs<8)
                `uvm_error("TEST",$sformatf("FCS%d C[%0d][%0d]=%0d expected %0d",
                  lvl,i,j,$signed(rdata),expected_val))
              total_errs++;
            end
          end
        end
      end

      `uvm_info("TEST",$sformatf("FCS%d: M=%0d K=%0d N=%0d cycles=%0d errors=%0d/%0d %s",
        lvl, M_v,K_v,N_v,cycle_lo,total_errs,M_v*N_v, (total_errs==0)?"PASS":"FAIL"),UVM_NONE)

      if (total_errs>0) break;
      levels_run=lvl+1;
    end
    `uvm_info("TEST",$sformatf("FC_STREAMING: %0d/6 levels PASS",levels_run),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
