# ResNet-20 Software Golden and Fixture Plan

本文档定义 `Project_npu` 在启动 ResNet-20 RTL 数值实现前必须先完成的 software golden、训练、量化、fixture 和 task sequence 前置流程。

本计划参考当前 LeNet/MNIST 的真实权重链路，但不复用 LeNet 的网络、地址图或量化参数。ResNet-20 必须建立独立的 CIFAR-10 资产链。

---

## 1. 目标与硬边界

目标网络固定为：

```text
CIFAR-10 ResNet v1 / ResNet-20
```

首版架构选择固定为：

```text
downsample shortcut: 1x1 projection Conv
bias: INT32 folded bias
residual ADD: INT32 same-scale ADD
ADD postproc: ADD / ADD+ReLU / ADD+Requant / ADD+ReLU+Requant
GAP: INT32 input -> INT32 output
FC head: FC10
```

进入 RTL 数值实现前的 software gate：

```text
CIFAR-10 fixed-point software accuracy >= 80%
```

当前明确不做：

```text
1. 不把 ResNet RTL 实现建立在随机权重或未验证 checkpoint 上。
2. 不在首版 RTL 中实现 dual-branch ADD rescale。
3. 不在首版 RTL 中实现 per-channel quantization。
4. 不改变当前 LeNet/MNIST baseline。
5. 不改变 shared memory 1 MB contract。
```

---

## 2. 与 LeNet Flow 的对应关系

当前 LeNet/MNIST 成熟链路包含：

```text
train_lenet_mnist.py
eval_lenet_checkpoint.py
generate_lenet_real_fixture.py
manifest.json
weights/*.memh
weights/*.preload_map.txt
sample full-fixture
manifest-only large eval
```

ResNet-20 应建立等价但独立的链路：

```text
datasets/scripts/train_resnet20_cifar10.py
datasets/scripts/eval_resnet20_checkpoint.py
datasets/scripts/generate_resnet20_fixture.py
datasets/scripts/inspect_resnet20_checkpoint.py
datasets/scripts/export_resnet20_fixed_point_skeleton.py
```

推荐目录：

```text
datasets/cifar10/
  cifar10.npz
  models/
    cifar10_resnet20_int8_candidate.pt
  exports/
    sample_xxxxx_label_y/
      input.memh
      packed_words.memh
      label.txt
      meta.json
  resnet20_candidate_fixture/
    manifest.json
    summary.json
    weights/
      summary.json
      layer_xxx_weights.memh
      layer_xxx_bias.memh
      layer_xxx.preload_map.txt
    sample_xxxxx_label_y/
      input.memh
      logits.memh
      argmax.txt
      summary.json
      tensor_checksums.json
```

说明：

- `datasets/cifar10/` 不与 `datasets/mnist/` 混用。
- 小样本 full-fixture 用于 RTL debug 和 block/end-to-end 对拍。
- manifest-only flow 用于后续大规模 software/RTL batch 管理。

---

## 3. Software Golden Contract

software fixed-point golden 必须和计划中的 RTL 语义一致。

### 3.1 数据类型

```text
input activation: INT8
Conv/FC weight: INT8
Conv/FC accumulate: INT32
bias: INT32 folded bias in accumulator domain
ADD: INT32 + INT32 -> INT32, same scale
GAP accumulate: INT48 or INT64 in software model
GAP output: INT32
Requant: INT32 -> INT8
```

### 3.2 Requant 语义

首版继续采用当前项目已验证的 requant 语义：

```text
acc * multiplier
shift
round-half-away-from-zero
clamp to [-128, 127]
```

ResNet fixture 必须在 `summary.json` 中记录每个 requant 点：

```text
layer/block name
source tensor
destination tensor
multiplier
shift
rounding version
```

### 3.3 ADD Scale Contract

首版 ADD 采用：

```text
src0: INT32
src1: INT32
dst: INT32
contract: src0 and src1 are already in compatible scale
```

该 scale 对齐由 software/training/export flow 保证，RTL v1 不实现：

```text
src0 multiplier/shift
src1 multiplier/shift
dual-branch rescale
INT8 saturated ADD
```

如果 software accuracy 长期无法达到 `80%`，应先调试训练/量化/scale 策略，而不是让 RTL 增加未规划的 rescale datapath。

### 3.4 Bias Contract

Conv/FC bias 必须由 software 折叠 BatchNorm 后导出为：

```text
INT32 bias[output_channel]
```

RTL 侧只负责按 global output channel 将 bias 加入 accumulator domain，不负责 BN 参数计算。

---

## 4. Required Generated Artifacts

R0.5 完成时，必须生成以下资产。

### 4.1 Checkpoint

```text
datasets/cifar10/models/cifar10_resnet20_int8_candidate.pt
```

checkpoint metadata 至少包含：

```text
arch = cifar10_resnet20_v1
quant_version
weight dtype
bias dtype
requant version
training config summary
best validation/test accuracy
```

### 4.2 Evaluation Result

必须输出完整 CIFAR-10 software fixed-point evaluation summary：

```text
correct / total
accuracy
checkpoint path
dataset path
quant version
generated_at
```

进入 RTL 数值实现的最低门槛：

```text
accuracy >= 80%
```

当前 fixed-point golden 设计入口：

```text
docs/RESNET20_FIXED_POINT_GOLDEN_PLAN.md
```

该文档和 skeleton 脚本只用于冻结接口、checkpoint inspection、layer graph 和 TODO 状态；在 actual fixed-point inference 和 full CIFAR-10 fixed-point eval 完成前，不能作为 RTL R1/R2/R3 启动条件。

### 4.3 Fixture

必须生成小批量 full-fixture：

```text
count = 8 or 16
```

每个 sample 至少包含：

```text
input memh
label
predicted_class
logits
argmax
per-layer or per-block tensor checksums
summary.json
```

建议 small fixture 在早期包含关键中间 tensor dump：

```text
first Conv output
each BasicBlock output
each DownsampleBlock output
GAP output
FC logits
```

### 4.4 Manifest

`manifest.json` 每个 entry 至少包含：

```json
{
  "sample": "sample_xxxxx_label_y",
  "label": 0,
  "predicted_class": 0,
  "input_memh": "...",
  "meta_path": "...",
  "summary_path": "..."
}
```

RTL 小批量验收默认对齐 `predicted_class`，不能把模型自身错分直接判为 RTL bug。

### 4.5 Weights and Biases

必须导出：

```text
layer_xxx_weights.memh
layer_xxx_bias.memh
layer_xxx.preload_map.txt
weights/summary.json
```

`weights/summary.json` 必须记录：

```text
layer name
op type
weight layout
weight bytes
bias layout
bias bytes
memory address
alignment
source checkpoint tensor name
```

### 4.6 Task Sequence

必须导出 ResNet-20 的完整 task sequence，包含：

```text
task index
op type
input tensor
output tensor
shortcut tensor, if ADD
input/output shape
kernel/stride/padding
weight_addr
bias_addr
src0_addr
src1_addr
output_addr
input_bytes
weight_bytes
bias_bytes
src1_bytes
output_bytes
requant slot or params
postproc mode
cluster mode/mask, if fixed by flow
```

该 task sequence 是后续 RTL testbench 和 driver 的主输入，不允许由 RTL testbench 隐式猜测网络结构。

### 4.7 Shared Memory Reuse Map

必须在 1 MB shared memory 内给出地址复用计划。

固定 contract：

```text
shared memory: 1 MB = 32768 x 256-bit beat
base address alignment: 64B
NPU DMA beat: 32B
```

reuse map 至少说明：

```text
weights/bias resident region
activation ping-pong/reuse regions
shortcut live tensor regions
ADD output region
GAP/FC region
final logits region
```

不允许为了 ResNet-20 golden flow 隐式扩大 shared memory 或放宽 64B 对齐。

---

## 5. R0.5 Completion Criteria

`R0.5 ResNet-20 Software Golden and Fixture Flow` 只有在以下条件全部满足时才可关闭：

```text
1. CIFAR ResNet v1 / ResNet-20 网络定义冻结。
2. 训练得到 candidate checkpoint。
3. fixed-point inference 与 RTL 计划数值语义一致。
4. software fixed-point CIFAR-10 accuracy >= 80%。
5. INT32 folded bias 已生成。
6. ADD same-scale contract 已记录。
7. 8/16 sample full-fixture 已生成。
8. manifest 同时包含 label 和 predicted_class。
9. weights/bias memh 与 preload map 已生成。
10. 完整 task sequence 已生成。
11. 1 MB shared memory reuse map 已生成。
12. 文档说明哪些结果是 software full-set，哪些只是 small fixture。
```

若任一项未满足，不应启动 ResNet RTL 数值实现。

---

## 6. Handoff to RTL Plan

本计划完成后，后续 RTL 修改应以以下文件为输入：

```text
docs/RESNET20_RTL_EXTENSION_PLAN.md
```

RTL 侧不得自行改变：

```text
network definition
quantization semantics
weight layout
bias layout
task sequence semantics
memory reuse map
ADD same-scale policy
```

若 R0.5 的 software golden 与 RTL 计划发生冲突，应先更新本计划和 golden flow，再进入 RTL 修改。
