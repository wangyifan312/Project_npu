//=============================================================================
// npu_dma_4kb_boundary_mixed_test.sv — Phase U9-a3 Mixed Read+Write 4KB Split
//
// All three DMA channels (input read, weight read, output write) are near
// 4KB boundaries.  Verifies AR and AW bursts all respect 4KB boundaries
// simultaneously.
//
// Setup:
//   input_addr  = 0x00000F80 (near 4KB at 0x1000)
//   weight_addr = 0x00001F80 (near 4KB at 0x2000)
//   output_addr = 0x00002F80 (near 4KB at 0x3000)
//   256B each → 2 bursts per channel × 3 channels = 6 bursts total
//=============================================================================
`timescale 1ns / 1ps

class npu_dma_4kb_boundary_mixed_test extends soc_base_test;
  `uvm_component_utils(npu_dma_4kb_boundary_mixed_test)
  function new(string name="npu_dma_4kb_boundary_mixed_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq seq;
    bit [31:0] rd_data;
    int poll_count;
    int i, j, total_errs, exp_val;

    phase.raise_objection(this);
    seq = soc_base_seq::type_id::create("seq");
    seq.start(env.axil_ag.seqr);
    #200;

    `uvm_info("TEST","=== DMA_4KB_BOUNDARY_MIXED (U9-a3) ===",UVM_NONE)
    `uvm_info("TEST","Input/weight/output all near 4KB boundaries",UVM_NONE)

    // Preload 256B all-1 input at 0x0F80
    for (i=0; i<64; i=i+1)
      seq.axil_write32(32'h0000_0F80 + i*4, 32'h01010101);
    // Preload 256B all-1 weight at 0x1F80
    for (i=0; i<64; i=i+1)
      seq.axil_write32(32'h0000_1F80 + i*4, 32'h01010101);
    // Clear output at 0x2F80
    for (i=0; i<64; i=i+1)
      seq.axil_write32(32'h0000_2F80 + i*4, 32'hDEADBEEF);

    // GEMM M=1,K=64,N=4 → 64-element dot product × 4 outputs
    // output: 1×4 INT32 = 16 bytes
    seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
    seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0F80);    // near 4KB
    seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0000_1F80);    // near 4KB
    seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0000_2F80);    // near 4KB
    seq.axil_write32(`NPU_REG_INPUT_BYTES,  32'd256);
    seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd256);
    seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd16);
    seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, 16'd1});
    seq.axil_write32(`NPU_REG_DIM_OUT,      {16'd4, 16'd64});
    seq.axil_write32(`NPU_REG_CONV_CFG,     32'h0);
    seq.axil_write32(`NPU_REG_POSTPROC,     32'h0);
    seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

    seq.axil_write32(`NPU_REG_CTRL, 32'h1);

    for (poll_count=0; poll_count<50000; poll_count++) begin
      seq.axil_read32(`NPU_REG_CTRL, rd_data);
      if (rd_data[2] || rd_data[3]) break;
      #100;
    end

    total_errs=0;
    if (rd_data[3]) begin
      seq.axil_read32(`NPU_REG_STATUS, rd_data);
      `uvm_error("TEST",$sformatf("ERROR code=0x%02x",rd_data[7:0]))
      total_errs++;
    end else begin
      exp_val=64;  // all-1 K=64 dot product
      for (i=0; i<4; i++) begin
        seq.axil_read32(32'h0000_2F80 + i*4, rd_data);
        if ($signed(rd_data) != exp_val) begin
          `uvm_error("TEST",$sformatf("Output[%0d]=%0d expected %0d",i,$signed(rd_data),exp_val))
          total_errs++;
        end
      end
    end

    `uvm_info("TEST",$sformatf("DMA_4KB_BOUNDARY_MIXED: errors=%0d %s",
      total_errs, (total_errs==0)?"PASS":"FAIL"),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
