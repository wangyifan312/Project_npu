//=============================================================================
// soc_base_seq.sv — 带 AXI-Lite 便捷任务的基础序列
//
// 提供阻塞式 axil_write32 / axil_read32 辅助函数 that all derived
// 序列s and test run_phase code can use for register-programming and
// shared-RAM access.
//=============================================================================

`timescale 1ns / 1ps

class soc_base_seq extends uvm_sequence #(axil_seq_item);

  `uvm_object_utils(soc_base_seq)

  function new(string name = "soc_base_seq");
    super.new(name);
  endfunction

  //---------------------------------------------------------------------------
  // axil_write32 — 阻塞式 AXI-Lite 写
  //---------------------------------------------------------------------------
  task axil_write32(bit [31:0] addr, bit [31:0] data, bit [3:0] strb = 4'hF);
    axil_seq_item tr;
    tr = axil_seq_item::type_id::create("tr");
    tr.cmd  = axil_seq_item::AXIL_WRITE;
    tr.addr = addr;
    tr.data = data;
    tr.strb = strb;
    start_item(tr);
    finish_item(tr);
    if (tr.resp != 2'b00)
      `uvm_error("BASE_SEQ", $sformatf("AXI-Lite write error: addr=0x%08h resp=%0d", addr, tr.resp))
  endtask

  //---------------------------------------------------------------------------
  // axil_read32 — 阻塞式 AXI-Lite 读
  //---------------------------------------------------------------------------
  task axil_read32(bit [31:0] addr, output bit [31:0] data);
    axil_seq_item tr;
    tr = axil_seq_item::type_id::create("tr");
    tr.cmd  = axil_seq_item::AXIL_READ;
    tr.addr = addr;
    start_item(tr);
    finish_item(tr);
    data = tr.rdata;
    if (tr.resp != 2'b00)
      `uvm_error("BASE_SEQ", $sformatf("AXI-Lite read error: addr=0x%08h resp=%0d", addr, tr.resp))
  endtask

  //---------------------------------------------------------------------------
  // body — empty by default; subclasses override with their own flow
  //---------------------------------------------------------------------------
  virtual task body();
  endtask

endclass
