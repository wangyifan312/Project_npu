# CPU+NPU SoC Architecture Specification

本文件定义本轮重构后的统一架构基线，用于约束 RTL、testbench、数据导出脚本和验收口径。

配套说明见 [docs/SOC_6CLUSTER_ARCHITECTURE.md](/root/Project_npu/docs/SOC_6CLUSTER_ARCHITECTURE.md)。

## 1. 目标与边界

- 目标平台：`PicoRV32 + NPU + shared memory` 的 `CPU+NPU SoC`
- 目标网络：`LeNet(MNIST)`，用于驱动本轮 SoC、真实权重和性能闭环
- 控制面：`AXI-Lite`
- 数据面：`AXI4 burst`
- 本轮 SoC 级验证方式：`top` 层 + testbench `AXI-Lite master` + shared memory preload
- 本轮不要求先由 PicoRV32 固件驱动完整 LeNet

本文件描述的是**本轮固定目标架构**，不是旧实现状态说明。

## 2. 固定目标规格

### 2.1 Compute Target

- 计算阵列采用 `6-cluster` 动态可调脉动阵列
- 每个 cluster = `16x16 PE`
- 每个 PE 每周期执行 `1 x INT8 MAC`
- 基础复用单元为 `4x4 tile`
- 总 PE 数：`6 x 16 x 16 = 1536`
- 峰值算力：`1536 x 2 x 200MHz = 0.6144 TOPS`
- 本轮正式目标口径固定为以上 `6-cluster / 1536 PE / 0.6144 TOPS`，不再沿用旧阵列目标说法

### 2.2 Cluster Modes

- `single-cluster mode`
- `dual-cluster mode`
- `six-cluster full mode`
- `cluster_enable[5:0]` 为正式架构接口

### 2.3 SoC Memory Target

- `top/shared_ram` 不再允许停留在旧 `64KB` 小容量模型
- 默认共享内存窗口必须覆盖当前 LeNet 地址图
- 当前基线要求默认可寻址窗口至少覆盖 `0x0000_0000 ~ 0x000F_FFFF`，即 `1MB`
- CPU 与 NPU DMA 必须继续访问同一份 shared memory 语义

## 3. 顶层角色划分

### 3.1 SoC Top

`rtl/soc/top.v` 负责：

- `PicoRV32`
- `axi_interconnect`
- `shared_ram`
- `npu_top`
- CPU/NPU 对同一内存空间的协同语义

### 3.2 NPU Top

`npu_top` 是任务编排与数据流统筹层，不再直接承载过多 cluster 级组织细节。

保留并继续作为正式主路径的模块：

- `npu_ctrl`
- `task_checker`
- `block_scheduler`
- `act_read_path`
- `weight_read_path`
- `dma_axi_writer`
- `npu_buffer`
- `conv_frontend`
- `fc_frontend` 或等价 FC 前端/执行流
- `postproc`
- `perf_counter`

Cluster 级结构必须下沉到新的 compute hierarchy。

## 4. Compute Hierarchy

### 4.1 `cluster_16x16`

职责：

- 封装单个 `16x16 PE` cluster
- 内部复用现有 `array_top` / `4x4 tile` 资产
- 提供 cluster 级 enable / busy / valid / done / result 接口
- 支持独立 clock gate 语义

### 4.2 `compute_core_6cluster`

职责：

- 真正例化 `6` 个 `cluster_16x16`
- 暴露统一 compute 接口
- 暴露 `cluster_enable[5:0]`
- 汇出 cluster busy / valid / done / result

### 4.3 `cluster_scheduler`

职责：

- 根据任务规模、模式和 cluster mask 进行 cluster 分配
- 至少支持 `1 / 2 / 6 cluster` 模式
- 输出 cluster 使能与调度决策

### 4.4 `output_arbiter`

职责：

- 汇聚 6 个 cluster 的输出
- 约束写回顺序和 channel/block 映射
- 不允许 cluster 输出覆盖、错位或乱序

## 5. 数据类型与算子语义

- activation：`INT8`
- weight：`INT8`
- accumulate：`INT32`
- 输出写回：`INT32`

固定支持：

- `Conv`: `5x5`, `stride=1`, `valid`, `no bias`
- `Pool`: `2x2 MaxPool`, `stride=2`
- `ReLU`: `INT32` 域
- `FC`: 共用 6-cluster compute hierarchy，不允许再按“未支持”处理

FC 规则固定为：

- 输入来自 `INT32` feature/vector
- 进入共享阵列前执行 `INT32 -> saturating INT8`
- 饱和区间 `[-128, 127]`

## 6. 任务模型

- 一次 `start` 只执行一条任务
- `busy=1` 时重复 `start` 必须报错
- 参数检查必须先于 DMA / compute 放行
- `block_scheduler` 必须真实驱动数据路径，而不是只保留框架
- `done=1` 只能在数值路径、后处理、写回和性能冻结全部完成后拉起

## 7. 共享内存与地址图

### 7.1 LeNet Default Address Map

| Region | Base |
|--------|------|
| Input image | `0x0000_0100` |
| Conv1 weights | `0x0000_1000` |
| Conv1 output / Pool1 input | `0x0000_4000` |
| Pool1 output / Conv2 input | `0x0001_8000` |
| Conv2 weights | `0x0002_0000` |
| Conv2 output / Pool2 input | `0x0006_0000` |
| Pool2 output / FC1 input | `0x0008_0000` |
| FC1 weights | `0x0009_0000` |
| FC1 output / FC2 input | `0x000F_2000` |
| FC2 weights | `0x000F_3000` |
| Final logits | `0x000F_5000` |

### 7.2 Alignment Rules

- 所有 base address 必须满足 `64B` 对齐
- `task_checker` 的合法地址窗口必须与 `top/shared_ram` 实际容量保持一致

## 8. 验证层级

### 8.1 NPU 子系统级

`npu_top + axi4_ram` 用于：

- 大容量特征图 / 权重回归
- deterministic fixture
- 层级与网络级数值对拍

### 8.2 SoC 顶层级

`top` 用于：

- CPU/NPU/共享内存统一语义
- AXI-Lite 控制面驱动
- shared memory preload
- NPU 执行与结果回读闭环

本轮默认 SoC 级方法：

1. testbench 预加载 input / weight 到 shared memory
2. testbench 通过 AXI-Lite master 模拟 CPU 配置寄存器
3. 启动 NPU 执行
4. 从同一份 shared memory 回读结果

说明：

- “完整 LeNet 已跑通”只有在对应层级的严格测试通过时才成立
- 旧结论“LeNet 仅在 `npu_top + axi4_ram` 子系统跑通”不能再被误写成 SoC 顶层已完成
- SoC 顶层当前的性能模式验证重点是 shared memory / AXI-Lite / 地址图 / 性能寄存器链路闭环
- 当前 `tb_top / tb_top_lenet` 仍主要工作在 `single-cluster compatibility mode`，对应 `cluster_cfg = 0x01`

## 9. LeNet 当前闭环要求

本轮必须同时保留两条验证链：

- deterministic fixture：快速 smoke / regression
- 真实训练权重 + 真实 MNIST 样本：正式网络级验收

真实 LeNet 闭环优先级高于“只做 deterministic fixture”。

## 10. 性能统计要求

至少保留并可导出：

- `mac_count`
- `cycle_count`
- `axi_read_beats`
- `axi_write_beats`
- `axi_read_active_cycles`
- `axi_write_active_cycles`
- `array_active_cycles`
- `array_stall_cycles`
- `cluster_active_cycles`
- `cluster_stall_cycles`
- `cluster_enable_mask`
- `cluster_mode`

派生指标至少包括：

- 理论峰值对比
- `read_bw_util`
- `write_bw_util`
- `array_util`
- 不同 cluster 模式性能对比

当前验证口径需要明确区分：

- compute-core / cluster-level：已通过 `tb_cluster_perf_modes` 覆盖 `single / dual / six-cluster full / dynamic mask`
- SoC top-level：已通过 `tb_top / tb_top_lenet` 覆盖性能寄存器读出与 LeNet 闭环，但当前 cluster 模式仍以 `single-cluster compatibility mode` 为主

## 11. 不回退约束

以下项目视为强制门槛，不再是“后续待修”：

- 参数检查先于执行启动
- `block_scheduler` 已接入真实主数据路径
- `AXI-Lite interconnect` 事务目标锁存安全
- CPU/NPU 共享同一份内存语义
- Conv / Pool / ReLU / FC 不允许以“结构已接通”替代功能验收

## 12. 完成判定

以下任一项都不能单独视为完成：

- `framework exists`
- `structure complete`
- `done=1`
- `output non-x`

完成必须同时满足：

1. 严格 testbench PASS
2. 输出数值与 golden/reference 一致
3. 相关回归未破坏
4. 文档、RTL、testbench 口径一致
