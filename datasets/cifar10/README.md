# CIFAR-10 Dataset Notes

## 当前状态

`CIFAR-10` 是 ResNet-20 R0.5 software golden / fixture flow 的目标数据集。当前仓库的正式 RTL 基线仍是已收口的 LeNet/MNIST 路径；不要把本目录中的 CIFAR-10 software flow 误写成当前 RTL 已支持 ResNet-20。

当前准确口径：

- LeNet/MNIST baseline、arrayized FC、6-cluster、HB/AXI 主线均已按当前边界收口。
- CIFAR-10 / ResNet-20 当前只推进到 R0.5 float software training/eval/fixture flow。
- ResNet fixed-point golden 尚未实现。
- ResNet RTL implementation 尚未启动。

## 官方来源

- Official page: `https://www.cs.toronto.edu/~kriz/cifar.html`
- 常见下载包：
  - `cifar-10-binary.tar.gz`
  - `cifar-10-python.tar.gz`
  - `cifar-10-matlab.tar.gz`

## 本目录预留内容

- 原始数据包
- RGB 到当前 NPU 输入格式的转换脚本
- 将来用于多通道卷积验证的样例

## R0.5 ResNet-20 software flow

当前 ResNet-20 R0.5 已支持从本地 CIFAR-10 python tarball 做 float software sanity / baseline training：

```text
datasets/cifar10/cifar-10-python.tar.gz
```

该 tarball 是 downloaded/generated asset，受 `.gitignore` 排除，不作为源码提交。

示例：

```bash
python3 datasets/scripts/train_resnet20_cifar10.py \
  --output datasets/cifar10/models/resnet20_cifar10_sanity.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --count 32 \
  --epochs 1 \
  --batch-size 8

python3 datasets/scripts/eval_resnet20_checkpoint.py \
  --checkpoint datasets/cifar10/models/resnet20_cifar10_sanity.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --split test \
  --count 32 \
  --output results/resnet20_cifar10_sanity_eval.json
```

边界：

- 当前仍是 float software flow。
- fixed-point golden 尚未实现。
- `>=80%` fixed-point accuracy gate 尚未完成。
- ResNet RTL implementation 尚未启动。

## Staged float candidate training

当前 Linux 环境通常按 CPU-only 跑 ResNet-20 pilot；长训练建议后台运行或换到 GPU/MPS 环境。仓库提供 staged runner，把长训练拆成多个可恢复 stage：

```bash
python3 datasets/scripts/run_resnet20_float_training_stages.py \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --out-dir results/resnet20_float_staged \
  --stages 2 \
  --epochs-per-stage 1 \
  --train-count 5000 \
  --eval-count 1000 \
  --batch-size 128 \
  --device cpu \
  --augment
```

每个 stage 会生成：

- `checkpoints/stage_XXX.pt`
- `metrics/stage_XXX_train.json`
- `metrics/stage_XXX_eval.json`

后一 stage 通过 `--resume` 加载前一 stage 的模型权重。当前不 resume optimizer state，metadata 中会明确记录 `optimizer_state_resume=false`。这些结果仍然只是 float software candidate 训练资产，不代表 fixed-point gate。

## 使用建议

当前阶段：

- 可以用本地 tarball 训练和评估 ResNet-20 float checkpoint candidate。
- 可以生成 R0.5 fixture skeleton，用于后续 fixed-point / RTL 规划。
- 不允许据此给出 ResNet RTL 的正式性能或准确率结论。

进入 ResNet RTL 前仍需补齐：

1. fixed-point golden
2. `>=80%` fixed-point accuracy gate
3. INT8 weights / INT32 folded bias memh
4. task sequence
5. `1 MB` shared memory reuse map
