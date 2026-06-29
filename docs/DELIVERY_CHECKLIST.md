# Final Delivery Checklist

本文件定义 `Project_npu` 面向**赛题最终提交 / 答辩交付**的最小收尾清单。

目标不是判断“工程上是否已经能跑”，而是判断：

- 是否已经具备可展示、可解释、可复现的 SoC 级证据链
- 是否已经具备真实网络、真实性能、真实验证边界的答辩材料

---

## 1. 完成判定

只有当以下 5 条**必做项**全部完成，才建议将当前仓库视为：

- 可用于赛题最终提交
- 可用于答辩正式展示

必做项：

1. `top` 级 real-weight 多样本回归
2. `top` 级至少一组非 single-cluster 模式证据
3. 正式性能结论表
4. 真实权重说明文档
5. 固定答辩回归入口

如果只完成其中一部分，则最多只能称为：

- 阶段性交付
- 工程可运行版本

不得直接表述为“赛题最终交付完成”。

补充说明：

- 上述 5 条必做项定义的是**当前仓库达到赛题答辩展示标准**的最小门槛
- 如果赛题明确要求**完整测试集结果**，则除本清单外，还必须继续执行：
  - [MNIST_FULL_EVAL_PLAN.md](MNIST_FULL_EVAL_PLAN.md)
- 如果完整测试集 software gate 长期低于 `80%`，则还必须继续执行：
  - [REQUANTIZATION_PLAN.md](REQUANTIZATION_PLAN.md)
- 也就是说：
  - `8` 样本或小批量 real-weight 回归可证明推理链路与 SoC 闭环
  - 但不能替代完整 `MNIST test set` 结果
  - 如果答辩或交付材料要明确宣称“标准 AXI4 / AXI-Lite 兼容”，则还必须继续执行：
    - [AXI_COMPLIANCE_SPEC.md](AXI_COMPLIANCE_SPEC.md)
    - [AXI_COMPLIANCE_EXECUTION_CHECKLIST.md](AXI_COMPLIANCE_EXECUTION_CHECKLIST.md)

---

## 2. 必做项

## 2.1 `top` 级 real-weight 多样本回归

### 目标

不再只停留于：

- deterministic fixture
- subsystem 级多样本
- `top` 级 single sample

而是要求在 `top` 层完成**真实权重 + 真实 MNIST 样本**的小批量回归。

### 最低要求

- 至少 `8` 个真实 `MNIST` 样本
- 在 `top` 层执行完整 LeNet：
  - `Conv1`
  - `Pool1`
  - `Conv2`
  - `Pool2`
  - `FC1`
  - `FC2`
  - `Argmax`

### 验收标准

- 每个样本都输出：
  - sample name / label
  - predicted class
  - expected class
  - PASS / FAIL
- 最终输出总通过数，例如：
  - `8/8 PASS`
  - 或 `15/16 PASS`

### 推荐证据

- `tb_top_lenet` 或等价 `top` 级 testbench 日志
- 汇总表格
- 可复现运行命令

### 口径限制

即使本项完成，也只能说明：

- `top` 级真实权重闭环已成立
- 小批量真实样本回归已成立

不能自动推出：

- 完整 `MNIST test set` 已跑完
- 全量测试集 accuracy 已得出

---

## 2.2 `top` 级非 single-cluster 模式证据

### 目标

当前仓库已明确：

- compute-core / cluster-level 已覆盖：
  - `single`
  - `dual`
  - `full`
  - `dynamic mask`
- 但 `top` 级目前仍主要是：
  - `single-cluster compatibility mode`

最终答辩前，必须至少补一组 `top` 级非 single-cluster 证据。

### 最低要求

至少补以下之一：

- `dual-cluster` top-level 运行结果
- `full-cluster` top-level 运行结果

### 验收标准

日志里必须明确看到：

- `cluster_cfg`
- `cycle count`
- `mac count`
- `utilization`
- 功能正确性结果

### 推荐证据

- `single-cluster` vs `dual/full-cluster` 的对比表
- `top` 级 testbench 输出日志

---

## 2.3 正式性能结论表

### 目标

将目前分散在 testbench / perf counter / 模式测试中的性能结果，整理成答辩可直接展示的正式表格。

### 最低要求

必须包含：

1. 理论峰值
   - `0.6144 TOPS @ 200MHz`
2. compute-core 级 cluster 模式对比
   - `single`
   - `dual`
   - `full`
   - `dynamic mask`
3. `top` 级 LeNet 分层性能
   - `Conv1`
   - `Conv2`
   - `FC1`
   - `FC2`

### 每项至少给出

- `MAC count`
- `cycle count`
- `array / cluster utilization`

### 强制说明

性能表中必须明确区分：

- **理论值**
- **compute-core / cluster-level 测得结果**
- **SoC top-level 测得结果**

不得混写。

### 推荐证据

- markdown 表格
- 附带生成这些表格的日志来源

---

## 2.4 真实权重说明文档

### 目标

保证答辩时可以解释：

- 真实 LeNet 权重从哪里来
- 如何量化
- 如何导入 RTL
- 如何和当前地址图 / 布局对应

### 最低要求

文档中至少写清楚：

1. 权重来源
   - 训练来源 / checkpoint 来源
2. 网络版本
   - LeNet(MNIST) 的具体层结构
3. 量化方法
   - 浮点到 `INT8` 的策略
4. 数据布局
   - conv weight layout
   - fc weight layout
5. 转换脚本入口
6. 与 RTL 内存地址图的对应关系

### 推荐落点

- `docs/LENET_MNIST_SPEC.md`
- 或单独新增 `docs/REAL_WEIGHT_FLOW.md`

---

## 2.5 固定答辩回归入口

### 目标

冻结一组“可直接复现”的命令，答辩时可直接运行或展示。

### 最低要求

至少固定以下 4 类回归入口：

1. deterministic quick regression
2. real-weight subsystem regression
3. real-weight top regression
4. perf mode regression

### 每条命令需要说明

- 用途
- 所处验证层级
  - subsystem
  - top
  - compute-core
- 预期输出

### 推荐落点

- `README.md`
- 或单独新增 `docs/RUNBOOK.md`

---

## 3. 强烈建议项

## 3.1 `top` 级准确率小结

### 目标

不要只展示“能跑通”，还应展示一组小规模准确率。

### 建议

- 至少 `8` 个样本
- 更好为 `16` 个样本

### 输出建议

- `correct / total`
- `accuracy`

---

## 3.2 SoC / subsystem 验证边界说明

### 目标

避免答辩时被问到“这个结果到底是在 NPU 子系统还是在完整 SoC 顶层得到的”。

### 文档中建议明确写出

- 哪些结果来自：
  - `npu_top + axi4_ram`
- 哪些结果来自：
  - `top`
- 哪些 cluster 模式只在 compute-core 级覆盖
- 哪些 cluster 模式已经在 `top` 级覆盖

---

## 4. 可选加分项

## 4.1 一页式架构图

建议包含：

- CPU
- AXI-Lite
- shared memory
- NPU orchestration
- single-cluster compute core
- postproc
- perf counter

## 4.2 一页式性能摘要

建议包含：

- 峰值 TOPS
- cluster 模式表
- LeNet 分层 cycles / util
- 当前 `top` 级覆盖边界

---

## 5. 当前最小收尾优先级

如果时间有限，建议优先按以下顺序推进：

1. `top` 级 real-weight 多样本回归
2. `top` 级非 single-cluster 模式证据
3. 正式性能结论表
4. 真实权重说明文档
5. 固定答辩回归入口

如果赛题明确要求完整测试集结果，则在完成上述 5 项后，继续按以下顺序推进：

1. 执行 [MNIST_FULL_EVAL_PLAN.md](MNIST_FULL_EVAL_PLAN.md)
2. 先确认 software full-set 主证据
3. 再补 RTL subsystem representative chunk evidence
4. 视仿真成本再推进 `top` 级大批量或完整测试集
5. 输出正式 accuracy / cycles / perf 统计与引用边界

当前 W3 收口状态：

- software full-set 是当前最终全量准确率主证据
  - 文件：`results/mnist_lenet_soc6_requant_candidate_final_eval.json`
  - 结果：`9885/10000 = 98.85%`
  - 已超过 `80%` gate
- RTL subsystem 采用 representative chunk evidence 口径收口
  - 结果目录：`results/w3_subsystem_full_10000_candidate_final_chunked/merged/`
  - 完整 merged chunk：`12`
  - 正式 merged 样本窗口：`3000/10000`
  - `summary.json` 口径：`2944/3000 = 98.1333%`
  - 停止时 write-out 观测值：`3000/3057 = 98.1354%`
- `chunk_03000_03249` 是 partial chunk，没有 `summary.json / finished_at.txt`，不计入正式 merged
- observed fail 需要区分模型错分与 RTL/software 偏差，不能默认视为 RTL 回归
- 完整 RTL `10000/10000` full-set 因仿真成本过高，降级为后续增强项，不作为当前 W3 关闭阻塞项

---

## 6. 一句话结论

只有当：

- `top` 级真实样本回归
- `top` 级非单 cluster 证据
- 正式性能表
- 真实权重说明
- 固定回归入口

这五条全部完成时，才建议将当前仓库对外表述为：

**“满足赛题最终提交 / 答辩交付要求的版本。”**

如果赛题书面要求包含**完整测试集结果**，则还必须额外满足：

- 已按 [MNIST_FULL_EVAL_PLAN.md](MNIST_FULL_EVAL_PLAN.md) 跑出完整测试集结论；当前以 software full-set 作为全量 accuracy 主证据，并以 RTL representative chunks 作为硬件侧代表性证据
- 完整 `MNIST test set` software accuracy 必须达到 `80%` 及以上

否则只能表述为：

- 已满足答辩展示级交付
- 但尚未完成完整测试集结果交付
