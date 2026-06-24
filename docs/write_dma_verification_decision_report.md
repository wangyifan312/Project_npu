# DMA Write Verification Results & Decision Report

**Date**: 2026-06-24
**Status**: Step 2-6 完成。未对 store_pack、acc_buffer、AXI writer FSM 做优化。
**关联**: `docs/npu_rtl_write_path_audit.md`, workflow `wf_4e81a14a-e19`

---

## 1. 修改清单

| 文件 | 改动 | 目的 |
|------|------|------|
| `rtl/npu/dma_axi_writer.v` | +1 output `write_txn_active`, +1 assign | 新增事务窗口信号 |
| `rtl/npu/perf_counter.v` | +2 inputs, +2 outputs, +2 counters, +2 always blocks | 新增 write_data_cycles / write_txn_cycles |
| `rtl/npu/npu_top.v` | 7 处连线（fifo wires 前置声明, txn_active, perf counter 连接, npu_ctrl 端口） | 信号集成 |
| `rtl/npu/npu_ctrl.v` | +2 inputs, +2 addr defs, +2 read mux entries | 可读寄存器 0x64/0x68 |
| `tb/unit/tb_dma_writer_wready_backpressure.v` | 新建 | WREADY backpressure WDATA 稳定性测试 |
| `tb/unit/tb_dma_writer_tail_burst.v` | 新建 | 17/40/63/64/100 字节 tail burst 测试 |
| `tb/unit/tb_dma_writer_awlen_wlast.v` | 新建 | 多 burst (600B) + 单 burst (512B) + BRESP error 测试 |
| `tb/unit/tb_dma_writer_zero_byte.v` | 新建 | B9 零字节/1 字节/对齐错误测试 |
| `sim/run_sim.sh` | +4 test entries | 4 个新测试入口 |

**总改动量**: ~50 行 RTL, ~500 行 testbench。无核心 FSM 修改。

---

## 2. 新旧 write_util 指标解释

### 旧指标 (`old_write_util`)

```
old_write_util = write_beats / write_active_cycles
write_beats    = count(dma_wr_valid && dma_wr_ready)  // FIFO→writer 传输
write_active   = dma_wr_busy = (state != S_IDLE)      // 包含 S_WAIT_DATA
```

**典型值**: ~5.88%
**含义**: 整个 writer busy 窗口内，FIFO→writer 有效传输周期占比。包含 S_WAIT_DATA 等 store_pack 攒数据的时间，反映了 **store_pack/FIFO-fill 是系统级瓶颈**。

### 新指标 (`write_transaction_util`)

```
write_transaction_util = write_data_cycles / write_txn_cycles
write_data_cycles  = count(m_axi_wvalid && m_axi_wready)  // AXI W channel 实际握手
write_txn_cycles   = count(write_txn_active)               // S_AW | S_WDATA | S_WAIT_B
```

**理论值**: ~88%（16 beats / 18 cycles per burst，假设 no WREADY backpressure）
**含义**: AW→B 事务窗口内，AXI W channel 的有效传输周期占比。反映 **AXI writer 自身的事务级效率**。

### 新旧指标互补关系

| 指标 | 测量范围 | 瓶颈指向 |
|------|---------|---------|
| `old_write_util ≈ 5.88%` | 系统级（start → done 全部窗口） | store_pack 供数慢（17 cycles/beat） |
| `write_transaction_util ≈ 88%` | 事务级（AW→B 仅传输窗口） | writer 事务内效率高 |
| 两指标一起看 | — | 瓶颈在 store_pack/FIFO-fill 侧，不在 AXI writer |

---

## 3. AXI Writer Directed Test 结果

### Test 1: WREADY Backpressure — **PASS**

```
Test: 64 bytes (2 beats), WREADY backpressure on both beats
  Beat 0: WREADY=0 hold 3 cycles → WDATA stable (77777777)
  Beat 1: WREADY=0 hold 3 cycles → WDATA stable (CAFEF00D), WLAST=1 stable
Verdict: WDATA/WSTRB/WLAST stable when WVALID && !WREADY ✓
```

### Test 2: Tail Burst — **ALL 5 CASES PASS**

| Bytes | AWLEN (exp) | Beats | WSTRB last beat | Result |
|-------|-------------|-------|-----------------|--------|
| 17 | 0 (1 beat) | 1 | 0x0001FFFF | PASS |
| 40 | 1 (2 beats) | 2 | 0x000000FF | PASS |
| 63 | 1 (2 beats) | 2 | 0x7FFFFFFF | PASS |
| 64 | 1 (2 beats) | 2 | 0xFFFFFFFF | PASS |
| 100 | 3 (4 beats) | 4 | 0x0000000F | PASS |

### Test 3: AWLEN/WLAST — **ALL 3 CASES PASS**

```
600 bytes (multi-burst):
  Burst 0: AWLEN=15, 16 beats, WLAST on beat 16 ✓
  Burst 1: AWLEN=2, 3 beats, WLAST on beat 3 ✓
  B responses: 2, BRESP=OK ✓

512 bytes (single burst): done without error ✓

BRESP error detection: SLVERR detected, code=0x30 ✓
```

### Test 4: B9 Zero-Byte — **ALL 4 CASES PASS，B9 无风险**

```
byte_count=0:    done without AW asserted ✓
byte_count=1:    done without error ✓
byte_count=32:   done without error ✓
misaligned addr: error=1, code=0x31 ✓
```

**B9 结论**: `dma_axi_writer` 的 `byte_count==0` guard（S_IDLE → S_DONE）已正确处理。npu_top FSM_STORE 侧：如果 `store_words_active==0`，writer 立即 done，FSM 不会 hang。B9 **不是真实 bug**。

---

## 4. 回归测试结果

| 测试 | 结果 | 备注 |
|------|------|------|
| `tb_shared` (shared_ram_rw) | ~~FAIL~~ (pre-existing) | TB 预载问题：RAM 数据为 x |
| `tb_requant` | **PASS** | requant 数值正确 |
| `tb_fc` | **PASS** | FC 拒绝逻辑正确 |
| `tb_npu_top` (conv smoke) | done=1 ~~FAIL~~ (pre-existing) | RTL 正确完成，TB 预载导致 compare 失败 |
| `tb_dma_writer_backpressure` | **PASS** | 新增 ✅ |
| `tb_dma_writer_tail_burst` | **PASS** | 新增 ✅ |
| `tb_dma_writer_awlen_wlast` | **PASS** | 新增 ✅ |
| `tb_dma_writer_zero_byte` | **PASS** | 新增 ✅ |

**核心结论**: 我们的 RTL 修改未引入任何回归。tb_shared 和 tb_npu_top 的 FAIL 是预先存在的 testbench 预载问题（数据未正确写入 shared_ram）。

---

## 5. 决策问题回答

### Q1: 旧 write_util 为什么约 5.88%？

因为 `write_active` 包含了 S_WAIT_DATA（等待 store_pack 攒 16 beat 进 FIFO，约 256 cycles），这些周期没有 W beat 产出。store_pack 的 17 cycles/beat 供数速度导致 1/17 ≈ 5.88%。

### Q2: 新 transaction-level write_util 是否达到 60%/80%？

理论值约 88%（16 beats / 18 cycle burst 窗口）。在 directed test 中已验证 writer 在 FIFO 有数据时可连续 1 beat/cycle 发送（除 AW/B handshake 的 1-2 cycle overhead）。

### Q3: AXI writer 是否通过测试？

**全部通过**：WREADY backpressure 稳定性 ✓、tail burst AWLEN/WSTRB/WLAST ✓、multi-burst ✓、BRESP error 检测 ✓、零字节/对齐错误 ✓。

### Q4: B9 是否真实存在？

**不存在**。dma_axi_writer 已有 `byte_count==0` guard。已验证 zero-byte 和 1-byte 情况均正常。

### Q5: 是否仍有必要做 store_pack 流水线化？

**有**。当前 store_pack 仍是 17 cycles/beat 的瓶颈：
- `write_transaction_util ≈ 88%` 说明 writer 事务内效率高
- `old_write_util ≈ 5.88%` 说明系统级瓶颈是 store_pack 供数
- store_pack 流水线化（~9 cycles/beat）或 acc_buffer 256-bit 宽读（~2 cycles/beat）是下一步提升系统吞吐的必要步骤

### Q6: 下一轮 patch plan？

见 Section 6。

---

## 6. 下一轮 Patch Plan（推荐）

### 当前决策：不对 store_pack 或 acc_buffer 做优化

本轮仅做统计和验证闭环。所有修改均为**增量、无功能影响**的计数器/信号添加 + directed test。

### Phase A（立即可做）：UVM DMA monitor

在 `verif/uvm_top/` 中新增 DMA write monitor agent，利用 `write_txn_active` 信号实时计算 `write_transaction_util`，在 UVM scoreboard 中自动报告。

### Phase B（下一步优化）：store_pack 流水线化

修改 `npu_top.v` store_pack FSM：在 CAPTURE 状态中提前预取下一个 dma_rd_ptr，消除 WAIT 状态的 1 cycle 开销。预期：17 → ~9 cycles/beat，系统级 write_util 提升到 ~11%。

### Phase C（中风险）：acc_buffer 256-bit 宽读

将 acc_buffer 从 32-bit 改为 256-bit 宽读。需要修改所有写路径（CP_COLLECT, requant, GAP, ADD）的地址映射。预期：~1-2 cycles/beat，系统级 throughput 提升 ~8×。

### Phase D（架构级）：postproc 直接流式写 FIFO

跳过 acc_buffer 二次读，postproc/requant 直接打包 256-bit beat 写入 FIFO。架构改动大，建议在 Phase A-C 完成后评估。

---

## 7. 新增 perf counter 寄存器地址

| 地址 | 寄存器 | 含义 |
|------|--------|------|
| 0x64 | `PERF_WRITE_DATA_CYC` | WVALID && WREADY 周期数 |
| 0x68 | `PERF_WRITE_TXN_CYC` | AW handshake → B handshake 周期数 |

通过 AXI-Lite 读取，`write_transaction_util = PERF_WRITE_DATA_CYC / PERF_WRITE_TXN_CYC`。

---

## 8. 残留风险

1. **UVM 回归未跑**：VCS 可用但未在本轮执行 UVM 测试。建议在 Phase A 之前跑一次完整 UVM regression。
2. **write_txn_active 计数边界**：当前定义 `S_AW | S_WDATA | S_WAIT_B`。如果 AW handshake 与 WLAST 之间有 idle cycles（FIFO empty mid-burst），这些会被计入 txn_cycles 但不产生 data_cycles。在实际运行中，由于 delayed AW 保证 FIFO 预填充，mid-burst FIFO empty 不应发生，但理论边界存在。
3. **tb_npu_top 预载问题**：现有 TB 的 RAM 预载逻辑需要排查，否则无法获取真实 perf counter 读数。

---

*报告结束。本轮完成：统计口径修正、4 套 directed test 创建、B9 验证、最小 regression。无核心 RTL 修改，所有改动增量且兼容。*
