# Datasets For Final Delivery

本目录保存当前赛题提交 / 答辩交付所需的数据与导出脚本。

当前正式口径：

- 标准数据集：`MNIST`
- 真实网络：`LeNet(MNIST)`
- 当前仓库已经支持：
  - deterministic fixture
  - real-weight fixture
  - `npu_top + axi4_ram` 子系统回归
  - `top` 层 real-weight 回归

## 目录

- [datasets/mnist](/root/Project_npu/datasets/mnist)
- [datasets/scripts](/root/Project_npu/datasets/scripts)

## 当前固定入口

- 样本导出：
  - [datasets/scripts/export_mnist_samples.py](/root/Project_npu/datasets/scripts/export_mnist_samples.py)
- checkpoint 训练：
  - [datasets/scripts/train_lenet_mnist.py](/root/Project_npu/datasets/scripts/train_lenet_mnist.py)
- checkpoint 评估：
  - [datasets/scripts/eval_lenet_checkpoint.py](/root/Project_npu/datasets/scripts/eval_lenet_checkpoint.py)
- fixture8 微调：
  - [datasets/scripts/fine_tune_lenet_fixture.py](/root/Project_npu/datasets/scripts/fine_tune_lenet_fixture.py)
- real-weight fixture 生成：
  - [datasets/scripts/generate_lenet_real_fixture.py](/root/Project_npu/datasets/scripts/generate_lenet_real_fixture.py)
- 小端 `memh` 打包：
  - [datasets/scripts/pack_bytes_to_memh.py](/root/Project_npu/datasets/scripts/pack_bytes_to_memh.py)

## 说明

- 当前答辩使用的真实权重链路说明见：
  - [docs/REAL_WEIGHT_FLOW.md](/root/Project_npu/docs/REAL_WEIGHT_FLOW.md)
- 如果 software full-test accuracy 长期低于 `80%`，应优先对照：
  - [docs/REQUANTIZATION_PLAN.md](/root/Project_npu/docs/REQUANTIZATION_PLAN.md)
- 当前网络规格、地址图和布局说明见：
  - [docs/LENET_MNIST_SPEC.md](/root/Project_npu/docs/LENET_MNIST_SPEC.md)
