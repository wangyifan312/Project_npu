# Requantization Upgrade Plan

本文件定义 `Project_npu` 从当前“direct saturate”中间激活语义，升级到**通用 requant 语义**的实施基线。

目标不是为 `LeNet` 写特判，而是建立一套可复用于其他 `Conv / Pool / ReLU / FC` 组合网络的层间量化规则。

---

## 1. 为什么需要这次改造

当前仓库已经确认：

- 浮点 software 的 spec-matching `LeNet(MNIST)` 可达到接近 `99%` 的 test accuracy
- 当前 RTL 匹配量化语义下，最佳候选 checkpoint 仅达到：
  - software full-test `70.52%`
  - software / RTL 100-sample `67%`
  - software / RTL 预测逐样本一致

这说明：

1. 网络结构本身不是瓶颈
2. RTL 推理链路不是主精度损失来源
3. 主要限制来自当前中间激活语义：
   - `INT32 accumulate -> direct saturating INT8`
   - 中间 feature map 大量饱和

因此，如果完整 `MNIST test set` accuracy `>= 80%` 是硬门槛，则必须优先审视并升级 requant 语义。

---

## 2. 当前语义（已实现）

当前仓库的正式实现与文档基线是：

- activation：`INT8`
- weight：`INT8`
- accumulate：`INT32`
- 下一层若仍要求 `INT8` 输入，则执行：
  - `round`
  - saturating clamp 到 `[-128, 127]`

当前显式存在的边界包括：

1. `Pool1 INT32 -> Conv2 INT8`
2. `Pool2 INT32 -> FC1 INT8`
3. `FC1(ReLU) INT32 -> FC2 INT8`

这套语义已经被：

- RTL
- 训练脚本中的硬件匹配 forward
- fixture / golden 生成脚本

共同使用，因此它是一个**完整但过于粗糙的量化基线**。

---

## 3. 目标语义（本轮计划）

本轮目标不是继续 direct saturate，而是切换到正式 requant：

```text
INT32 accumulate
-> multiply by layer-wise multiplier
-> arithmetic right shift
-> round to nearest
-> clamp to INT8
```

### 3.1 目标公式

统一要求实现：

```text
q = clamp( round( (acc * multiplier) >>> shift ), -128, 127 )
```

约束：

- `acc`：signed `INT32`
- `multiplier`：每层一组参数
- `shift`：每层一组参数
- rounding 规则必须在 RTL / Python / fixture 中完全一致
- 第一版保持**对称量化**
- 第一版不引入 zero-point

### 3.2 适用范围

该 requant 语义不是按网络层名硬编码，而是按**类型边界**应用：

- 任何 `INT32 feature / activation` 回到下一层 `INT8 activation` 的边界

这意味着：

- 当前 LeNet 的 3 个边界会用到
- 未来其他依赖 `Conv / Pool / ReLU / FC` 的小型 CNN，只要仍有 `INT32 -> INT8` handoff，也可以复用

---

## 4. 方案决策（已锁定）

后续实现已锁定以下决策：

1. **粒度**
   - 每层一组 requant 参数
   - 不是全局固定参数
   - 不是 per-channel 参数

2. **配置方式**
   - 通过 `npu_ctrl` / 寄存器可配置
   - 不依赖 fixture 隐式推导

3. **算术形式**
   - 使用 `multiplier + shift`
   - 不是仅右移的简化方案

4. **兼容策略**
   - 直接切换到新语义
   - 不保留旧 direct-saturate 兼容模式

这意味着：

- 旧 checkpoint / fixture / golden 不能再直接当最终基线
- 必须重新训练或重新导出与新语义匹配的 candidate checkpoint

---

## 5. 对现有架构的影响

## 5.1 不会推翻的部分

这次改造不会推翻以下主结构：

- `CPU + NPU + shared memory`
- `6-cluster` compute hierarchy
- `DMA`
- `block_scheduler`
- `conv_frontend`
- `postproc` 的 `INT32` 域 ReLU / Pool 职责

所以这不是 SoC 大架构重做，而是**数值语义升级**。

## 5.2 会显著变化的部分

### RTL

需要改：

- `npu_top` 中所有 `INT32 -> INT8` handoff
- FC 前输入读取路径
- Pool / FC 层间转换路径
- `npu_ctrl` 寄存器映射
- 如需要，`task_checker` 的 requant 参数合法性检查

### 软件

需要改：

- `train_lenet_mnist.py`
- `eval_lenet_checkpoint.py`
- `generate_lenet_real_fixture.py`

要求：

- 所有 software full-test / fixture / golden 都使用与 RTL 一致的 requant

### 文档

需要同步更新：

- `LENET_MNIST_SPEC.md`
- `REAL_WEIGHT_FLOW.md`
- `MNIST_FULL_EVAL_PLAN.md`
- 任何使用旧 direct-saturate 口径的材料

---

## 6. 实现边界建议

为了控制风险，建议按以下边界实现：

### 6.1 新增独立 requant 单元

新增一个可复用 RTL 模块，例如：

- `rtl/npu/requant_i32_to_i8.v`

职责：

- 输入：`INT32 acc`
- 配置：`multiplier`, `shift`
- 输出：`INT8`
- 内含：
  - signed multiply
  - arithmetic shift
  - rounding
  - clamp

### 6.2 `postproc` 不内嵌 requant

第一版不要把 requant 混进 Pool 内部状态机。  
建议边界保持为：

- `postproc`：负责 `INT32` 域 `ReLU / Pool`
- `requant`：负责层间精度变换

### 6.3 先保留 LeNet 驱动链，但实现本身必须是通用的

第一版 testbench 可以先只在 LeNet 下配置：

- `rq_conv2_in_multiplier / shift`
- `rq_fc1_in_multiplier / shift`
- `rq_fc2_in_multiplier / shift`

但实现本身必须是可复用于未来网络的通用层间语义。

---

## 7. 与训练/交付流程的关系

后续完整流程必须变成：

1. 完成 RTL requant 语义改造
2. 同步软件训练 / 评估 / fixture 生成
3. 重新训练多个 candidate checkpoint
4. 先做 software full-test gate
5. 只有 software full-test `>= 80%`，才恢复 full-set RTL

不允许再走：

- 旧 direct-saturate checkpoint
- 在 software gate 未通过时继续 full 10000 RTL

---

## 8. 验收标准

requant 改造完成后，必须同时满足：

1. 文档、RTL、software、fixture 使用同一 requant 语义
2. 不再存在 direct-saturate 残留路径作为正式基线
3. software full-test accuracy 至少达到 `80%`
4. subsystem 小批量 RTL 与 software 逐样本一致
5. full-set RTL 仅在 software gate 通过后恢复

---

## 9. 当前阶段的正式结论

在本文件落地时，当前仓库状态应明确表述为：

- 现有 direct-saturate 语义可用于：
  - LeNet 小批量 RTL/SoC 正确性验证
  - 调试与展示链路
- 但它**不应再作为完整 `MNIST test set` 最终交付的数值语义基线**
- 若 `>= 80%` 是最终门槛，则 requant 升级是当前最高优先级问题之一
