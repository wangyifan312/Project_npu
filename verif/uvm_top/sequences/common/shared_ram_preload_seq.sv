`timescale 1ns / 1ps

class shared_ram_preload_seq extends soc_base_seq;

  `uvm_object_utils(shared_ram_preload_seq)

  bit [31:0] base_addr;
  byte unsigned data[];

  function new(string name = "shared_ram_preload_seq");
    super.new(name);
  endfunction

  virtual task body();
    bit [31:0] word_addr;
    bit [31:0] word_data;
    int num_words;
    int byte_idx;
    int w, b;

    `uvm_info("PRELOAD", $sformatf("Preloading %0d bytes to shared RAM at 0x%08h", data.size(), base_addr), UVM_MEDIUM)

    num_words = (data.size() + 3) / 4;

    for (w = 0; w < num_words; w++) begin
      word_addr = base_addr + (w * 4);
      word_data = 32'h0;
      for (b = 0; b < 4; b++) begin
        byte_idx = w * 4 + b;
        if (byte_idx < data.size())
          word_data[8*b +: 8] = data[byte_idx];
      end
      axil_write32(word_addr, word_data);
    end

    `uvm_info("PRELOAD", $sformatf("Preload complete: %0d words written", num_words), UVM_MEDIUM)
  endtask

endclass
