# DMA Write Verification Closure Report

**Date**: 2026-06-24
**Branch**: main

---

## 1. 修改文件清单

| 文件 | 改动类型 | 说明 |
|------|---------|------|
| `rtl/npu/npu_ctrl.v` | Fix | ADDR_PERF_WRITE_DATA_CYC 34 (曾与 REQANT_SEL=25 冲突), ADDR_PERF_WRITE_TXN_CYC 35 |
| `rtl/npu/dma_axi_writer.v` | (上轮) | +write_txn_active output port |
| `rtl/npu/perf_counter.v` | (上轮) | +write_data_cycles, write_txn_cycles counters |
| `rtl/npu/npu_top.v` | (上轮) | FIFO wire 前置声明, txn_active 连接 |
| `tb/integration/tb_task4_shared_mem.v` | Fix | NPU AXI 端口扩为 256-bit，awsize=5 |
| `tb/integration/tb_npu_top.v` | Fix | 256-bit data-plane preload + perf counter readback |
| `verif/uvm_top/interfaces/soc_probe_if.sv` | Enhance | +npu_dma_wr_busy, +npu_dma_wr_txn_active |
| `verif/uvm_top/agents/dma_mon/axi4_dma_monitor.sv` | Enhance | 双指标 write utilization: txn-level + system-level |
| `verif/uvm_top/env/soc_perf_checker.sv` | Enhance | check_counters() 扩展接受 write_data/txn_cycles |
| `verif/uvm_top/tb/tb_soc_top_uvm.sv` | Enhance | hierarchical probe 连接 dma_wr_busy/txn_active |

---

## 2. Regression / Performance Table

| Test | PASS/FAIL | Output Compare | write_beats | old_write_util | write_txn_util | read_beats | Notes |
|------|-----------|---------------|-------------|----------------|----------------|------------|-------|
| `soc_shared_ram_rw_test` | **PASS** | 0 errors | — | — | — | — | CPU↔NPU shared mem |
| `npu_requant_smoke_test` | **PASS** | requant PASS | — | — | — | — | 单独 requant 单元 |
| `npu_fc_smoke_test` | **PASS** | FC reject OK | — | — | — | — | FC 拒绝逻辑正确 |
| `npu_conv_smoke_test` | **PASS** | Conv=50 ✓ | 1 | 11.1% | 25.0% | 2 | 5×5 Conv, 单输出 |
| `tb_dma_writer_backpressure` | **PASS** | WDATA stable | — | — | — | — | WVALID&&!WREADY 稳定 |
| `tb_dma_writer_tail_burst` | **PASS** | 5/5 正确 | — | — | — | — | 17/40/63/64/100B |
| `tb_dma_writer_awlen_wlast` | **PASS** | 3/3 正确 | — | — | — | — | 多 burst+BRESP error |
| `tb_dma_writer_zero_byte` | **PASS** | 4/4 正确 | — | — | — | — | B9 零字节无风险 |

**npu_conv_smoke_test perf details**:

| Counter | Value | Meaning |
|---------|-------|---------|
| total_cycle_lo | 107 | Total task cycles |
| write_beats | 1 | 1 beat from FIFO to writer |
| write_active_cyc | 9 | Writer busy (incl. S_WAIT_DATA) |
| write_data_cycles | 1 | WVALID && WREADY on AXI bus |
| write_txn_cycles | 4 | AW handshake → B handshake |
| read_beats | 2 | 2 read beats (act + wgt) |
| read_active_cyc | 8 | Reader active cycles |

```
old_write_util = write_beats / write_active_cyc = 1/9 = 11.1%
write_transaction_util = write_data_cycles / write_txn_cycles = 1/4 = 25%
→ 单 beat 传输：txn 窗口包含 1 AW + 1 W + 1 B + 1 gap = 4 cycles
→ 多 beat (16-beat burst) 时理论 txn_util ≈ 16/18 = 88.9%
```

---

## 3. UVM DMA Monitor 增强

已增强 `axi4_dma_monitor`，report_phase 现在输出：

```
WRITE util: transaction-level=X.X% (N data / M txn_cycles)
            | system-level=Y.Y% (N data / B busy_cycles)
```

- **transaction-level**: AW→B 窗口内 W beat 占比
- **system-level**: `npu_dma_wr_busy` 全部窗口内 W beat 占比（等价于 old_write_util）

---

## 4. B9 零字节验证结果

**B9 不存在**。dma_axi_writer 已正确处理：
- `byte_count=0` → S_IDLE → S_DONE，不发 AW
- 1-byte/tail burst 正确
- Misaligned address → error code 0x31

---

## 5. 关键发现与修复回顾

| 问题 | 根因 | 修复 |
|------|------|------|
| tb_shared/tb_npu_top X 数据 | NPU AXI 用 32-bit awsize=2，共享 RAM 校验 awsize=5 拒绝写入 | 扩为 256-bit + awsize=5 |
| write_data_cycles 读回 0 | ADDR=25 与 ADDR_REQUANT_SEL=25 冲突 | 重分配到 34/35 (0x88/0x8C) |
| 写路径 preload 被拒 | AW 和 W 同周期发送，wready 依赖 aw_active | 拆分为 AW→W 两周期 |

---

## 6. 后续建议

1. **UVM regression** (Phase A): 用 VCS 跑完整 UVM 测试套件，验证 DMA monitor 双指标输出
2. **store_pack optimization** (Phase B): store_pack 流水线化（~9 cycles/beat，提升 old_write_util 到 ~11%）
3. **acc_buffer 256-bit** (Phase C): 更根本的吞吐修复

---

*Closure report. 所有修改仅修复验证链路，未改动核心 datapath FSM。*
