//=============================================================================
// backdoor_if.sv — Fast shared-RAM access for fixture data loading
//
// Provides task/function methods that UVM tests can call through a virtual
// interface handle to bulk-load .memh files directly into the DUT shared RAM
// without going through slow per-word AXI-Lite writes.
//
// Interface tasks use $root hierarchical references to access the DUT RAM.
// The interface is instantiated in tb_soc_top_uvm and passed to UVM tests
// via uvm_config_db.
//=============================================================================

`timescale 1ns / 1ps

interface backdoor_if;

  // Large buffer for $readmemh — at interface scope to avoid VCS issues
  reg [31:0] words [0:131071];

  //---------------------------------------------------------------------------
  // load_memh — load a .memh file directly into the DUT shared RAM
  //---------------------------------------------------------------------------
  task load_memh(input string fname, input int base_addr, input int nwords);
    int i;
    int byte_addr;
    int beat_idx;
    int bit_offs;
    $readmemh(fname, words, 0, nwords - 1);
    for (i = 0; i < nwords; i = i + 1) begin
      byte_addr = base_addr + i * 4;
      beat_idx  = byte_addr >> 5;
      bit_offs  = (byte_addr & 31) * 8;
      $root.tb_soc_top_uvm.u_top.u_shared_ram.ram[beat_idx][bit_offs +: 32] = words[i];
    end
  endtask

  //---------------------------------------------------------------------------
  // read32 — read a single 32-bit word from the DUT shared RAM
  //---------------------------------------------------------------------------
  function int read32(input int byte_addr);
    int beat_idx;
    int bit_offs;
    beat_idx = byte_addr >> 5;
    bit_offs = (byte_addr & 31) * 8;
    read32 = int'($root.tb_soc_top_uvm.u_top.u_shared_ram.ram[beat_idx][bit_offs +: 32]);
  endfunction

endinterface
