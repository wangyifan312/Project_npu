//=============================================================================
// soc_cpu_npu_polling_smoke_test.sv — Phase U8-b PicoRV32 CPU Polling Smoke
//
// Proves PicoRV32 CPU can boot from shared_ram (backdoor preloaded firmware),
// write NPU CSR via CPU AXI master, start NPU task, and poll CTRL.done.
// Uses backdoor_if.read32() for shared_ram reads (BFM disabled in CPU mode).
//=============================================================================
`timescale 1ns / 1ps

class soc_cpu_npu_polling_smoke_test extends soc_base_test;
  `uvm_component_utils(soc_cpu_npu_polling_smoke_test)
  function new(string name="soc_cpu_npu_polling_smoke_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    virtual backdoor_if bd_if;
    int rdata, i, timeout_cycles;

    // Get backdoor interface handle (before raising objection for time-0 load)
    if (!uvm_config_db#(virtual backdoor_if)::get(this, "", "bd_if", bd_if))
      `uvm_fatal("CPU_POLL", "backdoor_if not found in config_db")

    // Step 1: Preload firmware via backdoor BEFORE reset release
    `uvm_info("CPU_POLL", "=== CPU POLLING SMOKE (Phase U8-b) ===", UVM_NONE)
    `uvm_info("CPU_POLL", "Loading firmware via backdoor...", UVM_NONE)
    bd_if.load_memh("verif/firmware/npu_irq_smoke/polling_firmware.memh", 0, 1024);
    `uvm_info("CPU_POLL", $sformatf("FW loaded: addr0=0x%08x addr4=0x%08x addr8=0x%08x",
      bd_if.read32(32'h00000000), bd_if.read32(32'h00000004), bd_if.read32(32'h00000008)), UVM_NONE)

    // Verify magic flag area is clear
    `uvm_info("CPU_POLL", $sformatf("Pre-boot: MAGIC_BOOT=0x%08x MAGIC_DONE=0x%08x",
      bd_if.read32(32'h000FF000), bd_if.read32(32'h000FF004)), UVM_NONE)

    phase.raise_objection(this);
    // Delay to allow CPU to boot (reset released at t=100ns)
    #1000;

    // Step 2: Wait for MAGIC_BOOT = 0xB007B007 at 0x000FF000
    `uvm_info("CPU_POLL", "Waiting for MAGIC_BOOT...", UVM_NONE)
    timeout_cycles = 200000;
    for (i=0; i<timeout_cycles; i++) begin
      rdata = bd_if.read32(32'h000FF000);
      if (rdata == 32'hB007B007) begin
        `uvm_info("CPU_POLL", $sformatf("MAGIC_BOOT at cycle %0d", i*100), UVM_NONE)
        break;
      end
      #100;
    end
    if (rdata != 32'hB007B007) begin
      `uvm_error("CPU_POLL", "MAGIC_BOOT not seen")
      phase.drop_objection(this); return;
    end

    // Step 3: Wait for MAGIC_POLL_DONE = 0xD00ED00E at 0x000FF004
    `uvm_info("CPU_POLL", "Waiting for MAGIC_POLL_DONE...", UVM_NONE)
    for (i=0; i<timeout_cycles; i++) begin
      rdata = bd_if.read32(32'h000FF004);
      if (rdata == 32'hD00ED00E) begin
        `uvm_info("CPU_POLL", $sformatf("MAGIC_POLL_DONE at cycle %0d", i*100), UVM_NONE)
        break;
      end
      #100;
    end
    if (rdata != 32'hD00ED00E) begin
      `uvm_error("CPU_POLL", "MAGIC_POLL_DONE not seen")
      phase.drop_objection(this); return;
    end

    // Step 4: Wait for MAGIC_TEST_DONE = 0x55AA55AA at 0x000FF010
    `uvm_info("CPU_POLL", "Waiting for MAGIC_TEST_DONE...", UVM_NONE)
    for (i=0; i<timeout_cycles; i++) begin
      rdata = bd_if.read32(32'h000FF010);
      if (rdata == 32'h55AA55AA) begin
        `uvm_info("CPU_POLL", $sformatf("MAGIC_TEST_DONE at cycle %0d", i*100), UVM_NONE)
        break;
      end
      #100;
    end
    if (rdata != 32'h55AA55AA) begin
      `uvm_error("CPU_POLL", "MAGIC_TEST_DONE not seen")
      phase.drop_objection(this); return;
    end

    // Step 5: Verify NPU output at 0x00030000
    rdata = bd_if.read32(32'h00030000);
    `uvm_info("CPU_POLL", $sformatf("Output: 0x%08x (expected 4)", rdata), UVM_NONE)
    if (rdata != 32'd4) begin
      `uvm_error("CPU_POLL", $sformatf("Output mismatch: %0d expected 4", rdata))
    end

    // Step 6: Check cpu_trap
    if (probe_vif.cpu_trap)
      `uvm_error("CPU_POLL", "cpu_trap asserted!")
    else
      `uvm_info("CPU_POLL", "cpu_trap = 0 PASS", UVM_NONE)

    `uvm_info("CPU_POLL", "=== CPU POLLING SMOKE COMPLETE ===", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
