`timescale 1ns / 1ps

class npu_start_poll_seq extends soc_base_seq;

  `uvm_object_utils(npu_start_poll_seq)

  int unsigned timeout_cycles;
  bit done;
  bit error;
  bit [7:0] error_code;

  function new(string name = "npu_start_poll_seq");
    super.new(name);
    timeout_cycles = 5000000;
    done   = 1'b0;
    error  = 1'b0;
    error_code = 8'h0;
  endfunction

  virtual task body();
    bit [31:0] rd;
    int i;

    `uvm_info("NPU_START", "Starting NPU task...", UVM_MEDIUM)

    // Start task. npu_ctrl now auto-clears done/error when CTRL bit[0]=1.
    axil_write32(`NPU_REG_CTRL, 32'h1);    // start task (auto-clears done/error)

    for (i = 0; i < timeout_cycles; i++) begin
      axil_read32(`NPU_REG_CTRL, rd);
      if (rd[2]) begin
        done = 1'b1;
        `uvm_info("NPU_POLL", $sformatf("NPU done at poll %0d", i), UVM_MEDIUM)
        break;
      end
      if (rd[3]) begin
        error = 1'b1;
        axil_read32(`NPU_REG_STATUS, rd);
        error_code = rd[7:0];
        `uvm_info("NPU_POLL", $sformatf("NPU error at poll %0d: code=0x%02x", i, error_code), UVM_MEDIUM)
        break;
      end
    end

    if (!done && !error) begin
      `uvm_error("NPU_POLL", $sformatf("Timeout after %0d poll iterations", timeout_cycles))
    end
  endtask

endclass
