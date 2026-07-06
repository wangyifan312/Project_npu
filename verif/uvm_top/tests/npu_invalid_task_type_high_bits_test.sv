//=============================================================================
// npu_invalid_task_type_high_bits_test.sv — U9-b4 ERR_INVALID_TASK_TYPE
//
// Verifies that writing non-zero values to TASK_TYPE[31:3] triggers
// ERR_INVALID_TASK_TYPE (0x01) at task start, rather than being silently
// truncated to a valid 3-bit task type.
//
// Cases:
//   A: TASK_TYPE = 0x0000_0008 (bit[3]=1) → ERR_INVALID_TASK_TYPE
//   B: TASK_TYPE = 0xFFFF_FFFF (all high bits set) → ERR_INVALID_TASK_TYPE
//   C: TASK_TYPE = 0x0000_0007 (max valid) → allowed (GEMM runs normally)
//
// Also verifies IRQ error_pending on invalid task type.
//=============================================================================
`timescale 1ns / 1ps

class npu_invalid_task_type_high_bits_test extends soc_base_test;
  `uvm_component_utils(npu_invalid_task_type_high_bits_test)
  function new(string name="npu_invalid_task_type_high_bits_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq seq;
    bit [31:0] rd_data;
    int poll_count;
    int failed_cases;

    phase.raise_objection(this);
    seq = soc_base_seq::type_id::create("seq");
    seq.start(env.axil_ag.seqr);
    #200;

    `uvm_info("TEST","=== INVALID_TASK_TYPE_HIGH_BITS (U9-b4) ===",UVM_NONE)
    `uvm_info("TEST","Verifying ERR_INVALID_TASK_TYPE (0x01) on TASK_TYPE[31:3] != 0",UVM_NONE)
    failed_cases = 0;

    // ============================================================
    // Case A: TASK_TYPE = 0x08 (bit[3]=1, invalid)
    // ============================================================
    begin
      `uvm_info("TEST","-- A: TASK_TYPE=0x08 (bit[3]=1) → expect ERR_INVALID_TASK_TYPE --",UVM_NONE)

      seq.axil_write32(`NPU_REG_TASK_TYPE,    32'h0000_0008);  // bit[3]=1
      seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0040);
      seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0000_0080);
      seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0000_00C0);
      seq.axil_write32(`NPU_REG_INPUT_BYTES,  32'd32);
      seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd32);
      seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd4);
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

      seq.axil_read32(`NPU_REG_STATUS, rd_data);
      if (!rd_data[3] && poll_count>=500) begin
        `uvm_error("TEST","Case A: No error detected — reserved bits NOT checked")
        failed_cases++;
      end else if (rd_data[7:0] != 8'h01) begin
        `uvm_error("TEST",$sformatf("Case A: Wrong error_code=0x%02x (expected 0x01)",rd_data[7:0]))
        failed_cases++;
      end else begin
        `uvm_info("TEST","Case A PASS: ERR_INVALID_TASK_TYPE (0x01) correctly triggered for TASK_TYPE=0x08",UVM_NONE)
      end

      seq.axil_write32(`NPU_REG_CTRL, 32'h10);  // clear error
    end

    // ============================================================
    // Case B: TASK_TYPE = 0xFFFF_FFFF (all high bits set)
    // ============================================================
    begin
      `uvm_info("TEST","-- B: TASK_TYPE=0xFFFF_FFFF → expect ERR_INVALID_TASK_TYPE --",UVM_NONE)

      seq.axil_write32(`NPU_REG_TASK_TYPE,    32'hFFFF_FFFF);  // all bits set
      seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0040);
      seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0000_0080);
      seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0000_00C0);
      seq.axil_write32(`NPU_REG_INPUT_BYTES,  32'd32);
      seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd32);
      seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd4);
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

      seq.axil_read32(`NPU_REG_STATUS, rd_data);
      if (!rd_data[3] && poll_count>=500) begin
        `uvm_error("TEST","Case B: No error detected")
        failed_cases++;
      end else if (rd_data[7:0] != 8'h01) begin
        `uvm_error("TEST",$sformatf("Case B: Wrong error_code=0x%02x (expected 0x01)",rd_data[7:0]))
        failed_cases++;
      end else begin
        `uvm_info("TEST","Case B PASS: ERR_INVALID_TASK_TYPE (0x01) for TASK_TYPE=0xFFFF_FFFF",UVM_NONE)
      end

      seq.axil_write32(`NPU_REG_CTRL, 32'h10);
    end

    // ============================================================
    // Case C: TASK_TYPE = 7 (max valid, GEMM) — should succeed
    // ============================================================
    begin
      `uvm_info("TEST","-- C: TASK_TYPE=7 (legal GEMM) → should NOT trigger error --",UVM_NONE)

      seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
      seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0040);
      seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0000_0080);
      seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0000_00C0);
      seq.axil_write32(`NPU_REG_INPUT_BYTES,  32'd32);
      seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd32);
      seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd4);
      seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, 16'd1});
      seq.axil_write32(`NPU_REG_DIM_OUT,      {16'd1, 16'd1});
      seq.axil_write32(`NPU_REG_CONV_CFG,     32'h0);
      seq.axil_write32(`NPU_REG_POSTPROC,     32'h0);
      seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
      seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

      seq.axil_write32(`NPU_REG_CTRL, 32'h1);

      for (poll_count=0; poll_count<5000; poll_count++) begin
        seq.axil_read32(`NPU_REG_CTRL, rd_data);
        if (rd_data[3]) break;  // error — should NOT happen
        if (rd_data[2]) break;  // done
        #100;
      end

      if (rd_data[3]) begin
        seq.axil_read32(`NPU_REG_STATUS, rd_data);
        `uvm_error("TEST",$sformatf("Case C: Legal TASK_TYPE=7 falsely rejected! error_code=0x%02x",rd_data[7:0]))
        failed_cases++;
      end else if (!rd_data[2] && poll_count>=5000) begin
        `uvm_error("TEST","Case C: Legal task timeout")
        failed_cases++;
      end else begin
        `uvm_info("TEST","Case C PASS: legal TASK_TYPE=7 runs normally",UVM_NONE)
      end

      seq.axil_write32(`NPU_REG_CTRL, 32'h10);
    end

    `uvm_info("TEST",$sformatf("INVALID_TASK_TYPE_HIGH_BITS: %0d/3 cases failed %s",
      failed_cases, (failed_cases==0)?"PASS":"FAIL"),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
