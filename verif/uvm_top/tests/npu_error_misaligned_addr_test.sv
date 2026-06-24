//=============================================================================
// npu_error_misaligned_addr_test.sv — Misaligned Address Error Path Test
//
// Verifies that non-64B-aligned input_address triggers ERR_ADDR_ALIGN (0x04).
// The task_checker requires all active addresses to have bits[5:0] == 0.
//=============================================================================

`timescale 1ns / 1ps

class npu_error_misaligned_addr_test extends soc_base_test;

  `uvm_component_utils(npu_error_misaligned_addr_test)

  function new(string name = "npu_error_misaligned_addr_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq seq;
    bit [31:0] rd_data;
    int poll_count;
    bit error_detected;
    bit stuck_busy;

    phase.raise_objection(this);

    // Create and start base sequence to set up m_sequencer handle
    seq = soc_base_seq::type_id::create("seq");
    seq.start(env.axil_ag.seqr);

    // Allow reset to fully de-assert
    #200;

    `uvm_info("TEST", "=== npu_error_misaligned_addr_test: Misaligned Address Error ===", UVM_NONE)

    //-----------------------------------------------------------------------
    // Step 1: Configure a Conv task with misaligned input_addr
    //   input_addr  = 0x0000_0004  (NOT 64B-aligned: bits[5:0] = 0x04)
    //   weight_addr = 0x0000_0040  (64B-aligned)
    //   output_addr = 0x0000_0080  (64B-aligned)
    //-----------------------------------------------------------------------
    `uvm_info("TEST", "Configuring Conv task with misaligned input_addr=0x0000_0004...", UVM_NONE)

    seq.axil_write32(`NPU_REG_TASK_TYPE,   32'd0);             // TASK_CONV
    seq.axil_write32(`NPU_REG_INPUT_ADDR,  32'h0000_0004);     // MISALIGNED: bits[5:0]=0x04
    seq.axil_write32(`NPU_REG_WEIGHT_ADDR, 32'h0000_0040);     // aligned
    seq.axil_write32(`NPU_REG_OUTPUT_ADDR, 32'h0000_0080);     // aligned
    seq.axil_write32(`NPU_REG_INPUT_BYTES,  32'd25);
    seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd25);
    seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd25);
    seq.axil_write32(`NPU_REG_DIM_IN,      {16'd5, 16'd5});    // W=5, H=5
    seq.axil_write32(`NPU_REG_DIM_OUT,     {16'd1, 16'd1});    // Cout=1, Cin=1
    seq.axil_write32(`NPU_REG_CONV_CFG,    32'h0);
    seq.axil_write32(`NPU_REG_POSTPROC,    32'h0);
    seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd2);
    seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd63);

    //-----------------------------------------------------------------------
    // Step 2: Start the task (write CTRL[0]=1)
    //-----------------------------------------------------------------------
    `uvm_info("TEST", "Starting task with misaligned address...", UVM_NONE)
    seq.axil_write32(`NPU_REG_CTRL, 32'h1);

    //-----------------------------------------------------------------------
    // Step 3: Poll CTRL register — expect error=1
    //-----------------------------------------------------------------------
    error_detected = 1'b0;
    for (poll_count = 0; poll_count < 5000; poll_count++) begin
      seq.axil_read32(`NPU_REG_CTRL, rd_data);
      if (rd_data[3]) begin  // error bit set
        error_detected = 1'b1;
        `uvm_info("TEST", $sformatf("Error detected at poll %0d", poll_count), UVM_NONE)
        break;
      end
      if (rd_data[2]) begin  // done bit set — should not happen
        `uvm_error("TEST", "Task unexpectedly completed with done=1 (expected error)")
        break;
      end
    end

    if (!error_detected) begin
      `uvm_error("TEST", $sformatf("Timeout after %0d polls: no error or done detected", poll_count))
    end

    //-----------------------------------------------------------------------
    // Step 4: Read error_code from STATUS register — expect 0x04 (ERR_ADDR_ALIGN)
    //-----------------------------------------------------------------------
    seq.axil_read32(`NPU_REG_STATUS, rd_data);
    if (rd_data[7:0] == 8'h04) begin
      `uvm_info("TEST", "PASS: error_code = 0x04 (ERR_ADDR_ALIGN) as expected", UVM_NONE)
    end else begin
      `uvm_error("TEST", $sformatf("Unexpected error_code: 0x%02x (expected 0x04)", rd_data[7:0]))
    end

    //-----------------------------------------------------------------------
    // Step 5: Verify NPU is NOT stuck busy (busy should be 0 after error)
    //-----------------------------------------------------------------------
    stuck_busy = 1'b0;
    for (poll_count = 0; poll_count < 100; poll_count++) begin
      seq.axil_read32(`NPU_REG_CTRL, rd_data);
      if (rd_data[1]) begin  // busy
        stuck_busy = 1'b1;
      end else begin
        stuck_busy = 1'b0;
        break;
      end
    end

    if (stuck_busy) begin
      `uvm_error("TEST", "NPU is stuck busy after error detection")
    end else begin
      `uvm_info("TEST", "NPU not stuck busy after error — OK", UVM_NONE)
    end

    //-----------------------------------------------------------------------
    // Step 6: Clear error (CTRL[4]=1) and verify recovery
    //-----------------------------------------------------------------------
    seq.axil_write32(`NPU_REG_CTRL, 32'h10);  // clear error
    seq.axil_read32(`NPU_REG_CTRL, rd_data);
    if (rd_data[3]) begin
      `uvm_error("TEST", "Error bit not cleared after CTRL[4]=1 write")
    end else begin
      `uvm_info("TEST", "Error bit cleared successfully", UVM_NONE)
    end

    `uvm_info("TEST", "=== npu_error_misaligned_addr_test PASSED ===", UVM_NONE)
    phase.drop_objection(this);
  endtask

endclass
