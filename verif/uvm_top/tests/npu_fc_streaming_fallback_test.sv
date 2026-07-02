//=============================================================================
// npu_fc_streaming_fallback_test.sv — FC Streaming Fallback Phase U1
//
// Verifies: FC with bias_enabled falls back to legacy FC path
// even when conv_cfg[5]=1 (streaming mode requested).
//
// fc_streaming_en = is_fc_mode && conv_cfg[5] && !bias_enabled
// When bias is enabled, fc_streaming_en=0 → legacy path
//=============================================================================
`timescale 1ns / 1ps

class npu_fc_streaming_fallback_test extends soc_base_test;
  `uvm_component_utils(npu_fc_streaming_fallback_test)
  function new(string name="npu_fc_streaming_fallback_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq m_seq;
    bit [31:0] rdata, cycle_lo, ctrl_val;
    int i, total_errs;
    int K_v, N_v;

    phase.raise_objection(this);
    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);
    #200;

    K_v=4; N_v=4;

    `uvm_info("TEST","=== FC_STREAMING FALLBACK (Phase U1) ===",UVM_NONE)
    `uvm_info("TEST",$sformatf("-- FALLBACK: M=1 K=%0d N=%0d with bias & conv_cfg[5]=1 --",
      K_v,N_v),UVM_NONE)

    // Preload A[1][K] all-1
    for (i=0; i<K_v; i=i+4)
      m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);

    // Preload W[K][N] — legacy N-major: W[n][k] layout
    // For N=4,K=4: each row n has K bytes, all 1s
    for (i=0; i<K_v*N_v; i=i+4)
      m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);

    // Preload bias: 4 INT32 = 0
    for (i=0; i<N_v*4; i=i+4)
      m_seq.axil_write32(32'h0000_0400+i, 32'd0);

    // Clear output
    for (i=0; i<N_v*4; i=i+4)
      m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);

    // Configure: FC, streaming, WITH bias
    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd1);          // FC mode
    m_seq.axil_write32(`NPU_REG_CONV_CFG,     32'h30);        // bit[4]=1 bias, bit[5]=1 streaming
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  K_v);
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, N_v*4);
    m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, 16'd1});   // H=1, W=1
    m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);
    // Bias configuration
    m_seq.axil_write32(`NPU_REG_BIAS_ADDR,   32'h0000_0400);
    m_seq.axil_write32(`NPU_REG_BIAS_BYTES,  N_v*4);

    // Start and poll
    m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
    repeat(500000) begin
      m_seq.axil_read32(`NPU_REG_CTRL, ctrl_val);
      if (ctrl_val[2] || ctrl_val[3]) break;
      #100;
    end

    m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);

    if (ctrl_val[3]) begin
      m_seq.axil_read32(`NPU_REG_STATUS, rdata);
      `uvm_error("TEST",$sformatf("FALLBACK ERROR code=0x%02x",rdata[7:0]))
    end else begin
      // Legacy FC with bias: output is requantized INT8
      // C[n] = requant(bias + sum_k A[k]*W[n][k])
      // = requant(0 + sum_k 1*1) = requant(K) = clamp(K, -128, 127) = 4
      int exp_int8;
      exp_int8 = K_v;  // K=4, requant(mult=1,shift=0) = 4, no clamp needed
      if (exp_int8 > 127) exp_int8 = 127;

      // Read output as 32-bit words, extract byte
      for (i=0; i<N_v; i++) begin
        m_seq.axil_read32(32'h0002_0000 + i*4, rdata);
        if ($signed(rdata[7:0]) != exp_int8) begin
          if (total_errs<5)
            `uvm_error("TEST",$sformatf("FALLBACK C[%0d]=%0d expected %0d",
              i, $signed(rdata[7:0]), exp_int8))
          total_errs++;
        end
      end
    end

    `uvm_info("TEST",$sformatf("FALLBACK: cycles=%0d errors=%0d %s",
      cycle_lo,total_errs, (total_errs==0)?"PASS":"FAIL"),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
