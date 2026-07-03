//=============================================================================
// soc_shared_ram_rw_test.sv — Shared-RAM AXI-Lite Write/Read Test
//
// Sanity test that exercises the AXI-Lite path through the SoC to shared RAM.
// 写s known patterns to various addresses, reads them back, and checks
// 数据 integrity.  Also validates byte-strobe masking.
//=============================================================================

`timescale 1ns / 1ps

class soc_shared_ram_rw_test extends soc_base_test;

  `uvm_component_utils(soc_shared_ram_rw_test)

  function new(string name = "soc_shared_ram_rw_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_base_seq seq;
    bit [31:0] rd_data;

    phase.raise_objection(this);

    // Create and start the base sequence (body is empty, returns immediately;
    // m_sequencer handle remains valid for subsequent start_item/finish_item).
    seq = soc_base_seq::type_id::create("seq");
    seq.start(env.axil_ag.seqr);

    // Allow reset to fully de-assert
    #200;

    `uvm_info("TEST", "=== AXI-Lite Shared RAM Write/Read Test ===", UVM_NONE)

    //-----------------------------------------------------------------------
    // Basic write / read-back at various offsets
    //-----------------------------------------------------------------------
    `uvm_info("TEST", "Writing test patterns...", UVM_NONE)

    seq.axil_write32(32'h0000_0000, 32'hDEADBEEF);
    seq.axil_write32(32'h0000_0004, 32'hCAFEBABE);
    seq.axil_write32(32'h0000_001C, 32'h12345678);
    seq.axil_write32(32'h0000_0020, 32'hAAAA5555);

    // High-address write (near end of 1 MB shared RAM)
    seq.axil_write32(32'h000F_FFFC, 32'hFEEDFACE);

    `uvm_info("TEST", "Reading back and verifying...", UVM_NONE)

    seq.axil_read32(32'h0000_0000, rd_data);
    if (rd_data !== 32'hDEADBEEF)
      `uvm_error("TEST", $sformatf("Mismatch at 0x0000_0000: got 0x%08h expected 0xDEADBEEF", rd_data))

    seq.axil_read32(32'h0000_0004, rd_data);
    if (rd_data !== 32'hCAFEBABE)
      `uvm_error("TEST", $sformatf("Mismatch at 0x0000_0004: got 0x%08h expected 0xCAFEBABE", rd_data))

    seq.axil_read32(32'h0000_001C, rd_data);
    if (rd_data !== 32'h12345678)
      `uvm_error("TEST", $sformatf("Mismatch at 0x0000_001C: got 0x%08h expected 0x12345678", rd_data))

    seq.axil_read32(32'h0000_0020, rd_data);
    if (rd_data !== 32'hAAAA5555)
      `uvm_error("TEST", $sformatf("Mismatch at 0x0000_0020: got 0x%08h expected 0xAAAA5555", rd_data))

    seq.axil_read32(32'h000F_FFFC, rd_data);
    if (rd_data !== 32'hFEEDFACE)
      `uvm_error("TEST", $sformatf("Mismatch at 0x000F_FFFC: got 0x%08h expected 0xFEEDFACE", rd_data))

    //-----------------------------------------------------------------------
    // Byte-strobe tests
    //-----------------------------------------------------------------------
    `uvm_info("TEST", "Testing byte strobes...", UVM_NONE)

    // 写 all zeros first, then build up bytes one at a time
    seq.axil_write32(32'h0000_0100, 32'h00000000);

    // 写 byte 0 only (strb = 4'b0001)
    seq.axil_write32(32'h0000_0100, 32'h000000FF, 4'b0001);
    seq.axil_read32(32'h0000_0100, rd_data);
    if (rd_data !== 32'h000000FF)
      `uvm_error("TEST", $sformatf("Byte strobe 0x1 failed: got 0x%08h", rd_data))

    // 写 byte 1 only (strb = 4'b0010) — keep byte 0 intact
    seq.axil_write32(32'h0000_0100, 32'h0000FF00, 4'b0010);
    seq.axil_read32(32'h0000_0100, rd_data);
    if (rd_data !== 32'h0000FFFF)
      `uvm_error("TEST", $sformatf("Byte strobe 0x2 failed: got 0x%08h", rd_data))

    // 写 bytes 2-3 (strb = 4'b1100)
    seq.axil_write32(32'h0000_0100, 32'hFFFF0000, 4'b1100);
    seq.axil_read32(32'h0000_0100, rd_data);
    if (rd_data !== 32'hFFFFFFFF)
      `uvm_error("TEST", $sformatf("Byte strobe 0xC failed: got 0x%08h", rd_data))

    `uvm_info("TEST", "=== soc_shared_ram_rw_test PASSED ===", UVM_NONE)

    phase.drop_objection(this);
  endtask

endclass
