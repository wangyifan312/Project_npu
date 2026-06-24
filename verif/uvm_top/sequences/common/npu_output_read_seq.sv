`timescale 1ns / 1ps

class npu_output_read_seq extends soc_base_seq;

  `uvm_object_utils(npu_output_read_seq)

  bit [31:0] output_addr;
  int unsigned output_bytes;
  byte unsigned actual[];

  function new(string name = "npu_output_read_seq");
    super.new(name);
    output_addr  = 32'h0;
    output_bytes = 0;
  endfunction

  virtual task body();
    bit [31:0] word_addr;
    bit [31:0] word_data;
    int num_words;
    int byte_idx;
    int w, b;

    num_words = (output_bytes + 3) / 4;
    actual = new[output_bytes];

    `uvm_info("OUTPUT_RD", $sformatf("Reading %0d bytes from 0x%08h", output_bytes, output_addr), UVM_MEDIUM)

    for (w = 0; w < num_words; w++) begin
      word_addr = output_addr + (w * 4);
      axil_read32(word_addr, word_data);
      for (b = 0; b < 4; b++) begin
        byte_idx = w * 4 + b;
        if (byte_idx < output_bytes)
          actual[byte_idx] = word_data[8*b +: 8];
      end
    end

    `uvm_info("OUTPUT_RD", "Output read complete", UVM_MEDIUM)
  endtask

endclass
