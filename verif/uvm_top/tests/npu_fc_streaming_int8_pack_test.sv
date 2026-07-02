//=============================================================================
// npu_fc_streaming_int8_pack_test.sv — Phase U4-d: INT8 packing infrastructure
// Verifies GST_INT8 packing via conv_cfg[6] internal test hook.
// All-1 data → simple golden: C[n] = K for all n.
//=============================================================================
`timescale 1ns / 1ps

class npu_fc_streaming_int8_pack_test extends soc_base_test;
  `uvm_component_utils(npu_fc_streaming_int8_pack_test)
  function new(string name="npu_fc_streaming_int8_pack_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_int8_pack(int M_v, int K_v, int N_v, string label);
    soc_base_seq m_seq;
    bit [31:0] word, ctrl_val, cycle_lo;
    int i, j, k, errs;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    // All-1 A and B
    for (i=0; i<M_v*K_v; i=i+4)
      m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
    for (i=0; i<K_v*N_v; i=i+4)
      m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);

    // Clear output
    for (i=0; i<M_v*N_v*4; i=i+4)
      m_seq.axil_write32(32'h0002_0000 + i, 32'hDEADBEEF);

    // FC streaming + INT8 test hook (conv_cfg[6]=1)
    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd1);
    m_seq.axil_write32(`NPU_REG_CONV_CFG,     32'h60);   // bit[5]=1 stream, bit[6]=1 INT8
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
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
      `uvm_error("INT8PK",$sformatf("%s ERROR code=0x%02x",label,ctrl_val[7:0]))
      return;
    end

    // Golden: C[m][n] = K (all-1 data, K-major weights)
    errs = 0;
    begin
      int exp_val, row_stride;
      exp_val = K_v & 8'hFF;
      row_stride = ((N_v + 31) / 32) * 32;
      for (i=0; i<M_v; i++) begin
        for (j=0; j<N_v; j=j+4) begin
          m_seq.axil_read32(32'h0002_0000 + i*row_stride + (j & ~3), word);
          for (k=0; k<4; k=k+1) begin
            if ((j+k) < N_v) begin
              if (word[k*8 +: 8] != exp_val) begin
                if (errs<8)
                  `uvm_error("INT8PK",$sformatf("%s C[%0d][%0d]=%0d expected %0d",
                    label,i,j+k,word[k*8 +: 8],exp_val))
                errs++;
              end
            end
          end
        end
      end
    end
    if (errs == 0)
      `uvm_info("INT8PK",$sformatf("%s: M=%0d K=%0d N=%0d cycles=%0d PASS",
        label,M_v,K_v,N_v,cycle_lo),UVM_NONE)
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    #200;
    `uvm_info("INT8PK","=== FC STREAMING INT8 PACK (Phase U4-d) ===",UVM_NONE)

    run_int8_pack(1, 8, 8, "INT8_BASIC");
    run_int8_pack(1, 64, 65, "INT8_NTILE");
    run_int8_pack(1, 128, 16, "INT8_KCHUNK");
    run_int8_pack(4, 16, 16, "INT8_BATCH");

    `uvm_info("INT8PK","=== INT8 PACK COMPLETE ===",UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
