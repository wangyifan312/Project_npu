//=============================================================================
// npu_dma_writer_forced_4kb_split_test.sv — Phase U9-a3 Writer Forced 4KB Split
//
// Uses VecReLU (task_type=6) streaming path to provide sustained 256-bit
// data to the DMA writer FIFO, bypassing the GEMM store_pack throughput
// limitation.  This forces the writer to issue bursts large enough to cross
// a 4KB boundary, proving calc_burst_beats_4kb truncates at the boundary.
//
// Configuration:
//   output_addr = 0x00002F80 (128B before 4KB at 0x3000)
//   byte_count  = 256B (8 beats)
//
// Expected AW sequence (with 4KB split):
//   AW0: addr=0x2F80, AWLEN=3, AWSIZE=5 (4 beats, 0x2F80→0x2FFF, exactly at 4KB)
//   AW1: addr=0x3000, AWLEN=3, AWSIZE=5 (4 beats, 0x3000→0x307F)
//
// Without 4KB split, a single 8-beat burst at 0x2F80 would cross 0x3000.
//=============================================================================
`timescale 1ns / 1ps

class npu_dma_writer_forced_4kb_split_test extends soc_base_test;
  `uvm_component_utils(npu_dma_writer_forced_4kb_split_test)
  function new(string name="npu_dma_writer_forced_4kb_split_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq seq;
    bit [31:0] rd_data;
    int poll_count;
    int i;

    phase.raise_objection(this);
    seq = soc_base_seq::type_id::create("seq");
    seq.start(env.axil_ag.seqr);
    #200;

    `uvm_info("TEST","=== DMA_WRITER_FORCED_4KB_SPLIT (U9-a3) ===",UVM_NONE)
    `uvm_info("TEST","VecReLU streaming path: output_addr=0x2F80, 256B → 2×4-beat bursts",UVM_NONE)
    `uvm_info("TEST","Expected: AW0 addr=0x2F80 len=3 (4 beats) + AW1 addr=0x3000 len=3 (4 beats)",UVM_NONE)

    // Preload 256B input data for VecReLU at safe address
    // VecReLU reads from input_addr, applies ReLU, writes to output_addr
    // All input bytes are positive (0x01) so ReLU passes them through unchanged
    for (i=0; i<64; i=i+1)
      seq.axil_write32(32'h0000_0100 + i*4, 32'h01010101);

    // VecReLU: task_type=6, input→output streaming
    seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd6);          // VECTOR_RELU
    seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);   // input data
    seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'd0);           // unused
    seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0000_2F80);   // near 4KB boundary!
    seq.axil_write32(`NPU_REG_INPUT_BYTES,  32'd256);         // 256B
    seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd0);           // unused
    seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd256);         // 256B = 8 beats
    seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, 16'd1});  // H=1, W=1
    seq.axil_write32(`NPU_REG_DIM_OUT,      {16'd1, 16'd1});  // C_IN=1, C_OUT=1
    seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);           // no extra postproc
    seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

    // Start task
    seq.axil_write32(`NPU_REG_CTRL, 32'h1);

    // Poll for done
    for (poll_count=0; poll_count<50000; poll_count++) begin
      seq.axil_read32(`NPU_REG_CTRL, rd_data);
      if (rd_data[2] || rd_data[3]) break;
      #100;
    end

    if (rd_data[3]) begin
      seq.axil_read32(`NPU_REG_STATUS, rd_data);
      `uvm_error("TEST",$sformatf("ERROR code=0x%02x",rd_data[7:0]))
    end else begin
      // Verify output: all bytes should be 0x01 (ReLU passes positive values)
      int total_errs;
      total_errs=0;
      for (i=0; i<64; i++) begin
        seq.axil_read32(32'h0000_2F80 + i*4, rd_data);
        if (rd_data != 32'h01010101) begin
          if (total_errs<4)
            `uvm_error("TEST",$sformatf("Output word[%0d]=0x%08h expected 0x01010101",i,rd_data))
          total_errs++;
        end
      end
      if (total_errs==0)
        `uvm_info("TEST","Output data correct: all 256B = 0x01",UVM_NONE)
      else
        `uvm_error("TEST",$sformatf("%0d/64 output words mismatch",total_errs))
    end

    // Dump AW summary from probe
    `uvm_info("TEST",$sformatf("Final probe: ARSIZE=%0d AWSIZE=%0d",probe_vif.npu_m_arsize,probe_vif.npu_m_awsize),UVM_NONE)

    `uvm_info("TEST","=== DMA_WRITER_FORCED_4KB_SPLIT COMPLETE ===",UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
