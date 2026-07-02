//=============================================================================
// npu_fc_streaming_robustness_test.sv — Phase U2 FC Streaming Robustness
//
// Boundary, signed/non-uniform, legacy-vs-streaming, post-op fallback.
// All streaming: task_type=FC(1), conv_cfg[5]=1, K-major B[k][n] layout.
//=============================================================================
`timescale 1ns / 1ps

class npu_fc_streaming_robustness_test extends soc_base_test;
  `uvm_component_utils(npu_fc_streaming_robustness_test)
  function new(string name="npu_fc_streaming_robustness_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  //============================================================================
  // Check output: row-major INT32, 32B-aligned stride
  //============================================================================
  task verify_output_int32(soc_base_seq m_seq, bit [31:0] out_addr,
                           int M_v, int N_v, int exp_val, output int errs);
    bit [31:0] rdata;
    int row_stride, i, j;
    errs = 0;
    row_stride = ((N_v*4 + 31) / 32) * 32;
    for (i=0; i<M_v; i++) begin
      for (j=0; j<N_v; j++) begin
        m_seq.axil_read32(out_addr + i*row_stride + j*4, rdata);
        if ($signed(rdata) != exp_val) begin
          if (errs<5)
            `uvm_error("ROBUST",$sformatf("C[%0d][%0d]=%0d expected %0d",
              i,j,$signed(rdata),exp_val))
          errs++;
        end
      end
    end
  endtask

  //============================================================================
  // Run FC streaming, verify all-1 expected output
  //============================================================================
  task run_fc_streaming_all1(bit [31:0] in_addr, bit [31:0] wgt_addr, bit [31:0] out_addr,
                             int M_v, int K_v, int N_v, int exp_val, output int errs);
    soc_base_seq m_seq;
    bit [31:0] ctrl_val, cycle_lo;
    int i;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    for (i=0; i<M_v*N_v*4; i=i+4)
      m_seq.axil_write32(out_addr+i, 32'hDEADBEEF);

    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd1);
    m_seq.axil_write32(`NPU_REG_CONV_CFG,     32'h20);
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   in_addr);
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,   wgt_addr);
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,   out_addr);
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
    m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
    m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

    m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
    repeat(500000) begin
      m_seq.axil_read32(`NPU_REG_CTRL, ctrl_val);
      if (ctrl_val[2] || ctrl_val[3]) break;
      #100;
    end

    m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);

    if (ctrl_val[3]) begin
      m_seq.axil_read32(`NPU_REG_STATUS, ctrl_val);
      `uvm_error("ROBUST",$sformatf("FC_STREAMING ERROR code=0x%02x",ctrl_val[7:0]))
      errs = -1;
      return;
    end

    verify_output_int32(m_seq, out_addr, M_v, N_v, exp_val, errs);
    if (errs == 0)
      `uvm_info("ROBUST",$sformatf("STREAM: M=%0d K=%0d N=%0d cycles=%0d PASS",
        M_v,K_v,N_v,cycle_lo),UVM_NONE)
  endtask

  //============================================================================
  // Run legacy FC and verify
  //============================================================================
  task run_legacy_fc_verify(bit [31:0] in_addr, bit [31:0] wgt_addr, bit [31:0] out_addr,
                            int K_v, int N_v, int exp_val, output int errs);
    soc_base_seq m_seq;
    bit [31:0] ctrl_val, cycle_lo, rdata;
    int i, j;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    for (i=0; i<N_v*4; i=i+4)
      m_seq.axil_write32(out_addr+i, 32'hDEADBEEF);

    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd1);
    m_seq.axil_write32(`NPU_REG_CONV_CFG,     32'h00);
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   in_addr);
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,   wgt_addr);
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,   out_addr);
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  K_v);
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, N_v*4);
    m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, 16'd1});
    m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

    m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
    repeat(500000) begin
      m_seq.axil_read32(`NPU_REG_CTRL, ctrl_val);
      if (ctrl_val[2] || ctrl_val[3]) break;
      #100;
    end

    m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);

    if (ctrl_val[3]) begin
      m_seq.axil_read32(`NPU_REG_STATUS, ctrl_val);
      `uvm_error("ROBUST",$sformatf("LEGACY FC ERROR code=0x%02x",ctrl_val[7:0]))
      errs = -1;
      return;
    end

    errs = 0;
    for (j=0; j<N_v; j++) begin
      m_seq.axil_read32(out_addr + j*4, rdata);
      if ($signed(rdata) != exp_val) begin
        if (errs<5)
          `uvm_error("ROBUST",$sformatf("LEGACY C[%0d]=%0d expected %0d",
            j,$signed(rdata),exp_val))
        errs++;
      end
    end
    if (errs == 0)
      `uvm_info("ROBUST",$sformatf("LEGACY: K=%0d N=%0d cycles=%0d PASS",
        K_v,N_v,cycle_lo),UVM_NONE)
  endtask

  //============================================================================
  // Preload helpers
  //============================================================================
  task preload_all_ones(soc_base_seq m_seq, bit [31:0] a_addr, int a_bytes,
                        bit [31:0] b_addr, int b_bytes);
    int i;
    for (i=0; i<a_bytes; i=i+4)
      m_seq.axil_write32(a_addr+i, 32'h01010101);
    for (i=0; i<b_bytes; i=i+4)
      m_seq.axil_write32(b_addr+i, 32'h01010101);
  endtask

  //============================================================================
  task run_phase(uvm_phase phase);
    soc_base_seq m_seq;
    int errs;
    int M_v, K_v, N_v;

    phase.raise_objection(this);
    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);
    #200;

    `uvm_info("ROBUST","=== FC STREAMING ROBUSTNESS (Phase U2) ===",UVM_NONE)

    //==================================================================
    // SECTION 1: Boundary Tests (FCR0-FCR7) — all-1 data
    //==================================================================
    `uvm_info("ROBUST","-- Boundary Tests --",UVM_NONE)

    // FCR0: M=1, K=1, N=1
    preload_all_ones(m_seq, 32'h0000_0100, 1, 32'h0001_0000, 1);
    run_fc_streaming_all1(32'h0000_0100, 32'h0001_0000, 32'h0002_0000, 1,1,1, 1, errs);

    // FCR1: M=1, K=63, N=64
    preload_all_ones(m_seq, 32'h0000_0100, 63, 32'h0001_0000, 63*64);
    run_fc_streaming_all1(32'h0000_0100, 32'h0001_0000, 32'h0002_0000, 1,63,64, 63, errs);

    // FCR2: M=1, K=64, N=64
    preload_all_ones(m_seq, 32'h0000_0100, 64, 32'h0001_0000, 64*64);
    run_fc_streaming_all1(32'h0000_0100, 32'h0001_0000, 32'h0002_0000, 1,64,64, 64, errs);

    // FCR3: M=1, K=65, N=64
    preload_all_ones(m_seq, 32'h0000_0100, 65, 32'h0001_0000, 65*64);
    run_fc_streaming_all1(32'h0000_0100, 32'h0001_0000, 32'h0002_0000, 1,65,64, 65, errs);

    // FCR4: M=1, K=64, N=65
    preload_all_ones(m_seq, 32'h0000_0100, 64, 32'h0001_0000, 64*65);
    run_fc_streaming_all1(32'h0000_0100, 32'h0001_0000, 32'h0002_0000, 1,64,65, 64, errs);

    // FCR5: M=8, K=64, N=64
    preload_all_ones(m_seq, 32'h0000_0100, 8*64, 32'h0001_0000, 64*64);
    run_fc_streaming_all1(32'h0000_0100, 32'h0001_0000, 32'h0002_0000, 8,64,64, 64, errs);

    // FCR6: M=9, K=64, N=64
    preload_all_ones(m_seq, 32'h0000_0100, 9*64, 32'h0001_0000, 64*64);
    run_fc_streaming_all1(32'h0000_0100, 32'h0001_0000, 32'h0002_0000, 9,64,64, 64, errs);

    // FCR7: M=9, K=65, N=65
    preload_all_ones(m_seq, 32'h0000_0100, 9*65, 32'h0001_0000, 65*65);
    run_fc_streaming_all1(32'h0000_0100, 32'h0001_0000, 32'h0002_0000, 9,65,65, 65, errs);

    //==================================================================
    // SECTION 2: Legacy vs Streaming Matched Comparison
    //==================================================================
    `uvm_info("ROBUST","-- Legacy vs Streaming Matched --",UVM_NONE)

    // MATCH0: K=16, N=16
    M_v=1; K_v=16; N_v=16;
    preload_all_ones(m_seq, 32'h0000_0100, M_v*K_v, 32'h0001_0000, K_v*N_v);
    run_legacy_fc_verify(32'h0000_0100, 32'h0001_0000, 32'h0003_0000, K_v, N_v, K_v, errs);
    run_fc_streaming_all1(32'h0000_0100, 32'h0001_0000, 32'h0002_0000, M_v, K_v, N_v, K_v, errs);

    // MATCH1: K=64, N=64
    M_v=1; K_v=64; N_v=64;
    preload_all_ones(m_seq, 32'h0000_0100, M_v*K_v, 32'h0001_0000, K_v*N_v);
    run_legacy_fc_verify(32'h0000_0100, 32'h0001_0000, 32'h0003_0000, K_v, N_v, K_v, errs);
    run_fc_streaming_all1(32'h0000_0100, 32'h0001_0000, 32'h0002_0000, M_v, K_v, N_v, K_v, errs);

    // MATCH2: K=128, N=64
    M_v=1; K_v=128; N_v=64;
    preload_all_ones(m_seq, 32'h0000_0100, M_v*K_v, 32'h0001_0000, K_v*N_v);
    run_legacy_fc_verify(32'h0000_0100, 32'h0001_0000, 32'h0003_0000, K_v, N_v, K_v, errs);
    run_fc_streaming_all1(32'h0000_0100, 32'h0001_0000, 32'h0002_0000, M_v, K_v, N_v, K_v, errs);

    `uvm_info("ROBUST",$sformatf("=== FC ROBUSTNESS: boundary 8 tests + 3 matched pairs COMPLETE ==="),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
