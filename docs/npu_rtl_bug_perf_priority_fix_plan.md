# NPU RTL Bug 与性能调优优先级修复文档

> 用途：交给 Claude Code 按优先级修复当前 NPU RTL bug 与后续性能优化项。  
> 当前主线目标：先闭合 `vector_int8_relu_256b` 的功能正确性，再验证系统级总线利用率是否真实达到 60%。  
> 当前限制：暂时不修改 FC RTL，不做 FC K-streaming，不做额外大架构优化。

---

## 0. 当前总体判断

当前 `vector_int8_relu_256b` 方向正确，但尚未完成 RTL correctness closure。

当前已知事实：

```text
512B 单 burst:
  output_compare PASS
  actual_write_beats == expected_write_beats == 16
  actual_read_beats = 32, expected_read_beats = 16

16KB 多 burst:
  output_compare FAIL
  mismatch 从 byte 512 / beat 16 附近开始
  actual_write_beats = 480/482, expected_write_beats = 512
  actual_read_beats = 1024, expected_read_beats = 512
  当前 ratio 约 67%，但由于 output FAIL + 2x read + write shortfall，不能作为有效达标证据
```

当前主线结论：

```text
vector_int8_relu_256b 不能宣称达到 60%；
必须先实现：
  output_compare PASS
  actual_read_beats == expected_read_beats
  actual_write_beats == expected_write_beats
  system_task_bus_active_ratio >= 60%
```

---

## 1. 硬性约束

Claude Code 后续修复时必须遵守：

```text
1. 不修改 FC RTL；
2. 不修改 Conv/FC compute datapath；
3. 不修改 golden / scoreboard 来掩盖 mismatch；
4. 不跳过 output compare；
5. 不缩短 task_cycles 统计窗口；
6. 不把 AR/AW/B 控制通道计入主带宽指标；
7. 不把 2x read 当作有效带宽；
8. 不在 output FAIL 时宣称 60% 达标；
9. 不在 actual_write_beats != expected_write_beats 时宣称 done 正确；
10. 不先 commit。
```

主带宽指标定义：

```text
system_task_bus_active_ratio =
    count((RVALID && RREADY) || (WVALID && WREADY)) / task_cycles
```

---

## 2. P0：必须优先修复的 RTL bug

### P0-1：`vector_int8_relu_256b` 16KB 多 burst output FAIL

#### 现象

```text
512B:
  output_compare PASS
  write 16/16 beats

16KB:
  output_compare FAIL
  mismatch 从 byte 512 / beat 16 附近开始
```

#### 技术判断

`byte 512 = 16 beats × 32 bytes/beat`，说明第一个 16-beat burst 基本正确，第二个 burst 或 burst 边界之后出现问题。

#### 可能根因

```text
1. vector Phase B producer 没有完整 push 512 beats；
2. fifo_full 时 beat_idx 仍然自增，导致丢 beat；
3. producer_done 提前；
4. rd_wait pipeline 没有正确 flush 最后若干 beat；
5. FIFO push/pop 边界错误；
6. dma_axi_writer 第二个 burst 后消费/地址/bytes_remaining 管理异常；
7. AWADDR / WDATA / WSTRB / WLAST 在第二个 burst 起错位。
```

#### 必须增加或打印的计数

```text
[VEC_COUNT] expected_beats
[VEC_COUNT] vec_rd_issue_count
[VEC_COUNT] vec_rd_data_valid_count
[VEC_COUNT] vec_fifo_push_count
[VEC_COUNT] fifo_pop_count
[VEC_COUNT] axi_w_handshake_count
[VEC_COUNT] producer_done_cycle
[VEC_COUNT] writer_done_cycle
[VEC_COUNT] bytes_remaining_at_writer_done
[VEC_COUNT] fifo_full_stall_count
[VEC_COUNT] fifo_empty_wait_count
```

#### 定责规则

```text
if vec_fifo_push_count < 512:
    root cause 在 npu_top.v 的 vector_relu Phase B producer。
    检查 producer_done / beat_idx / fifo_full stall / rd_wait pipeline。

if vec_fifo_push_count == 512 and fifo_pop_count < 512:
    root cause 在 write_beat_fifo pop 或 writer input handshake。

if fifo_pop_count == 512 and axi_w_handshake_count < 512:
    root cause 在 dma_axi_writer W channel / bytes_remaining / S_DONE。

if axi_w_handshake_count == 512 but output_compare FAIL:
    root cause 在 AWADDR / WDATA / WSTRB / shared RAM write address。
```

#### 验收标准

```text
16KB:
  output_compare PASS
  actual_write_beats == expected_write_beats == 512
  done == 1
  error == 0
```

---

### P0-2：`vector_int8_relu_256b` write beat shortfall

#### 现象

```text
16KB:
  expected_write_beats = 512
  actual_write_beats   = 480/482
```

#### 风险

这是 silent data loss 风险。`done=1` 但实际写回 beat 数不足，比 timeout 更危险。

#### 修复原则

```text
writer_done 只能在以下条件全部满足时产生：
  actual_write_beats == expected_write_beats
  bytes_remaining == 0
  当前 burst 已完成
  无 pending B response
```

禁止：

```text
producer_done && fifo_empty && bytes_remaining != 0 -> 正常 S_DONE
```

如果出现：

```text
producer_done == 1
fifo_empty == 1
bytes_remaining != 0
```

应视为：

```text
producer beat 不足 / writer underflow / producer_done 提前 / bytes_remaining 管理错误
```

不能正常 done。

#### 推荐修复方向

优先判断 `vec_fifo_push_count` 是否达到 512：

```text
case 1:
  vec_fifo_push_count < 512
  -> 修 npu_top.v vector producer。

case 2:
  vec_fifo_push_count == 512 but axi_w_handshake_count < 512
  -> 修 FIFO/writer 边界。

case 3:
  axi_w_handshake_count == 512 but output FAIL
  -> 修 AWADDR/WDATA/WSTRB/shared RAM 写入路径。
```

---

### P0-3：`vector_int8_relu_256b` 2x DMA read

#### 现象

```text
512B:
  expected_read_beats = 16
  actual_read_beats   = 32

16KB:
  expected_read_beats = 512
  actual_read_beats   = 1024
```

#### 当前判断

该问题必须修复，否则会被视为通过多读无效数据刷带宽。

#### 必须区分两种情况

```text
A. 真实 AXI R channel 读了 2x；
B. PERF_READ_BEATS / TB monitor 计数错误。
```

#### 必须交叉验证

```text
[READ_COUNT] configured_input_bytes
[READ_COUNT] act_dma_bytes_at_start
[READ_COUNT] dma_reader_start_bytes
[READ_COUNT] ar_bursts
[READ_COUNT] r_handshakes
[READ_COUNT] perf_read_beats
[READ_COUNT] tb_r_handshakes
[READ_COUNT] act_buffer_writes
```

#### 定责规则

```text
if dma_reader_start_bytes == 2x expected:
    root cause 在 npu_top / act_read_path / block_scheduler 的 byte_count 配置。

if dma_reader_start_bytes == expected and R handshakes == 2x:
    root cause 在 dma_axi_reader burst generation / repeated read start。

if R handshakes == expected but PERF_READ_BEATS == 2x:
    root cause 在 perf counter 或 TB monitor。

if R handshakes == 2x but act_buffer_writes == expected:
    root cause 在 redundant read / overwrite / monitor scope。
```

#### 验收标准

```text
512B:
  actual_read_beats == expected_read_beats == 16

16KB:
  actual_read_beats == expected_read_beats == 512

64KB:
  actual_read_beats == expected_read_beats == 2048
```

---

### P0-4：`vector_int8_relu_256b` 60% 带宽指标有效闭合

#### 当前状态

当前 16KB ratio 约 67%，但无效：

```text
output_compare FAIL
actual_read_beats = 2x expected
actual_write_beats = 482/512
```

#### 有效 PASS_TARGET 条件

```text
output_compare PASS
actual_read_beats == expected_read_beats
actual_write_beats == expected_write_beats
system_task_bus_active_ratio >= 60%
```

#### 理论可达模型

修复后 16KB case：

```text
N = 512 beats

read_cycles  = 512
write_cycles = 512
Phase B      = 1024   // 当前 0.5 beat/cycle
task_total   ≈ 1536   // read N + PhaseB 2N, write overlapped
bus_active   = 1024   // read N + write N
ratio        ≈ 1024 / 1536 = 66.7%
```

---

## 3. P1：修复 P0 后再处理的 RTL 健壮性问题

### P1-1：`producer_done / writer_done` 协议语义统一

#### 当前矛盾

```text
无 producer_done:
  writer 可能在 S_WAIT_DATA 永久等待。

有 producer_done:
  如果处理不当，writer 可能提前 S_DONE，造成 write shortfall。
```

#### 推荐语义

```text
producer_done:
  producer 不再产生新的 write beat。

writer_done:
  writer 已完成 expected bytes 对应的全部 AXI W handshake。
```

两者不能混用。

#### 推荐规则

```text
producer_done 不能直接触发正常 writer_done；
writer_done 必须由 bytes_remaining == 0 或 actual_w_beats == expected_beats 驱动；
producer_done && fifo_empty && bytes_remaining != 0 应视为 underflow/error。
```

---

### P1-2：强化 `npu_bandwidth_60pct_stress_test` PASS 条件

测试必须严格区分：

```text
functional PASS
bandwidth PASS
PASS_TARGET
```

建议打印：

```text
[SYS_BUS_60] workload=vector_int8_relu_256b
[SYS_BUS_60] input_bytes=<N>
[SYS_BUS_60] expected_read_beats=<N>
[SYS_BUS_60] actual_read_beats=<N>
[SYS_BUS_60] expected_write_beats=<N>
[SYS_BUS_60] actual_write_beats=<N>
[SYS_BUS_60] bus_active_cycles=<N>
[SYS_BUS_60] task_cycles=<N>
[SYS_BUS_60] system_task_bus_active_ratio=<XX.XX>%
[SYS_BUS_60] output_compare=PASS/FAIL
[SYS_BUS_60] PASS_TARGET/BELOW_TARGET
```

PASS_TARGET 只能在以下条件同时满足时打印：

```text
output_compare PASS
actual_read_beats == expected_read_beats
actual_write_beats == expected_write_beats
ratio >= 60%
```

---

### P1-3：Conv multi-cluster correctness 风险

#### 已知现象

Conv 在 multi-cluster 模式下存在历史 correctness 风险；single-cluster Conv 可作为 workaround。

#### 可能根因

```text
1. Conv output-channel 到 cluster 的映射错误；
2. output_arbiter 输出 beat 顺序与 golden 不一致；
3. Conv weight split / route 不正确；
4. partial-sum merge 或 cluster boundary 条件不完整；
5. Conv spatial window 与 cluster split 的边界条件未处理。
```

#### 当前建议

```text
当前不作为主线 P0；
vector bandwidth path 闭合后，再单独开分支修 Conv multi-cluster。
```

---

## 4. 性能调优项目

### Perf-0：`vector_int8_relu_256b` bandwidth path 收口

#### 优先级

```text
最高优先级。
```

#### 目标

```text
16KB/64KB:
  output_compare PASS
  read/write beats exact
  ratio >= 60%
```

#### 说明

这是当前最快满足赛题 “Burst 场景总线带宽利用率 ≥60%” 的路径。

---

### Perf-1：FC K-streaming / session merge

#### 当前问题

FC-1K→96 当前 system-level bus ratio 约 18.77%。根因不是 MAC 组合逻辑慢，而是 FC 被拆成太多 compute sessions。

当前结构：

```text
2 output tiles × 16 K chunks = 32 sessions
```

每个 session 都重复：

```text
FEED_ACT
DRAIN
COLLECT
```

#### 目标结构

```text
2 output tiles × 1 long K-stream = 2 sessions
```

#### 预期收益

```text
减少重复 drain/collect；
减少 partial sum 反复读写；
提高阵列持续利用率；
降低 task_cycles。
```

#### 当前建议

```text
暂时不碰 FC RTL。
等 vector bandwidth path P0 全部闭合后，单独开 branch/worktree 做。
```

---

### Perf-2：acc_buffer / store path 256-bit 化

#### 当前瓶颈

常规 Conv/FC/Requant store path 中：

```text
acc_buffer 32-bit read
  -> store_pack 串行组 256-bit beat
  -> write_beat_fifo
  -> dma_axi_writer
```

该路径与 256-bit AXI W channel 宽度不匹配。

#### 优化方向

```text
Option A:
  acc_buffer 改成 256-bit 宽读。

Option B:
  8-bank parallel acc_buffer，每 bank 32-bit。

Option C:
  compute collect 阶段直接生成 256-bit write beat。
```

#### 当前建议

```text
P1/P2。
风险中等偏高。
不要在 vector path bug closure 阶段做。
```

---

### Perf-3：store_pack pipeline

#### 当前问题

store_pack 约 16~17 cycles 才能生成一个 256-bit beat。

#### 优化目标

```text
减少 WAIT/CAPTURE 空拍；
从约 17 cycles/beat 降到约 9 cycles/beat。
```

#### 当前建议

```text
P2。
收益有限，优先级低于 vector path correctness 和 FC K-streaming。
```

---

### Perf-4：vector Phase B rd_wait pipeline 优化

#### 当前状态

```text
Phase B 当前约 0.5 beat/cycle：
  read address
  wait one cycle
  push ReLU output
```

#### 优化目标

```text
1 beat/cycle
```

#### 需要修改

```text
act_buffer read pipeline
rd_issue / rd_valid / push 解耦
fifo_full backpressure
beat_idx 对齐
```

#### 当前建议

```text
P2。
当前即使 0.5 beat/cycle，理论 ratio 也能到 66.7%。
先修 correctness，不急于优化。
```

---

### Perf-5：read / compute / write overlap

#### 当前多数 workload 模式

```text
read -> compute -> write
```

#### 目标模式

```text
read tile N+1
compute tile N
write tile N-1
```

#### 需要

```text
ping-pong buffer
streaming scheduler
独立 read/write/compute FSM 协同
更复杂 task boundary 管理
```

#### 当前建议

```text
P2/P3。
长期架构优化，不适合当前 bug closure 阶段。
```

---

## 5. 推荐执行顺序

### Stage 1：只修 vector write correctness

目标：

```text
16KB:
  output_compare PASS
  actual_write_beats == expected_write_beats == 512
```

重点：

```text
vec_fifo_push_count
fifo_pop_count
axi_w_handshake_count
```

只有这三个都等于 512，才能进入下一阶段。

---

### Stage 2：修 2x read

目标：

```text
512B:
  actual_read_beats == 16

16KB:
  actual_read_beats == 512

64KB:
  actual_read_beats == 2048
```

重点：

```text
dma_reader_start_bytes
AR burst count
R handshake count
PERF_READ_BEATS
act_buffer write count
```

---

### Stage 3：重新跑 bandwidth stress

目标：

```text
16KB/64KB:
  output_compare PASS
  read/write beats exact
  system_task_bus_active_ratio >= 60%
```

---

### Stage 4：跑 smoke / directed regression

最低回归集合：

```text
npu_bandwidth_60pct_stress_test
npu_fc_smoke_test
npu_conv_smoke_test
npu_requant_smoke_test
tb_dma_writer_long_burst
tb_dma_writer_tail_burst
tb_dma_writer_awlen_wlast
tb_dma_writer_backpressure
tb_dma_writer_zero_byte
```

如果测试不存在，报告 `NOT FOUND`，不要伪造 PASS。

---

### Stage 5：再开性能优化分支

顺序建议：

```text
1. FC K-streaming / session merge
2. acc_buffer/store path 256-bit 化
3. store_pack pipeline
4. vector Phase B 1 beat/cycle
5. read/compute/write overlap
6. Conv multi-cluster correctness + performance
```

---

## 6. Claude Code 修复时的最终报告格式

每轮最终报告必须包含：

```text
1. 是否修改 RTL；
2. 修改文件列表；
3. 是否修改 FC RTL，必须明确说明；
4. 本轮修复的 bug；
5. root cause；
6. 修复方案；
7. 512B 测试结果；
8. 16KB 测试结果；
9. 64KB 测试结果，如果运行；
10. expected/actual read beats；
11. expected/actual write beats；
12. output_compare 是否 PASS；
13. system_task_bus_active_ratio 是否 >=60%；
14. smoke/directed regression 结果；
15. 是否建议提交；
16. 不要输出 git commit 命令。
```

---

## 7. 当前优先级总表

| 优先级 | 项目 | 类型 | 当前状态 | 下一步 |
|---|---|---|---|---|
| P0 | 16KB `vector_relu` output FAIL | RTL bug | 未修复 | 修 write 512/512 + output PASS |
| P0 | write beats 480/482 of 512 | RTL bug | 未修复 | 定位 producer/FIFO/writer 哪一级少 beat |
| P0 | 2x DMA read | RTL/counter bug | 未修复 | 区分真实 2x read 还是 counter 计重 |
| P0 | 60% 有效达标 | 性能验收 | 未闭合 | correctness PASS 后重新计算 |
| P1 | producer_done / writer_done 协议 | RTL 健壮性 | 语义不清 | done 必须由 expected beats 完成驱动 |
| P1 | stress test PASS 条件 | 验证 | 需加强 | 缺一不可：output/read/write/ratio |
| P1 | FC K-streaming | 性能 | 暂不碰 | vector path 闭合后单独分支 |
| P1/P2 | acc_buffer 256-bit 化 | 性能/架构 | 未做 | 中风险，后续做 |
| P2 | store_pack pipeline | 性能 | 未做 | 可作为轻量优化 |
| P2 | vector Phase B pipeline | 性能 | 未做 | correctness 后再优化 |
| P2 | Conv multi-cluster correctness | RTL bug/性能 | 有风险 | 单独分支修 |
| P2/P3 | read/compute/write overlap | 架构优化 | 未做 | 长期优化 |

---

## 8. 一句话结论

当前主线不是继续调性能，而是先把 `vector_int8_relu_256b` 的 multi-burst correctness 闭合：

```text
16KB output PASS
write 512/512
read 512/512
ratio >= 60%
```

完成后，再进入 FC K-streaming 和 store path 256-bit 化等真实性能优化。
