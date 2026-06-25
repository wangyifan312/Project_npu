# Conv Multi-Window Drain Hang — Known Issue (RESOLVED)

**Date**: 2026-06-25
**Status**: RESOLVED — root cause DMA writer `S_WAIT_DATA` tail-burst deadlock
**Fix**: `rtl/npu/dma_axi_writer.v` + `rtl/npu/npu_top.v`

---

## 1. Symptom

Conv tasks with multi-window spatial output (e.g., 3x3+ or 4x4 output) hung in the
NPU drain phase. The NPU `busy` signal stayed high indefinitely with no `done` or
`error`. Single-window (1x1 output) tasks completed normally.

This affected **all cluster modes** (single, dual, full, mask), so it was NOT a
multi-cluster mapping bug.

## 2. Root Cause

**`dma_axi_writer.v` line 236: `S_WAIT_DATA` deadlock**

The DMA writer state machine enters `S_WAIT_DATA` after completing a burst and
waits for `fifo_level >= beats_in_burst` before issuing the next AW. This is the
**only exit condition** from `S_WAIT_DATA`.

For multi-burst writes, after completing burst N, the writer enters `S_WAIT_DATA`
to wait for burst N+1 data. But if the producer (store_pack) has already finished
(entered `STORE_PACK_IDLE`) and the remaining beats in the FIFO are fewer than
`beats_in_burst`, the condition `fifo_level >= beats_in_burst` never becomes true.

Result: **permanent deadlock**. The DMA writer waits for more data that will never
arrive, store_pack is idle, the compute pipeline is drained, and the NPU FSM is
stuck in `FSM_STORE` waiting for `dma_wr_done`.

## 3. Two Suspected Mechanisms — Only One Was Real

| Mechanism | Location | Real? | Finding |
|-----------|----------|-------|---------|
| **Hang A** | `conv_frontend.v` line 158: `lb_base_row` negative for kernel < 5 | **NO** | Cosmetic. Window extraction boundary checks (lines 289-291) prevent out-of-bounds access. Agents B confirmed all 1x1/3x3 multi-window Conv tests produce correct golden output. |
| **Hang B** | `dma_axi_writer.v` line 236: `S_WAIT_DATA` deadlock | **YES** | Confirmed by Agent A directed test (`tb_dma_writer_hang_expose.v`) and Agent C RTL fix. |

## 4. Fix (2026-06-25)

### dma_axi_writer.v
- Added `producer_done` input port (1-bit)
- Modified `S_WAIT_DATA` to use available FIFO data when `producer_done=1` and `fifo_level > 0`
- Falls back to `beats_in_burst = fifo_level` for the final tail burst

### npu_top.v
- Added `dma_producer_done` wire
- Asserted when: `fsm_state == FSM_STORE && store_pack_state == STORE_PACK_IDLE && dma_wr_started`
- Connected to DMA writer instance

## 5. Regression Verification (18/18 PASS)

| Category | Tests | Result |
|----------|-------|--------|
| DMA writer directed | 5 | 5/5 PASS, 80.00% util preserved |
| Conv multi-window diagnostic | 3 | 3/3 PASS (1x1 4x4, 3x3 3x3, 5x5 1x1) |
| Conv cluster_mode | 1 | 4/4 modes PASS |
| UVM smoke | 3 | 3/3 PASS |
| Structural UVM (FC) | 5 | 5/5 PASS |
| Verilog integration | 1 | tb_dma_writer_hang_expose PASS |

## 6. What Is NOT Affected

- FC multi-cluster: unchanged (uses separate `fc_store` path)
- DMA long burst 80.00% util: preserved
- Single-window Conv: already worked, still works
- Back-to-back task execution: unchanged
- Requant: unchanged

## 7. Related Documents

- `docs/uvm_structural_test_closure.md`: Overall regression status
- `CLAUDE.md` §8-10: DMA write optimization and structural regression
- `rtl/npu/dma_axi_writer.v`: DMA writer state machine with `producer_done` fix
- `rtl/npu/npu_top.v`: Store-to-DMA `producer_done` connection

---

*Resolved. Root cause: DMA writer `S_WAIT_DATA` tail-burst deadlock (Hang B).*
*Hang A (conv_frontend lb_base_row) confirmed harmless by diagnostic tests.*
