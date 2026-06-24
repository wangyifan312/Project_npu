# DMA 写通道带宽利用率优化方案简版

## 1. 当前瓶颈判断

当前 DMA 写通道利用率低的主要原因不是 AXI slave 或 shared RAM 慢，而是 **NPU 写回路径无法连续向 AXI writer 提供 256-bit WDATA**。

当前典型路径：

```text
acc_buffer 32-bit word
    -> store pack
    -> 256-bit AXI write beat
    -> dma_axi_writer
    -> AXI W channel
```

当前 store pack 大致需要：

```text
8 个 32-bit word 拼成 1 个 256-bit beat
约 17 cycles / beat
write_util ≈ 1 / 17 ≈ 5.88%
```

优化目标：

```text
让 dma_axi_writer 在 AW 事务开始后，尽量连续发送 WDATA。
```

---

## 2. 优化方案总览

| 方案 | 改动范围 | 主要提升 | 风险 | 推荐优先级 |
|---|---:|---|---|---:|
| A. 延迟发 AW | 小 | 提升事务级 write utilization | 主要改善统计口径，系统吞吐提升有限 | 1 |
| B. 加 write-beat FIFO | 中 | 解耦 store pack 和 AXI writer | 需要新增 FIFO 控制和 tail 处理 | 1 |
| C. writer W 通道流水化/skid buffer | 中 | 避免 writer 自身产生 bubble | 需要检查 WLAST/WSTRB 对齐 | 2 |
| D. acc_buffer 256-bit 宽读或 8-bank 并行读 | 中高 | 提升真实写回吞吐 | 可能影响 output ordering | 3 |
| E. postproc 直接流式写 FIFO | 高 | 架构级提升，减少中间 buffer | 改动大，验证成本高 | 4 |
| F. ping-pong output buffer | 高 | 计算与写回重叠 | 对调度/FSM 改动较大 | 5 |
| G. burst 聚合与 32B 对齐优化 | 小中 | 减少小 burst 和 partial beat | 依赖 output layout | 2 |

---

## 3. 推荐优先实现方案

优先评估并实现：

```text
store_packer
    -> 256-bit write_beat_fifo
    -> burst-aware dma_axi_writer
```

核心策略：

```text
1. store_packer 继续从 acc_buffer 读取 32-bit word；
2. 拼成完整 256-bit beat 后 push 到 write_beat_fifo；
3. dma_axi_writer 不在 STORE 一开始就发 AW；
4. 等 FIFO 中 beat 数达到 burst_len，或者 store_done 且 FIFO 非空时，再发 AW；
5. AW 发出后，writer 连续 pop FIFO 并发送 WDATA；
6. tail burst 使用正确 AWLEN 和 WSTRB；
7. WVALID 在 burst 内尽量保持连续。
```

目标：先把 **事务级 write utilization** 从约 5.88% 提升到 60% 以上，理想情况下接近 80%~90%。

---

## 4. 方案 A：延迟发 AW

### 当前问题

```text
STORE 状态开始
    -> dma_axi_writer 立即发 AW
    -> writer 等待 store pack 产生 data_valid
    -> W channel 中出现大量 bubble
```

由于 AW 已经 handshake，store pack 的等待时间被计入 write transaction cycles。

### 优化方式

```text
先 pack 数据；
等 FIFO 或 staging buffer 中有足够多 256-bit beat；
再发 AW；
然后连续发 WDATA。
```

### 触发条件建议

```verilog
if (fifo_level >= burst_len) begin
    start_write_burst = 1'b1;
end else if (store_done && fifo_level > 0) begin
    start_tail_burst = 1'b1;
end
```

### 评价

- 改动小。
- 对事务级 write utilization 提升明显。
- 如果 store pack 仍然慢，end-to-end 总周期未必明显下降。

---

## 5. 方案 B：加入 256-bit write-beat FIFO

### 结构

```text
acc_buffer / postproc
        |
        v
store_packer
        |
        v
write_beat_fifo
        |
        v
dma_axi_writer
        |
        v
AXI W channel
```

### FIFO entry 建议

SystemVerilog：

```systemverilog
typedef struct packed {
    logic [255:0] data;
    logic [31:0]  strb;
    logic         last;
} wr_beat_t;
```

Verilog 可拆成：

```text
wr_data_fifo : 256-bit
wr_strb_fifo : 32-bit
wr_last_fifo : 1-bit
```

### Writer 策略

```text
normal burst:
    fifo_level >= MAX_BURST_BEATS

tail burst:
    store_done && fifo_level > 0
```

推荐：

```text
MAX_BURST_BEATS = 16
AWLEN = burst_beats - 1
```

### 检查点

- tail burst 的 AWLEN 必须正确。
- 最后一个 partial beat 的 WSTRB 必须正确。
- FIFO pop 必须与 `WVALID && WREADY` 对齐。
- WLAST 必须落在当前 burst 的最后一个 beat。

---

## 6. 方案 C：dma_axi_writer 流水化

### 问题

即使 FIFO 有数据，如果 writer FSM 是低效结构，仍可能只能做到 1 beat / 2 cycles。

低效模式：

```text
load data
handshake
load next data
handshake
```

### 优化目标

当 FIFO 非空且 WREADY 为 1 时：

```text
WVALID 应连续保持为 1；
每周期发送一个 beat；
当前 beat handshake 的同时准备下一 beat。
```

### 建议结构

```text
FIFO -> skid buffer -> AXI W channel
```

### 检查点

- WDATA/WSTRB/WLAST 在 `WVALID && !WREADY` 时必须保持稳定。
- WLAST 必须与 burst beat counter 对齐。
- B response 必须在整个 burst 完成后等待。
- 不要在 B response 前启动下一个 burst，除非 writer 明确支持 outstanding。

---

## 7. 方案 D：acc_buffer 256-bit 宽读 / 8-bank 并行读

### 目标

从根本上提升 store pack 供数能力。

当前：

```text
acc_buffer 每次读 32-bit
8 次读才能形成 1 个 256-bit beat
```

优化后：

```text
acc_buffer 每周期读出 256-bit
或 8 个 32-bit bank 并行读出
```

### 预期效果

- store pack 从约 17 cycles/beat 降到 1~2 cycles/beat。
- 同时提升事务级 write utilization 和系统级 writeback throughput。

### 风险

- 需要调整 acc_buffer 地址组织。
- 可能影响 output ordering。
- 需要重新验证 Conv/FC/Requant 输出顺序。
- 改动比 FIFO 方案大。

---

## 8. 方案 E：postproc 直接流式写 FIFO

### 结构

```text
compute_core / output_arbiter
    -> postproc / requant
    -> output_stream_packer
    -> write_beat_fifo
    -> dma_axi_writer
```

### 优点

- 避免 acc_buffer 二次读。
- 减少中间存储访问。
- compute/postproc/writeback 更容易 pipeline。
- 架构更接近高性能 accelerator。

### 风险

- RTL 改动大。
- 需要保证不同算子的 output order。
- Conv/FC/Pool/Requant/ADD/GAP 的 pack 规则可能不同。
- 验证成本高。

建议作为长期优化，不建议比赛收尾阶段优先做。

---

## 9. 方案 F：ping-pong output buffer

### 目标

让计算和写回重叠：

```text
compute writes buffer A
DMA writes back buffer B

compute writes buffer B
DMA writes back buffer A
```

### 效果

- 降低 start-to-done 总周期。
- 隐藏部分 DMA write latency。
- 对事务级 utilization 的直接提升有限。

### 风险

- 控制 FSM 改动较大。
- 需要处理 buffer ownership。
- 需要防止 compute/writeback 读写冲突。

---

## 10. 方案 G：burst 聚合和输出地址对齐

### 优化点

1. 优先发满 16-beat burst。
2. 只有最后 tail 才发短 burst。
3. output_addr 保持 32B 对齐。
4. output_bytes 尽量按 32B 对齐。
5. 避免每行/每 channel 都单独 flush partial beat。
6. 合并连续输出区域，减少 AW/B overhead。

### 收益

- 减少小 burst。
- 减少 partial WSTRB。
- 提升 write transaction utilization。
- 改动相对较小。

---

## 11. 推荐决策顺序

### 第一优先级：低风险，直接解决指标

```text
A. 延迟 AW
B. write-beat FIFO
G. burst 聚合和 tail burst 处理
```

目标：

```text
write transaction utilization >= 60%
```

### 第二优先级：消除 writer 自身 bubble

```text
C. writer W channel 流水化 / skid buffer
```

目标：

```text
FIFO 非空且 WREADY=1 时，WVALID 连续。
```

### 第三优先级：提升真实系统吞吐

```text
D. acc_buffer 256-bit 宽读 / 8-bank 并行读
```

目标：

```text
store pack 接近 1 beat/cycle。
```

### 第四优先级：架构级重构

```text
E. postproc stream-to-FIFO
F. ping-pong output buffer
```

仅当时间充足、基础回归稳定时考虑。

---

## 12. 验证要求

每次修改后至少跑：

```text
1. npu_requant_smoke_test
2. npu_fc_smoke_test
3. npu_conv_smoke_test
4. soc_shared_ram_rw_test
5. 现有 store pack / dma writer directed test，如果仓库中存在
```

必须检查：

```text
1. output numerical compare PASS
2. WSTRB 正确，尤其 partial last beat
3. AWLEN 与实际 W beat 数一致
4. WLAST 只在最后一个 beat 拉高
5. B response 正常
6. no timeout
7. write_util counter 变高
```

---

## 13. 带宽利用率统计口径

写事务级利用率：

```text
write_util =
cycles(WVALID && WREADY)
/
cycles(AW handshake -> BVALID && BREADY)
```

如果当前 monitor 采用 AW 到 WLAST 作为窗口，也需要在报告中明确说明。

建议同时输出：

```text
write_txn_count
write_data_cycles
write_txn_cycles
avg_write_util
write_beats
write_active_cycles
```

注意：

```text
当前 shared_ram 是 SRAM/scratchpad 功能模型。
优化 write_util 主要说明 AXI write transaction 内 W channel 连续性提升；
如果 store pack 仍慢，系统级 start-to-done cycles 不一定同步大幅下降。
```

---

## 14. 推荐最终实现目标

最低目标：

```text
1. write-beat FIFO 可工作；
2. writer 延迟 AW；
3. tail burst 正确；
4. output compare 不回归；
5. write transaction utilization >= 60%。
```

理想目标：

```text
1. W channel 在 FIFO 非空时可连续 1 beat/cycle；
2. avg_write_util >= 80%；
3. Conv/FC/Requant smoke 均 PASS；
4. LeNet single sample 不回归；
5. perf report 能显示优化前后 write_util 对比。
```

---

## 15. 给 Claude Code 的任务边界

不要优先做：

```text
1. 多 outstanding write；
2. 完整 AXI interconnect 重构；
3. DDR/HBM controller；
4. 大规模 compute dataflow 重构；
5. 为了提高利用率而删除 output compare 或弱化 checker。
```

优先做：

```text
1. 用最小改动提升 write transaction utilization；
2. 保持输出数值正确；
3. 保持 AXI W channel 协议正确；
4. 用 regression 证明没有破坏 Conv/FC/Requant 路径。
```
