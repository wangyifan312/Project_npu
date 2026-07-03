//=============================================================================
// soc_cpu_boot_magic_smoke_test.sv — Phase U8-b0 PicoRV32 Boot Magic Test
//
// Minimal firmware: write 0xB007B007 to 0x000FF000, infinite loop.
// Proves PicoRV32 can fetch+execute from shared_ram.
// No NPU access. 5-instruction firmware (boot_magic.memh).
//=============================================================================
`timescale 1ns / 1ps

class soc_cpu_boot_magic_smoke_test extends soc_base_test;
  `uvm_component_utils(soc_cpu_boot_magic_smoke_test)
  function new(string name="soc_cpu_boot_magic_smoke_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    virtual backdoor_if bd_if;
    int rdata, i, timeout_cycles;

    // Get backdoor interface before objection
    if (!uvm_config_db#(virtual backdoor_if)::get(this, "", "bd_if", bd_if))
      `uvm_fatal("BOOTMAG", "backdoor_if not found in config_db")

    // Load firmware at time 0, BEFORE CPU reset released
    `uvm_info("BOOTMAG", "=== CPU BOOT MAGIC SMOKE (Phase U8-b0) ===", UVM_NONE)
    bd_if.load_memh("verif/firmware/npu_irq_smoke/boot_magic.memh", 0, 16);

    // Verify firmware loaded correctly
    `uvm_info("BOOTMAG", $sformatf("FW[0x00]=0x%08h FW[0x04]=0x%08h FW[0x08]=0x%08h FW[0x0C]=0x%08h FW[0x10]=0x%08h",
      bd_if.read32(32'h00000000), bd_if.read32(32'h00000004),
      bd_if.read32(32'h00000008), bd_if.read32(32'h0000000C),
      bd_if.read32(32'h00000010)), UVM_NONE)

    // Confirm magic area is clear
    `uvm_info("BOOTMAG", $sformatf("Pre:  MAGIC=0x%08h (expect 0)",
      bd_if.read32(32'h000FF000)), UVM_NONE)

    phase.raise_objection(this);
    #1000;

    // Wait for MAGIC_BOOT = 0xB007B007
    timeout_cycles = 100000;
    for (i=0; i<timeout_cycles; i++) begin
      rdata = bd_if.read32(32'h000FF000);
      if (rdata == 32'hB007B007) begin
        `uvm_info("BOOTMAG", $sformatf("MAGIC_BOOT at cycle %0d", i*100+1000), UVM_NONE)
        break;
      end
      #100;
    end

    if (rdata != 32'hB007B007) begin
      `uvm_info("BOOTMAG", $sformatf("Timeout: MAGIC=0x%08h cpu_trap=%0d",
        rdata, probe_vif.cpu_trap), UVM_NONE)
      `uvm_error("BOOTMAG", "MAGIC_BOOT not seen")
      phase.drop_objection(this);
      return;
    end

    // Success
    `uvm_info("BOOTMAG", $sformatf("cpu_trap=%0d", probe_vif.cpu_trap), UVM_NONE)
    if (probe_vif.cpu_trap)
      `uvm_error("BOOTMAG", "cpu_trap asserted!")

    `uvm_info("BOOTMAG", "=== CPU BOOT MAGIC SMOKE PASS ===", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
