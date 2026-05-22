# Project_npu

`Project_npu` 是一个面向赛题三的 `CPU + NPU` 异构处理器 RTL 仓库。本轮工作目标不是继续维护旧的阵列原型口径，而是正式切换到 `6-cluster` SoC 基线，并补齐 SoC、真实权重与性能闭环。

## 本轮固定目标

- `6-cluster` 动态可调脉动阵列
- 每个 cluster = `16x16 PE`
- 总计 `1536 PE`
- `200MHz` 理论峰值 `0.6144 TOPS`
- `top` 层 shared memory 默认覆盖完整 LeNet 地址图
- SoC 级验证采用 testbench `AXI-Lite master` + shared memory preload 模拟 CPU 软件行为
- FC 必须在新 compute hierarchy 下重新完成功能验收

## 当前仓库基线

已完成且本轮不得回退：

- 原始 `Tasks 1-9`
- 多通道 `Conv`
- `Pool / ReLU`
- FC 基本功能路径
- `LeNet` 层级对拍与 deterministic fixture 流程
- `npu_top + axi4_ram` 子系统级网络回归资产

需要明确的是：

- 旧版“完整 LeNet 跑通”主要指 `npu_top + axi4_ram` 子系统级闭环
- 本轮目标是把完整地址图、shared memory 语义、AXI-Lite 驱动流程推进到 `top` 层
- 本轮默认不要求先写 PicoRV32 固件来驱动完整 LeNet

## 架构摘要

- SoC 顶层：`rtl/soc/top.v`
- NPU 编排层：`rtl/npu/npu_top.v`
- 新 compute hierarchy：
  - `rtl/npu/cluster_16x16.v`
  - `rtl/npu/compute_core_6cluster.v`
  - `rtl/npu/cluster_scheduler.v`
  - `rtl/npu/output_arbiter.v`

详细基线见：

- [ARCHITECTURE_SPEC.md](ARCHITECTURE_SPEC.md)
- [docs/SOC_6CLUSTER_ARCHITECTURE.md](docs/SOC_6CLUSTER_ARCHITECTURE.md)
- [docs/LENET_MNIST_SPEC.md](docs/LENET_MNIST_SPEC.md)
- [docs/RTL_DEBUG_PLAYBOOK.md](docs/RTL_DEBUG_PLAYBOOK.md)

## 目标网络

固定网络为：

`Input(28x28x1) -> Conv1(20, 5x5, valid) -> Pool1(2x2 max, s=2) -> Conv2(50, 5x5, valid) -> Pool2(2x2 max, s=2) -> Flatten(800) -> FC1(500) -> ReLU -> FC2(10) -> Argmax`

固定规则：

- feature map layout：`HWC`
- conv weight layout：`[in_c][k_h][k_w][out_c]`，每个 `in_c` chunk 做 32-bit 对齐
- fc weight layout：`[out_neuron][in_neuron]`
- FC 输入：`INT32 -> saturating INT8`

## 验证层级

- `npu_top + axi4_ram`
  - 大容量 deterministic fixture
  - 层级/网络级黄金对拍
  - compute-core / cluster-level 性能模式覆盖由 `tb_cluster_perf_modes` 提供，已覆盖 `single / dual / full / dynamic mask`
- `top`
  - CPU/NPU/shared memory 协同
  - AXI-Lite 配置与状态回读
  - 完整 LeNet 地址图闭环
  - 当前 SoC 顶层性能验证仍主要是 `single-cluster compatibility mode`

本轮最终要求同时保留：

- deterministic fixture 快速回归
- 真实训练权重 + 真实 MNIST 小批量回归

## 仓库结构

```text
rtl/
  bus/        AXI 互连
  cpu/        PicoRV32
  npu/        NPU 主体与 compute hierarchy
  soc/        SoC 顶层与 shared memory

tb/
  unit/       单元测试
  integration/集成测试与网络级测试

sim/
  run_sim.sh
  run_lenet_fixture.sh

datasets/
  mnist/
  scripts/

docs/
  架构、LeNet 规格、调试规则
```

## 常用入口

基础回归：

```bash
bash sim/run_sim.sh all
```

LeNet fixture：

```bash
bash sim/run_lenet_fixture.sh compile
SIMULATOR=vcs bash sim/run_lenet_fixture.sh sample
SIMULATOR=vcs PROGRESS=0 bash sim/run_lenet_fixture.sh all
```

说明：

- deterministic fixture 继续作为快速 smoke/regression 路径
- 真实权重流会单独补充导出脚本与回归入口

## 完成标准

以下都不算完成：

- `done=1`
- 输出非 `x`
- framework exists
- structure complete

完成必须以严格测试与数值对拍为准，并且不能破坏既有回归。
