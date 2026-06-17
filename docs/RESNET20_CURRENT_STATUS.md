# ResNet-20 Current Status

本文档记录 CIFAR-10 ResNet-20 迁移线的当前状态。它只描述 ResNet-20 新工作，不改变当前 LeNet/MNIST、HB、AXI、NPU RTL Workstream A/B/C 的既有基线。

## 1. 当前阶段

当前状态：

- planning complete
- `R0.5 Software Golden and Fixture Flow` implementation started
- synthetic smoke skeleton complete
- real CIFAR-10 float train/eval/fixture sanity complete
- float candidate short pilot complete
- next target: staged float baseline candidate checkpoint training
- RTL implementation not started

当前新增的是 software golden / fixture flow 的工程骨架和 float baseline flow，不是 ResNet RTL 数值实现，也不是 fixed-point golden。

## 2. 固定架构决策

- 目标网络：CIFAR-10 ResNet v1 / ResNet-20
- downsample shortcut：`1x1 stride2 projection Conv`
- bias：INT32 folded bias
- residual ADD：INT32 same-scale ADD
- ADD postproc：ADD / ADD+ReLU / ADD+Requant / ADD+ReLU+Requant
- GAP：INT32 input -> INT32 output
- FC head：FC10
- software fixed-point accuracy gate：`>=80%`
- shared memory contract：`1 MB = 32768 x 256-bit beat`
- base address alignment：`64B`

## 3. 当前已新增入口

训练 smoke：

```bash
python3 datasets/scripts/train_resnet20_cifar10.py \
  --output datasets/cifar10/models/resnet20_smoke.pt \
  --smoke \
  --synthetic-count 8 \
  --epochs 1
```

eval smoke：

```bash
python3 datasets/scripts/eval_resnet20_checkpoint.py \
  --checkpoint datasets/cifar10/models/resnet20_smoke.pt \
  --smoke \
  --synthetic-count 8 \
  --output results/resnet20_smoke_eval.json
```

fixture smoke：

```bash
python3 datasets/scripts/generate_resnet20_fixture.py \
  --checkpoint datasets/cifar10/models/resnet20_smoke.pt \
  --output-dir datasets/cifar10/resnet20_smoke_fixture \
  --smoke \
  --synthetic-count 4
```

这些 smoke 入口使用 deterministic synthetic CIFAR-like data，不下载 CIFAR-10，不代表真实 accuracy。

真实 CIFAR-10 float training sanity：

```bash
python3 datasets/scripts/train_resnet20_cifar10.py \
  --output datasets/cifar10/models/resnet20_cifar10_sanity.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --count 32 \
  --epochs 1 \
  --batch-size 8 \
  --device cpu
```

真实 CIFAR-10 float eval sanity：

```bash
python3 datasets/scripts/eval_resnet20_checkpoint.py \
  --checkpoint datasets/cifar10/models/resnet20_cifar10_sanity.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --split test \
  --count 32 \
  --output results/resnet20_cifar10_sanity_eval.json \
  --device cpu
```

真实 CIFAR-10 float fixture sanity：

```bash
python3 datasets/scripts/generate_resnet20_fixture.py \
  --checkpoint datasets/cifar10/models/resnet20_cifar10_sanity.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --split test \
  --count 4 \
  --output-dir datasets/cifar10/resnet20_cifar10_sanity_fixture \
  --device cpu
```

这些真实 CIFAR-10 命令仍然只是 float software flow sanity，不是 fixed-point golden，不代表 `>=80%` fixed-point gate 已完成。

float baseline candidate training 示例：

```bash
python3 datasets/scripts/train_resnet20_cifar10.py \
  --output datasets/cifar10/models/resnet20_float_candidate.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --epochs 20 \
  --batch-size 128 \
  --lr 0.1 \
  --momentum 0.9 \
  --weight-decay 0.0001 \
  --augment \
  --eval-count 10000 \
  --save-best \
  --metrics-output results/resnet20_float_candidate_train.json \
  --device cpu
```

说明：

- 该命令是较长 float baseline training 入口，本轮不要求跑完。
- 输出 accuracy 仍是 float accuracy，不能写成 fixed-point accuracy。
- 只有后续 fixed-point golden 完成并达到 `>=80%`，才允许进入 ResNet RTL numerical implementation。

float candidate short pilot 结果：

```text
checkpoint: datasets/cifar10/models/resnet20_float_pilot_short.pt
train subset: 5000 samples
eval subset: 1000 test samples
epochs: 3
train accuracy: 1454/5000 = 29.08%
eval accuracy: 293/1000 = 29.3%
```

该结果只证明当前 float training/eval/checkpoint/fixture flow 能支撑 candidate 训练实验；它不是 fixed-point accuracy gate。

staged float candidate training runner：

```bash
python3 datasets/scripts/run_resnet20_float_training_stages.py \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --out-dir results/resnet20_float_staged_smoke \
  --stages 2 \
  --epochs-per-stage 1 \
  --train-count 256 \
  --eval-count 128 \
  --batch-size 32 \
  --device cpu
```

默认 staged runner 适合 CPU-only 环境做可恢复训练探针：

- 每个 stage 输出独立 checkpoint、train metrics JSON、eval JSON。
- 后续 stage 使用前一 stage checkpoint `--resume` 继续加载模型权重。
- optimizer state 当前不 resume，checkpoint metadata 明确记录 `optimizer_state_resume=false`。
- 总 summary 写入 `out-dir/summary.json`，包含 best checkpoint、best eval accuracy、所有 stage metrics 路径。
- staged runner 仍是 float software flow；不实现 fixed-point golden，不启动 RTL R1。

## 4. 当前输出资产

R0.5 smoke fixture 输出：

- `manifest.json`
- `summary.json`
- `weights/summary.json`
- `sample_xxxxx_label_y/input.memh`
- `sample_xxxxx_label_y/label.txt`
- `sample_xxxxx_label_y/meta.json`

`manifest.json` entry 同时包含：

- `label`
- `predicted_class`

当前 manifest schema 为：

- `manifest_schema = top_level_list_v1`
- `manifest.json` 顶层直接是 sample entry list
- `arch` / `checkpoint` / `dataset_source` / `fixed_point_status` 等全局 metadata 放在 `summary.json`

当前 smoke / float fixture `input.memh` 采用：

- `input_layout = HWC`
- `input_dtype = INT8`
- `input_quantization = uint8_minus_128_smoke_or_float_placeholder`

该输入 packing 只是 R0.5 placeholder，不是最终 fixed-point CIFAR input contract。

其中 `predicted_class` 来自当前 software float forward，仅用于 smoke 链路占位。

## 5. 当前未完成项

以下事项仍未完成，不能写成已通过：

- fixed-point golden
- `>=80%` CIFAR-10 fixed-point accuracy
- real CIFAR-10 full fixed-point eval
- INT8 weights memh
- INT32 folded bias memh
- preload map
- complete task sequence
- `1 MB` shared memory reuse map

在 fixed-point golden 和 `>=80%` accuracy gate 达成前，不允许进入 ResNet RTL numerical implementation。

## 6. RTL 边界

当前没有启动：

- RTL R1 register/task-type foundation
- RTL R2 generalized Conv
- RTL ADD/GAP datapath
- ResNet block/end-to-end RTL testbench

ResNet RTL 后续必须以 `docs/RESNET20_SOFTWARE_GOLDEN_PLAN.md` 和 `docs/RESNET20_RTL_EXTENSION_PLAN.md` 为输入，不能由 RTL testbench 隐式猜测网络结构、task sequence 或 memory reuse map。
