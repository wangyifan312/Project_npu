`timescale 1ns / 1ps

class soc_mem_model extends uvm_component;

  `uvm_component_utils(soc_mem_model)

  // Analysis import: receives AXI-Lite transactions from monitor
  uvm_analysis_imp #(axil_seq_item, soc_mem_model) axil_imp;

  // Byte-addressable storage
  byte unsigned mem[int unsigned];

  function new(string name = "soc_mem_model", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    axil_imp = new("axil_imp", this);
  endfunction

  // Called by analysis port: update mirror on writes to shared RAM
  function void write(axil_seq_item tr);
    if (tr.cmd == axil_seq_item::AXIL_WRITE && tr.addr < 32'h0010_0000) begin
      write32(tr.addr, tr.data, tr.strb);
      `uvm_info("MEM_MODEL", $sformatf("Mirror write: addr=0x%08h data=0x%08h strb=0x%0h", tr.addr, tr.data, tr.strb), UVM_HIGH)
    end
  endfunction

  // Byte-strobe-aware 32-bit write
  function void write32(bit [31:0] addr, bit [31:0] data, bit [3:0] strb);
    for (int i = 0; i < 4; i++) begin
      if (strb[i]) begin
        mem[addr + i] = data[8*i +: 8];
      end
    end
  endfunction

  // 32-bit read from mirror
  function bit [31:0] read32(bit [31:0] addr);
    bit [31:0] data;
    for (int i = 0; i < 4; i++) begin
      data[8*i +: 8] = mem.exists(addr + i) ? mem[addr + i] : 8'h00;
    end
    return data;
  endfunction

  // Bulk byte write
  function void write_bytes(bit [31:0] base_addr, byte unsigned data[]);
    foreach (data[i]) begin
      mem[base_addr + i] = data[i];
    end
  endfunction

  // Bulk byte read
  function void read_bytes(bit [31:0] base_addr, int unsigned nbytes,
                           output byte unsigned data[]);
    data = new[nbytes];
    for (int i = 0; i < nbytes; i++) begin
      data[i] = mem.exists(base_addr + i) ? mem[base_addr + i] : 8'h00;
    end
    `uvm_info("MEM_MODEL", $sformatf("Read %0d bytes from 0x%08h", nbytes, base_addr), UVM_HIGH)
  endfunction

  // Clear all memory
  function void clear();
    mem.delete();
  endfunction

endclass
