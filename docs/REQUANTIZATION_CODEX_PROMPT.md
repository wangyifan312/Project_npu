# Requantization Implementation Prompt

将以下内容直接发给新的 Codex / Claude Code 会话：

```text
请接手 `/root/Project_npu` 的下一阶段工作。

当前目标不是继续训练旧 direct-saturate 模型，也不是继续 full-set RTL 长跑，而是：

**实现通用 requant 量化语义，并用它重新建立 software / fixture / RTL 的一致基线。**

先完整阅读以下文档：
1. /root/Project_npu/README.md
2. /root/Project_npu/CLAUDE.md
3. /root/Project_npu/docs/DELIVERY_CHECKLIST.md
4. /root/Project_npu/docs/MNIST_FULL_EVAL_PLAN.md
5. /root/Project_npu/docs/REAL_WEIGHT_FLOW.md
6. /root/Project_npu/docs/REQUANTIZATION_PLAN.md
7. /root/Project_npu/docs/RTL_DEBUG_PLAYBOOK.md

当前必须接受的事实：
- 当前 direct-saturate 语义下，software 最好候选 full-test accuracy 只有 70.52%
- software / RTL 小批量结果一致，说明主问题不在硬件掉点
- 浮点软件上限接近 99%，说明网络结构本身不是瓶颈
- 当前 full-test 精度瓶颈已经被归因到中间层缺少正式 requant 语义
- 如果完整 `MNIST test set` accuracy `>= 80%` 是最终门槛，则 requant 升级是当前最高优先级问题之一

本轮唯一目标：

**按 `docs/REQUANTIZATION_PLAN.md` 实现通用 requant 语义。**

硬性约束：
1. 不是给 LeNet 写特判。
2. requant 必须是通用 `INT32 -> INT8` handoff 机制。
3. 粒度固定为：每层一组参数。
4. 参数入口固定为：`npu_ctrl` / AXI-Lite 寄存器可配置。
5. 算术固定为：`multiplier + shift + rounding + clamp`。
6. 兼容策略固定为：直接切换新语义，不保留旧 direct-saturate 兼容模式。
7. 不要推翻 `CPU + NPU + shared memory + 6-cluster` 主架构。
8. 不要在 software gate 未通过前恢复 full-set RTL。

建议执行顺序：

## Phase Q1 — RTL requant 基础设施
实现：
- 新增独立 `requant_i32_to_i8` 单元
- 扩展 `npu_ctrl` 寄存器接口，支持 layer-wise requant 参数
- 在 `npu_top` 中替换所有正式 `INT32 -> INT8` handoff

至少覆盖：
- `Pool1 -> Conv2`
- `Pool2 -> FC1`
- `FC1 -> FC2`
- FC 前输入路径中现有 direct `sat_i32_to_i8`

要求：
- `postproc` 保持 `INT32` 域职责，不把 requant 混进 Pool 状态机
- testbench 可通过寄存器写入 requant 参数

## Phase Q2 — 软件训练 / 评估 / fixture 同步
同步修改：
- `datasets/scripts/train_lenet_mnist.py`
- `datasets/scripts/eval_lenet_checkpoint.py`
- `datasets/scripts/generate_lenet_real_fixture.py`

要求：
- software 训练 forward 和 reloaded quantized checkpoint 评估都使用与 RTL 一致的 requant
- fixture / golden 使用相同 requant 规则
- metadata / sidecar 记录 requant 版本和参数

## Phase Q3 — 软件 gate
重新训练多个 candidate checkpoint。

要求：
- 不要只训一个候选
- 至少输出：
  - full-test accuracy
  - 100-sample accuracy
  - reloaded quantized checkpoint accuracy
  - candidate 参数摘要

只有当 software full-test `>= 80%` 时，才进入下一阶段。

## Phase Q4 — 小批量 RTL sanity
在 software gate 通过后：
- 先跑 subsystem 小批量 accuracy-only
- 再做 software / RTL 逐样本对比
- 必要时再跑 top 小批量

不要直接恢复 full 10000 RTL。

开始工作前，先输出：
1. 你对 requant 改造目标的理解
2. 你准备先改哪些 RTL 模块
3. 你准备如何定义 rounding 规则并保持 Python / RTL 一致
4. 你准备如何设计 requant 寄存器接口
5. 你准备如何证明它不是 LeNet 特判

每完成一个阶段，必须输出：
- 当前阶段
- 修改摘要
- 修改文件列表
- 新增/修改的测试
- 运行命令
- 结果
- 是否达到该阶段目标
- 残留风险

停止条件：
- software full-test `>= 80%` 的新语义 candidate checkpoint 已得到
- 或明确证明当前 requant 方案仍不能满足 gate，并给出 blocker

特别注意：
- 不要继续把旧 direct-saturate checkpoint 当最终基线
- 不要在 software gate 未通过前恢复 full-set RTL
- 所有结论必须基于实际训练/评估/回归结果
```
