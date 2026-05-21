# Project_npu

`Project_npu` 是一个面向比赛场景构建的 `CPU + NPU` 异构处理器 RTL 仓库。  
当前仓库已经具备：

- `PicoRV32 + NPU + shared memory` 的基础 SoC 架构
- `AXI-Lite` 控制面
- `AXI4 burst` 数据面
- `Conv / Pool / ReLU / FC` 的 NPU 子系统级功能验证
- 基于 `MNIST` 的 `LeNet(MNIST)` 逐层黄金对拍流程

## 当前状态

### 已完成

- 原始架构收敛任务 `Tasks 1-9`
- LeNet 扩展任务：
  - Task 1: 网络规格与数据导出链
  - Task 2: 多通道 Conv
  - Task 3: Pool / ReLU 集成
  - Task 4: FC 路径
  - Task 5: 网络级 LeNet testbench
  - Task 6: 黄金模型 / fixture / 逐层对拍

### 需要明确的边界

- 当前“完整 LeNet 跑通”的结论针对 **`npu_top + axi4_ram` 子系统级**
- `rtl/soc/top.v` 默认 `shared_ram` 容量为 `64KB`
- 因此，当前并不等同于 “SoC 顶层 `top` 已按完整 LeNet 地址图跑通”
- 当前 LeNet fixture 使用的是 **确定性构造权重**，主要用于 RTL 功能验证，不代表真实分类准确率

## 顶层架构

系统主结构如下：

- `rtl/soc/top.v`
  - `PicoRV32`
  - `axi_interconnect`
  - `shared_ram`
  - `npu_top`

角色分工：

- CPU：配置寄存器、启动任务、读取状态
- NPU：DMA 搬运、块调度、算子执行、结果写回
- Shared memory：CPU 与 NPU DMA 共享主存

## NPU 结构

主要模块位于 `rtl/npu/`：

- `npu_ctrl`：寄存器、任务生命周期、性能计数器映射
- `task_checker`：地址/对齐/参数检查
- `block_scheduler`：Conv / Pool / FC 分块
- `conv_frontend`：卷积窗口生成
- `postproc`：`ReLU + 2x2 MaxPool`
- `act_read_path / weight_read_path / dma_axi_writer`：DMA 读写
- `npu_buffer`：本地 buffer / bank 状态
- `npu_top`：主状态机与算子执行流

## 当前支持的算子语义

- `Conv`
  - `5x5`
  - `stride=1`
  - `valid`
  - `INT8 x INT8 -> INT32`
  - 支持多输入通道、多输出通道、multi-block
- `Pool`
  - `2x2 MaxPool`
  - `stride=2`
  - `INT32` 域
- `ReLU`
  - `INT32` 域
- `FC`
  - 共用主阵列
  - 输入先做 `INT32 -> saturating INT8`
  - 已验证 `4->2`、`800->500`、`500->10`

不支持：

- bias
- Average Pool
- 通用 kernel / stride / padding

## LeNet(MNIST) 目标网络

当前固定网络规格见：

- [docs/LENET_MNIST_SPEC.md](docs/LENET_MNIST_SPEC.md)

目标网络为：

`Input(28x28x1) -> Conv1(20, 5x5, valid) -> Pool1(2x2 max, s=2) -> Conv2(50, 5x5, valid) -> Pool2(2x2 max, s=2) -> Flatten(800) -> FC1(500) -> ReLU -> FC2(10) -> Argmax`

当前完整网络 testbench 位于：

- `tb/integration/tb_lenet_network.v`

## 仓库结构

```text
rtl/
  bus/        AXI 互连
  cpu/        PicoRV32
  npu/        NPU 主体
  soc/        SoC 顶层与 memory model

tb/
  unit/       单元测试
  integration/集成测试 / LeNet 网络测试

sim/
  run_sim.sh
  run_lenet_fixture.sh

datasets/
  mnist/
  cifar10/
  scripts/

docs/
  架构、任务单、LeNet 规格、调试规范
```

## 常用仿真入口

### 1. 基础回归

```bash
bash sim/run_sim.sh all
```

也可以单独运行：

```bash
bash sim/run_sim.sh tb_npu_top
bash sim/run_sim.sh tb_task1
bash sim/run_sim.sh tb_task2
bash sim/run_sim.sh tb_task3
bash sim/run_sim.sh tb_task6
bash sim/run_sim.sh tb_checker
```

### 2. LeNet fixture 测试

先编译：

```bash
bash sim/run_lenet_fixture.sh compile
```

单样本：

```bash
SIMULATOR=vcs bash sim/run_lenet_fixture.sh sample
```

8 样本：

```bash
SIMULATOR=vcs PROGRESS=0 bash sim/run_lenet_fixture.sh all
```

说明：

- `vcs` 是当前完整 LeNet 回归的主推荐后端
- `iverilog/vvp` 也可用于较小测试，但完整网络更慢

## 数据与 fixture

当前数据相关脚本位于：

- `datasets/scripts/export_mnist_samples.py`
- `datasets/scripts/pack_bytes_to_memh.py`
- `datasets/scripts/generate_lenet_fixture.py`

这些脚本用于：

- 导出 MNIST 样本
- 打包 `memh`
- 生成 LeNet 权重/中间层黄金值 fixture

默认情况下，大体积数据和可再生成产物不会纳入 git：

- 下载的数据集原始包
- `mnist.npz`
- 生成的 `exports/`
- 生成的 `lenet_fixture/`
- 下载的外部模型文件

## 关键文档

- [ARCHITECTURE_SPEC.md](ARCHITECTURE_SPEC.md)
- [CLAUDE.md](CLAUDE.md)
- [docs/LENET_MNIST_SPEC.md](docs/LENET_MNIST_SPEC.md)
- [docs/LENET_MNIST_IMPLEMENTATION_TASKS.md](docs/LENET_MNIST_IMPLEMENTATION_TASKS.md)
- [docs/RTL_DEBUG_PLAYBOOK.md](docs/RTL_DEBUG_PLAYBOOK.md)

## 当前建议

如果后续继续推进，建议优先级是：

1. 导入真实训练得到的 LeNet 权重
2. 将 `.pt`/其他模型源转换成当前 RTL 使用的 `memh/bin`
3. 在现有整网 testbench 上跑真实 MNIST 准确率测试
4. 再考虑把完整网络运行能力下沉到 `top` 层，而不是只停留在 `npu_top` 子系统层

