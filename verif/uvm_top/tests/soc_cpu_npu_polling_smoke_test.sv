//=============================================================================
// soc_cpu_npu_polling_smoke_test.sv — Phase U8-b1 CPU NPU Polling Smoke
//
// PicoRV32 CPU configures NPU GEMM (M=1,K=4,N=1), starts task,
// polls CTRL.done, writes MAGIC flags. Uses backdoor preload.
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

    if (!uvm_config_db#(virtual backdoor_if)::get(this, "", "bd_if", bd_if))
      `uvm_fatal("CPU_POLL", "backdoor_if not found")

    // --- Preload at time 0 (before CPU reset release) ---
    `uvm_info("CPU_POLL", "=== CPU NPU POLLING SMOKE (Phase U8-b1) ===", UVM_NONE)

    // Load firmware
    bd_if.load_memh("verif/firmware/npu_irq_smoke/npu_polling.memh", 0, 128);
    `uvm_info("CPU_POLL", $sformatf("FW[0]=0x%08h", bd_if.read32(32'h0)), UVM_NONE)

    // Preload input: 4 bytes all-1 at 0x00010000
    bd_if.load_memh("verif/firmware/npu_irq_smoke/npu_polling.memh", 32'h00010000, 1);  // reuse for all-1
    // Overwrite with explicit all-1
    for (i=0; i<4; i=i+1) begin
      // backdoor write: use hierarchical path
    end
    // Use simple preload via a small memh file
    // Actually: create inline via load_memh that's all-ones
    // Simpler: use existing mechanism
    `uvm_info("CPU_POLL", "Preloading input/weight via backdoor writes...", UVM_NONE)

    // Preload input (0x00010000) and weight (0x00020000) with all-ones
    // Use backdoor write by loading small memh files
    // Generate temp memh content via system task
    begin
      int fd;
      fd = $fopen("/tmp/u8b1_input.memh", "w");
      $fwrite(fd, "01010101\n");
      $fclose(fd);
    end
    bd_if.load_memh("/tmp/u8b1_input.memh", 32'h00010000, 1);
    bd_if.load_memh("/tmp/u8b1_input.memh", 32'h00020000, 1);

    // Clear output and magic areas
    begin
      int fd;
      fd = $fopen("/tmp/u8b1_zero8.memh", "w");
      for (i=0; i<8; i=i+1) $fwrite(fd, "00000000\n");
      $fclose(fd);
    end
    bd_if.load_memh("/tmp/u8b1_zero8.memh", 32'h00030000, 8);
    bd_if.load_memh("/tmp/u8b1_zero8.memh", 32'h000FF000, 16);

    `uvm_info("CPU_POLL", $sformatf("Pre:  MAGIC_BOOT=0x%08h IN=0x%08h",
      bd_if.read32(32'h000FF000), bd_if.read32(32'h00010000)), UVM_NONE)

    phase.raise_objection(this);
    #1000;

    // --- Poll MAGIC_BOOT ---
    timeout_cycles = 50000;
    for (i=0; i<timeout_cycles; i++) begin
      rdata = bd_if.read32(32'h000FF000);
      if (rdata == 32'hB007B007) begin
        `uvm_info("CPU_POLL", $sformatf("MAGIC_BOOT at +%0dns", i*100+1000), UVM_NONE)
        break;
      end
      #100;
    end
    if (rdata != 32'hB007B007) begin
      `uvm_error("CPU_POLL", $sformatf("MAGIC_BOOT timeout: got 0x%08h", rdata))
      phase.drop_objection(this); return;
    end

    // --- Poll MAGIC_POLL_DONE ---
    for (i=0; i<timeout_cycles; i++) begin
      rdata = bd_if.read32(32'h000FF004);
      if (rdata == 32'hD00ED00E) begin
        `uvm_info("CPU_POLL", $sformatf("MAGIC_POLL_DONE at +%0dns", i*100+1000), UVM_NONE)
        break;
      end
      #100;
    end
    if (rdata != 32'hD00ED00E) begin
      `uvm_error("CPU_POLL", $sformatf("MAGIC_POLL_DONE timeout: got 0x%08h err=0x%08h",
        rdata, bd_if.read32(32'h000FF00C)))
      phase.drop_objection(this); return;
    end

    // --- Poll MAGIC_TEST_DONE ---
    for (i=0; i<timeout_cycles; i++) begin
      rdata = bd_if.read32(32'h000FF008);
      if (rdata == 32'h55AA55AA) begin
        `uvm_info("CPU_POLL", $sformatf("MAGIC_TEST_DONE at +%0dns", i*100+1000), UVM_NONE)
        break;
      end
      #100;
    end
    if (rdata != 32'h55AA55AA) begin
      `uvm_error("CPU_POLL", $sformatf("MAGIC_TEST_DONE timeout: got 0x%08h", rdata))
      phase.drop_objection(this); return;
    end

    // --- Verify output ---
    rdata = bd_if.read32(32'h00030000);
    `uvm_info("CPU_POLL", $sformatf("Output=0x%08h (expect 4)", rdata), UVM_NONE)
    if ($signed(rdata) != 32'd4)
      `uvm_error("CPU_POLL", $sformatf("Output mismatch: %0d != 4", $signed(rdata)))

    // --- Verify no error ---
    rdata = bd_if.read32(32'h000FF00C);
    if (rdata != 0)
      `uvm_error("CPU_POLL", $sformatf("MAGIC_ERROR=0x%08h (expect 0)", rdata))

    if (!probe_vif.cpu_trap)
      `uvm_info("CPU_POLL", "cpu_trap=0 PASS", UVM_NONE)
    else
      `uvm_error("CPU_POLL", "cpu_trap asserted!")

    `uvm_info("CPU_POLL", "=== CPU NPU POLLING SMOKE PASS ===", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
