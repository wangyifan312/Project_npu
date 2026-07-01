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
    //=================================================================
    // RS7a: negative A, positive B  (M=2,K=4,N=4)
    // A = [-1,-1,-1,-1] rows 0,1  B = [1,1,1,1]  →  C[m][n] = -4
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int expected_val;
      M_v=2; K_v=4; N_v=4;
      expected_val = -4;  // sum_k(-1 * 1) = 4 * (-1) = -4
      lvl_name = "RS7a";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d A=-1 B=1 expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_val),UVM_NONE)

      // A[m][k] = -1 = 0xFF
      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'hFFFFFFFF);
      // B[k][n] = 1 = 0x01
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
            if ($signed(rdata) != expected_val) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), expected_val))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: A=-1 B=1 cycles=%0d mem_OK PASS", lvl_name, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS7b: positive A, negative B  (M=2,K=4,N=4)
    // A = [1,1,1,1]  B = [-1,-1,-1,-1]  →  C[m][n] = -4
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int expected_val;
      M_v=2; K_v=4; N_v=4;
      expected_val = -4;
      lvl_name = "RS7b";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d A=1 B=-1 expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_val),UVM_NONE)

      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      for(i=0; i<K_v*N_v; i=i+4) m_seq.axil_write32(32'h0001_0000+i, 32'hFFFFFFFF);
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
            if ($signed(rdata) != expected_val) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), expected_val))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: A=1 B=-1 cycles=%0d mem_OK PASS", lvl_name, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS7c: mixed signs  (M=1,K=4,N=4)
    // A = [1, -1, 2, -2]  B = [1, 1, -1, -1]
    // C = 1*1 + (-1)*1 + 2*(-1) + (-2)*(-1) = 1 - 1 - 2 + 2 = 0
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int expected_val;
      M_v=1; K_v=4; N_v=4;
      expected_val = 0;
      lvl_name = "RS7c";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d A=[1,-1,2,-2] B=[1,1,-1,-1] expected C=0",
        lvl_name, M_v, K_v, N_v),UVM_NONE)

      // A[0][0..3] = [1, -1, 2, -2] = [0x01, 0xFF, 0x02, 0xFE]
      m_seq.axil_write32(32'h0000_0100, {8'hFE, 8'h02, 8'hFF, 8'h01});
      // B[0..3][0..3] each row repeated
      // B[0][0..3]=B[1][0..3]=B[2][0..3]=B[3][0..3] = [1, 1, -1, -1] = [0x01, 0x01, 0xFF, 0xFF]
      for(i=0; i<K_v*N_v; i=i+4) m_seq.axil_write32(32'h0001_0000+i, {8'hFF, 8'hFF, 8'h01, 8'h01});
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
            if ($signed(rdata) != expected_val) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), expected_val))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: mixed signs cycles=%0d mem_OK PASS", lvl_name, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS9: K>64 cross-chunk accumulation, M=8,K=128,N=8, all-1
    // 2 K-chunks: chunk0 k_base=0 K_tile=64, chunk1 k_base=64 K_tile=64
    // expected C[m][n] = 128
    //=================================================================
    begin
      int M_v, K_v, N_v, beats_per_row;
      int expected_chunks;
      M_v=8; K_v=128; N_v=8;
      beats_per_row = (N_v * 4 + 31) / 32;
      expected_chunks = (K_v + 63) / 64;
      lvl_name = "RS9";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d K-chunks=%0d expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_chunks, K_v),UVM_NONE)

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
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: K=%0d chunks=%0d cycles=%0d mem_OK PASS",
            lvl_name, K_v, expected_chunks, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: K=%0d mem_ERR=%0d FAIL", lvl_name, K_v, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS10: K=512, N=8, all-1 — 8 K-chunks stress test
    //=================================================================
    begin
      int M_v, K_v, N_v, beats_per_row;
      int expected_chunks;
      M_v=8; K_v=512; N_v=8;
      beats_per_row = (N_v * 4 + 31) / 32;
      expected_chunks = (K_v + 63) / 64;
      lvl_name = "RS10";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d K-chunks=%0d expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_chunks, K_v),UVM_NONE)

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
      repeat(800000) begin
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
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: K=%0d chunks=%0d cycles=%0d mem_OK PASS",
            lvl_name, K_v, expected_chunks, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: K=%0d mem_ERR=%0d FAIL", lvl_name, K_v, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS11: K=128, N=16, all-1 — K-chunk + multi-beat STORE
    //=================================================================
    begin
      int M_v, K_v, N_v, beats_per_row;
      int expected_chunks;
      M_v=8; K_v=128; N_v=16;
      beats_per_row = (N_v * 4 + 31) / 32;
      expected_chunks = (K_v + 63) / 64;
      lvl_name = "RS11";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d K-chunks=%0d beats/row=%0d expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_chunks, beats_per_row, K_v),UVM_NONE)

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
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: K=%0d N=%0d chunks=%0d beats/row=%0d write_beats=%0d cycles=%0d mem_OK PASS",
            lvl_name, K_v, N_v, expected_chunks, beats_per_row, M_v*beats_per_row, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS12: K=65 boundary, all-1 — K%64 != 0
    //=================================================================
    begin
      int M_v, K_v, N_v, beats_per_row;
      int expected_chunks;
      M_v=7; K_v=65; N_v=8;
      beats_per_row = (N_v * 4 + 31) / 32;
      expected_chunks = (K_v + 63) / 64;
      lvl_name = "RS12";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d K-chunks=%0d chunk1_k_tile=1 expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_chunks, K_v),UVM_NONE)

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
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: K=%0d chunks=%0d chunk1_k_tile=1 cycles=%0d mem_OK PASS",
            lvl_name, K_v, expected_chunks, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: K=%0d mem_ERR=%0d FAIL", lvl_name, K_v, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS13a: signed INT8 + K>64, A=-1, B=1, expected C[n] = -128
    //=================================================================
    begin
      int M_v, K_v, N_v, beats_per_row;
      int expected_chunks, expected_val;
      M_v=2; K_v=128; N_v=4;
      beats_per_row = (N_v * 4 + 31) / 32;
      expected_chunks = (K_v + 63) / 64;
      expected_val = -128;  // K * (-1*1) = 128 * (-1) = -128
      lvl_name = "RS13a";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d signed A=-1 B=1 expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_val),UVM_NONE)

      // A[m][k] = -1 = 0xFF
      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'hFFFFFFFF);
      // B[k][n] = 1 = 0x01
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
            if ($signed(rdata) != expected_val) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), expected_val))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: signed K=%0d chunks=%0d cycles=%0d mem_OK PASS",
            lvl_name, K_v, expected_chunks, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS13b: signed INT8 + K>64, A=-2, B=1, expected C=-256
    // Uniform signed pattern (all-same) to avoid act_dma K-chunk reload issue
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int expected_chunks, expected_val;
      M_v=2; K_v=128; N_v=4;
      expected_chunks = (K_v + 63) / 64;
      expected_val = -256;  // K * (-2)*1 = 128 * (-2) = -256
      lvl_name = "RS13b";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d signed A=-2 B=1 expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_val),UVM_NONE)

      // A[m][k] = -2 = 0xFE
      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'hFEFEFEFE);
      // B[k][n] = 1 = 0x01
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
            if ($signed(rdata) != expected_val) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), expected_val))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: signed K=%0d chunks=%0d cycles=%0d mem_OK PASS",
            lvl_name, K_v, expected_chunks, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
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
    // RS14: non-uniform A across K chunks
    // M=2 K=128 N=4  B=all-1
    // A: k=0..63=1  k=64..127=2
    // expected C = 64*1 + 64*2 = 192
    // If A_tile stale: C = 64*1 + 64*1 = 128 (wrong)
    //=================================================================
    begin
      int M_v, K_v, N_v, beats_per_row;
      int expected_chunks, expected_val;
      int k;
      M_v=2; K_v=128; N_v=4;
      beats_per_row = (N_v * 4 + 31) / 32;
      expected_chunks = (K_v + 63) / 64;
      expected_val = 192;  // 64*1 + 64*2 = 192
      lvl_name = "RS14";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d non-uniform A expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_val),UVM_NONE)

      // Row 0, k=0..63 = 1: addresses 0x100..0x13F
      for(k=0; k<64; k=k+4) m_seq.axil_write32(32'h0000_0100 + k, 32'h01010101);
      // Row 0, k=64..127 = 2: addresses 0x140..0x17F
      for(k=0; k<64; k=k+4) m_seq.axil_write32(32'h0000_0140 + k, 32'h02020202);
      // Row 1, k=0..63 = 1: addresses 0x180..0x1BF (input_addr + K)
      for(k=0; k<64; k=k+4) m_seq.axil_write32(32'h0000_0180 + k, 32'h01010101);
      // Row 1, k=64..127 = 2: addresses 0x1C0..0x1FF
      for(k=0; k<64; k=k+4) m_seq.axil_write32(32'h0000_01C0 + k, 32'h02020202);
      // B[k][n] = 1 = 0x01
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
            if ($signed(rdata) != expected_val) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), expected_val))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: non-uniform A K=%0d chunks=%0d cycles=%0d mem_OK PASS",
            lvl_name, K_v, expected_chunks, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS15: K=65 boundary A reload
    // M=2 K=65 N=4  B=all-1
    // A: k=0..63=1  k=64=7
    // expected C = 64*1 + 7 = 71
    // Verifies last K_tile=1 correctly reloads A.
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int expected_chunks, expected_val;
      int k;
      M_v=2; K_v=65; N_v=4;
      expected_chunks = (K_v + 63) / 64;
      expected_val = 71;  // 64*1 + 7 = 71
      lvl_name = "RS15";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d boundary K%%64=1 expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_val),UVM_NONE)

      // A[m][k]: k=0..63=1  k=64=7  (K=65 per row)
      // Row 0: bytes 0..63 = 1 at addr 0x100..0x13F
      for(k=0; k<64; k=k+4) m_seq.axil_write32(32'h0000_0100 + k, 32'h01010101);
      // Row 0 byte 64 = 7 + Row 1 bytes 0..2 = 1 at addr 0x140
      m_seq.axil_write32(32'h0000_0140, 32'h01010107);
      // Row 1 bytes 3..62 = 1 at addr 0x144..0x17F
      for(k=4; k<64; k=k+4) m_seq.axil_write32(32'h0000_0140 + k, 32'h01010101);
      // Row 1 bytes 63=1, 64=7 at addr 0x180
      m_seq.axil_write32(32'h0000_0180, 32'h00000701);
      // B[k][n] = 1 = 0x01
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
            if ($signed(rdata) != expected_val) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), expected_val))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: boundary K=%0d K%%64=1 chunks=%0d cycles=%0d mem_OK PASS",
            lvl_name, K_v, expected_chunks, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS16: signed non-uniform A across K chunks
    // M=2 K=128 N=4  B=all-1
    // A: k=0..63=1  k=64..127=-1
    // expected C = 64*1 + 64*(-1) = 0
    // Verifies signed non-uniform A reload.
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int expected_chunks, expected_val;
      int k;
      M_v=2; K_v=128; N_v=4;
      expected_chunks = (K_v + 63) / 64;
      expected_val = 0;  // 64*1 + 64*(-1) = 0
      lvl_name = "RS16";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d signed non-uniform A expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_val),UVM_NONE)

      // Row 0, k=0..63 = 1 (0x01): addresses 0x100..0x13F
      for(k=0; k<64; k=k+4) m_seq.axil_write32(32'h0000_0100 + k, 32'h01010101);
      // Row 0, k=64..127 = -1 (0xFF): addresses 0x140..0x17F
      for(k=0; k<64; k=k+4) m_seq.axil_write32(32'h0000_0140 + k, 32'hFFFFFFFF);
      // Row 1, k=0..63 = 1: addresses 0x180..0x1BF
      for(k=0; k<64; k=k+4) m_seq.axil_write32(32'h0000_0180 + k, 32'h01010101);
      // Row 1, k=64..127 = -1: addresses 0x1C0..0x1FF
      for(k=0; k<64; k=k+4) m_seq.axil_write32(32'h0000_01C0 + k, 32'hFFFFFFFF);
      // B[k][n] = 1 = 0x01
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
            if ($signed(rdata) != expected_val) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), expected_val))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: signed non-uniform A K=%0d chunks=%0d cycles=%0d mem_OK PASS",
            lvl_name, K_v, expected_chunks, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS17: non-uniform B across K chunks
    // M=2 K=128 N=4  A=all-1
    // B: k=0..63=1  k=64..127=2
    // expected C = 64*1*1 + 64*2*1 = 64 + 128 = 192
    // If weight k_base wrong: C = 64*1 + 64*1 = 128
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int expected_chunks, expected_val;
      int k;
      M_v=2; K_v=128; N_v=4;
      expected_chunks = (K_v + 63) / 64;
      expected_val = 192;
      lvl_name = "RS17";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d non-uniform B expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_val),UVM_NONE)

      // A[m][k] = 1
      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      // B: k=0..63=1, k=64..127=2
      // Row-major: B[0..63][n]=1, B[64..127][n]=2
      for(k=0; k<64*N_v; k=k+4) m_seq.axil_write32(32'h0001_0000 + k, 32'h01010101);
      for(k=64*N_v; k<K_v*N_v; k=k+4) m_seq.axil_write32(32'h0001_0000 + k, 32'h02020202);
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
            if ($signed(rdata) != expected_val) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), expected_val))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: non-uniform B K=%0d chunks=%0d cycles=%0d mem_OK PASS",
            lvl_name, K_v, expected_chunks, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS18: signed canceling B across K chunks
    // M=2 K=128 N=4  A=all-1
    // B: k=0..63=1  k=64..127=-1
    // expected C = 64*1*1 + 64*(-1)*1 = 0
    // If weight k_base wrong: C = 128
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int expected_chunks, expected_val;
      int k;
      M_v=2; K_v=128; N_v=4;
      expected_chunks = (K_v + 63) / 64;
      expected_val = 0;
      lvl_name = "RS18";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d signed canceling B expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_val),UVM_NONE)

      // A[m][k] = 1
      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      // B: k=0..63=1, k=64..127=-1 (0xFF)
      for(k=0; k<64*N_v; k=k+4) m_seq.axil_write32(32'h0001_0000 + k, 32'h01010101);
      for(k=64*N_v; k<K_v*N_v; k=k+4) m_seq.axil_write32(32'h0001_0000 + k, 32'hFFFFFFFF);
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
            if ($signed(rdata) != expected_val) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), expected_val))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: signed canceling B K=%0d chunks=%0d cycles=%0d mem_OK PASS",
            lvl_name, K_v, expected_chunks, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // RS19: K=65 B boundary
    // M=2 K=65 N=4  A=all-1
    // B: k=0..63=1  k=64=7
    // expected C = 64*1 + 7 = 71
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int expected_chunks, expected_val;
      int k;
      M_v=2; K_v=65; N_v=4;
      expected_chunks = (K_v + 63) / 64;
      expected_val = 71;
      lvl_name = "RS19";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d B boundary K%%64=1 expected C=%0d",
        lvl_name, M_v, K_v, N_v, expected_val),UVM_NONE)

      // A[m][k] = 1
      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      // B: k=0..63=1, k=64=7
      for(k=0; k<64*N_v; k=k+4) m_seq.axil_write32(32'h0001_0000 + k, 32'h01010101);
      // k=64: one byte per output col = 7
      m_seq.axil_write32(32'h0001_0000 + 64*N_v, {8'd7, 8'd7, 8'd7, 8'd7});
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
            if ($signed(rdata) != expected_val) begin
              if (chk_errs < 8) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), expected_val))
              chk_errs++;
            end
          end
        end
        m_seq.axil_read32(32'h0001_FFE0, rdata);
        if (rdata != 32'hCAFE_BABE) `uvm_error("TEST",$sformatf("%s pre-guard corrupted: 0x%08x", lvl_name, rdata))
        m_seq.axil_read32(32'h0002_0000 + M_v * row_stride, rdata);
        if (rdata != 32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted: 0x%08x", lvl_name, rdata))
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: B boundary K=%0d K%%64=1 chunks=%0d cycles=%0d mem_OK PASS",
            lvl_name, K_v, expected_chunks, cycle_lo),UVM_NONE)
          levels_pass++;
        end else begin
          `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
        end
      end
    end

    //=================================================================
    // Phase 5-1: M-tiling tests
    //=================================================================

    // MT0: M tiling basic (M=16, K=64, N=8, A=1, B=1)
    begin
      int M_v, K_v, N_v;
      M_v=16; K_v=64; N_v=8;
      lvl_name = "MT0";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d M-tiling basic expected C=%0d",
        lvl_name, M_v, K_v, N_v, K_v),UVM_NONE)
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
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x", lvl_name, rdata[7:0]))
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
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d cycles=%0d mem_OK PASS",
            lvl_name, M_v, K_v, cycle_lo),UVM_NONE)
          levels_pass++;
        end else `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
      end
    end

    // MT1: M tiling + K chunks (M=16, K=128, N=8)
    begin
      int M_v, K_v, N_v;
      M_v=16; K_v=128; N_v=8;
      lvl_name = "MT1";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d M+K tiling expected C=%0d",
        lvl_name, M_v, K_v, N_v, K_v),UVM_NONE)
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
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x", lvl_name, rdata[7:0]))
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
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: M+K tiling cycles=%0d mem_OK PASS", lvl_name, cycle_lo),UVM_NONE)
          levels_pass++;
        end else `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
      end
    end

    // MT2: M boundary (M=9, K=64, N=8)
    begin
      int M_v, K_v, N_v;
      M_v=9; K_v=64; N_v=8;
      lvl_name = "MT2";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d M boundary expected C=%0d",
        lvl_name, M_v, K_v, N_v, K_v),UVM_NONE)
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
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x", lvl_name, rdata[7:0]))
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
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: M boundary cycles=%0d mem_OK PASS", lvl_name, cycle_lo),UVM_NONE)
          levels_pass++;
        end else `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
      end
    end

    //=================================================================
    // MT3: M tiling + non-uniform A by row
    // M=16, K=64, N=4, B=all-1, A[m][k] = m+1
    // Expected C[m][n] = 64 * (m+1)
    // Verifies A global row offset (tile_m_base + local_row)
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int m, k;
      M_v=16; K_v=64; N_v=4;
      lvl_name = "MT3";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d A[m][k]=m+1", lvl_name, M_v, K_v, N_v),UVM_NONE)
      // A[m][k] = m+1. Write 4 bytes at a time.
      for(m=0; m<M_v; m=m+1) begin
        for(k=0; k<K_v; k=k+4) begin
          automatic integer val = (m+1) | ((m+1) << 8) | ((m+1) << 16) | ((m+1) << 24);
          m_seq.axil_write32(32'h0000_0100 + m*K_v + k, val);
        end
      end
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
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x", lvl_name, rdata[7:0]))
      end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) begin
          for (c = 0; c < N_v; c = c + 1) begin
            m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
            if ($signed(rdata) != 64 * (r + 1)) begin
              if (chk_errs < 5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                lvl_name, r, c, $signed(rdata), 64*(r+1)))
              chk_errs++;
            end
          end
        end
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: A-by-row M-tiling cycles=%0d mem_OK PASS", lvl_name, cycle_lo),UVM_NONE)
          levels_pass++;
        end else `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
      end
    end

    //=================================================================
    // MT4: M tiling + non-uniform B chunks
    // M=16, K=128, N=4, A=all-1
    // B: k=0..63=1, k=64..127=2
    // Expected C = 192
    // Verifies K-chunk B address per M tile
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int k;
      M_v=16; K_v=128; N_v=4;
      lvl_name = "MT4";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d non-uniform B M-tiling expected C=192",
        lvl_name, M_v, K_v, N_v),UVM_NONE)
      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      // B: k=0..63=1, k=64..127=2 (K-major)
      for(k=0; k<64*N_v; k=k+4) m_seq.axil_write32(32'h0001_0000 + k, 32'h01010101);
      for(k=64*N_v; k<K_v*N_v; k=k+4) m_seq.axil_write32(32'h0001_0000 + k, 32'h02020202);
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
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x", lvl_name, rdata[7:0]))
      end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) begin
          for (c = 0; c < N_v; c = c + 1) begin
            m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
            if ($signed(rdata) != 192) begin
              if (chk_errs < 5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected 192",
                lvl_name, r, c, $signed(rdata)))
              chk_errs++;
            end
          end
        end
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: non-uniform B M-tiling cycles=%0d mem_OK PASS", lvl_name, cycle_lo),UVM_NONE)
          levels_pass++;
        end else `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
      end
    end

    //=================================================================
    // MT5: signed M tiling + M boundary
    // M=9, K=128, N=4, A=all-1
    // B: k=0..63=1, k=64..127=-1
    // Expected C = 0
    // Verifies signed + K chunks + M boundary (tile1 M=1)
    //=================================================================
    begin
      int M_v, K_v, N_v;
      int k;
      M_v=9; K_v=128; N_v=4;
      lvl_name = "MT5";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d signed M-tiling expected C=0",
        lvl_name, M_v, K_v, N_v),UVM_NONE)
      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      // B: k=0..63=1, k=64..127=-1
      for(k=0; k<64*N_v; k=k+4) m_seq.axil_write32(32'h0001_0000 + k, 32'h01010101);
      for(k=64*N_v; k<K_v*N_v; k=k+4) m_seq.axil_write32(32'h0001_0000 + k, 32'hFFFFFFFF);
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
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x", lvl_name, rdata[7:0]))
      end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) begin
          for (c = 0; c < N_v; c = c + 1) begin
            m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
            if ($signed(rdata) != 0) begin
              if (chk_errs < 5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d expected 0",
                lvl_name, r, c, $signed(rdata)))
              chk_errs++;
            end
          end
        end
        if (chk_errs == 0) begin
          `uvm_info("TEST",$sformatf("%s: signed M-tiling cycles=%0d mem_OK PASS", lvl_name, cycle_lo),UVM_NONE)
          levels_pass++;
        end else `uvm_info("TEST",$sformatf("%s: mem_ERR=%0d FAIL", lvl_name, chk_errs),UVM_NONE)
      end
    end

    //=================================================================
    // Phase 5-2: N-tiling tests
    //=================================================================

    // NT0: N tiling basic (M=8, K=64, N=128, all-1)
    begin
      int M_v, K_v, N_v;
      M_v=8; K_v=64; N_v=128;
      lvl_name = "NT0";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d N-tiling basic", lvl_name, M_v, K_v, N_v),UVM_NONE)
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
      repeat(400000) begin m_seq.axil_read32(`NPU_REG_CTRL, rdata); if(rdata[2]||rdata[3]) break; #100; end
      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo); levels_run++;
      if(rdata[3]) begin `uvm_error("TEST",$sformatf("%s ERROR", lvl_name)) end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) for (c = 0; c < N_v; c = c + 1) begin
          m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
          if ($signed(rdata) != K_v) begin if(chk_errs<5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d", lvl_name,r,c,$signed(rdata))) chk_errs++; end
        end
        if(chk_errs==0) begin `uvm_info("TEST",$sformatf("%s: N=%0d cycles=%0d PASS",lvl_name,N_v,cycle_lo),UVM_NONE) levels_pass++; end
        else `uvm_info("TEST",$sformatf("%s: ERR=%0d FAIL",lvl_name,chk_errs),UVM_NONE)
      end
    end

    // NT1: N boundary (M=8, K=64, N=65, all-1)
    begin
      int M_v, K_v, N_v;
      M_v=8; K_v=64; N_v=65;
      lvl_name = "NT1";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d N boundary", lvl_name, M_v, K_v, N_v),UVM_NONE)
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
      repeat(400000) begin m_seq.axil_read32(`NPU_REG_CTRL, rdata); if(rdata[2]||rdata[3]) break; #100; end
      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo); levels_run++;
      if(rdata[3]) begin `uvm_error("TEST",$sformatf("%s ERROR", lvl_name)) end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) for (c = 0; c < N_v; c = c + 1) begin
          m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
          if ($signed(rdata) != K_v) begin if(chk_errs<5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d", lvl_name,r,c,$signed(rdata))) chk_errs++; end
        end
        // Verify guard: col 65 should still be DEADBEEF
        m_seq.axil_read32(32'h0002_0000 + 0*row_stride + 65*4, rdata);
        if(rdata==32'hDEADBEEF) `uvm_info("TEST",$sformatf("%s guard OK",lvl_name),UVM_NONE)
        else `uvm_error("TEST",$sformatf("%s guard corrupted at col65",lvl_name))
        if(chk_errs==0) begin `uvm_info("TEST",$sformatf("%s: N=%0d cycles=%0d PASS",lvl_name,N_v,cycle_lo),UVM_NONE) levels_pass++; end
        else `uvm_info("TEST",$sformatf("%s: ERR=%0d FAIL",lvl_name,chk_errs),UVM_NONE)
      end
    end

    // NT3: non-uniform B by global column (M=8, K=64, N=128, B[k][n]=n+1)
    begin
      int M_v, K_v, N_v;
      M_v=8; K_v=64; N_v=128;
      lvl_name = "NT3";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d B[k][n]=n+1", lvl_name, M_v, K_v, N_v),UVM_NONE)
      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      // B[k][n] = (n % 64)+1, fits signed INT8 range 1..64
      for(i=0; i<K_v*N_v; i=i+4) begin
        automatic integer n0 = ((i % N_v) % 64) + 1;
        automatic integer n1 = (((i+1) % N_v) % 64) + 1;
        automatic integer n2 = (((i+2) % N_v) % 64) + 1;
        automatic integer n3 = (((i+3) % N_v) % 64) + 1;
        m_seq.axil_write32(32'h0001_0000+i, n0 | (n1<<8) | (n2<<16) | (n3<<24));
      end
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
      repeat(400000) begin m_seq.axil_read32(`NPU_REG_CTRL, rdata); if(rdata[2]||rdata[3]) break; #100; end
      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo); levels_run++;
      if(rdata[3]) begin `uvm_error("TEST",$sformatf("%s ERROR", lvl_name)) end else begin
        chk_errs = 0;
        for (r = 0; r < M_v; r = r + 1) for (c = 0; c < N_v; c = c + 1) begin
          m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
          if ($signed(rdata) != 64 * ((c % 64) + 1)) begin if(chk_errs<5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d exp %0d", lvl_name,r,c,$signed(rdata),64*((c%64)+1))) chk_errs++; end
        end
        if(chk_errs==0) begin `uvm_info("TEST",$sformatf("%s: B-by-col cycles=%0d PASS",lvl_name,cycle_lo),UVM_NONE) levels_pass++; end
        else `uvm_info("TEST",$sformatf("%s: ERR=%0d FAIL",lvl_name,chk_errs),UVM_NONE)
      end
    end

    // NT2: N tiling + K chunks (M=8, K=128, N=128, all-1)
    begin
      int M_v, K_v, N_v; M_v=8; K_v=128; N_v=128; lvl_name="NT2";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d N+K tiling",lvl_name,M_v,K_v,N_v),UVM_NONE)
      for(i=0;i<M_v*K_v;i=i+4) m_seq.axil_write32(32'h0000_0100+i,32'h01010101);
      for(i=0;i<K_v*N_v;i=i+4) m_seq.axil_write32(32'h0001_0000+i,32'h01010101);
      for(i=0;i<M_v*N_v*4+128;i=i+4) m_seq.axil_write32(32'h0002_0000+i,32'hDEADBEEF);
      row_stride=row_stride_bytes(N_v); m_seq.axil_write32(32'h0001_FFE0,32'hCAFE_BABE);
      m_seq.axil_write32(32'h0002_0000+M_v*row_stride,32'hFEED_F00D);
      m_seq.axil_write32(`NPU_REG_TASK_TYPE,32'd7); m_seq.axil_write32(`NPU_REG_INPUT_ADDR,32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,32'h0001_0000); m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,M_v*K_v); m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES,K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES,M_v*N_v*4); m_seq.axil_write32(`NPU_REG_DIM_IN,{16'd1,M_v[15:0]});
      m_seq.axil_write32(`NPU_REG_DIM_OUT,{N_v[15:0],K_v[15:0]}); m_seq.axil_write32(`NPU_REG_POSTPROC,32'd0);
      m_seq.axil_write32(`NPU_REG_CONV_CFG,32'h20); m_seq.axil_write32(`NPU_REG_CLUSTER_MODE,32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK,32'd1); m_seq.axil_write32(`NPU_REG_CTRL,32'd1);
      repeat(400000) begin m_seq.axil_read32(`NPU_REG_CTRL,rdata); if(rdata[2]||rdata[3]) break; #100; end
      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO,cycle_lo); levels_run++;
      if(rdata[3]) begin `uvm_error("TEST",$sformatf("%s ERROR",lvl_name)) end else begin
        chk_errs=0; for(r=0;r<M_v;r=r+1) for(c=0;c<N_v;c=c+1) begin
          m_seq.axil_read32(32'h0002_0000+r*row_stride+c*4,rdata);
          if($signed(rdata)!=K_v) begin if(chk_errs<5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d",lvl_name,r,c,$signed(rdata))) chk_errs++; end
        end
        if(chk_errs==0) begin `uvm_info("TEST",$sformatf("%s: N+K tiling cycles=%0d PASS",lvl_name,cycle_lo),UVM_NONE) levels_pass++; end
        else `uvm_info("TEST",$sformatf("%s: ERR=%0d FAIL",lvl_name,chk_errs),UVM_NONE)
      end
    end

    // NT4: M + N tiling combined (M=16, K=64, N=128, A[m][k]=m+1, B=1)
    begin
      int M_v,K_v,N_v,m,k; M_v=16; K_v=64; N_v=128; lvl_name="NT4";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d M+N tiling",lvl_name,M_v,K_v,N_v),UVM_NONE)
      for(m=0;m<M_v;m=m+1) for(k=0;k<K_v;k=k+4) begin
        automatic integer val = (m+1)|((m+1)<<8)|((m+1)<<16)|((m+1)<<24);
        m_seq.axil_write32(32'h0000_0100+m*K_v+k,val);
      end
      for(i=0;i<K_v*N_v;i=i+4) m_seq.axil_write32(32'h0001_0000+i,32'h01010101);
      for(i=0;i<M_v*N_v*4+128;i=i+4) m_seq.axil_write32(32'h0002_0000+i,32'hDEADBEEF);
      row_stride=row_stride_bytes(N_v); m_seq.axil_write32(32'h0001_FFE0,32'hCAFE_BABE);
      m_seq.axil_write32(32'h0002_0000+M_v*row_stride,32'hFEED_F00D);
      m_seq.axil_write32(`NPU_REG_TASK_TYPE,32'd7); m_seq.axil_write32(`NPU_REG_INPUT_ADDR,32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,32'h0001_0000); m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,M_v*K_v); m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES,K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES,M_v*N_v*4); m_seq.axil_write32(`NPU_REG_DIM_IN,{16'd1,M_v[15:0]});
      m_seq.axil_write32(`NPU_REG_DIM_OUT,{N_v[15:0],K_v[15:0]}); m_seq.axil_write32(`NPU_REG_POSTPROC,32'd0);
      m_seq.axil_write32(`NPU_REG_CONV_CFG,32'h20); m_seq.axil_write32(`NPU_REG_CLUSTER_MODE,32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK,32'd1); m_seq.axil_write32(`NPU_REG_CTRL,32'd1);
      repeat(400000) begin m_seq.axil_read32(`NPU_REG_CTRL,rdata); if(rdata[2]||rdata[3]) break; #100; end
      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO,cycle_lo); levels_run++;
      if(rdata[3]) begin `uvm_error("TEST",$sformatf("%s ERROR",lvl_name)) end else begin
        chk_errs=0; for(r=0;r<M_v;r=r+1) for(c=0;c<N_v;c=c+1) begin
          m_seq.axil_read32(32'h0002_0000+r*row_stride+c*4,rdata);
          if($signed(rdata)!=64*(r+1)) begin if(chk_errs<5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d exp %0d",lvl_name,r,c,$signed(rdata),64*(r+1))) chk_errs++; end
        end
        if(chk_errs==0) begin `uvm_info("TEST",$sformatf("%s: M+N tiling cycles=%0d PASS",lvl_name,cycle_lo),UVM_NONE) levels_pass++; end
        else `uvm_info("TEST",$sformatf("%s: ERR=%0d FAIL",lvl_name,chk_errs),UVM_NONE)
      end
    end

    // NT5: M+N+K chunks + non-uniform B (M=16, K=128, N=128, A=1, B:k<64=1,k>=64=2)
    begin
      int M_v,K_v,N_v,k; M_v=16; K_v=128; N_v=128; lvl_name="NT5";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d M+N+K tiling",lvl_name,M_v,K_v,N_v),UVM_NONE)
      for(i=0;i<M_v*K_v;i=i+4) m_seq.axil_write32(32'h0000_0100+i,32'h01010101);
      for(k=0;k<64*N_v;k=k+4) m_seq.axil_write32(32'h0001_0000+k,32'h01010101);
      for(k=64*N_v;k<K_v*N_v;k=k+4) m_seq.axil_write32(32'h0001_0000+k,32'h02020202);
      for(i=0;i<M_v*N_v*4+128;i=i+4) m_seq.axil_write32(32'h0002_0000+i,32'hDEADBEEF);
      row_stride=row_stride_bytes(N_v); m_seq.axil_write32(32'h0001_FFE0,32'hCAFE_BABE);
      m_seq.axil_write32(32'h0002_0000+M_v*row_stride,32'hFEED_F00D);
      m_seq.axil_write32(`NPU_REG_TASK_TYPE,32'd7); m_seq.axil_write32(`NPU_REG_INPUT_ADDR,32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,32'h0001_0000); m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,M_v*K_v); m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES,K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES,M_v*N_v*4); m_seq.axil_write32(`NPU_REG_DIM_IN,{16'd1,M_v[15:0]});
      m_seq.axil_write32(`NPU_REG_DIM_OUT,{N_v[15:0],K_v[15:0]}); m_seq.axil_write32(`NPU_REG_POSTPROC,32'd0);
      m_seq.axil_write32(`NPU_REG_CONV_CFG,32'h20); m_seq.axil_write32(`NPU_REG_CLUSTER_MODE,32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK,32'd1); m_seq.axil_write32(`NPU_REG_CTRL,32'd1);
      repeat(400000) begin m_seq.axil_read32(`NPU_REG_CTRL,rdata); if(rdata[2]||rdata[3]) break; #100; end
      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO,cycle_lo); levels_run++;
      if(rdata[3]) begin `uvm_error("TEST",$sformatf("%s ERROR",lvl_name)) end else begin
        chk_errs=0; for(r=0;r<M_v;r=r+1) for(c=0;c<N_v;c=c+1) begin
          m_seq.axil_read32(32'h0002_0000+r*row_stride+c*4,rdata);
          if($signed(rdata)!=192) begin if(chk_errs<5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d",lvl_name,r,c,$signed(rdata))) chk_errs++; end
        end
        if(chk_errs==0) begin `uvm_info("TEST",$sformatf("%s: M+N+K tiling cycles=%0d PASS",lvl_name,cycle_lo),UVM_NONE) levels_pass++; end
        else `uvm_info("TEST",$sformatf("%s: ERR=%0d FAIL",lvl_name,chk_errs),UVM_NONE)
      end
    end

    // NT6: signed N tiling boundary (M=9, K=128, N=65, A=1, B:k<64=1,k>=64=-1)
    begin
      int M_v,K_v,N_v,k; M_v=9; K_v=128; N_v=65; lvl_name="NT6";
      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d signed boundary",lvl_name,M_v,K_v,N_v),UVM_NONE)
      for(i=0;i<M_v*K_v;i=i+4) m_seq.axil_write32(32'h0000_0100+i,32'h01010101);
      for(k=0;k<64*N_v;k=k+4) m_seq.axil_write32(32'h0001_0000+k,32'h01010101);
      for(k=64*N_v;k<K_v*N_v;k=k+4) m_seq.axil_write32(32'h0001_0000+k,32'hFFFFFFFF);
      for(i=0;i<M_v*N_v*4+128;i=i+4) m_seq.axil_write32(32'h0002_0000+i,32'hDEADBEEF);
      row_stride=row_stride_bytes(N_v); m_seq.axil_write32(32'h0001_FFE0,32'hCAFE_BABE);
      m_seq.axil_write32(32'h0002_0000+M_v*row_stride,32'hFEED_F00D);
      m_seq.axil_write32(`NPU_REG_TASK_TYPE,32'd7); m_seq.axil_write32(`NPU_REG_INPUT_ADDR,32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,32'h0001_0000); m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,M_v*K_v); m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES,K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES,M_v*N_v*4); m_seq.axil_write32(`NPU_REG_DIM_IN,{16'd1,M_v[15:0]});
      m_seq.axil_write32(`NPU_REG_DIM_OUT,{N_v[15:0],K_v[15:0]}); m_seq.axil_write32(`NPU_REG_POSTPROC,32'd0);
      m_seq.axil_write32(`NPU_REG_CONV_CFG,32'h20); m_seq.axil_write32(`NPU_REG_CLUSTER_MODE,32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK,32'd1); m_seq.axil_write32(`NPU_REG_CTRL,32'd1);
      repeat(400000) begin m_seq.axil_read32(`NPU_REG_CTRL,rdata); if(rdata[2]||rdata[3]) break; #100; end
      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO,cycle_lo); levels_run++;
      if(rdata[3]) begin `uvm_error("TEST",$sformatf("%s ERROR",lvl_name)) end else begin
        chk_errs=0; for(r=0;r<M_v;r=r+1) for(c=0;c<N_v;c=c+1) begin
          m_seq.axil_read32(32'h0002_0000+r*row_stride+c*4,rdata);
          if($signed(rdata)!=0) begin if(chk_errs<5) `uvm_error("TEST",$sformatf("%s C[%0d][%0d]=%0d",lvl_name,r,c,$signed(rdata))) chk_errs++; end
        end
        m_seq.axil_read32(32'h0002_0000+M_v*row_stride,rdata);
        if(rdata!=32'hFEED_F00D) `uvm_error("TEST",$sformatf("%s post-guard corrupted",lvl_name))
        if(chk_errs==0) begin `uvm_info("TEST",$sformatf("%s: signed boundary cycles=%0d PASS",lvl_name,cycle_lo),UVM_NONE) levels_pass++; end
        else `uvm_info("TEST",$sformatf("%s: ERR=%0d FAIL",lvl_name,chk_errs),UVM_NONE)
      end
    end

    //=================================================================
    // Final summary
    //=================================================================
    `uvm_info("TEST",$sformatf("ROW_STREAMING_ENHANCED: %0d/%0d levels PASS", levels_pass, levels_run),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
