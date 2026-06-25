# DMA Write Optimization — Final Summary

**Date**: 2026-06-24
**Status**: Phase A/B/B2 Complete + REQ-1 Resolved

---

## 1. 修改概述

### Phase A: Write Transaction Utilization Statistics
- `rtl/npu/perf_counter.v`: +2 counters (`write_data_cycles`, `write_txn_cycles`)
- `rtl/npu/npu_ctrl.v`: +2 readable registers at 0xD0/0xD4 (originally 0x88/0x8C, moved in subsequent control-plane fix)
- `rtl/npu/dma_axi_writer.v`: +1 `write_txn_active` output port
- `rtl/npu/npu_top.v`: signal wiring

### Phase B: Store Pack First-Word Optimization
- `rtl/npu/npu_top.v`: IDLE→CAPTURE direct transition (skip initial WAIT, saves 1 cycle)

### Phase B2: DMA Writer W-Channel Skid Buffer
- `rtl/npu/dma_axi_writer.v`: `next_*` preload buffer + `next_ready` combinational logic
- Eliminates 1-cycle bubble between W beats: **2 cycles/beat → ~1 beat/cycle**

### REQ-1: Requant Testbench Fix
- `tb/integration/tb_task_requant.v`: 32-bit→256-bit AXI preload rewrite
- Root cause: pre-existing TB issue (awsize=2 rejected by axi4_ram), not RTL bug

### Testbench Infrastructure
- 5 new DMA writer directed unit tests
- 3 integration testbenches fixed for 256-bit data plane
- UVM probe interface enhanced with `npu_dma_wr_busy`/`npu_dma_wr_txn_active`

---

## 2. 指标总表

| Metric | Baseline | Final | Phase |
|--------|----------|-------|-------|
| **write_transaction_util** (16-beat burst) | 45.71% | **80.00%** | B2 |
| write_txn_cycles (16 beats) | 35 | **20** | B2 |
| write_data_cycles (16 beats) | 16 | 16 | — |
| old_write_util (1-beat conv) | 11.1% | 12.5% | B |
| store_pack cycles/beat | ~17 | ~16-17 | B |
| W channel bubbles | 1 per beat | 0 (after 1st beat) | B2 |

---

## 3. 回归结果 (DMA regression: 10 directed + 3 smoke PASS)

### Verilog Directed Tests

| Test | Result | Output Compare |
|------|--------|---------------|
| `tb_shared` | **PASS** | 0 errors |
| `tb_requant` | **PASS** | requant unit PASS |
| `tb_task_requant` | **PASS** | 0x7FCD3332 matched |
| `tb_fc` | **PASS** | FC rejection correct |
| `tb_npu_top` | **PASS** | Conv=50 |
| `tb_dma_writer_backpressure` | **PASS** | WDATA stable |
| `tb_dma_writer_tail_burst` | **PASS** | 5/5 correct |
| `tb_dma_writer_awlen_wlast` | **PASS** | 3/3 correct |
| `tb_dma_writer_zero_byte` | **PASS** | 4/4 correct |
| `tb_dma_writer_long_burst` | **PASS** | util=80.00% |

### UVM Smoke Tests

| Test | Result | Scoreboard | DMA Monitor |
|------|--------|------------|-------------|
| `npu_conv_smoke_test` | **PASS** | 0 mismatches | txn=25%, sys=12.5% |
| `npu_fc_smoke_test` | **PASS** | 0 mismatches | txn=25%, sys=12.5% |
| `npu_requant_smoke_test` | **PASS** | 0 mismatches | txn=25%, sys=11.1% |

---

## 4. 32-bit AXI Preload 扫描结果

| Category | Files | Status |
|----------|-------|--------|
| Fixed | `tb_npu_top.v`, `tb_task_requant.v`, `tb_task4_shared_mem.v` | ✅ 256-bit preload |
| Legacy (per CLAUDE.md) | `tb_task1/2/3/6` series (7 files) | ⚠️ 32-bit, not formal baseline |
| Untracked debug | `tb_stride2_debug.v` | ⚠️ Debug only |

Legacy `tb_task*` 系列按 CLAUDE.md 归类为 "legacy/debug/micro 入口，不能代表正式阵列规模"。它们使用 32-bit AXI 端口是设计意图，不需要修改。

---

## 5. Git Commit 建议

### Commit 1: `feat: DMA write utilization optimization and verification`
```
dma_axi_writer: Phase B2 W-channel skid buffer (80% transaction utilization)
npu_top: Phase B store-pack first-word optimization
perf_counter: add write_data_cycles/write_txn_cycles counters
npu_ctrl: add perf registers (now 0xD0/0xD4, originally 0x88/0x8C)
sim/run_sim.sh: add DMA writer directed test entries

New tests:
  tb_dma_writer_wready_backpressure.v
  tb_dma_writer_tail_burst.v
  tb_dma_writer_awlen_wlast.v
  tb_dma_writer_zero_byte.v
  tb_dma_writer_long_burst.v

Modified: rtl/npu/dma_axi_writer.v, rtl/npu/npu_top.v,
          rtl/npu/perf_counter.v, rtl/npu/npu_ctrl.v,
          sim/run_sim.sh
```

### Commit 2: `fix: 256-bit AXI preload in integration testbenches`
```
tb_npu_top.v: fix 256-bit AXI preload (awsize=5)
tb_task_requant.v: fix 256-bit AXI preload, resolves REQ-1
tb_task4_shared_mem.v: fix NPU port width (awsize=5)

Root cause: testbenches used 32-bit AXI signals with awsize=2,
rejected by 256-bit axi4_ram validation.
```

---

## 6. 残留风险

| ID | 描述 | 影响 |
|----|------|------|
| R1 | Legacy `tb_task*` 测试仍使用 32-bit AXI（按设计意图，非缺陷） | 不影响 formal baseline |
| R2 | FPGA synthesis 未验证 `next_ready` 组合路径时序 | 不影响功能仿真 |
| R3 | `old_write_util ≈ 12.5%` 受 store_pack 限制，系统级吞吐未显著提升 | 需 Phase C 解决 |

---

## 7. Phase C 暂缓理由

1. `write_transaction_util = 80%` 已达赛题答辩要求
2. Phase C（acc_buffer 256-bit widening）需修改所有写路径（CP_COLLECT, requant, GAP, ADD），风险高
3. 当前 store_pack/acc_buffer 瓶颈仅在系统级体现，不影响 AXI 事务级证据
4. 建议顺序：先做 FPGA synthesis → UVM full regression → 再评估 Phase C

---

## 8. 文件统计

```
RTL modified:     5 files
RTL new:          1 file  (write_beat_fifo.v, untracked)
TB new:           5 files (DMA writer directed tests)
TB modified:      3 files (integration tests)
UVM modified:     4 files
Docs new:         7 files
Sim script:       1 file modified
Total:           ~26 files
```

---

*Final summary. DMA write optimization complete. 建议进入 FPGA synthesis / delivery hardening 阶段。*
