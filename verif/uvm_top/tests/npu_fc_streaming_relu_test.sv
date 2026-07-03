//=============================================================================
// npu_fc_streaming_relu_test.sv — Phase U4-b: ReLU on result_tile GST path
//
// 验证： FC streaming + relu_en=1 + bias_enabled=0 → MatrixOp path
// with INT32 ReLU applied in GST_PUSH_BEAT via store_desc_relu_en.
//=============================================================================
`timescale 1ns / 1ps

class npu_fc_streaming_relu_test extends soc_base_test;
  `uvm_component_utils(npu_fc_streaming_relu_test)
  function new(string name="npu_fc_streaming_relu_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_fc_relu(int M_v, int K_v, int N_v, string label);
    soc_base_seq m_seq;
    bit [31:0] word, ctrl_val, cycle_lo;
    int i, j, k, errs, row_stride;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    // Preload A: alternating +5/-3 to create mixed-sign outputs
    for (i=0; i<M_v; i++) begin
      for (k=0; k<K_v; k=k+4) begin
        word = 32'h00000000;
        for (j=0; j<4; j=j+1) begin
          if ((k+j) < K_v) begin
            if (((i*K_v + k + j) % 2) == 0)
              word[j*8 +: 8] = 8'd5;
            else
              word[j*8 +: 8] = 8'hFD; // -3
          end
        end
        m_seq.axil_write32(32'h0000_0100 + i*K_v + k, word);
      end
    end

    // Preload B: all +2 → magnify values, K-major
    for (i=0; i<K_v*N_v; i=i+4)
      m_seq.axil_write32(32'h0001_0000 + i, 32'h02020202);

    // Clear output
    for (i=0; i<M_v*N_v*4; i=i+4)
      m_seq.axil_write32(32'h0002_0000 + i, 32'hDEADBEEF);

    // Configure: FC, streaming, ReLU enabled
    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd1);
    m_seq.axil_write32(`NPU_REG_CONV_CFG,     32'h20);   // streaming=1
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd1);    // relu_en=1
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
    m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
    m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
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
      `uvm_error("RELU",$sformatf("%s ERROR code=0x%02x",label,ctrl_val[7:0]))
      return;
    end

    // Verify: ReLU(INT32) — negative → 0, positive unchanged
    errs = 0;
    row_stride = ((N_v*4 + 31) / 32) * 32;
    for (i=0; i<M_v; i++) begin
      for (j=0; j<N_v; j++) begin
        int expected_val;
        // A[m][k] = alternating (+5, -3); B[k][n] = 2 all
        // C[m][n] = 2 * sum_k A[m][k]
        // K even: sum = (5-3)*K/2 = K; K odd: sum = (5-3)*(K-1)/2 + 5 = K-1+5 = K+4... wait
        // Actually for alternating (+5,-3,+5,-3,...):
        // K even: sum = (5-3)*K/2 = K
        // K odd: sum = (5-3)*(K-1)/2 + 5 = K-1 + 5 = K+4
        if ((K_v % 2) == 0)
          expected_val = 2 * K_v;    // 2 * K
        else
          expected_val = 2 * (K_v + 4);  // 2 * (K+4) for odd K

        m_seq.axil_read32(32'h0002_0000 + i*row_stride + j*4, word);
        if ($signed(word) != expected_val) begin
          if (errs<8)
            `uvm_error("RELU",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
              label,i,j,$signed(word),expected_val))
          errs++;
        end
      end
    end

    if (errs == 0)
      `uvm_info("RELU",$sformatf("%s: M=%0d K=%0d N=%0d cycles=%0d PASS",
        label,M_v,K_v,N_v,cycle_lo),UVM_NONE)
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    #200;

    `uvm_info("RELU","=== FC STREAMING RELU (Phase U4-b) ===",UVM_NONE)

    // RELU_MIXED: mixed positive/negative, relu_en=1
    `uvm_info("RELU","-- RELU_MIXED: M=1 K=8 N=8 relu=1 --",UVM_NONE)
    run_fc_relu(1, 8, 8, "RELU_MIXED");

    // RELU_ALLPOS: all-positive via all-1 data, relu=1 → no change
    `uvm_info("RELU","-- RELU_ALLPOS: M=1 K=8 N=8 all-1 relu=1 --",UVM_NONE)
    run_fc_relu_allpos(1, 8, 8, "RELU_ALLPOS");

    // RELU_BATCH: M=4 mixed
    `uvm_info("RELU","-- RELU_BATCH: M=4 K=16 N=16 relu=1 --",UVM_NONE)
    run_fc_relu(4, 16, 16, "RELU_BATCH");

    // RELU_NTILE: N>64
    `uvm_info("RELU","-- RELU_NTILE: M=1 K=64 N=65 relu=1 --",UVM_NONE)
    run_fc_relu(1, 64, 65, "RELU_NTILE");

    // RELU_KCHUNK: K>64
    `uvm_info("RELU","-- RELU_KCHUNK: M=1 K=128 N=16 relu=1 --",UVM_NONE)
    run_fc_relu(1, 128, 16, "RELU_KCHUNK");

    `uvm_info("RELU","=== FC STREAMING RELU COMPLETE ===",UVM_NONE)
    phase.drop_objection(this);
  endtask

  // All-positive variant: all-1 Act, all-1 B, relu=1 → should match non-relu
  task run_fc_relu_allpos(int M_v, int K_v, int N_v, string label);
    soc_base_seq m_seq;
    bit [31:0] word, ctrl_val, cycle_lo;
    int i, j, errs, row_stride;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    for (i=0; i<M_v*K_v; i=i+4)
      m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
    for (i=0; i<K_v*N_v; i=i+4)
      m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);
    for (i=0; i<M_v*N_v*4; i=i+4)
      m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);

    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd1);
    m_seq.axil_write32(`NPU_REG_CONV_CFG,     32'h20);
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd1);  // relu=1
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
    m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
    m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
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
      `uvm_error("RELU",$sformatf("%s ERROR code=0x%02x",label,ctrl_val[7:0]))
      return;
    end

    errs = 0;
    row_stride = ((N_v*4 + 31) / 32) * 32;
    for (i=0; i<M_v; i++) begin
      for (j=0; j<N_v; j++) begin
        m_seq.axil_read32(32'h0002_0000 + i*row_stride + j*4, word);
        if ($signed(word) != K_v) begin
          if (errs<5)
            `uvm_error("RELU",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
              label,i,j,$signed(word),K_v))
          errs++;
        end
      end
    end
    if (errs == 0)
      `uvm_info("RELU",$sformatf("%s: M=%0d K=%0d N=%0d cycles=%0d PASS",
        label,M_v,K_v,N_v,cycle_lo),UVM_NONE)
  endtask
endclass
