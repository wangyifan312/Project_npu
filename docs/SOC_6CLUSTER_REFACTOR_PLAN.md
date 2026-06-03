# CPU+NPU SoC 6-Cluster 重构计划

> Historical refactor plan:
> 本文档是 6-cluster 重构阶段的执行计划和任务拆解记录。
> 它保留了若干当时的“待做项/迁移项”描述，因此不应直接当作当前仓库状态说明。
> 当前正式基线请以：
> - [README.md](/root/Project_npu/README.md)
> - [ARCHITECTURE_SPEC.md](/root/Project_npu/ARCHITECTURE_SPEC.md)
> - [CLAUDE.md](/root/Project_npu/CLAUDE.md)
> - [docs/REQUANTIZATION_PLAN.md](/root/Project_npu/docs/REQUANTIZATION_PLAN.md)
> 为准。

## 1. 背景与目标

当前 `Project_npu` 仓库已经具备较完整的 `NPU` 子系统功能框架，包括：

- `rtl/npu/`
  - `mac_pe`
  - `mac_tile_4x4`
  - `array_top`
  - DMA reader/writer
  - `npu_buffer`
  - `npu_ctrl`
  - `conv_frontend`
  - `fc_frontend`
  - `postproc`
  - `perf_counter`
  - `block_scheduler`
  - `task_checker`
  - `npu_top`
- `rtl/bus/`
  - `axi_interconnect`
- `rtl/soc/`
  - `top`
  - `shared_ram`
  - `axi4_ram`
- `tb/unit/`
- `tb/integration/`
- `datasets/`
- `docs/`

当前仓库还完成了以下功能收敛：

- 原始 `Tasks 1-9` 已完成
- LeNet 扩展任务已完成到：
  - 多通道 Conv
  - Pool / ReLU
  - FC 功能路径
  - LeNet 网络级 testbench
  - fixture / 黄金模型 / 逐层对拍

但是，当前仓库仍然更偏向 `NPU` 子系统功能模型，还没有完全闭合为满足赛题目标的 **CPU+NPU 异构 SoC**。

本次重构目标：

1. 将阵列目标规格从旧的模糊 `64x64` 口径，正式重写为：
   - **基于 4x4 Tile 的 6-Cluster 动态可调脉动阵列**
   - 每个 Cluster = `16x16 PE`
   - 共 `6 x 16 x 16 = 1536 PE`
   - 每个 PE 每周期 `1 x INT8 MAC`
   - 在 `200MHz` 下峰值算力：
     - `1536 * 2 * 200MHz = 0.6144 TOPS`
   - 满足赛题 `>= 0.5 TOPS` 指标

2. 将当前功能原型升级为：
   - 文档一致
   - 计算核心结构清晰
   - 支持 cluster 动态使能
   - 支持 SoC 顶层共享内存闭环
   - 支持真实 LeNet/MNIST 测试闭环
   - 支持性能与利用率统计

本轮的系统级验证口径固定为：

- **SoC 级验证 = 在 `top` 层完成共享内存、寄存器配置、NPU 执行、结果回读闭环**
- **本轮不要求编写 PicoRV32 固件来驱动完整 LeNet**
- SoC 级验证默认使用 testbench 中的 AXI-Lite master / memory preload 流程来模拟 CPU 软件行为
- PicoRV32 固件级完整网络运行可作为后续扩展项，但不纳入本轮强制交付范围

## 2. 当前仓库真实状态

### 2.1 已完成但不能破坏的基础能力

以下能力已经存在，并且在本次重构中必须保持不回退：

1. 参数检查先于执行启动
   - `task_checker` 必须先于 DMA / compute 放行
2. `block_scheduler` 已接入主数据路径
3. `AXI-Lite interconnect` 已具备事务目标锁存能力
4. CPU / NPU 访问共享内存语义已成立
5. 多通道 Conv 已经打通
6. Pool / ReLU 已经打通
7. FC 已经有功能路径
8. LeNet 子系统级 testbench 已能跑完整层序
9. fixture / 黄金模型 / 逐层对拍链路已存在

### 2.2 当前真正的系统级缺口

当前尚未闭合的关键问题不是“算子能不能跑”，而是：

1. 文档中的阵列目标规格仍偏旧
2. `npu_top` 过于“大一统”，compute 边界不清晰
3. `top` 层默认 `shared_ram` 容量不足以承载完整 LeNet 地址图
4. 完整 LeNet 目前主要是在 `npu_top + axi4_ram` 子系统级验证，不是完整 SoC 顶层级
5. 真实训练权重尚未接入，当前 fixture 使用的是确定性构造权重
6. 性能统计项存在，但还不够形成赛题证明级报告
7. SoC 级完整验证目前不应被误解为“必须由 PicoRV32 固件驱动完成”

## 3. 重构总原则

### 3.1 本次重构不是小修补

本次工作不是“再修几个 bug”，而是一次**有边界的架构升级**：

- 保留已有 DMA / buffer / frontend / postproc / control / test 资产
- 明确拆分新的 compute hierarchy
- 扩展 SoC 顶层承载能力
- 补齐真实网络与性能闭环

### 3.2 所有历史 P0/P1 问题视为“强制不回退约束”

以下项目不再当作“待修清单”，而是本次重构后的硬门槛：

- 参数检查必须先于 DMA/compute 启动
- `block_scheduler` 必须真实接入主数据路径
- `AXI-Lite interconnect` 必须保持目标锁存安全
- CPU/NPU 必须继续共享同一份内存语义
- 不允许重新出现“结构接通但功能未验收”的假完成状态

### 3.3 完成标准

任何任务都不能用以下结论代替完成：

- structure complete
- framework exists
- accepted and completed
- done=1
- output 非 x

真正完成标准必须是：

- 严格 testbench PASS
- 与黄金值数值一致
- 退出码正确
- 不破坏已有回归

## 4. 目标架构定义（新基线）

### 4.1 新阵列目标

正式目标改为：

- 6 个 cluster
- 每个 cluster = `16x16 PE`
- PE 由 `4x4 tile` 拼接
- 总计 1536 PE
- 支持 cluster 动态使能：
  - 1 cluster
  - 2 cluster
  - 6 cluster full mode

### 4.2 新模块边界

新增并固定以下模块：

#### `cluster_16x16.v`

职责：

- 作为单个 16x16 PE cluster 封装
- 内部实例化：
  - `array_top #(.TILE_ROWS(4), .TILE_COLS(4))`
- 支持：
  - activation input
  - weight input
  - sum input
  - local enable / clock gate
  - sum output

#### `compute_core_6cluster.v`

职责：

- 例化 6 个 `cluster_16x16`
- 提供统一 compute 接口
- 暴露：
  - `cluster_enable[5:0]`
  - cluster result buses
  - cluster busy / valid / done signals

#### `cluster_scheduler.v`

职责：

- 根据任务规模、模式和 cluster mask 分配 cluster
- 支持：
  - 1 cluster mode
  - 2 cluster mode
  - 6 cluster mode
- 后续需支持动态 cluster enable 策略

#### `output_arbiter.v`

职责：

- 汇聚 6 个 cluster 的输出
- 决定写回顺序 / channel 映射 / block 对应关系
- 不允许 cluster 输出互相覆盖或错位

### 4.3 `npu_top` 的新角色

`npu_top` 在本轮后不再直接承担过多阵列细节，而是作为：

- 任务编排层
- DMA / buffer / frontend / postproc / perf 统筹层

它保留：

- `npu_ctrl`
- `task_checker`
- DMA reader/writer
- `npu_buffer`
- `block_scheduler`
- `conv_frontend`
- `postproc`
- FC 高层执行流
- `perf_counter`

它不再直接内嵌太多 cluster 级阵列组织细节，这些应下沉到：

- `compute_core_6cluster`
- `cluster_scheduler`
- `output_arbiter`

## 5. 详细任务拆解

## Task A — 规格与文档基线重写

### 目标

统一所有文档，使其与本轮架构目标一致。

### 必做项

修改以下文档：

- `ARCHITECTURE_SPEC.md`
- `CLAUDE.md`
- `README.md`
- `docs/LENET_MNIST_SPEC.md`
- 如有需要，补充新文档：
  - `docs/SOC_6CLUSTER_ARCHITECTURE.md`

### 必须同步的内容

- 旧 `64x64` 目标改为 `6-cluster`
- 峰值算力公式写清楚
- `top` 与 `npu_top` 的验证层级区别写清楚
- SoC 级验证采用 testbench AXI-Lite master 驱动，而不是要求 PicoRV32 固件链
- FC 当前状态写清楚
- LeNet 当前闭环边界写清楚
- shared memory 容量要求写清楚
- 性能验证目标写清楚

### 验收

- 文档之间无互相冲突描述
- 不再出现“FC 不支持”之类过时说法
- 不再出现“完整 LeNet 已在 top 层跑通”之类误导

## Task B — 新 compute hierarchy 落地

### 目标

建立新的 6-cluster 计算核心结构。

### 必做项

新增：

- `rtl/npu/cluster_16x16.v`
- `rtl/npu/compute_core_6cluster.v`
- `rtl/npu/cluster_scheduler.v`
- `rtl/npu/output_arbiter.v`

### 设计要求

- `cluster_16x16` 内部必须复用 `array_top`
- `compute_core_6cluster` 必须真正例化 6 个 cluster
- `cluster_enable[5:0]` 必须作为正式接口
- 每个 cluster 必须支持独立 clock gating
- `cluster_scheduler` 与 `output_arbiter` 不能只是空壳，必须有真实功能

### 验收

- 1 cluster 模式可跑
- 2 cluster 模式可跑
- 6 cluster 模式可跑
- cluster 输出不会互相覆盖或乱序

## Task C — `npu_top` 重构接入新 compute core

### 目标

将现有执行流接到新 `compute_core_6cluster`。

### 必做项

- 替换 `npu_top` 中对旧阵列直连的方式
- 让 Conv / FC 路径都走新 compute hierarchy
- `block_scheduler` 仍然必须驱动真实数据路径
- `postproc` 与 writeback 仍然保持正确

### 注意

- 这是本轮最大 RTL 改动之一
- 不允许一边重构一边放松旧测试口径
- 所有已有子系统级回归都必须回跑

### 验收

- 不回退已有 Conv / Pool / ReLU / FC 功能
- LeNet 子系统级 testbench 在新 compute core 上仍可跑通

## Task D — SoC 顶层 shared memory 扩容与闭环

### 目标

让 `top` 层真正能承载完整 LeNet 地址图。

### 必做项

- 升级 `shared_ram` 默认容量
- 使 `top` 默认内存窗口与 LeNet 地址图一致
- 确认 `task_checker` 地址合法范围与 `top` memory 一致
- 升级 `tb_top` 或新增 SoC 顶层级 LeNet 测试

### 验收

- CPU 可写输入和权重
- NPU 可从同一份 shared memory 读数据
- NPU 可将结果写回同一份 shared memory
- CPU 可读回结果
- 完整 LeNet 不再只停留在 `npu_top + axi4_ram`

说明：

- 本轮 SoC 级验证允许由 testbench 驱动 AXI-Lite 事务来模拟 CPU 软件
- 不强制要求 PicoRV32 固件在本轮承担完整 LeNet 调度职责

## Task E — LeNet 真实权重闭环

### 目标

用真实训练得到的 LeNet 权重跑真实 MNIST 样本。

### 必做项

- 建立：
  - checkpoint -> tensor extraction -> INT8 quantization -> memh/bin
- 保持当前布局约定：
  - feature map: `HWC`
  - conv weight: `[in_c][k_h][k_w][out_c]`，每个 `in_c` chunk 32-bit 对齐
  - fc weight: `[out_neuron][in_neuron]`
- 真实运行：
  - `Conv1`
  - `Pool1`
  - `Conv2`
  - `Pool2`
  - `FC1`
  - `FC2`
  - `Argmax`

同时要求：

- 保留当前 deterministic fixture 流程，作为快速非回归验证链
- 新增真实权重流时，不能破坏现有 `run_lenet_fixture.sh` 和层级黄金回归
- 真实权重生成产物默认不强制纳入 git，允许通过脚本和外部 checkpoint 再生成

### 验收

- 单样本逐层黄金对拍 PASS
- 8 样本小批量回归 PASS
- 给出分类结果而不是只给逐层 feature map
- deterministic fixture 回归仍然可运行，作为快速 smoke/regression

## Task F — 性能与验证体系全量补齐

### 目标

一次完成赛题证明级统计与验证体系。

### 必做项

至少输出：

- MAC count
- cycle count
- AXI read beats
- AXI write beats
- AXI active cycles
- array / cluster active cycles
- array / cluster stall cycles
- cluster enable mask / mode
- bandwidth utilization
- array utilization

### 验证模式

必须覆盖：

- single cluster
- 2 cluster
- 6 cluster full mode
- cluster 动态使能
- shared memory CPU/NPU 协同
- MNIST 子系统级测试
- MNIST SoC 级测试

其中：

- SoC 级测试默认采用 testbench AXI-Lite master 驱动
- PicoRV32 固件级网络运行不属于本轮强制验收项

当前验收口径需要明确拆分：

- compute-core / cluster-level 模式覆盖：由 `tb_cluster_perf_modes` 完成，覆盖 `single / 2 cluster / 6 cluster full mode / cluster 动态使能`
- SoC 顶层模式覆盖：当前 `tb_top / tb_top_lenet` 重点验证 shared memory、AXI-Lite、LeNet 地址图和性能寄存器链路，cluster 模式仍主要是 `single-cluster compatibility mode`

### 验收

输出可读表格或日志，至少能支持：

- 理论峰值 vs 实测 cycle / util 对比
- 不同 cluster 模式性能对比
- 带宽利用率对比
- 真实 MNIST 小批量运行结果

## 6. 测试与验收基线

### 6.1 不回退测试

以下旧测试必须保留并回归：

- checker-before-execute
- multi-block Conv
- AXI-Lite decoupling
- shared memory 语义
- Pool/ReLU
- FC 基本数值路径
- 现有 LeNet fixture 测试

### 6.2 新增测试

必须新增：

- `cluster_16x16` 单元测试
- `compute_core_6cluster` 模式测试
- `cluster_scheduler` 测试
- `output_arbiter` 测试
- SoC 顶层 LeNet 测试
- 真实权重 LeNet 测试
- 性能模式测试

### 6.3 验收原则

任何任务不能以以下方式宣称完成：

- only framework exists
- structure complete
- done=1
- output non-x

必须满足：

- strict testbench PASS
- 数值黄金对拍正确
- 回归不破坏
- 文档同步完成

## 7. 实现顺序（强制）

本轮必须按以下顺序推进：

1. Task A — 文档基线重写
2. Task B — 新 compute hierarchy 模块落地
3. Task C — `npu_top` 接入新 compute core
4. Task D — `top/shared_ram` 扩容与 SoC 闭环
5. Task E — 真实 LeNet 权重闭环
6. Task F — 性能与验证体系全量补齐

不允许跳跃式推进：

- 不允许先做性能报告，再补 SoC memory
- 不允许先做真实权重，再不完成 compute core 重构
- 不允许一边 Task B 未收敛，一边直接展开 Task E

## 8. 默认决策（本轮锁死）

以下选择已经锁定，不允许实现过程中擅自更改：

- 阵列目标：`6-cluster`
- 单 cluster 规模：`16x16 PE`
- 总 PE：`1536`
- 峰值口径：`0.6144 TOPS @ 200MHz`
- 采用明显重构方案（原方案 B）
- feature map layout：`HWC`
- conv weight layout：`[in_c][k_h][k_w][out_c]` + per-`in_c` 32-bit 对齐
- fc weight layout：`[out_neuron][in_neuron]`
- `Pool = 2x2 MaxPool, stride=2`
- `ReLU` 工作在 `INT32`
- FC 输入：`INT32 -> saturating INT8`
- 真实 LeNet 闭环优先于“只做 deterministic fixture”
- deterministic fixture 必须保留为快速回归路径
- `top` 本轮必须一起升级，不再允许仅保留 64KB 小容量模型
- 性能与验证体系本轮一次做全套

## 9. 交付结果要求

本轮结束后，仓库应具备：

1. 一套统一且无冲突的文档规格
2. 可解释的 6-cluster 计算核心结构
3. 不回退的 NPU 子系统功能
4. 可承载完整 LeNet 地址图的 SoC 顶层
5. 真实 LeNet 权重的 MNIST 推理闭环
6. 可用于比赛论证的性能统计与模式测试结果
