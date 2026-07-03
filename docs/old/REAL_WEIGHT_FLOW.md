# Real-Weight Flow

本文件说明当前 `Project_npu` 的真实 LeNet 权重链路，并明确区分：

- 当前**正式 full-test 候选模型**
- 当前**展示 / 抽样回归模型**

目标是回答 6 个问题：

1. 权重从哪里来
2. 网络版本是什么
3. 如何量化
4. 数据如何布局
5. 转换脚本入口是什么
6. 如何映射到 RTL 地址图

---

## 1. 当前权重状态总览

当前仓库里需要区分两条链：

1. **正式 full-test 候选模型**
   - [datasets/mnist/models/mnist_lenet_soc6_requant_candidate_final.pt](/root/Project_npu/datasets/mnist/models/mnist_lenet_soc6_requant_candidate_final.pt)
   - 用途：
     - software full-test accuracy gate
     - 新 requant 语义下的正式候选 checkpoint
   - 当前已验证：
     - software full-test accuracy = `98.85%`
   - 当前状态：
     - 这是仓库里最新、最高优先级的正式候选
     - 后续 RTL/subsystem/top sanity 应优先围绕该 checkpoint 展开

2. **展示 / 抽样回归模型**
   - [datasets/mnist/models/mnist_lenet_soc6_fixture8.pt](/root/Project_npu/datasets/mnist/models/mnist_lenet_soc6_fixture8.pt)
   - 用途：
     - 旧 real-weight 8 样本展示链
     - 旧 direct-saturate 语义下的阶段性调试/展示
   - 当前状态：
     - 仍可作为历史展示资产保留
     - 但**不再**作为完整 `MNIST test set` 结果交付模型

---

## 2. 展示/历史链路中的权重来源

当前仓库里旧 `real-weight` fixture 使用的 checkpoint 记录在：

- [datasets/mnist/lenet_real_fixture/weights/summary.json](/root/Project_npu/datasets/mnist/lenet_real_fixture/weights/summary.json)

当前值为：

- `checkpoint = datasets/mnist/models/mnist_lenet_soc6_fixture8.pt`
- `best_test_acc = 0.7265625`

这条**历史展示链**的生成过程是：

1. 先用 [datasets/scripts/train_lenet_mnist.py](/root/Project_npu/datasets/scripts/train_lenet_mnist.py)
   在 `datasets/mnist/mnist.npz` 上训练 spec-matching INT8-aware LeNet
2. 生成基础 checkpoint：
   - [datasets/mnist/models/mnist_lenet_soc6.pt](/root/Project_npu/datasets/mnist/models/mnist_lenet_soc6.pt)
3. 再用 [datasets/scripts/fine_tune_lenet_fixture.py](/root/Project_npu/datasets/scripts/fine_tune_lenet_fixture.py)
   在当前导出的 8 个展示样本上微调，得到：
   - [datasets/mnist/models/mnist_lenet_soc6_fixture8.pt](/root/Project_npu/datasets/mnist/models/mnist_lenet_soc6_fixture8.pt)
4. 最后用 [datasets/scripts/generate_lenet_real_fixture.py](/root/Project_npu/datasets/scripts/generate_lenet_real_fixture.py)
   把 checkpoint 转成 RTL 可直接 preload 的 `memh / preload_map / golden`

说明：

- `mnist_lenet_soc6.pt` 是旧基础 spec-matching checkpoint
- `mnist_lenet_soc6_fixture8.pt` 是旧展示样本链路使用的 checkpoint
- 当前仓库内 `lenet_real_fixture` 的 8 个样本与该 checkpoint 一一对应

### 2.1 Checkpoint Quality Gate

从当前基线开始，仓库内 checkpoint 需要明确区分两类用途：

1. 展示/抽样回归模型
2. 完整测试集交付模型

其中：

- `mnist_lenet_soc6_fixture8.pt` 属于展示/抽样回归模型
- 它可以继续用于 `8` 样本答辩展示链路
- 但不能直接当作完整 `MNIST test set` 结果交付模型

完整测试集交付模型的强制门槛是：

- 必须先通过 software full-test accuracy gate
- 完整 `MNIST test set` accuracy 必须达到 `80%` 及以上

低于该门槛的 checkpoint：

- 可以作为阶段性训练结果
- 可以作为 RTL/fixture 调试样本来源
- 但不得表述为“最终可交付 checkpoint”

---

## 3. 网络版本

checkpoint 在脚本中被强制校验为：

- `arch = soc6_lenet_int8_v1`
- `bias = false`

固定层结构：

`Input(28x28x1) -> Conv1(20, 5x5, valid) -> Pool1(2x2 max) -> requant INT8 -> Conv2(50, 5x5, valid) -> Pool2(2x2 max) -> requant INT8 -> FC1(800->500) -> ReLU -> requant INT8 -> FC2(500->10)`

这与：

- [docs/LENET_MNIST_SPEC.md](/root/Project_npu/docs/LENET_MNIST_SPEC.md)
- [datasets/scripts/train_lenet_mnist.py](/root/Project_npu/datasets/scripts/train_lenet_mnist.py)
- [datasets/scripts/generate_lenet_real_fixture.py](/root/Project_npu/datasets/scripts/generate_lenet_real_fixture.py)

保持一致。

---

## 4. 量化方法

### 3.1 输入图像

输入样本来自：

- [datasets/mnist/mnist.npz](/root/Project_npu/datasets/mnist/mnist.npz)

样本导出脚本：

- [datasets/scripts/export_mnist_samples.py](/root/Project_npu/datasets/scripts/export_mnist_samples.py)

输入量化规则：

- 原始像素：`UINT8`
- RTL 输入：`INT8`
- 转换公式：`int8_pixel = clamp(uint8_pixel - 128, -128, 127)`

### 3.2 权重量化

训练脚本中的权重量化规则在：

- [datasets/scripts/train_lenet_mnist.py](/root/Project_npu/datasets/scripts/train_lenet_mnist.py)

当前方法：

- `weight_scale = 32.0`
- 训练阶段使用 fake quant / STE
- 导出阶段执行：
  - `round(weight_scale * weight_fp)`
  - clamp 到 `[-128, 127]`
  - 存成 `torch.int8`

也就是说，交付给 RTL 的权重已经是离散 `INT8` 张量。

### 3.3 中间激活 requant

真实权重 golden 生成脚本中保留 3 处显式 `INT32 -> INT8` requant：

1. `Pool1 -> Conv2`
2. `Pool2 -> FC1`
3. `FC1(ReLU) -> FC2`

规则统一为：

- `acc * multiplier`
- `>>> shift`
- `round-half-away-from-zero`
- clamp 到 `[-128, 127]`

对应实现见：

- [datasets/scripts/generate_lenet_real_fixture.py](/root/Project_npu/datasets/scripts/generate_lenet_real_fixture.py)

当前正式基线：

- `requant_version = per_layer_i32_to_i8_v1`
- 粒度：每层一组参数
- 当前层名映射：
  - `conv2_in`
  - `fc1_in`
  - `fc2_in`
- 参数通过 checkpoint metadata / fixture summary / AXI-Lite 寄存器共同描述

---

## 4. 数据布局

固定布局与 RTL 规格一致：

- feature map layout：`HWC`
- conv weight layout：`[in_c][k_h][k_w][out_c]`
- conv 每个 `in_c` chunk 做 `32-bit` 对齐
- fc weight layout：`[out_neuron][in_neuron]`

### 4.1 Conv Weight Layout

转换函数：

- `conv_weight_bytes()` in [datasets/scripts/generate_lenet_real_fixture.py](/root/Project_npu/datasets/scripts/generate_lenet_real_fixture.py)

展开顺序：

1. 遍历 `ic`
2. 遍历 `kh`
3. 遍历 `kw`
4. 遍历 `oc`
5. 对每个 `ic` chunk 补零到 `4-byte` 对齐

### 4.2 FC Weight Layout

转换函数：

- `fc_weight_bytes()` in [datasets/scripts/generate_lenet_real_fixture.py](/root/Project_npu/datasets/scripts/generate_lenet_real_fixture.py)

展开顺序：

1. 遍历 `out_neuron`
2. 遍历 `in_neuron`

### 4.3 MEMH Packing

打包脚本：

- [datasets/scripts/pack_bytes_to_memh.py](/root/Project_npu/datasets/scripts/pack_bytes_to_memh.py)

规则：

- 4 个 byte 打成一个 `32-bit little-endian` word
- `word = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)`

---

## 5. 转换脚本入口

完整真实权重数据链入口如下：

### 5.1 导出 MNIST 样本

```bash
python3 datasets/scripts/export_mnist_samples.py \
  --input datasets/mnist/mnist.npz \
  --output-dir datasets/mnist/exports \
  --count 8
```

### 5.2 训练 spec-matching INT8-aware LeNet

```bash
python3 datasets/scripts/train_lenet_mnist.py \
  --input datasets/mnist/mnist.npz \
  --output datasets/mnist/models/mnist_lenet_soc6.pt
```

如果目标是完整测试集交付，而不是展示样本链路，训练完成后必须继续执行 software gate：

```bash
PYTHONPATH=datasets/scripts python3 datasets/scripts/eval_lenet_checkpoint.py \
  --checkpoint <candidate.pt> \
  --exports-dir datasets/mnist/exports_full \
  --exports-count 100
```

最低要求：

- `full_test_accuracy >= 0.80`
- 评估脚本输出中 `quality_gate_status` 必须为 `PASS`

在 software gate 未达到该门槛前，不应继续投入 full-set RTL 长跑。

### 5.3 在展示样本上微调 checkpoint

```bash
python3 datasets/scripts/fine_tune_lenet_fixture.py \
  --checkpoint datasets/mnist/models/mnist_lenet_soc6.pt \
  --exports-dir datasets/mnist/exports \
  --output datasets/mnist/models/mnist_lenet_soc6_fixture8.pt \
  --count 8
```

### 5.4 生成 real-weight RTL fixture

```bash
python3 datasets/scripts/generate_lenet_real_fixture.py \
  --checkpoint datasets/mnist/models/mnist_lenet_soc6_fixture8.pt \
  --exports-dir datasets/mnist/exports \
  --output-dir datasets/mnist/lenet_real_fixture \
  --count 8
```

---

## 6. 与 RTL 地址图的对应关系

地址常量来自：

- [docs/LENET_MNIST_SPEC.md](/root/Project_npu/docs/LENET_MNIST_SPEC.md)
- [datasets/scripts/generate_lenet_fixture.py](/root/Project_npu/datasets/scripts/generate_lenet_fixture.py)
- [tb/integration/tb_top_lenet.v](/root/Project_npu/tb/integration/tb_top_lenet.v)

固定对应关系如下：

| 数据 | Base Address | 生成文件 |
| --- | --- | --- |
| Input image | `0x0000_0100` | `sample_xxx/input.memh` |
| Conv1 weights | `0x0000_1000` | `weights/conv1_weights.memh` |
| Conv1 output / Pool1 input | `0x0000_4000` | `sample_xxx/conv1_out.memh` |
| Pool1 output | `0x0001_8000` | `sample_xxx/pool1_out.memh` |
| Conv2 INT8 input | `0x0001_C000` | `sample_xxx/conv2_input.memh` |
| Conv2 weights | `0x0002_0000` | `weights/conv2_weights.memh` |
| Conv2 output / Pool2 input | `0x0006_0000` | `sample_xxx/conv2_out.memh` |
| Pool2 output / FC1 input | `0x0008_0000` | `sample_xxx/pool2_out.memh` |
| FC1 weights | `0x0009_0000` | `weights/fc1_weights.memh` |
| FC1 output / FC2 input | `0x000F_2000` | `sample_xxx/fc1_out.memh` |
| FC2 weights | `0x000F_3000` | `weights/fc2_weights.memh` |
| Final logits | `0x000F_5000` | `sample_xxx/fc2_logits.memh` |

说明：

- `conv2_input.memh` 是 `Pool1` 输出经 `INT32 -> INT8` 饱和转换后的 preload 文件
- `fc1_out.memh` 保存的是 `FC1 + ReLU` 后的 `INT32` 输出
- `argmax.txt` 由 testbench / 软件侧读取 `fc2_logits` 后做最终分类验证

---

## 7. 当前交付边界

当前可以严格成立的说法：

1. `lenet_real_fixture` 使用真实训练得到的 `INT8` checkpoint，而不是 deterministic 构造权重
2. 真实权重布局、量化规则、脚本入口、RTL 地址图已在文档和脚本中对齐
3. `top` 层与 `npu_top + axi4_ram` 层都可以消费这套 real-weight fixture
4. 完整测试集交付模型必须先通过 software accuracy gate，再进入 full-set RTL

当前不应过度表述的说法：

1. 不能把 `fixture8` 微调 checkpoint 表述成“完整 MNIST 全量最优模型”
2. 不能把 real-weight 8-sample PASS 直接表述成全测试集精度结论
3. 不能把 software full-test accuracy 低于 `80%` 的 checkpoint 写成“最终可交付模型”
