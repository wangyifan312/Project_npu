# Datasets For Contest Evaluation

本目录用于整理赛题三可用的标准测试集，以及当前 RTL 版本的适配范围。

## 赛题要求

仓库内原始赛题文档 [赛题三.docx](/root/Project_npu/赛题三.docx) 在“验证与测试要求 / 性能测试”中明确写到：

- 使用标准测试集进行 AI 推理性能测试
- 示例包括 `MNIST`、`CIFAR-10` 等

这说明赛题并没有强制指定唯一官方下载包，而是允许使用标准公开数据集。

## 当前建议

优先级建议如下：

1. `MNIST`
   - 28x28
   - 单通道灰度图
   - 更接近当前 RTL 已验证的 `INT8 + 单通道 + Conv` 子集
   - 适合先做功能验证、时延统计、数据流闭环验证

2. `CIFAR-10`
   - 32x32x3
   - 三通道彩色图
   - 当前 RTL 尚未真正打通通用 `C_in/C_out` 卷积与 FC 端到端链路
   - 暂不建议直接用于当前版本的正式性能结论

## 当前 RTL 适配边界

截至目前仓库中的 RTL 状态：

- `Conv`：已验证 `5x5 / stride=1 / valid / INT8 / INT32 output`
- `FC`：当前版本不支持，会在 `task_checker` 阶段拒绝
- `Pool/ReLU`：模块存在，但系统级覆盖弱于 Conv 主路径
- 当前集成回归主要验证的是 `C_in=1, C_out=1`

因此：

- 可以先尝试 `MNIST` 的 **Conv-only / partial-pipeline** 测试
- 不建议现在直接做完整 `LeNet + FC` 分类准确率测试
- 也不建议现在直接用 `CIFAR-10` 给出正式性能指标

## 目录结构

- [datasets/mnist](/root/Project_npu/datasets/mnist)
- [datasets/cifar10](/root/Project_npu/datasets/cifar10)
- [datasets/scripts](/root/Project_npu/datasets/scripts)

## 后续建议

下一步更合理的是：

1. 先准备 `MNIST` 测试数据
2. 做 `INT8` 量化/导出脚本
3. 生成适合当前 NPU testbench 直接 preload 的内存镜像
4. 先测 `Conv` 子集正确性和周期数
5. 再决定是否扩展到完整模型链路

## 当前固定入口

与 `LeNet(MNIST)` 相关的统一入口如下：

- 网络规格：
  - [docs/LENET_MNIST_SPEC.md](/root/Project_npu/docs/LENET_MNIST_SPEC.md)
- Claude Code 任务单：
  - [docs/LENET_MNIST_IMPLEMENTATION_TASKS.md](/root/Project_npu/docs/LENET_MNIST_IMPLEMENTATION_TASKS.md)
- 数据导出脚本：
  - [datasets/scripts/export_mnist_samples.py](/root/Project_npu/datasets/scripts/export_mnist_samples.py)
  - [datasets/scripts/pack_bytes_to_memh.py](/root/Project_npu/datasets/scripts/pack_bytes_to_memh.py)
