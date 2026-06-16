# Full-Cluster 性能优化执行方案

> 项目：Project_npu  
> 范围：`rtl/npu` 当前 6-cluster 正式数据流上的 first-pass 性能优化。  
> 目的：在不改变 current route/aggregate 语义、不破坏 shared memory / store-path contract 的前提下，提升 full-cluster 的实际运行速度。

---

## 1. 背景与结论基础

本方案建立在 `docs/NPU_RTL_TODO.md` 已收口的 Workstream A / Workstream B 结论之上。

### 1.1 Workstream A 已确认的事实

当前 6-cluster 路径已经确认：

- `AGGREGATE_MODE=1` 不是 arithmetic reduce，而是 routed global-column bitfield OR merge。
- 当前 multi-cluster 数据流是：
  - activation broadcast
  - weight 按 output column / output channel group 切分
  - route 到 global output column 后进行 OR merge
- route / aggregate correctness 可以按 Workstream A 范围关闭。

### 1.2 当前 full-cluster 不明显提速的原因

当前 full-cluster 速度问题的主因不是 cluster 语义错误，而是系统级串行瓶颈：

1. activation / weight 共用单一 AXI read channel  
   `read_sel_act = act_dma_busy`
2. 当前运行证据中  
   `act_wgt_overlap = 0`
3. Conv 主路径仍按如下顺序组织：

```text
LOAD_ACT -> CIN_LOAD_WGT -> LOAD_ARRAY -> WGT_LD -> COMPUTE -> COLLECT/STORE
```

4. `LOAD_ARRAY` 是明确的大开销阶段
5. `COLLECT / STORE` 也是非零且不可忽略的尾部阶段
6. 双 bank 结构存在，但 weight-side overlap 利用不足

### 1.3 当前 layer-like probe 基线

已知 `tb_npu_top_layer_event_probe` 结果：

```text
shape = 8x8x2 -> 4x4x8
total = 4119
load_act = 9
cin_load_wgt = 24
load_array = 416
wgt_ld = 2
compute = 3370
drain = 1664
collect = 512
store = 278
route_valid = 256
collect_events = 256
act_dma_busy = 7
wgt_dma_busy = 20
act_wgt_overlap = 0
write_dma_busy = 275
```

这说明：

- 纯 DMA read 不是唯一大头
- `LOAD_ARRAY / COLLECT / STORE` 都是实际存在的运行级成本
- 若要让 full-cluster 真正体现价值，必须优先打薄前端供数和内部装载链路

---

## 2. 优化目标与硬约束

## 2.1 优化目标

当前优化目标不是“大改架构”，而是：

> 在不改变 current 6-cluster 数据流语义的前提下，做 first-pass 性能优化，让 full-cluster 在 layer-like probe 上出现可测的总周期下降。

更具体地说：

1. 让 weight-side preload / consume 出现可观测重叠
2. 压缩 `CIN_LOAD_WGT` 和/或 `LOAD_ARRAY`
3. 降低 total cycles
4. 不牺牲 current correctness

## 2.2 Workstream B 护栏

本次优化必须严格遵守 Workstream B 的 contract，以下内容不得被性能优化顺手改坏：

1. 地址对齐规则保持 `64B`
2. shared memory / layer memory map 不重排
3. `acc_buffer -> DMA writer` 的 32-bit → 256-bit packing 语义不变
4. `dma_axi_writer` 的最后一拍 `WSTRB` 语义不变
5. output layout 不变
6. `blk_out_addr / blk_out_bytes` 的解释不变

这意味着：

> 当前优化对象是 weight-side orchestration 与 `LOAD_ARRAY` 装载链，不是 store-path contract。

---

## 3. 最佳 first-pass 方案

## 3.1 方案总述

当前最佳方案是：

> **weight-side ping-pong preload + `LOAD_ARRAY` 串行成本压缩**

这是当前最可能同时满足：

- 不破坏 correctness
- 不触碰 Workstream B 契约
- 能给 full-cluster 带来可见收益

的方案。

---

## 3.2 Phase 1：weight-side ping-pong preload

### 目标

让当前 compute 消费一个 weight bank 时，下一轮 `c_in` 的 weight 能尽早进入另一个 bank。

### 当前问题

从 Workstream A 当前证据看：

- `wgt_buffer` 结构上支持双 bank
- 但 current FSM 对 weight path 的 overlap 利用不足
- 下一轮 weight 基本还是等当前阶段结束后才开始推进

### 实施方向

允许修改：

- `npu_top` 中 weight bank orchestration
- `wgt_load_bank`
- `wgt_rd_bank`
- `comp_bank_sel`
- 下一轮 `c_in` 的 weight 准备时机

不允许修改：

- weight 逻辑映射
- route / aggregate 语义
- cluster scheduler 模式语义
- AXI 外部接口协议
- shared memory contract

### 目标行为

优化后应出现：

- 当前 compute 使用 bank A 时，下一轮 weight 已开始装入 bank B
- 或反过来
- 当前 compute bank 不被覆盖
- 下一轮 `FSM_CIN_LOAD_WGT` 不再完全串行阻塞在 compute 前

### 预期结果

第一层收益：

- 出现可观测的 weight-side overlap
- `act_wgt_overlap` 或等价 overlap 证据不再为 `0`

第二层收益：

- `CIN_LOAD_WGT` 时间下降

第三层收益：

- total cycles 可测下降

---

## 3.3 Phase 2：压缩 `LOAD_ARRAY`

### 目标

降低从 `wgt_buffer` 到 `wgt_load_reg / array` 的内部串行装载成本。

### 当前问题

当前 layer-like probe 中：

```text
LOAD_ARRAY = 416
```

这已经说明：

- 仅靠 DMA 提前并不足以解决主要瓶颈
- 必须把内部装载链本身压薄

### 实施方向

允许修改：

- `wgt_load_phase`
- `wgt_load_wait`
- beat extraction 节奏
- 每拍有效装载量
- `LOAD_ARRAY -> WGT_LD` 的局部时序组织

不允许修改：

- array 看到的权重内容与顺序
- cluster 内 local column 的 weight 解释
- single / dual / full / mask correctness
- output/store/address contract

### 目标行为

优化后应出现：

- `LOAD_ARRAY` 周期明显下降
- `LOAD_ARRAY` 不再成为 current case 下的显著串行大段
- 在保持结果一致的前提下提高装载效率

### 预期结果

第一层收益：

- `LOAD_ARRAY` 周期下降

第二层收益：

- total cycles 比“只做 preload”更明显下降

第三层收益：

- full-cluster 并行收益更容易体现在端到端延迟上

---

## 3.4 当前不作为主优化对象的部分

以下内容当前不作为 first-pass 主优化对象：

### `COLLECT / STORE`

原因：

- 它们确实有开销
- 但当前更优先解决的是 “喂 cluster” 和 “装 weight”
- 同时它们受 Workstream B contract 约束更强

要求：

- 当前只允许“不能明显恶化”
- 不作为 first-pass 主攻方向

### AXI 结构重构

当前明确不做：

- 双 AXI read master
- inter-cluster reduce
- `npu_top` 主 FSM 大重构

---

## 4. 验收口径

本次优化采用三层验收：

## 4.1 主验收

- total cycles 下降
- correctness 不回退

## 4.2 次验收

至少满足以下之一：

- `CIN_LOAD_WGT` 明显下降
- `LOAD_ARRAY` 明显下降

更理想情况：

- 二者都下降

## 4.3 机制验收

必须出现可引用的重叠或 bank-level 证据：

- `act_wgt_overlap` 或等价 preload overlap 从 `0` 变成非零
- 或者明确证明：
  - 当前 compute 正在消费一个 bank
  - 下一轮 weight 已经在另一个 bank 进入 ready/loading

## 4.4 回归护栏

优化前后至少比较以下指标：

```text
total cycles
CIN_LOAD_WGT
LOAD_ARRAY
COMPUTE
COLLECT
STORE
act_dma_busy
wgt_dma_busy
act_wgt_overlap
write_dma_busy
cluster_util
```

并要求：

- `COLLECT / STORE` 不明显恶化
- `cluster_util` 不下降
- current correctness 护栏继续通过

---

## 5. 验证与回归要求

本次优化前后至少复跑：

### Workstream A 护栏

- `tb_cluster_route_aggregate_semantics`
- `tb_npu_top_route_observe`
- `tb_npu_top_layer_event_probe`
- 如需要可加 `tb_npu_top_stage_event_probe`

### Workstream B 护栏

若仓库已有 store-path / packing 定向验证入口，则一并运行。  
没有的话，至少保证：

- output layout 不变
- last-beat `WSTRB` 语义不变
- `dma_axi_writer` 行为不变

---

## 6. 不做事项

本工单明确不做：

- inter-cluster reduce
- 双 AXI read master
- `npu_top` 大规模状态机重写
- LeNet 地址图调整
- requant 算法调整
- route / aggregate 语义改造
- `dma_axi_writer` 重写
- task checker 的 `64B` 对齐放宽
- shared memory / layer memory map 重排

---

## 7. 预期输出结论

如果本方案执行成功，最终应能稳定表述为：

1. 当前 6-cluster 路径 correctness 保持成立
2. full-cluster 速度优化不是靠改数据流语义，而是靠改善供数/装载重叠
3. weight-side preload 已真实发生
4. `LOAD_ARRAY` 已被打薄
5. full-cluster 在 layer-like runtime probe 上已出现可测的总周期收益
6. Workstream B 的 memory/store contract 未被破坏

若 first-pass 收益仍有限，则下一步才考虑：

- second-pass `COLLECT / STORE` 优化
- 更深的 read scheduling
- 更大带宽结构

而不是直接跳到大架构重构。

