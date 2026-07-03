# NPU RTL TODO List 与问题跟踪

> 项目：Project_npu  
> 范围：当前聚焦 `rtl/npu`，尤其是 `npu_top` 控制、存储、DMA、single-cluster 数据流与输出聚合逻辑。  
> 说明：本文档不再只是问题收集表，而是当前 `rtl/npu` 后续整改的**决策基线**。文中每条 TODO 都已给出是否执行、何时执行、是否允许改 RTL 的明确结论。

---

## 1. 总览

当前 NPU RTL 已经具备以下基本结构：

```text
CPU / AXI-Lite
    ↓
npu_ctrl
    ↓
task_checker
    ↓
npu_top 主 FSM
    ↓
DMA read / local buffer / compute_core / output_arbiter / DMA write
```

当前设计特点：

- 控制模式：单任务寄存器触发模型。
- CPU 配置方式：CPU 写完一组 task 寄存器后写 `CTRL.start`，NPU 执行完后 CPU 再配置下一条任务。
- DMA 数据通路：NPU AXI4 DMA 当前为 256-bit，即 32B/beat。
- 控制通路：AXI-Lite 控制寄存器仍为 32-bit。
- 计算核心：6 个 `pe_cluster` 并列组成 `compute_core`。
- 多 cluster 供数方式：activation 广播，weight 按 output column / output channel group 切分。
- cluster 间通信：当前没有 cluster-to-cluster NoC / mesh / psum forwarding，而是集中式供数与输出聚合。

### 1.1 已收口的执行结论

当前 11 条 TODO 已正式收口为四类：

1. 立即进入后续工单：
   - `TODO-10/11/6/5`：合并为 multi-cluster dataflow / bandwidth analysis
   - `TODO-7/9`：合并为 shared memory contract + store-path verification
   - `TODO-1`：保留为后续控制面增强项
2. 保留讨论、不执行当前 RTL 主变更：
   - `TODO-3`：地址对齐策略继续维持 `64B`
   - `TODO-8`：并入性能归因，不单独重构
   - `TODO-4`：task queue / descriptor / shadow config 当前不做
3. 低优先级顺手清理：
   - `TODO-2`：历史错误码清理
4. 当前明确不做的事：
   - 不因为“主流 NPU 有 reduce”而立即引入 inter-cluster reduce
   - 不直接改成双 AXI read master
   - 不直接重写 `npu_top` 主 FSM

---

## 2. TODO 总表

| 编号 | 事项 | 优先级 | 类型 | 状态 | 备注 |
|---|---|---:|---|---|---|
| TODO-1 | 将 `CLUSTER_MODE / CLUSTER_MASK` 从静态 parameter 改为 AXI-Lite 可配置寄存器 | P1 | 功能增强 | 已完成 | Workstream C 已支持 runtime AXI-Lite 配置，parameter 保留为 reset default |
| TODO-2 | 清理 `task_checker.v` 中历史错误码 `ERR_FC_NOT_SUPPORTED` | P2 | 代码清理 | 已完成 | RTL 已移除未使用定义；文档保留 `0x0A` 数值空洞说明 |
| TODO-3 | 讨论 NPU task 地址对齐策略 | P1 | 架构讨论 | 保留讨论，不改 RTL | 当前继续维持 `64B` 对齐，后续若出现地址压力再单独决策是否放宽到 `32B` |
| TODO-4 | 讨论是否增加 task queue / descriptor FIFO / shadow config | P2 / P1.5 | 架构增强 | 当前不执行 | 明显扩 scope，会改变控制模型；不作为当前交付线目标 |
| TODO-5 | 明确 activation DMA 和 weight DMA 共享 AXI read channel 的性能影响 | P1 | 存储/带宽分析 | 已完成分析 | Workstream A 已确认 read channel 严格共享，是当前性能主瓶颈之一 |
| TODO-6 | 评估 256-bit buffer 到 single-cluster 阵列的供数能力 | P1 | 存储/性能验证 | 已完成分析 | Workstream A 已确认 256-bit buffer/feed path 功能自洽，但不足以喂满 single-cluster 理论峰值 |
| TODO-7 | 检查 `acc_buffer` 到 DMA writer 的 32-bit → 256-bit packing 逻辑 | P1 | 存储/正确性验证 | 已完成验证 | Workstream B 已补 `tb_store_pack_path`，覆盖 Conv/FC/Requant packing 与 partial-beat `WSTRB` |
| TODO-8 | 确认 `npu_buffer` 双 bank 是否真正实现 load/compute overlap | P2 | 存储/调度分析 | 已完成分析 | 结构支持 ping-pong，但当前 `npu_top` FSM 对 act/wgt overlap 利用不足 |
| TODO-9 | 梳理 shared memory 地址映射和 layer memory map | P1 | 存储/文档 | 已完成收口 | Workstream B 已固化 shared memory / layer memory map / store layout 口径 |
| TODO-10 | 明确 single-cluster 输出聚合语义，重点检查 `output_arbiter` 的 `AGGREGATE_MODE` | P1 | 计算/数据流正确性 | 已完成分析 | 定向测试确认 `AGGREGATE_MODE=1` 在互斥全局输出列路由下安全 |
| TODO-11 | 深挖 buffer 到 single-cluster 的供数路径 | P1 | 存储/计算数据流 | 已完成分析 | activation broadcast / weight split / global column route / aggregate 数据流自洽 |

### 2.1 后续工单分组

为避免 11 条 TODO 被碎片化推进，后续统一拆成 3 个正式工单：

#### Workstream A：NPU Multi-Cluster Dataflow and Bandwidth Analysis

覆盖：

```text
TODO-10
TODO-11
TODO-6
TODO-5
TODO-8
```

核心目标：

```text
1. 证明 AGGREGATE_MODE=1 是否建立在互斥全局输出列之上；
2. 证明 routed output 是否对非负责列清零；
3. 归因 full-cluster 不明显提速的真实瓶颈；
4. 判断双 bank overlap 是真实发生还是结构存在但利用不足。
```

当前明确不做：

```text
1. 不直接上 inter-cluster reduce；
2. 不直接改成双 AXI read master；
3. 不直接重写 npu_top 主 FSM。
```

#### Workstream A 当前分析结论

状态：route/aggregate correctness 可按 Workstream A 范围关闭；runtime bottleneck evidence 已增强；尚未形成完整 LeNet-wide stage attribution。当前不进入架构重构。

验证证据：

```text
tb/unit/tb_cluster_route_aggregate_semantics.v

证据边界：
公式级验证，不实例化 `npu_top`；用于验证 cluster ownership / overlap / routed OR merge 规则。

覆盖：
1. single mode：16 active output columns；
2. dual mode：50 active output columns；
3. full mode：64 active output columns；
4. masked-full mode：50 active output columns，mask=6'b10_1011。

运行：
iverilog -g2012 -I rtl/npu -o /tmp/tb_cluster_route_aggregate_semantics.vvp \
  rtl/npu/cluster_scheduler.v rtl/npu/output_arbiter.v \
  tb/unit/tb_cluster_route_aggregate_semantics.v
vvp /tmp/tb_cluster_route_aggregate_semantics.vvp

结果：
tb_cluster_route_aggregate_semantics PASS

tb/unit/tb_npu_top_route_observe.v

证据边界：
直接实例化 `npu_top` 并观测其 route 组合逻辑；通过 force 注入 `cluster_sum_out_all_flat` 和 drain 状态，
因此证明的是 `npu_top` route / aggregate 组合语义，不是 upstream compute-to-route-to-aggregate 端到端全证明。

覆盖：
1. 直接实例化 npu_top；
2. hierarchical force npu_top 进入 CP_DRAIN route 组合路径；
3. 直接观测 cluster_routed_sum_out_all_flat；
4. 直接观测 cluster_arb_valid；
5. 直接观测 array_sum_out；
6. mask_50cols case：mode=2, mask=6'b10_1011, active_cols=50；
7. route bus width = 64 global output columns。

说明：
该 probe 使用 `TILE_ROWS=4, TILE_COLS=16` 的 `npu_top` 实例以控制仿真展开成本；
它保留 64-column route bus，验证的是 `npu_top` 本体 route 组合逻辑。

结果：
tb_npu_top_route_observe PASS

tb/unit/tb_npu_top_stage_event_probe.v

证据边界：
运行级 tiny Conv smoke，用于证明 per-stage / DMA overlap 统计方法可工作；不是 layer-like workload。

覆盖：
1. 运行一个 top 级小 Conv smoke；
2. hierarchical 统计 npu_top fsm_state / comp_sub_state；
3. 统计 act_dma_busy / wgt_dma_busy / dma_wr_busy；
4. 统计 act/wgt DMA overlap。

结果：
STAGE_EVENT_RESULT total=134 load_act=6 cin_load_wgt=6 load_array=27 wgt_ld=1 compute=69 drain=13 collect=2 store=9 act_dma_busy=4 wgt_dma_busy=4 act_wgt_overlap=0 write_dma_busy=6 output=50 status=PASS

tb/unit/tb_npu_top_layer_event_probe.v

证据边界：
layer-like runtime evidence，覆盖更接近 LeNet Conv layer 的单层 workload；
但它仍不是完整 LeNet-wide stage breakdown。

覆盖：
1. 运行一个更接近 LeNet Conv layer 的 top 级 Conv-like workload；
2. shape=8x8x2 -> 4x4x8；
3. 覆盖多 spatial window、多 input channel、多 output column；
4. hierarchical 统计 npu_top fsm_state / comp_sub_state；
5. 统计 route_valid / collect_events / DMA busy / act-wgt overlap。

结果：
LAYER_EVENT_RESULT shape=8x8x2_to_4x4x8 total=4119 load_act=9 cin_load_wgt=24 load_array=416 wgt_ld=2 compute=3370 drain=1664 collect=512 store=278 route_valid=256 collect_events=256 act_dma_busy=7 wgt_dma_busy=20 act_wgt_overlap=0 write_dma_busy=275 first_last_output=100 status=PASS
```

Correctness 结论：

```text
1. AGGREGATE_MODE=1 当前不是 arithmetic reduce，而是 routed global-column bitfield OR merge；
2. npu_top 中 cluster_rank/base/end 将 enabled cluster 映射到互斥 global output column 区间；
3. cluster_routed_sum_out_all_flat 每个组合周期先整体清零，再只写当前 cluster 负责的 global column；
4. single / dual / full / masked-full 公式级覆盖下未发现 global column overlap / hole；
5. npu_top 本体 mask_50cols route observe 下，cluster_arb_valid 只在合法 route column 拉高；
6. npu_top 本体 route observe 已扩到 50 active output columns / 64-column route bus；
7. npu_top 本体 route observe 下，disabled cluster 不会通过 routed output 注入 stale data；
8. layer-like event probe 在真实 top task 运行中观测到 route_valid=256、collect_events=256。
```

Performance / bottleneck 结论：

```text
1. activation DMA 与 weight DMA 在 npu_top 中共享单一 AXI read channel：
   read_sel_act = act_dma_busy；
   act busy 时 weight ARREADY 被拉低，二者不能并行取数。

2. 当前 Conv 路径的主要阶段是串行组织：
   LOAD_ACT -> CIN_LOAD_WGT -> LOAD_ARRAY -> WGT_LD -> COMPUTE -> COLLECT/STORE。
   weight DMA 完成后才进入 LOAD_ARRAY，LOAD_ARRAY 再逐 byte / beat 抽取到 wgt_load_reg。

3. 运行级 stage probe 显示 act_dma_busy=4、wgt_dma_busy=4、act_wgt_overlap=0，
   shared read channel 的串行占用不是纯静态推断。

4. tiny stage probe 显示 LOAD_ARRAY=27、COMPUTE=69、COLLECT=2、STORE=9，
   load/collect/store 阶段在小 Conv 中已经是可观测的非零阶段成本。

5. layer-like event probe 显示 shape=8x8x2 -> 4x4x8 时：
   LOAD_ARRAY=416、COMPUTE=3370、DRAIN=1664、COLLECT=512、STORE=278、
   route_valid=256、act_dma_busy=7、wgt_dma_busy=20、act_wgt_overlap=0。

6. 256-bit buffer/feed path 功能自洽，但它是本地解包与阵列装载通道，不等于能持续喂满 single-cluster 理论峰值。

7. npu_buffer 双 bank 结构存在，act buffer 在 block 间 ping-pong；
   但当前 FSM 先 load 完 activation 再 compute，weight buffer 的 comp_bank_sel 固定为 0，
   实际 weight load/compute overlap 利用不足。

8. collect/store 仍是串行尾部阶段：CP_COLLECT 按列写 acc_buffer，FSM_STORE 再按 8x32-bit 打包为 256-bit beat。
```

建议动作：

```text
结论选择：当前 route/aggregate correctness 可以按 Workstream A 范围关闭；
performance attribution 已从 preliminary 静态判断增强为 layer-like runtime evidence，
但仍不是完整 LeNet-wide 阶段分解。是否进入结构优化仍需先决定优化目标和验收指标，不建议直接大改架构。

不建议立即做：
1. inter-cluster reduce；
2. 双 AXI read master；
3. npu_top 主 FSM 大重写。

优先后续方向：
1. 若继续优化，先把 stage event probe 升级成可选 debug counter 或 trace；
2. 若要形成优化前基线，再在真实 LeNet 层级上量化 LOAD_ARRAY / COMPUTE / COLLECT / STORE 占比；
3. 若证据继续指向 read/load 串行瓶颈，再评估 read scheduler 或 weight prefetch 的小范围优化。
```

#### Workstream B：Shared Memory Contract and Store-Path Verification

覆盖：

```text
TODO-7
TODO-9
TODO-3
```

核心目标：

```text
1. 固化 layer memory map；
2. 验证 acc_buffer → DMA writer packing；
3. 统一 top / subsystem / script / doc 的地址与 layout 口径。
```

当前明确结论：

```text
状态：已完成。

1. shared memory contract 固化为 1 MB = 32768 x 256-bit beat；
2. CPU 侧按 32-bit AXI-Lite word lane 访问同一物理 RAM；
3. NPU DMA 侧按 256-bit AXI4 INCR burst 访问；
4. LeNet layer memory map 继续采用 docs/soc_fs.md 中 6.3 地址图；
5. acc_buffer -> DMA writer store path 已补定向验证；
6. 地址对齐策略继续维持 64B，不在当前阶段放宽到 32B。
```

验证证据：

```text
tb/unit/tb_store_pack_path.v

证据边界：
直接实例化 npu_top，force 到 FSM_STORE，并直接填充 u_acc_buffer；
验证真实 npu_top store_pack_state / store_pack_lane / store_pack_data_next 与真实 dma_axi_writer 输出，
不是在 testbench 中单独复刻写回路径。

覆盖：
1. Conv-like output：40B = 10 x 32-bit word，跨 2 个 256-bit beat；
2. FC-like output：20B = 5 x 32-bit word，单 beat partial；
3. Requant-like output：7B，覆盖非 4B 整数倍 tail；
4. 32-bit word lane 顺序：word i -> beat lane (i mod 8)，lane0 在低 32-bit；
5. last-beat WSTRB：由有效 byte 数产生低位连续 byte mask；
6. WREADY stall 下 WDATA/WSTRB/WLAST 保持稳定。

运行：
vcs -full64 -sverilog -timescale=1ns/1ps \
  +incdir+rtl/npu +incdir+rtl/soc +incdir+rtl/bus \
  rtl/soc/axi4_ram.v rtl/soc/shared_ram.v rtl/bus/axi_interconnect.v \
  rtl/npu/*.v rtl/cpu/picorv32/picorv32.v rtl/soc/top.v \
  tb/unit/tb_store_pack_path.v

结果：
STORE_PACK_CASE case=requant_7_bytes mode=3 bytes=7 words=2 beats=1 status=PASS
STORE_PACK_CASE case=fc_5_words mode=1 bytes=20 words=5 beats=1 status=PASS
STORE_PACK_CASE case=conv_10_words mode=0 bytes=40 words=10 beats=2 status=PASS
PASS tb_store_pack_path
```

#### Workstream C：Runtime Cluster Mode AXI-Lite Control

覆盖：

```text
TODO-1
```

核心目标：

```text
1. 把 cluster mode / mask 从 compile-time 选择升级为运行时 AXI-Lite 控制；
2. 保持当前 parameter 作为 reset default；
3. 不改变现有 task 启动模型。
```

当前明确结论：

```text
状态：已完成。

1. 新增 CLUSTER_MODE / CLUSTER_MASK AXI-Lite 寄存器；
2. parameter NPU_CLUSTER_MODE / NPU_CLUSTER_MASK_REQ 继续作为 reset default；
3. npu_ctrl 保存 runtime config，npu_top 将 runtime config 接入 cluster_scheduler；
4. PERF_CLUSTER_CFG 继续提供 `{cluster_mode, effective_cluster_enable}` 可观测状态；
5. 配置寄存器仍遵循既有 busy 写保护；
6. 当前仍是单任务寄存器触发模型，不引入 queue / descriptor / shadow config。
```

新增寄存器：

```text
0x88 CLUSTER_MODE [1:0]
  0 = single
  1 = dual
  2 = full
  3 = mask/full-mask semantics

0x8C CLUSTER_MASK [5:0]
  enabled cluster request mask
```

验证证据：

```text
tb/unit/tb_npu_runtime_cluster_config.v

覆盖：
1. reset default：parameter mode=dual, mask=000011；
2. runtime single：mode=0, mask=111111 -> enable=000001；
3. runtime dual：mode=1, mask=111111 -> enable=000011；
4. runtime full：mode=2, mask=111111 -> enable=111111；
5. runtime mask：mode=3, mask=101011 -> enable=101011；
6. AXI-Lite write/readback 一致；
7. PERF_CLUSTER_CFG 与 runtime scheduler effective enable 一致。

结果：
PASS tb_npu_runtime_cluster_config
```

---

## 3. TODO 详细说明

### TODO-1：将 `CLUSTER_MODE / CLUSTER_MASK` 改为 AXI-Lite 可配置寄存器

#### 当前状态

当前 `CLUSTER_MODE` 和 `CLUSTER_MASK_REQ` 已升级为 AXI-Lite runtime config。
Verilog parameter 仍保留，但语义变为 reset default：

```text
top.v:
  NPU_CLUSTER_MODE
  NPU_CLUSTER_MASK_REQ

npu_top.v:
  CLUSTER_MODE
  CLUSTER_MASK_REQ
```

reset 后，软件可通过 `CLUSTER_MODE / CLUSTER_MASK` 寄存器覆盖默认值。
`npu_top` 将 runtime config 传入 `cluster_scheduler`，由 `cluster_scheduler` 生成：

```text
cluster_enable[5:0]
cluster_count
schedule_valid
```

#### 已实现寄存器

```text
0x88 CLUSTER_MODE
0x8C CLUSTER_MASK
```

使 CPU 可以运行时选择：

```text
single mode
dual mode
full mode
mask mode
```

#### 当前不做

```text
1. 不引入 task queue；
2. 不引入 descriptor FIFO；
3. 不引入 shadow config / 多任务预取；
4. 不改变 CTRL.start 单任务触发模型。
```

#### 涉及文件

```text
rtl/npu/npu_ctrl.v
rtl/npu/npu_top.v
rtl/soc/top.v
tb/integration/tb_top_cluster_modes.v
相关寄存器文档
```

---

### TODO-2：清理 `ERR_FC_NOT_SUPPORTED`

#### 当前状态

历史上 `task_checker.v` 曾保留如下错误码：

```verilog
localparam ERR_FC_NOT_SUPPORTED = 8'h0A;
```

但当前 `task_type = 2'd1` 已经是合法 FC 任务，因此该定义已无功能用途。

#### 问题

该错误码容易让评审或新成员误以为当前 RTL 不支持 FC。

#### 当前结论

本项已完成：

```text
1. RTL 中移除未使用的 ERR_FC_NOT_SUPPORTED 定义；
2. 文档保留 0x0A 数值空洞说明，避免和既有调试记录冲突。
```

---

### TODO-3：讨论 NPU task 地址对齐策略

#### 当前状态

当前 NPU DMA 数据通路为：

```text
AXI_DMA_DATA_W = 256-bit
1 beat = 32B
```

但 `task_checker` 要求 task 地址 64B 对齐：

```text
input_addr[5:0] == 0
output_addr[5:0] == 0
Conv / FC 的 weight_addr[5:0] == 0
```

#### 问题

64B 对齐比当前 256-bit DMA beat 的自然对齐要求更严格。

#### 需要讨论的方案

| 方案 | 优点 | 缺点 |
|---|---|---|
| 保持 64B 对齐 | burst 规整，利于未来扩展 | memory map 有 padding，软件地址分配更严格 |
| 放宽到 32B 对齐 | 与当前 256-bit DMA beat 匹配 | 后续更宽总线时可能需要再改 |
| 参数化对齐 | 最灵活 | `task_checker`、文档、测试都要同步复杂化 |

#### 当前结论

```text
继续维持 64B 对齐，不改 RTL。

Workstream B 已将该结论固化为当前 shared memory contract：
1. 256-bit DMA beat 的自然对齐是 32B；
2. task_checker 对 input/output/weight base address 继续要求 64B；
3. 该要求是当前项目地址分配与 burst/layout contract，不是当前 bug；
4. 放宽到 32B 会影响 task_checker、脚本、地址图和验证资产，必须单独立项。
```

只有当下面场景出现时才重新决策：

```text
1. 新模型地址空间压力明显增大；
2. shared memory padding 成为真实问题；
3. 必须放宽到 32B 才能推进新功能或新数据集。
```

---

### TODO-4：讨论 task queue / descriptor FIFO / shadow config

#### 当前状态

当前 `npu_ctrl` 是单任务寄存器触发模型：

```text
CPU 配置一组寄存器
CPU 写 CTRL.start
NPU 执行当前任务
CPU 等 done/error
CPU 再配置下一条任务
```

当前不支持：

```text
busy 期间预配置下一条任务
内部 task queue
descriptor FIFO
shadow config
自动执行完整网络
```

#### 当前需求判断

用户当前明确倾向保留单任务模式，因此该项不进入当前执行范围。

#### 后续增强方向

如需提升软件效率，可考虑：

```text
1. shadow config：最多缓存一条 pending task；
2. command FIFO：缓存多条 task；
3. descriptor list：CPU 在 shared memory 中写 descriptor 列表，NPU 自动读取执行。
```

#### 当前结论

```text
当前不执行，不进入当前工单线。
```

---

### TODO-5：明确 activation DMA 和 weight DMA 共享 AXI read channel 的性能影响

#### 当前状态

当前存在两套 read path：

```text
act_read_path
weight_read_path
```

但对外 AXI read channel 是共享的。`npu_top` 中通过选择逻辑决定当前使用 activation 读还是 weight 读。

#### 问题

activation 和 weight 不能真正并行从 shared RAM 读取。

#### 影响

这对功能正确性不是问题，但会影响：

```text
DMA 搬运时间
计算前等待时间
带宽利用率
single-cluster 实际吞吐
```

#### Workstream A 结论

本项已随 Workstream A 补强到第三轮证据：

```text
1. act_read_path / weight_read_path 逻辑上分离；
2. 对外 AXI read channel 在 npu_top 中通过 read_sel_act 复用；
3. read_sel_act = act_dma_busy，activation busy 时 weight read 被阻塞；
4. 当前不能宣称 activation/weight 能并行从 shared RAM 读取；
5. tiny stage event probe 中 act_dma_busy=4、wgt_dma_busy=4、act_wgt_overlap=0；
6. layer-like event probe 中 act_dma_busy=7、wgt_dma_busy=20、act_wgt_overlap=0；
7. 这是 full-cluster 网络级不明显提速的主要瓶颈之一。
```

#### 后续可选优化前检查点

```text
1. 增加 act/wgt DMA overlap cycle counter；
2. 量化 act/wgt read wait cycle；
3. 若证据仍指向 read 串行瓶颈，再评估 read scheduler 或小范围 prefetch。
```

---

### TODO-6：评估 256-bit buffer 到 single-cluster 阵列的供数能力

#### 当前状态

当前 DMA 和 activation/weight buffer 是：

```text
BUF_DATA_W = 256-bit
AXI_DMA_DATA_W = 256-bit
```

但 single-cluster 满速计算的理论供数需求显著高于 256-bit/cycle。

#### 问题

不能直接宣称：

```text
256-bit DMA / buffer 能喂满 single-cluster 阵列。
```

#### Workstream A 结论

本项已随 Workstream A 补强到第三轮证据：

```text
1. 256-bit DMA / buffer 语义在 HB1/HB2 和 AXI 回归中成立；
2. buffer 到阵列的本地 feed path 功能自洽；
3. 但 LOAD_ARRAY 仍按 byte / beat 将 weight 装入 wgt_load_reg；
4. tiny stage event probe 中 LOAD_ARRAY=27、COMPUTE=69、COLLECT=2、STORE=9；
5. layer-like event probe 中 LOAD_ARRAY=416、COMPUTE=3370、COLLECT=512、STORE=278；
6. 256-bit buffer 宽度不能等同于 single-cluster 满速供数；
7. full-cluster 性能提升受 read/load/collect/store 串行阶段限制。
```

#### 后续若做优化需补的测量

```text
1. 每层 cycle count；
2. MAC count；
3. array utilization；
4. cluster_active / cluster_stall；
5. read/write beat；
6. DMA active cycle；
7. buffer stall。
```

---

### TODO-7：检查 `acc_buffer` 到 DMA writer 的 32-bit → 256-bit packing 逻辑

#### 当前状态

`acc_buffer` 以 32-bit 数据组织，而 DMA writer 为 256-bit。

因此写回 shared memory 前需要将多个 32-bit word 打包成 256-bit beat：

```text
8 × 32-bit word → 1 × 256-bit AXI beat
```

#### 当前结论

本项已由 Workstream B 完成定向 correctness verification，不改写回路径。

正式 store-path contract：

```text
1. acc_buffer 以 32-bit word 为单位保存写回数据；
2. FSM_STORE 按递增 acc_buffer index 读取 word；
3. store_pack_lane = 0..7 对应 256-bit beat 的低到高 32-bit lane；
4. store_words_active = ceil(store_bytes_active / 4)；
5. 每 8 个 32-bit word 形成一个 256-bit beat；
6. 最后一拍不满 256-bit 时，dma_axi_writer 根据 byte_count 生成低位连续 WSTRB；
7. Requant 输出允许 byte_count 不是 4 的整数倍，最后一个 32-bit packed word 中的无效 byte 由 WSTRB 屏蔽；
8. Conv 使用 blk_out_addr / blk_out_bytes；
9. FC 使用 fc_store_addr / fc_store_bytes，按 output tile 写回；
10. Requant 使用 rq_store_addr / rq_store_bytes。
```

验证入口：

```text
tb/unit/tb_store_pack_path.v
```

验证结果：

```text
Conv-like 40B：10 x 32-bit word -> 2 x 256-bit beat，tail WSTRB = 0x000000ff
FC-like 20B：5 x 32-bit word -> 1 x 256-bit beat，WSTRB = 0x000fffff
Requant-like 7B：2 x 32-bit packed word -> 1 x 256-bit beat，WSTRB = 0x0000007f

PASS tb_store_pack_path
```

#### 风险点

```text
1. store_pack_lane 顺序已由定向测试覆盖；
2. 最后一个不满 256-bit beat 的 WSTRB 已由定向测试覆盖；
3. Conv / FC / Requant 三类 store source 已由定向测试覆盖；
4. output layout 仍需依赖 top/subsystem LeNet replay 与 golden 对拍持续守护。
```

---

### TODO-8：确认 `npu_buffer` 双 bank 是否真正实现 load/compute overlap

#### 当前状态

`npu_buffer` 具有双 bank 和状态机：

```text
EMPTY
LOADING
READY
USING
```

结构上支持 ping-pong buffer。

#### Workstream A 结论

本项已随 Workstream A 补强到第三轮证据：

```text
1. npu_buffer 结构上支持 EMPTY / LOADING / READY / USING 双 bank ping-pong；
2. act_buffer 在 block 间使用 bank 切换；
3. 当前 npu_top 仍是 activation load 完成后才进入 compute；
4. weight buffer 的 comp_bank_sel 固定为 1'b0，wgt_rd_bank 跟随 wgt_load_bank；
5. 当前双 bank overlap 更接近结构能力，实际 load/compute overlap 利用不足。
```

#### 后续可选优化前检查点

```text
1. 增加 bank state / load_active / comp_active trace；
2. 量化 act/wgt buffer ready-to-use gap；
3. 若要优化，优先评估 weight prefetch / bank role split，而不是先改主 FSM。
```

---

### TODO-9：梳理 shared memory 地址映射和 layer memory map

#### 当前状态

shared memory 当前是 unified memory：

```text
CPU 32-bit port
NPU 256-bit AXI4 DMA port
同一份物理 RAM
```

需要明确所有层的数据在 shared memory 中如何排布。

#### 当前结论

本项已由 Workstream B 收口为可交付引用的 shared memory contract，不动 RTL。

正式 shared memory contract：

```text
1. shared memory 总容量：1 MB；
2. 物理组织：32768 x 256-bit beat；
3. CPU 访问：32-bit AXI-Lite word；
4. NPU DMA 访问：256-bit AXI4 INCR burst；
5. 地址拆分：beat_addr=addr[19:5], word_in_beat=addr[4:2], byte_in_word=addr[1:0]；
6. NPU DMA beat 自然对齐：32B；
7. NPU task base address contract：64B 对齐；
8. LeNet 默认 layer memory map：以 docs/soc_fs.md 6.3 为正式引用。
```

#### 需要梳理

```text
Input image                      0x0000_0100  INT8
Conv1 weights                    0x0000_1000  INT8
Conv1 output / Pool1 input        0x0000_4000  INT32 feature map
Pool1 output / Conv2 input        0x0001_8000  INT32/INT8 handoff region
Conv2 weights                    0x0002_0000  INT8
Conv2 output / Pool2 input        0x0006_0000  INT32 feature map
Pool2 output / FC1 input          0x0008_0000  INT32/INT8 handoff region
FC1 weights                      0x0009_0000  INT8
FC1 output / FC2 input            0x000F_2000  INT32/INT8 handoff region
FC2 weights                      0x000F_3000  INT8
Final logits                     0x000F_5000  INT32 logits
```

#### 需要统一

```text
1. 地址继续要求 64B 对齐；
2. feature map layout 继续使用 HWC；
3. Conv weight layout 继续使用 [in_c][k_h][k_w][out_c]；
4. FC weight layout 继续使用 [out_neuron][in_neuron]；
5. FC flatten 继续沿用 HWC 展平；
6. Conv/FC INT32 输出按 32-bit word 写回；
7. Requant INT8 输出按 4-byte packed word 经同一 store path 写回，tail byte 由 WSTRB 屏蔽；
8. output_bytes 继续由 task_checker 做非零、范围和 Requant 关系检查。
```

---

### TODO-10：明确 single-cluster 输出聚合语义

#### 当前状态

`output_arbiter` 存在两类行为：

```text
AGGREGATE_MODE = 0:
  round-robin 选择一个 cluster 输出

AGGREGATE_MODE = 1:
  对多个 cluster 的输出做按位 OR 聚合
```

当前 `npu_top` 在送入 `output_arbiter` 前，已经做了一层输出列重路由：

```text
cluster local output column
  ↓
global output column
  ↓
cluster_routed_sum_out_all_flat
```

#### Workstream A 结论

本项已随 Workstream A 补强到第三轮证据：

```text
1. AGGREGATE_MODE=1 是 OR merge，不是 partial-sum reduce；
2. npu_top 在进入 output_arbiter 前将 local output column 重路由到 global output column；
3. cluster_routed_sum_out_all_flat 默认清零；
4. single / dual / full / mask 定向测试未发现 overlap / hole；
5. npu_top route observe 直接观测 mask_50cols 下 routed bus / cluster_arb_valid / array_sum_out；
6. npu_top route observe 已扩到 50 active output columns / 64-column route bus；
7. layer-like event probe 在运行中观测到 route_valid=256；
8. 因此当前 AGGREGATE_MODE=1 在“互斥全局输出列拼接”语义下安全。
```

验证入口：

```text
tb/unit/tb_cluster_route_aggregate_semantics.v
tb/unit/tb_npu_top_route_observe.v
tb/unit/tb_npu_top_layer_event_probe.v
```

---

### TODO-11：深挖 buffer 到 single-cluster 的供数路径

#### 当前阶段结论

经过对 `npu_top` 供数路径的初步分析，当前可总结为：

```text
1. DMA 从 shared RAM 搬 input / weight 到 act_buffer / wgt_buffer；
2. npu_top 从 buffer 读取 256-bit beat；
3. activation 通过 hb_beat_byte 解包；
4. Conv 模式下 activation 经 conv_frontend 形成 5×5 window；
5. array_act_in 被广播给所有启用 cluster；
6. weight 从 wgt_load_reg 中按 output column group 切分给不同 cluster；
7. sum_in 当前为 0，不做跨 cluster partial-sum reduction；
8. 6 个 cluster 并行计算不同 output column / output channel group；
9. 输出先按 global column 重路由，再送入 output_arbiter。
```

#### 当前供数模式

```text
activation：广播
weight：按 output column / output channel group 切分
sum_in：全 0
输出：按 global column 路由后聚合
```

#### Workstream A 结论

本项已随 Workstream A 补强到第三轮证据，当前数据流语义如下：

```text
activation：从 act_buffer 解包后广播给所有 enabled cluster；
weight：从 wgt_load_reg 按 enabled-cluster rank 切分 output column group；
sum_in：全 0，不做跨 cluster reduce；
output：local column -> global column route -> AGGREGATE_MODE OR merge；
disabled cluster：weight/routed output 默认清零，不参与有效输出。
```

#### 后续若做优化需继续观测的具体信号

```text
act_rd_addr
wgt_rd_addr
act_feed_beat_addr
wgt_mac_addr
fc_act_beat_addr
fc_weight_beat_addr
array_act_in
wgt_load_reg
cluster_act_all_flat
cluster_weight_all_flat
cluster_sum_all_flat
cluster_routed_sum_out_all_flat
cluster_arb_sum_out
```

#### 已回答的问题

```text
1. Conv / FC 统一使用 active_cols 和 rank/base/end 做 output column group 切分；
2. activation 当前始终 broadcast；
3. weight 切分覆盖 active output columns 且不重复；
4. cluster_enable 关闭时，weight/routed output 默认清零；
5. full / dual / mask 模式下输出列映射在定向测试中通过；
6. npu_top 本体 route observe 已直接验证 mask_50cols routed bus 和 cluster_arb_valid；
7. layer-like event probe 覆盖 8x8x2 -> 4x4x8 Conv-like workload；
8. AGGREGATE_MODE=1 明确依赖输出列互斥；
9. 实际利用率受共享 read channel、LOAD_ARRAY 和 collect/store 串行阶段限制。
```

---

## 4. 当前优先级排序

### P1 优先执行项

```text
TODO-10 / TODO-11 / TODO-6 / TODO-5：合并成 multi-cluster dataflow / bandwidth analysis
TODO-7 / TODO-9：合并成 shared memory contract + store-path verification
TODO-1：cluster mode / mask 运行时可配置（已完成）
```

### 保留讨论，不进入当前 RTL 主变更

```text
TODO-3：地址对齐策略（当前保持 64B）
TODO-8：双 bank overlap 深入确认（并入性能归因）
TODO-4：task queue / descriptor FIFO / shadow config
```

### 低优先级顺手清理

```text
TODO-2：历史错误码清理（已完成）
```

---

## 5. 当前最关键风险

当前最关键的三个问题是：

### 5.1 多 cluster 输出是否正确聚合

对应：

```text
TODO-10
TODO-11
```

原因：这直接关系到 single-cluster 是否真的输出正确的并行计算结果。

---

### 5.2 buffer 供数是否支撑实际吞吐

对应：

```text
TODO-5
TODO-6
TODO-8
TODO-11
```

原因：DMA/buffer 是 256-bit，但 single-cluster 满速供数需求更高，需要通过性能计数和实际网络测试证明。

---

### 5.3 地址图和数据 layout 是否稳定

对应：

```text
TODO-3
TODO-7
TODO-9
```

原因：地址对齐、INT8/INT32 layout、写回 packing 都会直接影响 LeNet 端到端结果正确性。

---

## 6. 推荐后续执行顺序

建议按下面顺序推进，不要交叉发散：

```text
1. Workstream A：TODO-10/11/6/5/8
2. Workstream B：TODO-7/9/3
3. Workstream C：TODO-1
4. TODO-2 仅顺手清理
5. TODO-4 继续保留讨论，不进入当前实现
```

## 7. 推荐后续阅读顺序

建议后续继续分析 RTL 时按以下顺序：

```text
1. npu_top.v 中 act_rd_addr / wgt_rd_addr 生成逻辑
2. npu_top.v 中 array_act_in / wgt_load_reg 形成逻辑
3. npu_top.v 中 cluster_*_all_flat 分发逻辑
4. compute_core.v 的切片方式
5. pe_cluster.v 到 array_top.v 的连接
6. output_arbiter.v 的 aggregate / round-robin 行为
7. npu_top.v 中 store packing 与 DMA writer 连接
8. shared_ram.v 中 32-bit CPU port 与 256-bit NPU port 的地址映射
```

---

## 8. 当前简明结论

当前 NPU RTL 的存储与 single-cluster 供数模式可以概括为：

```text
shared RAM 通过 256-bit AXI4 DMA 将 activation / weight 搬入本地 buffer；
npu_top 从 256-bit buffer 中解包出 INT8 activation 和 weight；
activation 广播给 6 个 cluster；
weight 按 output column / output channel group 切分给不同 cluster；
各 cluster 独立计算，不进行 cluster-to-cluster 通信；
输出按 global column 重路由后进入 output_arbiter 聚合；
最终通过 acc_buffer packing 成 256-bit beat 写回 shared RAM。
```

当前正式决策可以再压缩成一句话：

```text
先证明并归因当前 single-cluster 路径，再决定是否重构；先把 shared memory/layout/store packing 语义收清楚，再讨论地址契约调整；当前控制面增强里只保留 cluster mode/mask 运行时可配置这一条。
```
