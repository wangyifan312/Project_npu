//=============================================================================
// npu_task_gemm_row_streaming_test.sv — Phase 2b-1: Row-streaming GEMM
// No STORE — verification via RTL c_tile values printed to log
//=============================================================================
`timescale 1ns / 1ps

class npu_task_gemm_row_streaming_test extends soc_base_test;
  `uvm_component_utils(npu_task_gemm_row_streaming_test)
  function new(string name="npu_task_gemm_row_streaming_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq m_seq;
    bit [31:0] rdata, cycle_lo;
    int M_arr[4], K_arr[4], N_arr[4];
    int M_v, K_v, N_v, lvl, i, levels_run;
    string lvl_name;

    phase.raise_objection(this);
    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);
    #200;

    M_arr[0]=4;  K_arr[0]=4;  N_arr[0]=4;   // RS0
    M_arr[1]=8;  K_arr[1]=8;  N_arr[1]=8;   // RS1
    M_arr[2]=8;  K_arr[2]=16; N_arr[2]=8;   // RS2
    M_arr[3]=8;  K_arr[3]=64; N_arr[3]=8;   // RS3

    `uvm_info("TEST","=== TASK_GEMM_ROW_STREAMING ===",UVM_NONE)

    for (lvl=0; lvl<4; lvl++) begin
      M_v = M_arr[lvl]; K_v = K_arr[lvl]; N_v = N_arr[lvl];
      lvl_name = $sformatf("RS%0d", lvl);

      `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d expected C=%0d",
        lvl_name, M_v, K_v, N_v, K_v),UVM_NONE)

      // Preload A[M×K] all-1
      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      // Preload B[K×N] all-1
      for(i=0; i<K_v*N_v; i=i+4) m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);
      // Clear output
      for(i=0; i<M_v*N_v*4; i=i+4) m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);

      // Config: TASK_GEMM=7, conv_cfg[5]=1 → row_streaming_en
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
      m_seq.axil_write32(`NPU_REG_CONV_CFG,    32'h20);  // bit5=1 → row_streaming_en
      m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
      m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

      // Start/poll
      m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
      repeat(200000) begin
        m_seq.axil_read32(`NPU_REG_CTRL, rdata);
        if(rdata[2] || rdata[3]) break;
        #100;
      end

      m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);

      if(rdata[3]) begin
        m_seq.axil_read32(`NPU_REG_STATUS, rdata);
        `uvm_error("TEST",$sformatf("%s ERROR code=0x%02x cycles=%0d",
          lvl_name, rdata[7:0], cycle_lo))
        break;
      end else begin
        // Verify memory outputs from DMA writeback
        int row_stride, chk_errs, r, c;
        chk_errs = 0;
        row_stride = ((N_v*4 + 31) / 32) * 32;
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
        if (chk_errs == 0)
          `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d cycles=%0d mem_OK PASS",
            lvl_name, M_v, K_v, N_v, cycle_lo),UVM_NONE)
        else
          `uvm_info("TEST",$sformatf("%s: M=%0d K=%0d N=%0d cycles=%0d mem_ERR=%0d FAIL",
            lvl_name, M_v, K_v, N_v, cycle_lo, chk_errs),UVM_NONE)
      end
      levels_run = lvl+1;
    end

    `uvm_info("TEST",$sformatf("ROW_STREAMING: %0d/4 levels PASS", levels_run),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
