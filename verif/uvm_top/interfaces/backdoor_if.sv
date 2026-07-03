//=============================================================================
// backdoor_if.sv — 用于加载测试数据的快速共享 RAM 访问
//
// Provides task/function methods that UVM tests can call through a virtual
// 批量加载 .memh 文件到 DUT 共享 RAM 的接口
// without going through slow per-word AXI-Lite writes.
//
// Interface tasks use $root hierarchical references to access the DUT RAM.
// The interface is instantiated in tb_soc_top_uvm and passed to UVM tests
// via uvm_config_db.
//=============================================================================

`timescale 1ns / 1ps

interface backdoor_if;

  // $readmemh 的大缓冲区 — 在接口作用域以避免 VCS 问题
  reg [31:0] words [0:131071];

  //---------------------------------------------------------------------------
  // load_memh — 将 .memh 文件直接加载到 DUT 共享 RAM
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
  // read32 — 从 DUT 共享 RAM 读取单个 32-bit 字
  //---------------------------------------------------------------------------
  function int read32(input int byte_addr);
    int beat_idx;
    int bit_offs;
    beat_idx = byte_addr >> 5;
    bit_offs = (byte_addr & 31) * 8;
    read32 = int'($root.tb_soc_top_uvm.u_top.u_shared_ram.ram[beat_idx][bit_offs +: 32]);
  endfunction

endinterface
