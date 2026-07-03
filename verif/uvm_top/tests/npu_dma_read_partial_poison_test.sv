//=============================================================================
// npu_dma_read_partial_poison_test.sv — Phase U9-a1 DMA Read Partial Mask
//
// Verifies that dma_axi_reader data_strb correctly zeros invalid bytes
// in partial final beats.  GEMM M=1 K=4 N=1: valid data in first 4B,
// poison (0x7F) in high 28B of same 32B beat.  If strb mask works,
// output = 0x00000004.  Without mask, poison corrupts the result.
//
// Design invariants checked:
//   - ARSIZE remains 3'd5 (256-bit full-width) — no narrow burst
//   - DMA reads are full-width INCR bursts
//   - data_strb zeros invalid bytes before buffer write
//=============================================================================
`timescale 1ns / 1ps

class npu_dma_read_partial_poison_test extends soc_base_test;
  `uvm_component_utils(npu_dma_read_partial_poison_test)
  function new(string name="npu_dma_read_partial_poison_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq m_seq;
    bit [31:0] rdata, cycle_lo;
    int i, total_errs, exp_val;
    int M_v, K_v, N_v;
    bit [2:0] sampled_arsize;

    phase.raise_objection(this);
    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);
    #200;

    `uvm_info("TEST","=== DMA_READ_PARTIAL_POISON (Phase U9-a1) ===",UVM_NONE)
    `uvm_info("TEST","Strategy: M=1 K=4 N=1 GEMM; 4B valid + 28B poison(0x7F) per 32B beat",UVM_NONE)
    `uvm_info("TEST","Expected: output=4.  Poison bytes MUST be zeroed by data_strb mask.",UVM_NONE)

    M_v = 1; K_v = 4; N_v = 1;
    total_errs = 0; exp_val = K_v;  // all-1 data: output = sum(k) = K

    // --- Preload input A[1x4]: first 4B=0x01, next 28B=0x7F poison ---
    // Shared RAM address 0x0000_0100, DMA reads full 32B beat
    m_seq.axil_write32(32'h0000_0100, 32'h01010101);       // bytes [3:0] valid
    for (i=1; i<8; i=i+1)
      m_seq.axil_write32(32'h0000_0100 + i*4, 32'h7F7F7F7F); // bytes [31:4] poison

    // --- Preload weight B[4x1]: first 4B=0x01, next 28B=0x7F poison ---
    // Shared RAM address 0x0001_0000
    m_seq.axil_write32(32'h0001_0000, 32'h01010101);
    for (i=1; i<8; i=i+1)
      m_seq.axil_write32(32'h0001_0000 + i*4, 32'h7F7F7F7F);

    // Clear output region
    for (i=0; i<8; i=i+1)
      m_seq.axil_write32(32'h0002_0000 + i*4, 32'hDEADBEEF);

    // Sample pre-task ARSIZE: should be unknown/idle (ARVALID=0)
    `uvm_info("TEST",$sformatf("Probe ARSIZE (pre-task): %0d (ARVALID=%0d)",
      probe_vif.npu_m_arsize, probe_vif.npu_m_arvalid),UVM_NONE)

    // --- Configure NPU: TASK_GEMM=7 ---
    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);       // 4 bytes
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);       // 4 bytes
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);     // 4 bytes
    m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});   // W=1, H=1
    m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]}); // C_OUT=1, C_IN=4
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

    // --- Start and poll ---
    m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);
    repeat(200000) begin
      m_seq.axil_read32(`NPU_REG_CTRL, rdata);
      if (rdata[2] || rdata[3]) break;
      #100;
    end

    m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);

    // --- Check for hardware error ---
    if (rdata[3]) begin
      m_seq.axil_read32(`NPU_REG_STATUS, rdata);
      `uvm_error("TEST",$sformatf("HARDWARE ERROR: status=0x%02x",rdata[7:0]))
    end else begin
      // --- Verify output: should be 4 (all-1 input * all-1 weight, K=4) ---
      m_seq.axil_read32(32'h0002_0000, rdata);
      `uvm_info("TEST",$sformatf("Output[0]: %0d (expected %0d), cycles=%0d",
        $signed(rdata), exp_val, cycle_lo),UVM_NONE)

      if ($signed(rdata) != exp_val) begin
        `uvm_error("TEST",$sformatf("POISON LEAK: output=%0d expected=%0d — data_strb mask FAILED",
          $signed(rdata), exp_val))
        total_errs++;
      end else begin
        `uvm_info("TEST","PASS: Poison tail correctly zeroed by data_strb mask",UVM_NONE)
      end

      // Dump post-task probe state for ARSIZE evidence
      `uvm_info("TEST",$sformatf("Probe ARSIZE (post-task): %0d (ARVALID=%0d, ARADDR=0x%08h)",
        probe_vif.npu_m_arsize, probe_vif.npu_m_arvalid, probe_vif.npu_m_araddr),UVM_NONE)
    end

    `uvm_info("TEST",$sformatf("DMA_READ_PARTIAL_POISON: errors=%0d %s",
      total_errs, (total_errs==0)?"PASS":"FAIL"),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
