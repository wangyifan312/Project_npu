//=============================================================================
// npu_dma_buffer_boundary_legal_test.sv — Phase U9-a2 Boundary Cases
//
// Two independent test classes verifying exact buffer-capacity boundary:
//   E: input_bytes  == BUF_BANK_BYTES  → CSR quick check (no error)
//   F: weight_bytes == BUF_BANK_BYTES  → CSR quick check (no error)
//
// Each test does a CSR-level quick check: configures NPU, starts task,
// polls CTRL briefly — if no error, checker PASS.  Does NOT wait for
// full DMA completion (512 KiB would take too long).
//
// NOTE: these must be run as separate simulation invocations because
// after checker passes, the NPU starts DMA and remains busy.
//=============================================================================
`timescale 1ns / 1ps

// ============================================================
// Test E: exact input_bytes boundary
// ============================================================
class npu_dma_buffer_boundary_input_test extends soc_base_test;
  `uvm_component_utils(npu_dma_buffer_boundary_input_test)
  function new(string name="npu_dma_buffer_boundary_input_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq seq;
    bit [31:0] rd_data;
    int poll_count;
    int buf_bank_bytes;
    buf_bank_bytes = 16384 * 32;  // 524288

    phase.raise_objection(this);
    seq = soc_base_seq::type_id::create("seq");
    seq.start(env.axil_ag.seqr);
    #200;

    `uvm_info("TEST","=== BOUNDARY INPUT (U9-a2) ===",UVM_NONE)
    `uvm_info("TEST",$sformatf("input_bytes=%0d == BUF_BANK_BYTES=%0d — expect NO error",buf_bank_bytes,buf_bank_bytes),UVM_NONE)

    // Configure GEMM with exact boundary input_bytes
    seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
    seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0040);   // non-null
    seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0008_0000);
    seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h000C_0000);
    seq.axil_write32(`NPU_REG_INPUT_BYTES,  buf_bank_bytes);  // exact boundary!
    seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd32);          // small, legal
    seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd32);
    seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, 16'd1});
    seq.axil_write32(`NPU_REG_DIM_OUT,      {16'd1, 16'd1});
    seq.axil_write32(`NPU_REG_CONV_CFG,     32'h0);
    seq.axil_write32(`NPU_REG_POSTPROC,     32'h0);
    seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

    // Start task
    seq.axil_write32(`NPU_REG_CTRL, 32'h1);

    // CSR-level quick check: poll for error (should NOT appear)
    for (poll_count=0; poll_count<500; poll_count++) begin
      seq.axil_read32(`NPU_REG_CTRL, rd_data);
      if (rd_data[3]) break;  // error — FAIL
      #100;
    end

    if (rd_data[3]) begin
      seq.axil_read32(`NPU_REG_STATUS, rd_data);
      `uvm_error("TEST",$sformatf("BOUNDARY INPUT: exact boundary rejected! error_code=0x%02x (expected NO error)",rd_data[7:0]))
    end else begin
      `uvm_info("TEST","BOUNDARY INPUT PASS: exact boundary NOT falsely rejected",UVM_NONE)
    end

    `uvm_info("TEST",$sformatf("Probe: ARVALID=%0d (task may have started DMA after check)",probe_vif.npu_m_arvalid),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass


// ============================================================
// Test F: exact weight_bytes boundary
// ============================================================
class npu_dma_buffer_boundary_weight_test extends soc_base_test;
  `uvm_component_utils(npu_dma_buffer_boundary_weight_test)
  function new(string name="npu_dma_buffer_boundary_weight_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq seq;
    bit [31:0] rd_data;
    int poll_count;
    int buf_bank_bytes;
    buf_bank_bytes = 16384 * 32;

    phase.raise_objection(this);
    seq = soc_base_seq::type_id::create("seq");
    seq.start(env.axil_ag.seqr);
    #200;

    `uvm_info("TEST","=== BOUNDARY WEIGHT (U9-a2) ===",UVM_NONE)
    `uvm_info("TEST",$sformatf("weight_bytes=%0d == BUF_BANK_BYTES=%0d — expect NO error",buf_bank_bytes,buf_bank_bytes),UVM_NONE)

    seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
    seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0040);
    seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0008_0000);
    seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h000C_0000);
    seq.axil_write32(`NPU_REG_INPUT_BYTES,  32'd32);          // small, legal
    seq.axil_write32(`NPU_REG_WEIGHT_BYTES, buf_bank_bytes);  // exact boundary!
    seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd32);
    seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, 16'd1});
    seq.axil_write32(`NPU_REG_DIM_OUT,      {16'd1, 16'd1});
    seq.axil_write32(`NPU_REG_CONV_CFG,     32'h0);
    seq.axil_write32(`NPU_REG_POSTPROC,     32'h0);
    seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

    seq.axil_write32(`NPU_REG_CTRL, 32'h1);

    for (poll_count=0; poll_count<500; poll_count++) begin
      seq.axil_read32(`NPU_REG_CTRL, rd_data);
      if (rd_data[3]) break;
      #100;
    end

    if (rd_data[3]) begin
      seq.axil_read32(`NPU_REG_STATUS, rd_data);
      `uvm_error("TEST",$sformatf("BOUNDARY WEIGHT: exact boundary rejected! error_code=0x%02x (expected NO error)",rd_data[7:0]))
    end else begin
      `uvm_info("TEST","BOUNDARY WEIGHT PASS: exact boundary NOT falsely rejected",UVM_NONE)
    end

    phase.drop_objection(this);
  endtask
endclass
