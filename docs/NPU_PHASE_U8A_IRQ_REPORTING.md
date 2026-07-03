# NPU Phase U8-a: IRQ Reporting CSR and BFM-Level Verification

**Date:** 2026-07-02  
**Branch:** `feature/npu-irq-reporting-u8a`  
**Phase:** U8-a (BFM-Level Interrupt Reporting Verification)

---

## 1. Overview

Phase U8-a implements NPU done/error interrupt reporting CSRs and verifies the protocol using AXI-Lite BFM. No CPU-running firmware is involved.

---

## 2. CSR Map

| Register | Address | Width | Access | Description |
|----------|---------|-------|--------|-------------|
| IRQ_EN | 0x100 | [1:0] | RW | bit0=done_irq_en, bit1=error_irq_en |
| IRQ_STATUS | 0x104 | [1:0] | RO | bit0=done_pending, bit1=error_pending |
| IRQ_CLEAR | 0x108 | [1:0] | W1C | write 1 to clear corresponding irq_status bit |

IRQ CSRs are in the extended 7-bit address space of npu_ctrl (0x00-0x1FC).  
NPU_MASK was expanded from 0xFFFF_FF00 (256B) to 0xFFFF_FE00 (512B) to accommodate.

---

## 3. IRQ Semantics

| Behavior | Description |
|----------|-------------|
| Done pending | IRQ_STATUS[0] set on task_done_i rising edge |
| Error pending | IRQ_STATUS[1] set on task_error_i rising edge OR checker failure |
| IRQ gating | npu_irq = \|(IRQ_STATUS & IRQ_EN) |
| IRQ_EN reset | 2'b00 (backward compatible: no IRQ by default) |
| IRQ_CLEAR | Write-1-clear: writing 1 clears corresponding pending bit; writing 0 has no effect |
| Status unaffected | IRQ_STATUS pending bits are sticky regardless of IRQ_EN state |
| CTRL/STATUS unaffected | IRQ registers do not affect CTRL.done/error or STATUS.error_code |

---

## 4. Address Decode

```
NPU_BASE = 0x1000_0000
NPU_MASK = 0xFFFF_FE00 (512B window)
IRQ CSR at NPU_BASE + offset:

  IRQ_EN     = 0x1000_0100
  IRQ_STATUS = 0x1000_0104
  IRQ_CLEAR  = 0x1000_0108

axi_interconnect decode:
  if ((addr & 0xFFFF_FE00) == 0x1000_0000) → route to NPU

npu_ctrl internal decode:
  wr_addr = write_addr[8:2] (7 bits, 0-127)
  ADDR_IRQ_EN     = 7'd64 (= byte offset 0x100)
  ADDR_IRQ_STATUS = 7'd65 (= byte offset 0x104)
  ADDR_IRQ_CLEAR  = 7'd66 (= byte offset 0x108)
```

---

## 5. Signal Path

```
npu_ctrl.irq_status[1:0]  →  npu_irq = |(irq_status & irq_en)
  → npu_top.npu_irq (output port)
    → top.v.npu_irq_int wire
      → cpu_irq[4]  (cpu_irq = {27'h0, npu_irq_int, 4'h0})
        → PicoRV32 .irq(cpu_irq)
      → probe_vif.npu_irq (UVM observation)
```

PicoRV32 has `ENABLE_IRQ = 0` (default). The structural connection enables future CPU IRQ smoke without additional wiring changes.

---

## 6. Verification

**Test:** `npu_irq_reporting_test` (7 sub-tests)

| # | Test | Result |
|---|------|--------|
| T1 | IRQ_EN reset default = 0 | PASS |
| T2 | Done pending independent of IRQ_EN; IRQ_EN=0 gates npu_irq | PASS |
| T3 | Enable done IRQ; npu_irq fires when pending + enabled | PASS |
| T4 | IRQ_CLEAR.done deasserts npu_irq | PASS |
| T5 | IRQ_CLEAR=0 does NOT clear (W1C verified) | PASS |
| T6 | Error IRQ from checker-detected error (invalid task_type) | PASS |
| T7 | Back-to-back: task1 IRQ → clear → task2 IRQ; no stale pending | PASS |

**Method:** All tests use AXI-Lite BFM via `soc_base_seq::axil_write32/axil_read32`. npu_irq is observed via `probe_vif.npu_irq`. GEMM outputs verified correct for all functional sub-tests.

---

## 7. Scope Limitations

| Limitation | Status |
|------------|--------|
| Verification level | BFM only (AXI-Lite BFM drives NPU CSR) |
| CPU-running test | Not implemented |
| Bare-metal C/assembly ISR | Not implemented |
| PicoRV32 firmware | Not implemented |
| ENABLE_IRQ parameter | Still 0 (default); future U8-b requirement |
| Multi-source IRQ (timer, external) | Not implemented |

---

## 8. Future Work (U8-b)

1. Set `ENABLE_IRQ = 1` in PicoRV32 instantiation
2. Write minimal firmware: CPU configures NPU, enables IRQ, enters WFI, handles IRQ
3. Backdoor preload firmware binary into shared_ram
4. Release CPU reset (`tb_axil_enable = 0`)
5. Verify CPU receives interrupt, handler executes, MAGIC word written to shared_ram
6. `soc_cpu_npu_irq_smoke_test`
