# Project_npu

`Project_npu` 是面向赛题“CPU + NPU 异构处理器设计”的 RTL 仓库。当前正式基线是 `PicoRV32 CPU + 6-cluster NPU + shared memory` SoC，目标网络为 `LeNet(MNIST)`。

当前项目状态的唯一总表入口是：

- [docs/CURRENT_PROJECT_STATUS.md](docs/CURRENT_PROJECT_STATUS.md)

README 只保留导航、关键边界和常用入口；不要把 README 当作完整状态总表使用。

## 固定硬件基线

- NPU：`6 x 16x16 PE cluster`
- 总 PE：`1536`
- 理论峰值：`0.6144 TOPS @ 200MHz`
- shared memory：`1 MB = 32768 x 256-bit beat`
- CPU 控制面：`32-bit AXI-Lite`
- NPU DMA 数据面：`256-bit AXI4 INCR burst`
- 正式计算路径：`cluster_scheduler -> compute_core_6cluster -> output_arbiter`
- FC 正式路径：arrayized FC，不回退到 legacy scalar FC

## 当前状态摘要

完整结论见 [docs/CURRENT_PROJECT_STATUS.md](docs/CURRENT_PROJECT_STATUS.md)。当前可简述为：

- `HB1/HB2` 已按当前边界完成。
- `AXI-1/2/3/4` 已按当前项目子集边界完成。
- `W1/W2/W3` 已完成并可关闭。
- `W4/W5/W6` 当前降级为后续增强项，不作为正在执行的正式工单。
- NPU RTL `Workstream A/B/C` 已完成。
- first-pass full-cluster 优化已达到 `top32 + subsystem64 stronger regression stable`。

关键证据边界：

- software full-set 是当前全量 accuracy 主证据：`9885/10000 = 98.85%`。
- RTL 侧是 representative chunk evidence，不能表述为 RTL `10000/10000` full-set 已完成。
- multi-cluster correctness 已收口，runtime bottleneck evidence 已增强，但不能表述为 full LeNet-wide performance attribution complete。
- 当前 AXI 实现是标准化 `AXI-Lite` / `AXI4 INCR burst` 项目子集，不是完整通用 AXI IP。

## 不可随意改动的 contract

- LeNet 地址图不变。
- requant 算法语义不变。
- shared memory 继续固定为 `32768 x 256-bit beat`。
- NPU task base address contract 继续维持 `64B` 对齐，不在普通优化中顺手放宽到 `32B`。
- `acc_buffer -> DMA writer` packing 固定为 `32-bit word -> 256-bit AXI beat`。
- last-beat `WSTRB` 由实际 byte count 决定。
- runtime `CLUSTER_MODE / CLUSTER_MASK` 已支持 AXI-Lite 配置，但当前仍是单任务寄存器触发模型，不是 queue / descriptor / shadow config 架构。

## 关键文档入口

- [ARCHITECTURE_SPEC.md](ARCHITECTURE_SPEC.md)：总体架构基线。
- [docs/CURRENT_PROJECT_STATUS.md](docs/CURRENT_PROJECT_STATUS.md)：当前状态总表。
- [docs/soc_fs.md](docs/soc_fs.md)：SoC 功能规格与寄存器/地址口径。
- [docs/NPU_RTL_TODO.md](docs/NPU_RTL_TODO.md)：NPU RTL Workstream A/B/C 详细证据。
- [docs/FULL_CLUSTER_OPT_PLAN.md](docs/FULL_CLUSTER_OPT_PLAN.md)：first-pass full-cluster 优化方案。
- [docs/PERFORMANCE_SUMMARY.md](docs/PERFORMANCE_SUMMARY.md)：性能证据与引用边界。
- [docs/LENET_MNIST_SPEC.md](docs/LENET_MNIST_SPEC.md)：LeNet 网络、数据布局和地址规则。
- [docs/REAL_WEIGHT_FLOW.md](docs/REAL_WEIGHT_FLOW.md)：真实权重与 candidate-final 资产链。
- [docs/MNIST_FULL_EVAL_PLAN.md](docs/MNIST_FULL_EVAL_PLAN.md)：full-set evaluation 口径。
- [docs/DELIVERY_CHECKLIST.md](docs/DELIVERY_CHECKLIST.md)：答辩/交付收尾清单。
- [docs/NEXT_TASK_WORKLIST.md](docs/NEXT_TASK_WORKLIST.md)：历史 W1-W6 工单定义；当前 W4-W6 为后续增强项。
- [docs/AXI_COMPLIANCE_SPEC.md](docs/AXI_COMPLIANCE_SPEC.md)：AXI 支持范围。
- [docs/HB_256BIT_REFACTOR_SPEC.md](docs/HB_256BIT_REFACTOR_SPEC.md)：256-bit HB 数据面基线。

## 目标网络

固定网络：

```text
Input(28x28x1)
-> Conv1(20, 5x5, valid)
-> Pool1(2x2 max, s=2)
-> Conv2(50, 5x5, valid)
-> Pool2(2x2 max, s=2)
-> Flatten(800)
-> FC1(500)
-> ReLU
-> FC2(10)
-> Argmax
```

固定数据规则：

- feature map layout：`HWC`
- conv weight layout：`[in_c][k_h][k_w][out_c]`
- fc weight layout：`[out_neuron][in_neuron]`
- activation / weight：`INT8`
- accumulate / output：`INT32`
- 层间 handoff：layer-wise requant，`multiplier + shift + round-half-away-from-zero + clamp`

## 仓库结构

```text
rtl/       RTL source
tb/        unit and integration testbenches
sim/       official simulation scripts
datasets/  MNIST fixtures, manifests, exported assets
docs/      specs, status, checklists, runbooks
results/   retained evidence and run outputs
```

## 常用入口

基础回归：

```bash
bash sim/run_sim.sh all
```

LeNet subsystem / top：

```bash
SIMULATOR=vcs bash sim/run_lenet_fixture.sh sample
SIMULATOR=vcs bash sim/run_top_lenet.sh sample
```

Makefile 入口：

```bash
make help
make top1
make top8
make top16
make top32
make subsystem8
make perf-top16
make perf-top32
make perf-subsystem8
make fullset-subsystem-status
```

说明：

- `Makefile` 是对现有 `sim/*.sh` 的薄封装。
- `tb_top`、`tb_top_lenet`、`tb_top_cluster_modes` 是正式 SoC 入口。
- 历史 `tb_task*`、`tb_npu_top`、`tb_fc*` 等只作为 legacy/debug/micro 入口，不能作为正式功能或性能基线。

## 完成标准

以下都不算完成：

- `done=1`
- 输出非 `x`
- framework exists
- structure complete

完成必须以严格测试、数值对拍、回归不破坏和文档口径一致为准。
