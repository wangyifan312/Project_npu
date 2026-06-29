//=============================================================================
// npu_task_gemm_func_test.sv — TASK_GEMM Functional Correctness
// STATUS: SUPPLEMENTAL — not primary TOPS evidence
//=============================================================================
`timescale 1ns / 1ps

class npu_task_gemm_func_test extends soc_base_test;
  `uvm_component_utils(npu_task_gemm_func_test)
  function new(string name="npu_task_gemm_func_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq m_seq;
    bit [31:0] rdata, cycle_lo;
    int M_v, K_v, N_v, lvl;
    int i, j, total_errs;
    int exp_val;
    int M_arr[6], K_arr[6], N_arr[6];
    int levels_run;

    phase.raise_objection(this);
    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);
    #200;

    // GEMM func levels: G0a,G0b,G0 + G1,G2,G3
    M_arr[0]=1;  K_arr[0]=4;   N_arr[0]=4;   // G0a
    M_arr[1]=2;  K_arr[1]=4;   N_arr[1]=4;   // G0b
    M_arr[2]=4;  K_arr[2]=4;   N_arr[2]=4;   // G0
    M_arr[3]=8;  K_arr[3]=64;  N_arr[3]=8;   // G1
    M_arr[4]=16; K_arr[4]=128; N_arr[4]=16;  // G2
    M_arr[5]=32; K_arr[5]=512; N_arr[5]=32;  // G3

    `uvm_info("TEST","=== TASK_GEMM_FUNC ===",UVM_NONE)

    for(lvl=0; lvl<6; lvl++) begin
      M_v=M_arr[lvl]; K_v=K_arr[lvl]; N_v=N_arr[lvl];
      exp_val=K_v; total_errs=0;
      if(lvl<3) `uvm_info("TEST",$sformatf("-- G0%0s: M=%0d K=%0d N=%0d expected=%0d --",
        lvl==0?"a":lvl==1?"b":"", M_v,K_v,N_v,exp_val),UVM_NONE)
      else `uvm_info("TEST",$sformatf("-- G%d: M=%0d K=%0d N=%0d expected=%0d --",
        lvl-2, M_v,K_v,N_v,exp_val),UVM_NONE)

      // Preload A[M×K] all-1
      for(i=0; i<M_v*K_v; i=i+4) m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
      // Preload B[K×N] all-1
      for(i=0; i<K_v*N_v; i=i+4) m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);
      // Clear output
      for(i=0; i<M_v*N_v*4; i=i+4) m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);

      // Config: TASK_GEMM=7
      m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
      m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
      m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
      m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
      m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
      m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
      m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
      m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});  // W=1, H=M
      m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]}); // C_OUT=N, C_IN=K
      m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
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
        `uvm_error("TEST",$sformatf("G%d ERROR code=0x%02x",lvl,rdata[7:0]))
        break;
      end

      // Check outputs (row stride = ceil(N*4/32)*32 for 32B-aligned DMA)
      begin
        int row_stride;
        row_stride = ((N_v*4 + 31) / 32) * 32;
        for(i=0; i<M_v; i++) begin
          for(j=0; j<N_v; j++) begin
            m_seq.axil_read32(32'h0002_0000 + i*row_stride + j*4, rdata);
          if($signed(rdata) != exp_val) begin
            if(total_errs<5) `uvm_error("TEST",$sformatf("G%0s C[%0d][%0d]=%0d expected %0d",
              lvl<3?(lvl==0?"0a":lvl==1?"0b":"0"):$sformatf("%0d",lvl-2), i,j,$signed(rdata),exp_val))
            total_errs++;
          end
          end
        end
      end

      if(lvl<3)
        `uvm_info("TEST",$sformatf("G0%0s: M=%0d K=%0d N=%0d cycles=%0d errors=%0d/%0d %s",
          lvl==0?"a":lvl==1?"b":"", M_v,K_v,N_v,cycle_lo,total_errs,M_v*N_v, (total_errs==0)?"PASS":"FAIL"),UVM_NONE)
      else
        `uvm_info("TEST",$sformatf("G%d: M=%0d K=%0d N=%0d cycles=%0d errors=%0d/%0d %s",
          lvl-2, M_v,K_v,N_v,cycle_lo,total_errs,M_v*N_v, (total_errs==0)?"PASS":"FAIL"),UVM_NONE)

      if(total_errs>0) break;
      levels_run=lvl+1;
    end
    `uvm_info("TEST",$sformatf("GEMM_FUNC: %0d/6 levels PASS",levels_run),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
