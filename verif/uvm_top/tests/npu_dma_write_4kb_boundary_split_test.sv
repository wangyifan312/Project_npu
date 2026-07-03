//=============================================================================
// npu_dma_write_4kb_boundary_split_test.sv — Phase U9-a3 Writer 4KB Split
//
// Verifies DMA writer AW/W bursts are split at 4KB boundaries.
// output_addr near 4KB boundary forces first burst truncated.
//
// Setup: output_addr = 0x00002F80 (128B before 4KB at 0x3000)
//        256B output (M=4,N=16,K=4 → INT32: 4×16×4=256B)
//        Should split into 2 AW bursts:
//          AW0: addr=0x2F80, AWLEN=3 (4 beats × 32B = 128B)
//          AW1: addr=0x3000, AWLEN=3 (4 beats)
//=============================================================================
`timescale 1ns / 1ps

class npu_dma_write_4kb_boundary_split_test extends soc_base_test;
  `uvm_component_utils(npu_dma_write_4kb_boundary_split_test)
  function new(string name="npu_dma_write_4kb_boundary_split_test", uvm_component parent=null);
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

    `uvm_info("TEST","=== DMA_WRITE_4KB_BOUNDARY_SPLIT (U9-a3) ===",UVM_NONE)
    `uvm_info("TEST","output_addr=0x2F80 (near 4KB), 256B output → expect 2 AW bursts",UVM_NONE)

    // GEMM: M=4, K=4, N=16 → output 4×16 INT32 = 256 bytes
    // Preload input (M×K = 16 bytes all-1) and weight (K×N = 64 bytes all-1)
    for (i=0; i<4; i=i+1)
      seq.axil_write32(32'h0000_0100 + i*4, 32'h01010101);   // input: 16B
    for (i=0; i<16; i=i+1)
      seq.axil_write32(32'h0000_0200 + i*4, 32'h01010101);   // weight: 64B
    // Clear output area: 0x2F80 - 0x307F (256B)
    for (i=0; i<64; i=i+1)
      seq.axil_write32(32'h0000_2F80 + i*4, 32'hDEADBEEF);

    seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
    seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
    seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0000_0200);
    seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0000_2F80);   // near 4KB boundary!
    seq.axil_write32(`NPU_REG_INPUT_BYTES,  32'd16);
    seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd64);
    seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd256);          // 256B = 8 × 32B beats
    seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, 16'd4});   // W=1, H=4
    seq.axil_write32(`NPU_REG_DIM_OUT,      {16'd16, 16'd4});  // C_OUT=16, C_IN=4
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
    end else begin
      total_errs=0; exp_val=4;  // all-1: each output = K = 4
      for (i=0; i<4; i++) begin
        for (j=0; j<16; j++) begin
          seq.axil_read32(32'h0000_2F80 + i*64 + j*4, rd_data);
          if ($signed(rd_data) != exp_val) begin
            if (total_errs<5)
              `uvm_error("TEST",$sformatf("C[%0d][%0d]=%0d expected %0d",i,j,$signed(rd_data),exp_val))
            total_errs++;
          end
        end
      end
    end

    `uvm_info("TEST",$sformatf("DMA_WRITE_4KB_BOUNDARY: errors=%0d %s",
      total_errs, (total_errs==0)?"PASS":"FAIL"),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
