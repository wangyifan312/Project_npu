# LeNet(MNIST) Specification For The 6-Cluster SoC Baseline

本文件固定本轮 `LeNet(MNIST)` 的网络规格、地址图、数据布局和验证口径。

真实训练权重的生成、量化、导出与地址映射说明见：

- [docs/REAL_WEIGHT_FLOW.md](/root/Project_npu/docs/REAL_WEIGHT_FLOW.md)

## 1. 目标网络

固定网络：

`Input(28x28x1) -> Conv1(20, 5x5, valid) -> Pool1(2x2 max, s=2) -> Conv2(50, 5x5, valid) -> Pool2(2x2 max, s=2) -> Flatten(800) -> FC1(500) -> ReLU -> FC2(10) -> Argmax`

### Layer Shapes

| Layer | Type | Input | Output |
|------|------|-------|--------|
| Input | Image | `28x28x1` | `28x28x1` |
| Conv1 | Conv | `28x28x1` | `24x24x20` |
| Pool1 | MaxPool | `24x24x20` | `12x12x20` |
| Conv2 | Conv | `12x12x20` | `8x8x50` |
| Pool2 | MaxPool | `8x8x50` | `4x4x50` |
| Flatten | Reshape | `4x4x50` | `800` |
| FC1 | Fully Connected | `800` | `500` |
| ReLU | Postproc | `500` | `500` |
| FC2 | Fully Connected | `500` | `10` |
| Argmax | Software/Testbench | `10` | `1` |

## 2. 数据类型

- image activation：`INT8`
- conv weights：`INT8`
- fc weights：`INT8`
- MAC accumulate：`INT32`
- conv/pool 中间 feature map：`INT32`
- FC 输出：`INT32`
- final logits：`INT32`

### FC Input Rule

共享阵列的乘加口径固定为 `INT8 x INT8 -> INT32`，因此：

- `FC1` / `FC2` 输入都从 `INT32` 显式 requant 到 `INT8`
- 转换规则固定为：`multiplier + shift + round-half-away-from-zero + clamp`
- requant 参数粒度固定为：每层一组

## 3. 算子语义

### Conv

- `kernel = 5x5`
- `stride = 1`
- `padding = valid`
- `bias` 不支持

### Pool

- `2x2 MaxPool`
- `stride = 2`

### ReLU

- 工作在 `INT32` 域

### FC

- 必须走共享 `6-cluster` compute hierarchy
- 不允许再用“FC 未支持”描述当前基线
- `FC1` 与 `FC2` 都属于本轮强制验收范围
- P0-3 后，`FC1` / `FC2` 正式执行流使用 `cluster_scheduler -> compute_core_6cluster -> output_arbiter`
- `Pool2 -> FC1` 与 `FC1(ReLU) -> FC2` 的 handoff 继续通过当前 layer-wise requant 语义提供 `INT8` 输入

## 4. Tensor Layout

- feature maps：`HWC`
- conv weights：`[in_c][k_h][k_w][out_c]`
- 每个 `in_c` 权重块在内存中做 `32-bit` 对齐
- fc weights：`[out_neuron][in_neuron]`

### Flatten Rule

`Pool2` 输出 `4x4x50` 按 `HWC` 顺序展开：

`for h in 0..3, for w in 0..3, for c in 0..49`

## 5. SoC Default Address Map

所有 base address 必须满足 `64B` 对齐。

| Region | Suggested Base |
|--------|-----------------|
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

约束：

- `top/shared_ram` 默认容量必须覆盖该地址图
- `task_checker` 地址合法范围必须与 `top` 实际内存窗口一致
- 本轮 SoC 顶层不允许继续以 `64KB` 小容量模型作为默认闭环环境

## 6. Storage Size

- Input image：`28 * 28 * 1 = 784 bytes`
- Conv1 output：`24 * 24 * 20 * 4 = 46080 bytes`
- Pool1 output：`12 * 12 * 20 * 4 = 11520 bytes`
- Conv2 output：`8 * 8 * 50 * 4 = 12800 bytes`
- Pool2 output：`4 * 4 * 50 * 4 = 3200 bytes`
- FC1 weights：`500 * 800 = 400000 bytes`
- FC2 weights：`10 * 500 = 5000 bytes`

## 7. 数据导出规则

MNIST 主数据源：

- [datasets/mnist/mnist.npz](/root/Project_npu/datasets/mnist/mnist.npz)

导出样本目录至少包含：

- `image_u8.bin`
- `image_i8.bin`
- `packed_words.memh`
- `preload_map.txt`
- `label.txt`
- `meta.json`

### INT8 Image Conversion

- `int8_pixel = clamp(uint8_pixel - 128, -128, 127)`

### MEMH Packing

`packed_words.memh` / `preload_map.txt` 仍采用小端 32-bit word 打包：

- bytes `[b0, b1, b2, b3]`
- word = `0x b3 b2 b1 b0`

## 8. 执行模型

网络执行不固化在 RTL 中，由 testbench 或软件驱动层逐任务编排：

1. preload image / weights 到 shared memory
2. 配置一个 NPU task
3. 启动 NPU
4. 将输出区作为下一层输入区
5. 层序执行完整 LeNet
6. testbench / software 读取 logits 并做 `argmax`

### 本轮 SoC 级默认驱动模型

- 在 `top` 层使用 testbench `AXI-Lite master`
- 通过寄存器写模拟 CPU 行为
- 不要求先写 PicoRV32 固件来驱动整网

## 9. Requantization Rules

当前正式网络驱动链中保留 3 处显式 `INT32 -> INT8` requant：

- `Pool1 -> Conv2`
- `Pool2 -> FC1`
- `FC1(ReLU) -> FC2`

三处都采用统一 requant 公式：

`q = clamp(round_half_away_from_zero((acc * multiplier) / 2^shift), -128, 127)`

规则约束：

- `multiplier` / `shift` 为 layer-wise 参数
- 参数通过 `npu_ctrl` / AXI-Lite 寄存器配置
- testbench / fixture / software / RTL 必须使用同一组 requant 参数
- `postproc` 保持 `INT32` 域职责，不把 requant 混入 Pool 状态机

## 10. 验证闭环要求

本轮必须同时保留两条路径：

### Deterministic Fixture

用途：

- 快速 smoke
- 层级黄金对拍
- 回归保护

### Real-Weight LeNet

用途：

- 真实训练权重
- 真实 MNIST 样本
- 单样本逐层对拍
- 多样本分类结果验证

验收要求：

- 不能只给 feature map，不给最终分类结果
- 不能只跑 deterministic fixture，必须补真实权重闭环

## 11. 当前禁止的误导性表述

以下类型的说法在本轮文档中都不允许再出现：

- 用“结构已存在”替代功能验收
- 把 `top` 层误写成已经完成完整 LeNet 闭环
- 把 FC 写成未支持或无需重新验收
- 把小容量 shared memory 模型写成足以承载完整 LeNet 地址图
