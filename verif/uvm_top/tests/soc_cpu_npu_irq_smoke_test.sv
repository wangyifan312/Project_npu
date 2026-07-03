//=============================================================================
// soc_cpu_npu_irq_smoke_test.sv — Phase U8-b2 CPU NPU IRQ Smoke
//
// PicoRV32 configures NPU, enables done IRQ, starts task.
// Verifies IRQ handler: reads IRQ_STATUS, writes MAGIC_IRQ_SEEN,
// 清除s IRQ (npu_irq deasserted). Backdoor preload + monitor.
//=============================================================================
`timescale 1ns / 1ps

class soc_cpu_npu_irq_smoke_test extends soc_base_test;
  `uvm_component_utils(soc_cpu_npu_irq_smoke_test)
  function new(string name="soc_cpu_npu_irq_smoke_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    virtual backdoor_if bd_if;
    int rdata, i, timeout_cycles;
    bit npu_irq_seen, npu_irq_cleared;

    if (!uvm_config_db#(virtual backdoor_if)::get(this, "", "bd_if", bd_if))
      `uvm_fatal("CPU_IRQ", "backdoor_if not found")

    // ---- Preload firmware + data at time 0 ----
    `uvm_info("CPU_IRQ", "=== CPU NPU IRQ SMOKE (Phase U8-b2) ===", UVM_NONE)
    bd_if.load_memh("verif/firmware/npu_irq_smoke/npu_irq_smoke.memh", 0, 256);
    `uvm_info("CPU_IRQ", $sformatf("FW[0x00]=0x%08h FW[0x10]=0x%08h",
      bd_if.read32(0), bd_if.read32(32'h10)), UVM_NONE)

    // 预加载 input/weight with all-ones
    begin int fd;
      fd = $fopen("/tmp/u8b2_ones.memh", "w");
      $fwrite(fd, "01010101\n");
      $fclose(fd);
    end
    bd_if.load_memh("/tmp/u8b2_ones.memh", 32'h00010000, 1);
    bd_if.load_memh("/tmp/u8b2_ones.memh", 32'h00020000, 1);

    // 清除 output + magic
    begin int fd;
      fd = $fopen("/tmp/u8b2_zero.memh", "w");
      for (i=0; i<16; i=i+1) $fwrite(fd, "00000000\n");
      $fclose(fd);
    end
    bd_if.load_memh("/tmp/u8b2_zero.memh", 32'h00030000, 8);
    bd_if.load_memh("/tmp/u8b2_zero.memh", 32'h000FF000, 16);

    phase.raise_objection(this);

    // ---- Launch npu_irq monitor ----
    fork
      begin
        wait (probe_vif.npu_irq === 1'b1);
        npu_irq_seen = 1'b1;
        `uvm_info("CPU_IRQ", "npu_irq RISING detected", UVM_NONE)
        wait (probe_vif.npu_irq === 1'b0);
        npu_irq_cleared = 1'b1;
        `uvm_info("CPU_IRQ", "npu_irq FALLING detected (cleared)", UVM_NONE)
      end
    join_none

    #1000;

    // ---- Poll MAGIC_BOOT ----
    timeout_cycles = 50000;
    for (i=0; i<timeout_cycles; i++) begin
      rdata = bd_if.read32(32'h000FF000);
      if (rdata == 32'hB007B007) begin
        `uvm_info("CPU_IRQ", $sformatf("MAGIC_BOOT at +%0dns", i*100+1000), UVM_NONE)
        break;
      end
      #100;
    end
    if (rdata != 32'hB007B007) begin
      `uvm_error("CPU_IRQ", $sformatf("MAGIC_BOOT timeout: got 0x%08h", rdata))
      phase.drop_objection(this); return;
    end

    // ---- Poll MAGIC_IRQ_SEEN ----
    for (i=0; i<timeout_cycles; i++) begin
      rdata = bd_if.read32(32'h000FF004);
      if (rdata == 32'h1A2B3C4D) begin
        `uvm_info("CPU_IRQ", $sformatf("MAGIC_IRQ_SEEN at +%0dns", i*100+1000), UVM_NONE)
        break;
      end
      #100;
    end
    if (rdata != 32'h1A2B3C4D) begin
      `uvm_error("CPU_IRQ", $sformatf("MAGIC_IRQ_SEEN timeout: got 0x%08h err=0x%08h",
        rdata, bd_if.read32(32'h000FF010)))
      phase.drop_objection(this); return;
    end

    // ---- Poll MAGIC_TEST_DONE ----
    for (i=0; i<timeout_cycles; i++) begin
      rdata = bd_if.read32(32'h000FF00C);
      if (rdata == 32'h55AA55AA) begin
        `uvm_info("CPU_IRQ", $sformatf("MAGIC_TEST_DONE at +%0dns", i*100+1000), UVM_NONE)
        break;
      end
      #100;
    end
    if (rdata != 32'h55AA55AA) begin
      `uvm_error("CPU_IRQ", $sformatf("MAGIC_TEST_DONE timeout: got 0x%08h", rdata))
      phase.drop_objection(this); return;
    end

    // ---- Verify IRQ behavior ----
    `uvm_info("CPU_IRQ", $sformatf("npu_irq_seen=%0d npu_irq_cleared=%0d",
      npu_irq_seen, npu_irq_cleared), UVM_NONE)
    if (!npu_irq_seen)
      `uvm_error("CPU_IRQ", "npu_irq NEVER asserted!")
    if (!npu_irq_cleared)
      `uvm_error("CPU_IRQ", "npu_irq NOT cleared after handler!")

    // ---- Verify MAGIC_IRQ_STATUS ----
    rdata = bd_if.read32(32'h000FF008);
    `uvm_info("CPU_IRQ", $sformatf("MAGIC_IRQ_STATUS=0x%08h (expect bit0=1)", rdata), UVM_NONE)
    if (!(rdata & 1))
      `uvm_error("CPU_IRQ", "IRQ_STATUS[0] != 1")

    // ---- Verify output ----
    rdata = bd_if.read32(32'h00030000);
    `uvm_info("CPU_IRQ", $sformatf("Output=0x%08h (expect 4)", rdata), UVM_NONE)
    if ($signed(rdata) != 32'd4)
      `uvm_error("CPU_IRQ", $sformatf("Output mismatch: %0d != 4", $signed(rdata)))

    // ---- Verify no MAGIC_ERROR ----
    rdata = bd_if.read32(32'h000FF010);
    if (rdata != 0)
      `uvm_error("CPU_IRQ", $sformatf("MAGIC_ERROR=0x%08h (expect 0)", rdata))

    if (!probe_vif.cpu_trap)
      `uvm_info("CPU_IRQ", "cpu_trap=0 PASS", UVM_NONE)
    else
      `uvm_error("CPU_IRQ", "cpu_trap asserted!")

    `uvm_info("CPU_IRQ", "=== CPU NPU IRQ SMOKE PASS ===", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
