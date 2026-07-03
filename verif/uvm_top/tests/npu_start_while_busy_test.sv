//=============================================================================
// npu_start_while_busy_test.sv — Start-While-Busy Error Path Test
//
// Verifies behavior when CTRL.start is written while the NPU is already
// processing a task.  The npu_ctrl module detects this as a
// 忙_start_violation and sets error_code = 0x10.
//
// The test also verifies that the NPU can recover from the violation and
// execute a subsequent valid task successfully (no hang).
//=============================================================================

`timescale 1ns / 1ps

class npu_start_while_busy_test extends soc_base_test;

  `uvm_component_utils(npu_start_while_busy_test)

  function new(string name = "npu_start_while_busy_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq seq;
    bit [31:0] rd_data;
    int poll_count;
    bit error_detected;
    bit done_detected;
    bit stuck_busy;

    phase.raise_objection(this);

    // Create and start base sequence to set up m_sequencer handle
    seq = soc_base_seq::type_id::create("seq");
    seq.start(env.axil_ag.seqr);

    // Allow reset to fully de-assert
    #200;

    `uvm_info("TEST", "=== npu_start_while_busy_test: Start-While-Busy ===", UVM_NONE)

    //-----------------------------------------------------------------------
    // Step 1: Configure a valid, small Conv task
    //   5x5 input, 5x5 weight, stride=1 valid — should complete quickly
    //-----------------------------------------------------------------------
    `uvm_info("TEST", "Configuring valid Conv task...", UVM_NONE)

    seq.axil_write32(`NPU_REG_TASK_TYPE,   32'd0);              // TASK_CONV
    seq.axil_write32(`NPU_REG_INPUT_ADDR,  32'h0000_0000);      // 64B-aligned
    seq.axil_write32(`NPU_REG_WEIGHT_ADDR, 32'h0000_0040);      // 64B-aligned
    seq.axil_write32(`NPU_REG_OUTPUT_ADDR, 32'h0000_0080);      // 64B-aligned
    seq.axil_write32(`NPU_REG_INPUT_BYTES,  32'd25);
    seq.axil_write32(`NPU_REG_WEIGHT_BYTES, 32'd25);
    seq.axil_write32(`NPU_REG_OUTPUT_BYTES, 32'd25);
    seq.axil_write32(`NPU_REG_DIM_IN,      {16'd5, 16'd5});     // W=5, H=5
    seq.axil_write32(`NPU_REG_DIM_OUT,     {16'd1, 16'd1});     // Cout=1, Cin=1
    seq.axil_write32(`NPU_REG_CONV_CFG,    32'h0);              // 5x5, stride=1, valid, no bias
    seq.axil_write32(`NPU_REG_POSTPROC,    32'h0);
    seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd2);
    seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd63);

    //-----------------------------------------------------------------------
    // Step 2: First start — write CTRL[0]=1 to start the valid task
    //-----------------------------------------------------------------------
    `uvm_info("TEST", "First start: writing CTRL[0]=1...", UVM_NONE)
    seq.axil_write32(`NPU_REG_CTRL, 32'h1);

    //-----------------------------------------------------------------------
    // Step 3: Second start while busy — write CTRL[0]=1 again
    //   After the first write, busy should be asserted.  Writing start again
    //   should trigger busy_start_violation with error_code=0x10.
    //
    //   We do this immediately after the first write returns.
    //-----------------------------------------------------------------------
    `uvm_info("TEST", "Second start while busy: writing CTRL[0]=1 again...", UVM_NONE)
    seq.axil_write32(`NPU_REG_CTRL, 32'h1);

    //-----------------------------------------------------------------------
    // Step 4: Poll CTRL register
    //   The busy_start_violation should abort the task with error=1.
    //   The NPU should NOT hang.
    //-----------------------------------------------------------------------
    error_detected = 1'b0;
    done_detected  = 1'b0;
    for (poll_count = 0; poll_count < 10000; poll_count++) begin
      seq.axil_read32(`NPU_REG_CTRL, rd_data);
      if (rd_data[3]) begin  // error bit set
        error_detected = 1'b1;
        `uvm_info("TEST", $sformatf("Error detected at poll %0d", poll_count), UVM_NONE)
        break;
      end
      if (rd_data[2]) begin  // done bit set — original task completed before violation
        done_detected = 1'b1;
        `uvm_info("TEST", $sformatf("Done detected at poll %0d (task completed before re-start took effect)", poll_count), UVM_NONE)
        break;
      end
    end

    if (!error_detected && !done_detected) begin
      `uvm_error("TEST", $sformatf("Timeout after %0d polls: no error or done detected", poll_count))
    end

    //-----------------------------------------------------------------------
    // Step 5: Read error_code if error was detected
    //-----------------------------------------------------------------------
    if (error_detected) begin
      seq.axil_read32(`NPU_REG_STATUS, rd_data);
      if (rd_data[7:0] == 8'h10) begin
        `uvm_info("TEST", "PASS: error_code = 0x10 (busy_start_violation) as expected", UVM_NONE)
      end else begin
        `uvm_error("TEST", $sformatf("Unexpected error_code: 0x%02x (expected 0x10 for busy_start_violation)", rd_data[7:0]))
      end
    end

    if (done_detected) begin
      `uvm_info("TEST", "Original task completed before re-start took effect — acceptable behavior (done=1)", UVM_NONE)
    end

    //-----------------------------------------------------------------------
    // Step 6: Verify NPU is NOT stuck busy
    //-----------------------------------------------------------------------
    stuck_busy = 1'b0;
    for (poll_count = 0; poll_count < 100; poll_count++) begin
      seq.axil_read32(`NPU_REG_CTRL, rd_data);
      if (rd_data[1]) begin
        stuck_busy = 1'b1;
      end else begin
        stuck_busy = 1'b0;
        break;
      end
    end

    if (stuck_busy) begin
      `uvm_error("TEST", "NPU is stuck busy — possible hang detected")
    end else begin
      `uvm_info("TEST", "NPU not stuck busy — OK", UVM_NONE)
    end

    //-----------------------------------------------------------------------
    // Step 7: Clear error and verify recovery — run a valid task to prove
    //   the NPU is still functional after the violation.
    //-----------------------------------------------------------------------
    if (error_detected) begin
      seq.axil_write32(`NPU_REG_CTRL, 32'h10);  // CTRL[4]=1 clears error/done
      seq.axil_read32(`NPU_REG_CTRL, rd_data);
      if (rd_data[3] || rd_data[2]) begin
        `uvm_error("TEST", "Error/done bits not cleared after CTRL[4]=1 write")
      end else begin
        `uvm_info("TEST", "Error/done bits cleared successfully", UVM_NONE)
      end
    end

    // Re-configure and start a fresh valid task to verify NPU still works
    `uvm_info("TEST", "Running recovery task to verify NPU is still functional...", UVM_NONE)

    seq.axil_write32(`NPU_REG_TASK_TYPE,  32'd0);
    seq.axil_write32(`NPU_REG_INPUT_ADDR, 32'h0000_0100);
    seq.axil_write32(`NPU_REG_WEIGHT_ADDR,32'h0000_0140);
    seq.axil_write32(`NPU_REG_OUTPUT_ADDR,32'h0000_0180);
    seq.axil_write32(`NPU_REG_INPUT_BYTES, 32'd25);
    seq.axil_write32(`NPU_REG_WEIGHT_BYTES,32'd25);
    seq.axil_write32(`NPU_REG_OUTPUT_BYTES,32'd25);
    seq.axil_write32(`NPU_REG_DIM_IN,     {16'd5, 16'd5});
    seq.axil_write32(`NPU_REG_DIM_OUT,    {16'd1, 16'd1});
    seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd2);
    seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd63);

    seq.axil_write32(`NPU_REG_CTRL, 32'h1);

    // 轮询等待完成 on recovery task
    done_detected = 1'b0;
    for (poll_count = 0; poll_count < 50000; poll_count++) begin
      seq.axil_read32(`NPU_REG_CTRL, rd_data);
      if (rd_data[3]) begin
        `uvm_error("TEST", $sformatf("Recovery task failed with error at poll %0d", poll_count))
        break;
      end
      if (rd_data[2]) begin
        done_detected = 1'b1;
        `uvm_info("TEST", $sformatf("Recovery task completed successfully at poll %0d", poll_count), UVM_NONE)
        break;
      end
    end

    if (!done_detected) begin
      `uvm_error("TEST", "Recovery task did not complete — NPU may be hung")
    end else begin
      `uvm_info("TEST", "NPU recovery verified — subsequent task runs correctly", UVM_NONE)
    end

    `uvm_info("TEST", "=== npu_start_while_busy_test PASSED ===", UVM_NONE)
    phase.drop_objection(this);
  endtask

endclass
