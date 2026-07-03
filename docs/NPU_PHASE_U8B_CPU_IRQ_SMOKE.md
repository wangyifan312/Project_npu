# NPU Phase U8-b: PicoRV32 CPU-Running NPU IRQ Smoke Verification

**Date:** 2026-07-02  
**Branch:** `feature/npu-cpu-irq-smoke-u8b`  
**Phase:** U8-b (CPU-Running Interrupt Smoke)

---

## 1. Objective

Prove PicoRV32 CPU can:
1. Boot from shared_ram (backdoor preloaded firmware)
2. Configure NPU CSR via CPU AXI master
3. Start NPU task
4. Receive NPU interrupt on irq[4]
5. Enter IRQ handler at vector 0x10
6. Read IRQ_STATUS, write IRQ_CLEAR
7. Clear npu_irq

---

## 2. CPU-Running Mode

| Parameter | BFM Mode (default) | CPU Mode (U8-b) |
|-----------|-------------------|-----------------|
| `tb_axil_enable` | 1 | 0 (+TB_AXIL_ENABLE=0) |
| CPU reset | Held in reset | Released |
| NPU CSR write | BFM AXI-Lite | CPU AXI master |
| NPU CSR read | BFM AXI-Lite | CPU AXI master |
| Shared RAM preload | backdoor | backdoor |
| Output verification | backdoor | backdoor |

---

## 3. Firmware Build

| Tool | Path |
|------|------|
| Compiler | `/root/Project_seu/riscv_toolchain/bin/riscv64-unknown-elf-gcc` (8.1.0) |
| Flags | `-nostdlib -nostartfiles -ffreestanding -march=rv32i -mabi=ilp32` |
| Linker script | `verif/firmware/npu_irq_smoke/npu_irq_smoke.ld` |
| memh generation | `makehex.py` (from PicoRV32 firmware) |

Memh format: 32-bit word per line, loaded via `backdoor_if::load_memh()`.

---

## 4. U8-b0: Boot Magic Smoke

**Test:** `soc_cpu_boot_magic_smoke_test`  
**Firmware:** 5-instruction RV32I (LUI/ADDI/SW/JAL)  
**Verifies:** CPU fetches from shared_ram[0x0], executes, writes MAGIC_BOOT=0xB007B007.

**Result:** PASS. MAGIC_BOOT written at cycle 1000, cpu_trap=0.

---

## 5. U8-b1: CPU NPU Polling Smoke

**Test:** `soc_cpu_npu_polling_smoke_test`  
**Firmware:** `npu_polling.S` (52 instructions)  
**NPU task:** GEMM M=1,K=4,N=1, all-1 data → C[0]=4  
**Verifies:** CPU configures NPU CSR, starts task, polls CTRL.done, writes MAGIC_POLL_DONE.

**Result:** PASS. Output=0x00000004, cpu_trap=0.

---

## 6. U8-b2: CPU NPU IRQ Smoke

**Test:** `soc_cpu_npu_irq_smoke_test`  
**Firmware:** `npu_irq_smoke.S` (compiled RV32I)  
**Mechanism:**
1. CPU writes MAGIC_BOOT
2. CPU clears NPU IRQ pending (IRQ_CLEAR=3)
3. CPU enables done IRQ (IRQ_EN=1)
4. CPU calls `maskirq` to unmask irq[4]
5. CPU configures GEMM, writes CTRL.start
6. NPU done → npu_irq asserts → CPU irq[4] received
7. CPU enters IRQ vector at 0x10
8. Handler reads IRQ_STATUS (=0x01), writes MAGIC_IRQ_STATUS
9. Handler writes IRQ_CLEAR (=1) → npu_irq deasserts
10. Handler writes MAGIC_IRQ_SEEN (=0x1A2B3C4D)
11. Handler writes MAGIC_TEST_DONE (=0x55AA55AA)

**UVM observations:**
- npu_irq RISING detected ✅
- npu_irq FALLING detected (cleared) ✅
- MAGIC_IRQ_STATUS = 0x00000001 ✅
- Output = 0x00000004 ✅

**Result:** PASS. cpu_trap=0, UVM_ERROR=0, UVM_FATAL=0.

---

## 7. IRQ Vector Layout

```
0x00000000: j reset_main       (reset vector)
0x00000004-0x0C: nop padding
0x00000010: irq_handler entry  (PROGADDR_IRQ)
0x00000044: retirq
0x00000080: reset_main start
```

Verified via `riscv64-unknown-elf-objdump -d npu_irq_smoke.elf`.

---

## 8. Scope Limitations

| Limitation | Detail |
|------------|--------|
| Verification level | Minimal bare-metal firmware smoke test |
| Software stack | Not a full OS/driver |
| IRQ return-to-main | Handler writes MAGIC_TEST_DONE directly; retirq executes but main-loop re-entry not verified as primary criterion |
| Multi-source IRQ | Not tested (only irq[4] used) |
| IRQ nesting | Not tested |
| PicoRV32 ENABLE_IRQ_QREGS | Enabled; q-reg save/restore active |

---

## 9. Regression Results

| Test | Status |
|------|--------|
| `soc_cpu_boot_magic_smoke_test` | PASS |
| `soc_cpu_npu_polling_smoke_test` | PASS |
| `soc_cpu_npu_irq_smoke_test` | PASS |
| `npu_irq_reporting_test` (U8-a BFM) | PASS |
| `npu_task_gemm_func_test` | PASS |
| `npu_gemm_kchunk_stress_test` | PASS |
| `npu_int8_extreme_value_stress_test` | 192/192 PASS |
| `npu_fc_streaming_smoke_test` | PASS |
| `npu_fc_streaming_fallback_test` | PASS |
| `npu_pe_array_clock_gating_test` | PASS |

**UVM_ERROR=0, UVM_FATAL=0.**
