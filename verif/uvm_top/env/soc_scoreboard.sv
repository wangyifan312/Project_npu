`timescale 1ns / 1ps

class soc_scoreboard extends uvm_component;

  `uvm_component_utils(soc_scoreboard)

  // Analysis imports
  uvm_analysis_imp #(axil_seq_item, soc_scoreboard) axil_imp;

  // 错误 tracking
  int unsigned axil_write_count = 0;
  int unsigned axil_read_count = 0;
  int unsigned axil_error_count = 0;

  // 输出 compare tracking
  int unsigned compared_bytes = 0;
  int unsigned mismatch_count = 0;
  int unsigned first_mismatch_offset = -1;

  function new(string name = "soc_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    axil_imp = new("axil_imp", this);
  endfunction

  // AXI-Lite transaction checker
  function void write(axil_seq_item tr);
    if (tr.cmd == axil_seq_item::AXIL_WRITE) begin
      axil_write_count++;
    end else begin
      axil_read_count++;
    end
    // Check response
    if (tr.resp != 2'b00) begin
      axil_error_count++;
      `uvm_error("SCOREBOARD", $sformatf("AXI-Lite error response: addr=0x%08h resp=%0d cmd=%0s",
        tr.addr, tr.resp, tr.cmd == axil_seq_item::AXIL_WRITE ? "WRITE" : "READ"))
    end
  endfunction

  // Byte-by-byte output comparison with golden
  function void compare_output_bytes(byte unsigned actual[], byte unsigned expected[],
                                     bit [31:0] base_addr = 0);
    compared_bytes = actual.size() < expected.size() ? actual.size() : expected.size();
    mismatch_count = 0;
    first_mismatch_offset = -1;

    for (int i = 0; i < compared_bytes; i++) begin
      if (actual[i] !== expected[i]) begin
        if (mismatch_count == 0) first_mismatch_offset = i;
        mismatch_count++;
        if (mismatch_count <= 10) begin  // limit verbose output
          `uvm_error("SCOREBOARD", $sformatf(
            "Output mismatch at addr=0x%08h (byte %0d): actual=%02x expected=%02x",
            base_addr + i, i, actual[i], expected[i]))
        end
      end
    end

    if (actual.size() != expected.size()) begin
      `uvm_error("SCOREBOARD", $sformatf(
        "Output size mismatch: actual=%0d bytes expected=%0d bytes",
        actual.size(), expected.size()))
    end

    if (mismatch_count == 0) begin
      `uvm_info("SCOREBOARD", $sformatf(
        "Output compare PASS: %0d bytes matched", compared_bytes), UVM_NONE)
    end else begin
      `uvm_info("SCOREBOARD", $sformatf(
        "Output compare FAIL: %0d/%0d mismatches, first at byte %0d",
        mismatch_count, compared_bytes, first_mismatch_offset), UVM_NONE)
    end
  endfunction

  // Report summary
  function void report_phase(uvm_phase phase);
    `uvm_info("SCOREBOARD", $sformatf(
      "AXI-Lite: writes=%0d reads=%0d errors=%0d | Output: %0d bytes, %0d mismatches",
      axil_write_count, axil_read_count, axil_error_count,
      compared_bytes, mismatch_count), UVM_NONE)
  endfunction

endclass
