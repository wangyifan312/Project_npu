//=============================================================================
// npu_dma_buffer_capacity_guard_test.sv — Phase U9-a2 Buffer Capacity Guard
//
// Verifies that task_checker rejects DMA loads exceeding one buffer bank
// capacity (BUF_ENTRIES × DMA_BEAT_BYTES = 16384 × 32 = 512 KiB).
//
// Cases:
//   A: input_bytes  = BUF_BANK_BYTES + 32 → ERR_BUF_OVERFLOW (0x0D)
//   B: weight_bytes = BUF_BANK_BYTES + 32 → ERR_BUF_OVERFLOW (0x0D)
//   C: input_bytes  = 32 (small, well within capacity) → allowed
//   D: weight_bytes = 32 (small, well within capacity) → allowed
//
// Cases C/D verify the checker does NOT produce false-positive
// buffer-overflow rejections on legal sizes.
//=============================================================================
`timescale 1ns / 1ps

class npu_dma_buffer_capacity_guard_test extends soc_base_test;
  `uvm_component_utils(npu_dma_buffer_capacity_guard_test)
  function new(string name="npu_dma_buffer_capacity_guard_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq seq;
    bit [31:0] rd_data;
    int poll_count;
    int buf_bank_bytes;
    int failed_cases;

    buf_bank_bytes = 16384 * 32;  // BUF_ENTRIES * DMA_BEAT_BYTES = 524288

    phase.raise_objection(this);
    seq = soc_base_seq::type_id::create("seq");
    seq.start(env.axil_ag.seqr);
    #200;

    `uvm_info("TEST","=== DMA_BUFFER_CAPACITY_GUARD (Phase U9-a2) ===",UVM_NONE)
    `uvm_info("TEST",$sformatf("BUF_BANK_BYTES=%0d (0x%0h)",buf_bank_bytes,buf_bank_bytes),UVM_NONE)

    failed_cases = 0;

    // ============================================================
    // Case A: input_bytes overflow
    // ============================================================
    begin
      bit [31:0] ovf_bytes;
      ovf_bytes = buf_bank_bytes + 32;
      `uvm_info("TEST",$sformatf("-- A: input_bytes=%0d (>%0d) overflow --",ovf_bytes,buf_bank_bytes),UVM_NONE)

      seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);  // TASK_GEMM
      seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0040);  // non-null
      seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0008_0000);
      seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h000C_0000);
      seq.axil_write32(`NPU_REG_INPUT_BYTES,  ovf_bytes);  // overflow!
      seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd32);     // legal
      seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd32);
      seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, 16'd1});   // W=1, H=1
      seq.axil_write32(`NPU_REG_DIM_OUT,      {16'd1, 16'd1});   // C_OUT=1, C_IN=1
      seq.axil_write32(`NPU_REG_CONV_CFG,     32'h0);
      seq.axil_write32(`NPU_REG_POSTPROC,     32'h0);
      seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
      seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

      seq.axil_write32(`NPU_REG_CTRL, 32'h1);

      // Poll for error
      for (poll_count=0; poll_count<500; poll_count++) begin
        seq.axil_read32(`NPU_REG_CTRL, rd_data);
        if (rd_data[3]) break;
        #100;
      end

      seq.axil_read32(`NPU_REG_STATUS, rd_data);
      if (!rd_data[3] && poll_count>=500) begin
        `uvm_error("TEST","Case A: No error detected — buffer overflow guard MISSING")
        failed_cases++;
      end else if (rd_data[7:0] != 8'h0D) begin
        `uvm_error("TEST",$sformatf("Case A: Wrong error_code=0x%02x (expected 0x0D ERR_BUF_OVERFLOW)",rd_data[7:0]))
        failed_cases++;
      end else begin
        `uvm_info("TEST","Case A PASS: ERR_BUF_OVERFLOW correctly triggered",UVM_NONE)
      end

      // Verify no DMA AR was issued
      `uvm_info("TEST",$sformatf("Case A: ARVALID=%0d ARADDR=0x%08h (should be idle)",
        probe_vif.npu_m_arvalid, probe_vif.npu_m_araddr),UVM_NONE)

      // Clear error (busy=0 after checker reject, so CTRL[4]=1 works)
      seq.axil_write32(`NPU_REG_CTRL, 32'h10);
    end

    // ============================================================
    // Case B: weight_bytes overflow
    // ============================================================
    begin
      bit [31:0] ovf_bytes;
      ovf_bytes = buf_bank_bytes + 32;
      `uvm_info("TEST",$sformatf("-- B: weight_bytes=%0d (>%0d) overflow --",ovf_bytes,buf_bank_bytes),UVM_NONE)

      seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
      seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0040);  // non-null
      seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0000_0040);  // wgt_addr+ovf fits in 1MB
      seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h000C_0000);
      seq.axil_write32(`NPU_REG_INPUT_BYTES,  32'd32);     // legal
      seq.axil_write32(`NPU_REG_WEIGHT_BYTES, ovf_bytes);  // overflow!
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

      seq.axil_read32(`NPU_REG_STATUS, rd_data);
      if (!rd_data[3] && poll_count>=500) begin
        `uvm_error("TEST","Case B: No error detected")
        failed_cases++;
      end else if (rd_data[7:0] != 8'h0D) begin
        `uvm_error("TEST",$sformatf("Case B: Wrong error_code=0x%02x (expected 0x0D)",rd_data[7:0]))
        failed_cases++;
      end else begin
        `uvm_info("TEST","Case B PASS: ERR_BUF_OVERFLOW correctly triggered",UVM_NONE)
      end

      seq.axil_write32(`NPU_REG_CTRL, 32'h10);
    end

    // ============================================================
    // Case C: small input_bytes — checker should NOT reject
    // ============================================================
    begin
      `uvm_info("TEST","-- C: input_bytes=32 (well within capacity) legal --",UVM_NONE)

      seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
      seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0040);
      seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0008_0000);
      seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h000C_0000);
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

      // Poll: checker should NOT report error (task will start and complete)
      for (poll_count=0; poll_count<5000; poll_count++) begin
        seq.axil_read32(`NPU_REG_CTRL, rd_data);
        if (rd_data[3]) break;  // error — should NOT happen
        if (rd_data[2]) break;  // done — expected
        #100;
      end

      if (rd_data[3]) begin
        seq.axil_read32(`NPU_REG_STATUS, rd_data);
        `uvm_error("TEST",$sformatf("Case C: legal input_bytes falsely rejected! error_code=0x%02x",rd_data[7:0]))
        failed_cases++;
      end else if (!rd_data[2] && poll_count>=5000) begin
        `uvm_error("TEST","Case C: Task did not complete (stuck or timeout)")
        failed_cases++;
      end else begin
        `uvm_info("TEST","Case C PASS: legal input_bytes NOT rejected, task completed",UVM_NONE)
      end

      // Clear done (busy=0 now)
      seq.axil_write32(`NPU_REG_CTRL, 32'h10);
    end

    // ============================================================
    // Case D: small weight_bytes — checker should NOT reject
    // ============================================================
    begin
      `uvm_info("TEST","-- D: weight_bytes=32 (well within capacity) legal --",UVM_NONE)

      seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
      seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0040);
      seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0008_0000);
      seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h000C_0000);
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
        if (rd_data[3]) break;
        if (rd_data[2]) break;
        #100;
      end

      if (rd_data[3]) begin
        seq.axil_read32(`NPU_REG_STATUS, rd_data);
        `uvm_error("TEST",$sformatf("Case D: legal weight_bytes falsely rejected! error_code=0x%02x",rd_data[7:0]))
        failed_cases++;
      end else if (!rd_data[2] && poll_count>=5000) begin
        `uvm_error("TEST","Case D: Task did not complete (stuck or timeout)")
        failed_cases++;
      end else begin
        `uvm_info("TEST","Case D PASS: legal weight_bytes NOT rejected, task completed",UVM_NONE)
      end

      seq.axil_write32(`NPU_REG_CTRL, 32'h10);
    end

    `uvm_info("TEST",$sformatf("DMA_BUFFER_CAPACITY_GUARD: %0d/4 cases failed %s",
      failed_cases, (failed_cases==0)?"PASS":"FAIL"),UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
