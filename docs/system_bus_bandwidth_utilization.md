# System-Level NPU Bus Bandwidth Utilization

**Date**: 2026-06-25
**Status**: Measurement infrastructure established

---

## 1. 指标定义

### 主指标：system_task_bus_active_ratio

```
system_task_bus_active_ratio =
    bus_data_active_cycles / task_cycles × 100%
```

其中：

```
task_cycles:
    从 NPU busy 拉高到 done 拉高的完整任务窗口周期数。
    来源：PERF_CYCLE_LO (0x30)，每个 task_start 自动复位。

bus_data_active_cycles =
    read_data_cycles + write_data_cycles

read_data_cycles:
    任务窗口内 RVALID && RREADY 同时为高的周期数。
    来源：PERF_READ_BEATS (0x38)

write_data_cycles:
    任务窗口内 WVALID && WREADY 同时为高的周期数。
    来源：PERF_WRITE_DATA_CYC (0xD0)
```

**赛题目标**: `system_task_bus_active_ratio >= 60%`

### 辅助指标

| 指标 | 公式 | 来源 |
|------|------|------|
| compute_active_ratio | PERF_ARRAY_ACTIVE (0x48) / task_cycles | NPU perf counter |
| payload_bandwidth_util | payload_bytes / (task_cycles × 32B) | 有效数据 payload 带宽 |
| beat_bandwidth_util | beat_bytes / (task_cycles × 32B) | AXI beat 级总线占用 |
| write_transaction_util | PERF_WRITE_DATA_CYC (0xD0) / PERF_WRITE_TXN_CYC (0xD4) | DMA writer sub-metric |

### AR/AW/B 请求统计（波形可见性）

| 指标 | 统计方式 | 来源 |
|------|---------|------|
| read_addr_cycles | ARVALID && ARREADY | TB accumulator (probe_vif.bus_ar_cycles) |
| write_addr_cycles | AWVALID && AWREADY | TB accumulator (probe_vif.bus_aw_cycles) |
| write_resp_cycles | BVALID && BREADY | TB accumulator (probe_vif.bus_b_cycles) |

AR/AW 请求周期仅用于波形可见性分析，**不作为带宽利用率主指标**。带宽利用率仅从 R/W 数据通道握手计算。

---

## 2. 指标层次关系

```
层次              | 指标                          | 用途
-----------------|------------------------------|---------------------------
AXI W-channel    | write_transaction_util       | DMA writer 内部子指标
sub-metric       | = 80.00% (long burst)        | 保留，不作为系统级指标
-----------------|------------------------------|---------------------------
AXI data-channel | read_data_cycles             | R 通道数据握手周期
activity         | write_data_cycles            | W 通道数据握手周期
                 | bus_data_active_cycles       | R||W 数据周期总和
-----------------|------------------------------|---------------------------
System-level     | system_task_bus_active_ratio | **赛题主指标**
task window      | = bus_active / task_cycles   | 完整任务窗口内总线活跃占比
-----------------|------------------------------|---------------------------
Compute          | compute_active_ratio         | 脉动阵列计算周期占比
activity         | = array_active / task_cycles |
-----------------|------------------------------|---------------------------
Overhead         | overhead_cycles              | FSM/后处理/存储通路/etc
                 | = task - bus - compute       |
-----------------|------------------------------|---------------------------

重要：dma_axi_writer 的 80.00% long-burst 结果是 write transaction-level 子指标，
仅衡量 AW→B 窗口内的 W 通道填充效率。它**不是**系统级总线利用率。
```

---

## 3. 测试 Workload

由 UVM 测试 `npu_system_bus_util_test` 测量。

### Workload A: FC Full-Cluster 96-Output (Baseline)

| 参数 | 值 |
|------|-----|
| 任务类型 | FC |
| Cluster 模式 | full (6 clusters) |
| Input channels | 16 |
| Output channels | 96 |
| 总 payload | 1,936 字节 |

### Workload B: FC Large Bandwidth-Stress (1K→96)

| 参数 | 值 |
|------|-----|
| 任务类型 | FC |
| Cluster 模式 | full (6 clusters) |
| Input channels | 1024 |
| Output channels | 96 |
| 总 payload | 99,712 字节 (input 1K + weight 96K + output 384B) |
| DMA read beats (理论) | ~3104 |

设计目标：大权重矩阵产生持续的 DMA read burst，写入阶段占比极小（仅 384 字节输出）。

---

## 4. 实测结果

| 指标 | Workload A: Baseline | Workload B: Bus-Stress |
|------|---------------------|----------------------|
| task_cycles | 2,318 | 111,835 |
| read_data_cycles (RVALID&&RREADY) | 49 | 3,104 |
| write_data_cycles (WVALID&&WREADY) | 12 | 12 |
| **bus_data_active_cycles** | **61** | **3,116** |
| AR handshake cycles | 4 | 194 |
| AW handshake cycles | 2 | 2 |
| B handshake cycles | 2 | 2 |
| array_active_cycles | 428 | 6,848 |
| overhead_cycles | 1,829 | 101,871 |
| | | |
| **system_task_bus_active_ratio** | **2.63%** | **2.79%** |
| compute_active_ratio | 18.46% | 6.12% |
| payload_bandwidth_util | 2.61% | 2.79% |
| beat_bandwidth_util | 2.63% | 2.79% |
| write_transaction_util (ref) | 66.67% | 66.67% |
| | | |
| **赛题 60% 目标** | **未达标** | **未达标** |

### 关键发现

1. **bus_data_active_cycles 随 workload 增大而增大**：Workload A 61 cycles → Workload B 3,116 cycles（50× 增长）
2. **overhead_cycles 占绝对主导**：Workload A 78.9%，Workload B 91.1%
3. **即使大 workload，bus_active_ratio 仍然很低**：因为 task_cycles 同步增长（2,318 → 111,835），overhead 占比反而更高
4. **compute 占比不高**：Workload A 18.46%，Workload B 仅 6.12%（tile pass 管理开销大）

---

## 5. 瓶颈分析：为什么 system_task_bus_active_ratio 低于 60%

### 5.1 Overhead 占主导（78-91%）

Overhead 包括：
- **FSM 状态转换**：每个 tile pass 需要多个 FSM 状态（FC_TILE_PREP → FC_LOAD_WGT → FC_LOAD_WAIT → LOAD_ARRAY → WGT_LD → COMPUTE → STORE）
- **Store-pack 路径**：32-bit acc_buffer 需要 8 个 read 周期才能组装 1 个 256-bit beat（~16 cycles/beat）
- **Buffer 管理**：npu_buffer bank 切换、读等待延迟
- **Post-process**：ReLU/Pool/Bias+Requant 处理
- **DMA setup/teardown**：AW 握手、B 响应等待

### 5.2 读/写串行化

- DMA read（激活 + 权重）和 DMA write（输出）在不同 FSM 阶段，不能并发
- 读阶段和写阶段之间隔了 compute 和 store-pack
- 不能像流水线那样读/写 overlap

### 5.3 Store-pack 是主要瓶颈

- acc_buffer 32-bit 单端口，store_pack 需要 8 次顺序读取才能产生 1 个 AXI beat
- 写入 384 字节（12 beats）需要 ~200 cycles 的 store-pack 时间
- 写入 99,712 字节需要大量 store-pack 周期，但实际只写了 384 字节 output（FC 输出固定）

### 5.4 FC tile-based 多 pass

- 1024 输入通道需要 16 个 input chunk pass（fc_chunk_inputs = min(1024,64) = 64）
- 96 输出通道需要 6 个 output tile pass（fc_tile_capacity = 16）
- 总 pass 数 = 16 × 6 = 96 次 LOAD_ARRAY → WGT_LD → COMPUTE 循环
- 每次循环的 overhead 累积导致 task_cycles 极大

---

## 6. 波形分析指南

在波形中应观察到以下序列（每个 tile pass 内）：

```
ARVALID/ARREADY ──[read burst]──
RVALID/RREADY   ──[read data]───
                                    [compute window]
                                    cluster_busy ────
                                    array_active ────
                                                          AW──[write burst]──
                                                          W──[write data]────
                                                          B──[write resp]────
```

关键观察点：
- RVALID/RREADY 握手密度（read 阶段带宽利用率）
- WVALID/WREADY 握手密度（write 阶段带宽利用率）
- cluster_busy / array_active 窗口持续时间（compute 占比）
- AR/AW 请求之间的间隔（FSM overhead）
- Store-pack 期间 W 通道的间隔（32-bit 路径瓶颈）

---

## 7. 提高 system_task_bus_active_ratio 的方向

| 优化方向 | 预期效果 | 状态 |
|---------|---------|------|
| **Phase C: acc_buffer 256-bit 位宽扩展** | 消除 store-pack 8:1 瓶颈，写阶段缩短 ~8× | **暂缓** |
| **DMA read/write 并行化** | 读/写阶段可重叠，增加 bus 并发利用率 | **待实现** |
| **Weight preload 与 compute 重叠** | 多通道 Conv 已部分实现；FC 可扩展 | **部分实现** |
| **减少 FSM overhead** | 合并状态、预取下一 tile | **待优化** |
| **增加 output 数据量** | 对于写入为主的 workload 提高 bus 占比 | **受限于网络结构** |
| **Ping-pong buffer** | 一边 compute 一边 DMA，隐藏延迟 | **待实现** |

**当前架构下 system_task_bus_active_ratio < 3% 是真实测量结果。**
需要通过上述 RTL 优化才能显著提高。

---

## 8. 测试运行命令

```bash
# 系统级总线利用率测试
bash verif/uvm_top/scripts/run_uvm.sh npu_system_bus_util_test UVM_NONE

# DMA writer transaction-level test (80.00% reference)
bash sim/run_sim.sh tb_dma_writer_long_burst
```

---

## 9. 相关文档

- `docs/dma_write_final_summary.md`: DMA write 80.00% 指标（write-channel sub-metric）
- `docs/CPU_NPU_design_spec.md`: CPU+NPU SoC 设计规范
- `docs/uvm_structural_test_closure.md`: UVM 结构性测试回归状态
- `verif/uvm_top/tests/npu_system_bus_util_test.sv`: 系统级总线利用率 UVM 测试

---

*文档更新。system_task_bus_active_ratio 测量框架已建立。当前实测 2.6-2.8%，未达 60% 赛题目标。需 RTL 优化（Phase C、读/写并行化、ping-pong buffer）才能显著提升。*
