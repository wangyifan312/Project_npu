//=============================================================================
// npu_task_gemm_row_streaming_test.sv — Row-streaming GEMM coverage
// Phase 2b-2: RS0-RS3 baseline + RS4-RS8 enhanced coverage
//=============================================================================
`timescale 1ns / 1ps

class npu_task_gemm_row_streaming_test extends soc_base_test;
  `uvm_component_utils(npu_task_gemm_row_streaming_test)
  function new(string name="npu_task_gemm_row_streaming_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  // Helper: compute row stride (32B-aligned, matching RTL)
  function int row_stride_bytes(int N);
    return ((N * 4 + 31) / 32) * 32;
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq m_seq;
    bit [31:0] rdata, cycle_lo;
    int levels_run, levels_pass;
    string lvl_name;
    int i, r, c, chk_errs, row_stride;

    phase.raise_objection(this);
    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);
    #200;

    `uvm_info("TEST","=== TASK_GEMM_ROW_STREAMING ENHANCED ===",UVM_NONE)

    levels_run  = 0;
    levels_pass = 0;

    //=================================================================
    // RS0-RS3: baseline
    //=================================================================
    begin
      int M_arr[4], K_arr[4], N_arr[4];
      int M_v, K_v, N_v, lvl;
      M_arr[0]=4;  K_arr[0]=4;  N_arr[0]=4;   // RS0
      M_arr[1]=8;  K_arr[1]=8;  N_arr[1]=8;   // RS1
      M_arr[2]=8;  K_arr[2]=16; N_arr[2]=8;   // RS2
      M_arr[3]=8;  K_arr[3]=64; N_arr[3]=8;   // RS3

      for (lvl=0; lvl<4; lvl++) begin
        M_v = M_arr[lvl]; K_v = K_arr[lvl]; N_v = N_arr[lvl];
        lvl_name = $sformatf("RS%0d", lvl);

        `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d expected C=%0d",
          lvl_name, M_v, K_v, N_v, K_v),UVM_NONE)

        for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
        for(i=0; i<K_v*N_v; i=i+4) m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);
        for(i=0; i<M_v*N_v*4+64; i=i+4) m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);

        row_stride = row_stride_bytes(N_v);
        m_seq.axil_write32(32'h0001_FFE0, 32'hCAFE_BABE);
        m_seq.axil_write32(32'h0002_0000 + M_v * row_stride, 32'hFEED_F00D);

        m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
        m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
        m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
        m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
        m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
        m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
        m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
        m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
        m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
        m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
        m_seq.axil_write32(`NPU_REG_CONV_CFG,    32'h20);
        m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
        m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);
        m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
        repeat(200000) begin
          m_seq.axil_read32(`NPU_REG_CTRL, rdata);
          if(rdata[2] || rdata[3]) break;
          #100;
        end

        m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);
        levels_run++;

        if(rdata[3]) begin
          m_seq.axil_read32(`NPU_REG_STATUS, rdata);
          `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x cycles=%0d",
            lvl_name, rdata[7:0], cycle_lo))
        end else begin
          chk_errs = 0;
          for (r = 0; r < M_v; r = r + 1) begin
            for (c = 0; c < N_v; c = c + 1) begin
              m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
              if ($signed(rdata) != K_v) begin
                if (chk_errs < 5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                  lvl_name, r, c, $signed(rdata), K_v))
                chk_errs++;
              end
            end
          end
          m_seq.axil_read32(32'h0001_FFE0, rdata);
          if (rdata != 32'hCAFE_BABE)
            `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
          m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
          if (rdata != 32'hFEED_F00D)
            `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))

          if (chk_errs == 0) begin
            `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d cycles=%0d stride=%0d mem_OK PASS",
              lvl_name, M_v, K_v, N_v, cycle_lo, row_stride),UVM_NONE)
            levels_pass++;
          end else begin
            `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d cycles=%0d mem_ERR=%0d FAIL",
              lvl_name, M_v, K_v, N_v, cycle_lo, chk_errs),UVM_NONE)
          end
        end
      end
    end

    //=================================================================
    // RS4: multi-beat store, N=16
    // M=8, K=16, N=16 → beats_per_row=2, write_beat_count=16
    //=================================================================
    begin
      int M_v, K_v, N_v, beats_per_row;
      M_v=8; K_v=16; N_v=16;
      beats_per_row = (N_v * 4 + 31) / 32;
      lvl_name = "RS4";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d beats/row=%0d expected C=%0d",
        lvl_name, M_v, K_v, N_v, beats_per_row, K_v),UVM_NONE)

      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      for(i=0; i<K_v*N_v; i=i+4) m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);
      for(i=0; i<M_v*N_v*4+128; i=i+4) m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);
      row_stride = row_stride_bytes(N_v);
      m_seq.axil_write32(32'h0001_FFE0, 32'hCAFE_BABE);
      m_seq.axil_write32(32'h0002_0000 + M_v * row_stride, 32'hFEED_F00D);

      m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
      m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
      m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
      m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
      m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
      m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
      m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
      m_seq.axil_write32(`NPU_REG_CONV_CFG,    32'h20);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);
      m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
      repeat(400000) begin
        m_seq.axil_read32(`NPU_REG_CTRL, rdata);
        if(rdata[2] || rdata[3]) break;
        #100;
      end

      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);
      levels_run++;
      if(rdata[3]) begin
        m_seq.axil_read32(`NPU_REG_STATUS, rdata);
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x cycles=%0d",
          lvl_name, rdata[7:0], cycle_lo))
      end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) begin
          for (c = 0; c < N_v; c = c + 1) begin
            m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
            if ($signed(rdata) != K_v) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), K_v))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE)
          `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D)
          `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))

        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: N=%0d beats/row=%0d write_beats=%0d valid_bytes/row=%0d cycles=%0d mem_OK PASS",
            lvl_name, N_v, beats_per_row, M_v*beats_per_row, N_v*4, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: N=%0d beats/row=%0d cycles=%0d mem_ERR=%0d FAIL",
            lvl_name, N_v, beats_per_row, cycle_lo, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS5: multi-beat store, N=32
    // M=8, K=16, N=32 → beats_per_row=4, write_beat_count=32
    //=================================================================
    begin
      int M_v, K_v, N_v, beats_per_row;
      M_v=8; K_v=16; N_v=32;
      beats_per_row = (N_v * 4 + 31) / 32;
      lvl_name = "RS5";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d beats/row=%0d expected C=%0d",
        lvl_name, M_v, K_v, N_v, beats_per_row, K_v),UVM_NONE)

      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      for(i=0; i<K_v*N_v; i=i+4) m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);
      for(i=0; i<M_v*N_v*4+256; i=i+4) m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);
      row_stride = row_stride_bytes(N_v);
      m_seq.axil_write32(32'h0001_FFE0, 32'hCAFE_BABE);
      m_seq.axil_write32(32'h0002_0000 + M_v * row_stride, 32'hFEED_F00D);

      m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
      m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
      m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
      m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
      m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
      m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
      m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
      m_seq.axil_write32(`NPU_REG_CONV_CFG,    32'h20);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);
      m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
      repeat(400000) begin
        m_seq.axil_read32(`NPU_REG_CTRL, rdata);
        if(rdata[2] || rdata[3]) break;
        #100;
      end

      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);
      levels_run++;
      if(rdata[3]) begin
        m_seq.axil_read32(`NPU_REG_STATUS, rdata);
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x cycles=%0d",
          lvl_name, rdata[7:0], cycle_lo))
      end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) begin
          for (c = 0; c < N_v; c = c + 1) begin
            m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
            if ($signed(rdata) != K_v) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), K_v))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE)
          `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D)
          `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))

        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: N=%0d beats/row=%0d write_beats=%0d valid_bytes/row=%0d cycles=%0d mem_OK PASS",
            lvl_name, N_v, beats_per_row, M_v*beats_per_row, N_v*4, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: N=%0d beats/row=%0d cycles=%0d mem_ERR=%0d FAIL",
            lvl_name, N_v, beats_per_row, cycle_lo, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS6: max tested N tile, N=64
    // M=8, K=16, N=64 → beats_per_row=8, write_beat_count=64
    //=================================================================
    begin
      int M_v, K_v, N_v, beats_per_row;
      M_v=8; K_v=16; N_v=64;
      beats_per_row = (N_v * 4 + 31) / 32;
      lvl_name = "RS6";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d beats/row=%0d expected C=%0d",
        lvl_name, M_v, K_v, N_v, beats_per_row, K_v),UVM_NONE)

      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      for(i=0; i<K_v*N_v; i=i+4) m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);
      for(i=0; i<M_v*N_v*4+512; i=i+4) m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);
      row_stride = row_stride_bytes(N_v);
      m_seq.axil_write32(32'h0001_FFE0, 32'hCAFE_BABE);
      m_seq.axil_write32(32'h0002_0000 + M_v * row_stride, 32'hFEED_F00D);

      m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
      m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
      m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
      m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
      m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
      m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
      m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
      m_seq.axil_write32(`NPU_REG_CONV_CFG,    32'h20);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);
      m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
      repeat(400000) begin
        m_seq.axil_read32(`NPU_REG_CTRL, rdata);
        if(rdata[2] || rdata[3]) break;
        #100;
      end

      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);
      levels_run++;
      if(rdata[3]) begin
        m_seq.axil_read32(`NPU_REG_STATUS, rdata);
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x cycles=%0d",
          lvl_name, rdata[7:0], cycle_lo))
      end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) begin
          for (c = 0; c < N_v; c = c + 1) begin
            m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
            if ($signed(rdata) != K_v) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), K_v))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE)
          `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D)
          `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))

        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: N=%0d beats/row=%0d write_beats=%0d valid_bytes/row=%0d cycles=%0d mem_OK PASS",
            lvl_name, N_v, beats_per_row, M_v*beats_per_row, N_v*4, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: N=%0d beats/row=%0d cycles=%0d mem_ERR=%0d FAIL",
            lvl_name, N_v, beats_per_row, cycle_lo, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS7: signed INT8 patterns, M=4, K=4, N=8
    // A[m][k] = ((m*13 + k*17) mod 7) - 3    →  [-3, 3]
    // B[k][n] = ((k*7 + n*11) mod 5) - 2     →  [-2, 2]
    // C[m][n] = sum_k A[m][k] * B[k][n]
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int A_signed[0:3][0:3];
      int B_signed[0:3][0:7];
      int golden_C[0:3][0:7];
      int kk;
      M_v=4; K_v=4; N_v=8;
      lvl_name = "RS7";

      // Generate A
      for (r = 0; r < M_v; r = r + 1)
        for (c = 0; c < K_v; c = c + 1)
          A_signed[r][c] = ((r*13 + c*17) % 7) - 3;
      // Generate B
      for (r = 0; r < K_v; r = r + 1)
        for (c = 0; c < N_v; c = c + 1)
          B_signed[r][c] = ((r*7 + c*11) % 5) - 2;
      // Compute golden
      for (r = 0; r < M_v; r = r + 1)
        for (c = 0; c < N_v; c = c + 1) begin
          golden_C[r][c] = 0;
          for (kk = 0; kk < K_v; kk = kk + 1)
            golden_C[r][c] = golden_C[r][c] + A_signed[r][kk] * B_signed[kk][c];
        end

      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d signed patterns", lvl_name, M_v, K_v, N_v),UVM_NONE)

      // Preload A
      for(i=0; i<M_v*K_v; i=i+4) begin
        int a0, a1, a2, a3;
        a0 = i+0; a1 = i+1; a2 = i+2; a3 = i+3;
        m_seq.axil_write32(32'h0000_0100+i,
          {8'(A_signed[a3/K_v][a3%K_v]), 8'(A_signed[a2/K_v][a2%K_v]),
           8'(A_signed[a1/K_v][a1%K_v]), 8'(A_signed[a0/K_v][a0%K_v])});
      end
      // Preload B
      for(i=0; i<K_v*N_v; i=i+4) begin
        int b0, b1, b2, b3;
        b0 = i+0; b1 = i+1; b2 = i+2; b3 = i+3;
        m_seq.axil_write32(32'h0001_0000+i,
          {8'(B_signed[b3/N_v][b3%N_v]), 8'(B_signed[b2/N_v][b2%N_v]),
           8'(B_signed[b1/N_v][b1%N_v]), 8'(B_signed[b0/N_v][b0%N_v])});
      end

      for(i=0; i<M_v*N_v*4+64; i=i+4) m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);
      row_stride = row_stride_bytes(N_v);
      m_seq.axil_write32(32'h0001_FFE0, 32'hCAFE_BABE);
      m_seq.axil_write32(32'h0002_0000 + M_v * row_stride, 32'hFEED_F00D);

      m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
      m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
      m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
      m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
      m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
      m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
      m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
      m_seq.axil_write32(`NPU_REG_CONV_CFG,    32'h20);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);
      m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
      repeat(200000) begin
        m_seq.axil_read32(`NPU_REG_CTRL, rdata);
        if(rdata[2] || rdata[3]) break;
        #100;
      end

      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);
      levels_run++;
      if(rdata[3]) begin
        m_seq.axil_read32(`NPU_REG_STATUS, rdata);
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x cycles=%0d",
          lvl_name, rdata[7:0], cycle_lo))
      end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) begin
          for (c = 0; c < N_v; c = c + 1) begin
            m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
            if ($signed(rdata) != golden_C[r][c]) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), golden_C[r][c]))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE)
          `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D)
          `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))

        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: signed patterns mem_OK cycles=%0d PASS", lvl_name, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: signed patterns mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS8a: boundary M=1, K=1, N=8
    //=================================================================
    begin
      int M_v, K_v, N_v;
      M_v=1; K_v=1; N_v=8;
      lvl_name = "RS8a";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d boundary min", lvl_name, M_v, K_v, N_v),UVM_NONE)

      // A[0][0]=3, B[0][0..7]=2 → C[0][0..7]=6
      m_seq.axil_write32(32'h0000_0100, {8'd0, 8'd0, 8'd0, 8'd3});
      m_seq.axil_write32(32'h0000_0104, 32'd0);
      for(i=0; i<K_v*N_v; i=i+4) m_seq.axil_write32(32'h0001_0000+i, 32'h02020202);
      for(i=0; i<M_v*N_v*4+64; i=i+4) m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);
      row_stride = row_stride_bytes(N_v);
      m_seq.axil_write32(32'h0001_FFE0, 32'hCAFE_BABE);
      m_seq.axil_write32(32'h0002_0000 + M_v * row_stride, 32'hFEED_F00D);

      m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
      m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
      m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
      m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
      m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
      m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
      m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
      m_seq.axil_write32(`NPU_REG_CONV_CFG,    32'h20);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);
      m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
      repeat(200000) begin
        m_seq.axil_read32(`NPU_REG_CTRL, rdata);
        if(rdata[2] || rdata[3]) break;
        #100;
      end

      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);
      levels_run++;
      if(rdata[3]) begin
        m_seq.axil_read32(`NPU_REG_STATUS, rdata);
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x cycles=%0d",
          lvl_name, rdata[7:0], cycle_lo))
      end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) begin
          for (c = 0; c < N_v; c = c + 1) begin
            m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
            if ($signed(rdata) != 6) begin
              if (chk_errs < 5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected 6",
                lvl_name, r, c, $signed(rdata)))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE)
          `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D)
          `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))

        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: M=1 K=1 N=8 cycles=%0d mem_OK PASS", lvl_name, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS8b: boundary M=7, K=63, N=8
    //=================================================================
    begin
      int M_v, K_v, N_v;
      M_v=7; K_v=63; N_v=8;
      lvl_name = "RS8b";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d boundary high", lvl_name, M_v, K_v, N_v),UVM_NONE)

      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      for(i=0; i<K_v*N_v; i=i+4) m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);
      for(i=0; i<M_v*N_v*4+64; i=i+4) m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);
      row_stride = row_stride_bytes(N_v);
      m_seq.axil_write32(32'h0001_FFE0, 32'hCAFE_BABE);
      m_seq.axil_write32(32'h0002_0000 + M_v * row_stride, 32'hFEED_F00D);

      m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
      m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
      m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
      m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
      m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
      m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
      m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
      m_seq.axil_write32(`NPU_REG_CONV_CFG,    32'h20);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);
      m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
      repeat(200000) begin
        m_seq.axil_read32(`NPU_REG_CTRL, rdata);
        if(rdata[2] || rdata[3]) break;
        #100;
      end

      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);
      levels_run++;
      if(rdata[3]) begin
        m_seq.axil_read32(`NPU_REG_STATUS, rdata);
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x cycles=%0d",
          lvl_name, rdata[7:0], cycle_lo))
      end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) begin
          for (c = 0; c < N_v; c = c + 1) begin
            m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
            if ($signed(rdata) != K_v) begin
              if (chk_errs < 5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), K_v))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE)
          `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D)
          `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))

        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: M=7 K=63 N=8 cycles=%0d mem_OK PASS", lvl_name, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // Final summary
    //=================================================================
    `uvm_info("TEST",$sformatf("ROW_STREAMING_ENHANCED: %0d/%0d levels PASS", levels_pass, levels_run),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
