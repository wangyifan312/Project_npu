# MNIST Assets

本目录保存当前 `LeNet(MNIST)` 交付链所需的原始数据、checkpoint、导出样本和 real-weight fixture。

## 当前正式资产

- 原始数据：
  - [mnist.npz](/root/Project_npu/datasets/mnist/mnist.npz)
- 导出样本：
  - [exports/manifest.json](/root/Project_npu/datasets/mnist/exports/manifest.json)
- deterministic fixture：
  - [lenet_fixture/manifest.json](/root/Project_npu/datasets/mnist/lenet_fixture/manifest.json)
- real-weight fixture：
  - [lenet_real_fixture/manifest.json](/root/Project_npu/datasets/mnist/lenet_real_fixture/manifest.json)
- requant candidate fixture：
  - [lenet_requant_candidate_final_fixture/manifest.json](/root/Project_npu/datasets/mnist/lenet_requant_candidate_final_fixture/manifest.json)
- checkpoint：
  - [models/mnist_lenet_soc6.pt](/root/Project_npu/datasets/mnist/models/mnist_lenet_soc6.pt)
  - [models/mnist_lenet_soc6_fixture8.pt](/root/Project_npu/datasets/mnist/models/mnist_lenet_soc6_fixture8.pt)
  - [models/mnist_lenet_soc6_requant_candidate_final.pt](/root/Project_npu/datasets/mnist/models/mnist_lenet_soc6_requant_candidate_final.pt)

## 当前说明

- `mnist_lenet_soc6_fixture8.pt`：
  - 旧展示 / 抽样回归 checkpoint
  - 对应 `lenet_real_fixture`
- `mnist_lenet_soc6_requant_candidate_final.pt`：
  - 当前正式 requant 候选 checkpoint
  - software full-test accuracy gate 已通过
  - 后续 RTL sanity 应优先围绕该 checkpoint

## 当前答辩/交付链路

1. 从 `mnist.npz` 导出样本
2. 训练 / 微调 spec-matching `INT8` LeNet checkpoint
3. 生成历史展示链 `lenet_real_fixture` 或新 requant 链 `lenet_requant_candidate_final_fixture`
4. 用 `npu_top` 或 `top` testbench 读取这些 `memh / preload_map / golden`

## 统一说明文档

- 网络规格与地址图：
  - [docs/LENET_MNIST_SPEC.md](/root/Project_npu/docs/LENET_MNIST_SPEC.md)
- 真实权重流：
  - [docs/REAL_WEIGHT_FLOW.md](/root/Project_npu/docs/REAL_WEIGHT_FLOW.md)

## 说明

- 当前仓库不再使用“FC 未支持”或“只建议 Conv-only”作为正式口径
- 当前 `LeNet(MNIST)` 已有 deterministic / real-weight / top-level 回归链
