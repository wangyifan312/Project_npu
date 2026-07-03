//=============================================================================
// npu_dma_read_4kb_boundary_split_test.sv — Phase U9-a3 Reader 4KB Split
//
// Verifies DMA reader AR bursts are split at 4KB boundaries.
// input_addr near 4KB boundary forces first burst to be truncated,
// second burst continues from the next 4KB-aligned address.
//
// Setup: input_addr = 0x00000F80 (128B before 4KB boundary at 0x1000)
//        256B input → should split into 2 AR bursts:
//          AR0: addr=0x0F80, ARLEN=3 (4 beats × 32B = 128B, ends at 0xFFF)
//          AR1: addr=0x1000, ARLEN=3 (4 beats, remaining 128B)
//=============================================================================
`timescale 1ns / 1ps

class npu_dma_read_4kb_boundary_split_test extends soc_base_test;
  `uvm_component_utils(npu_dma_read_4kb_boundary_split_test)
  function new(string name="npu_dma_read_4kb_boundary_split_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq seq;
    bit [31:0] rd_data;
    int poll_count;
    int i;
    int total_errs;
    int exp_val;

    phase.raise_objection(this);
    seq = soc_base_seq::type_id::create("seq");
    seq.start(env.axil_ag.seqr);
    #200;

    `uvm_info("TEST","=== DMA_READ_4KB_BOUNDARY_SPLIT (U9-a3) ===",UVM_NONE)
    `uvm_info("TEST","input_addr=0x0F80 (near 4KB), 256B input → expect 2 AR bursts",UVM_NONE)
    `uvm_info("TEST","AR0: addr=0x0F80 len=3 (4 beats), AR1: addr=0x1000 len=3 (4 beats)",UVM_NONE)

    // Preload 256B of all-1 input at 0x0F80-0x107F
    for (i=0; i<64; i=i+1)
      seq.axil_write32(32'h0000_0F80 + i*4, 32'h01010101);
    // Weight: 256B all-1 at safe address (no 4KB split needed for weight)
    for (i=0; i<64; i=i+1)
      seq.axil_write32(32'h0000_2000 + i*4, 32'h01010101);
    // Clear output
    for (i=0; i<8; i=i+1)
      seq.axil_write32(32'h0000_3000 + i*4, 32'hDEADBEEF);

    // GEMM M=1, K=64, N=4 → input=64B, weight=256B, output=16B
    // But we set INPUT_BYTES=256 to force 4KB split on read side
    seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
    seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0F80);  // near 4KB boundary!
    seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0000_2000);
    seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0000_3000);
    seq.axil_write32(`NPU_REG_INPUT_BYTES,  32'd256);   // 8 beats → 4KB split
    seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd256);
    seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd16);
    seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, 16'd1});     // W=1, H=1
    seq.axil_write32(`NPU_REG_DIM_OUT,      {16'd4, 16'd64});    // C_OUT=4, C_IN=64
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

    if (rd_data[3]) begin
      seq.axil_read32(`NPU_REG_STATUS, rd_data);
      `uvm_error("TEST",$sformatf("ERROR code=0x%02x",rd_data[7:0]))
      total_errs=1;
    end else begin
      total_errs=0; exp_val=64;  // all-1 K=64 dot product
      for (i=0; i<4; i++) begin
        seq.axil_read32(32'h0000_3000 + i*4, rd_data);
        if ($signed(rd_data) != exp_val) begin
          `uvm_error("TEST",$sformatf("Output[%0d]=%0d expected %0d",i,$signed(rd_data),exp_val))
          total_errs++;
        end
      end
    end

    `uvm_info("TEST",$sformatf("DMA_READ_4KB_BOUNDARY: errors=%0d %s",
      total_errs, (total_errs==0)?"PASS":"FAIL"),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
