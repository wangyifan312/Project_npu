# MNIST Full-Test Evaluation Plan

本文件定义 `Project_npu` 在**赛题要求完整测试集结果**时的执行方案。

目标不是只证明：

- SoC 已具备推理能力
- 真实权重 + 真实样本子集已经打通

而是进一步给出：

- 完整 `MNIST test set` 的推理结果
- 可复现的准确率统计
- 对应的性能统计结果

---

## 1. 当前已完成状态

当前仓库已经完成：

- deterministic fixture 回归
- real-weight fixture 小批量回归
- `npu_top + axi4_ram` subsystem 级 `8` 样本 real-weight 回归
- `top` 层 `8` 样本 real-weight 回归
- candidate-final software full-set
  - `results/mnist_lenet_soc6_requant_candidate_final_eval.json`
  - `9885/10000 = 98.85%`
- RTL subsystem representative chunk evidence
  - `results/w3_subsystem_full_10000_candidate_final_chunked/merged/`
  - 完整 merged chunk：`12`
  - 正式 merged 样本窗口：`3000/10000`
  - `summary.json` 口径：`2944/3000 = 98.1333%`
  - 停止时 write-out 观测值：`3000/3057 = 98.1354%`

这证明：

- 推理链路已闭环
- 真实样本与真实权重链路已打通
- `LeNet(MNIST)` 在 subsystem 和 `top` 两层都已可运行
- 当前 software full-set 已形成最终全量 accuracy 主证据
- 当前 RTL 侧已形成 representative full-set chunk evidence

但这**不等于**：

- RTL 已经完整跑完 `10000/10000`
- top-level 已经完整跑完 `10000/10000`
- RTL representative chunks 可以被包装成完整 RTL full-set 结果

当前 W3 关闭口径：

- software full-set 是最终全量准确率主证据
- RTL subsystem full-set 因仿真成本过高，采用 representative chunk evidence 收口
- `chunk_03000_03249` 是 partial chunk，没有 `summary.json / finished_at.txt`，不计入正式 merged
- observed fail 需要区分模型错分与 RTL/software 偏差，不能默认视为 RTL 回归
- 完整 RTL `10000/10000` full-set 降级为后续增强项，不作为当前 W3 关闭阻塞项

---

## 2. 最终目标

如果赛题要求“完整测试集结果”，则必须至少输出：

1. 全量 `MNIST test set` 总样本数
2. 正确数
3. 准确率
4. 总周期数
5. 平均每样本周期数
6. 必要的性能统计（至少 subsystem 级）

推荐同时输出：

7. 总 `MAC count`
8. 平均 `MAC / sample`
9. 平均阵列利用率
10. 必要的 AXI 读写统计

并且必须满足一个强制 accuracy gate：

11. 完整 `MNIST test set` accuracy 必须达到 `80%` 及以上

说明：

- `80%` 以下的 full-test 结果可以作为阶段性测量、调试结果或 checkpoint 筛选结果
- 但不得表述为“完整测试集结果交付完成”
- 如果在 software full-test 下长期低于 `80%`，且 software / RTL 小批量预测一致，则默认应优先转入 [REQUANTIZATION_PLAN.md](REQUANTIZATION_PLAN.md) 所定义的数值语义升级，而不是继续盲跑 full-set RTL

---

## 3. 总体策略

不要一开始就直接把 `10000` 个样本全部压到 `top` 层仿真上。

### 3.0 accuracy-only full-eval 前提

Phase 1.5 已确认：

- subsystem 默认 perf-heavy 路径的主 blocker 是层后 `report_perf()` 读寄存器
- 不是 RTL 主计算错误
- 不是 golden compare 主瓶颈
- 不是 fixture I/O 主瓶颈

因此 full-set accuracy 必须优先走 `accuracy-only` 模式：

- `EVAL_MODE=1`
- `SKIP_PERF_READS=1`
- `PROGRESS=0`
- `VERBOSE_LIMIT=0`

这条路径保留：

- 最终 `predicted / expected / PASS/FAIL`
- `total_cycles`
- `total_mac`

这条路径不保留：

- per-layer perf 寄存器读数
- `read/write beats`
- array / cluster utilization

推荐分两层执行：

### 3.1 subsystem 级全量回归

目的：

- 获取完整测试集准确率
- 获取完整测试集主性能统计
- 作为最终提交结果的主数据来源

执行层级：

- `npu_top + axi4_ram`

### 3.2 `top` 级大批量或全量回归

目的：

- 证明共享内存、AXI-Lite、结果回读在 SoC 顶层真实成立
- 作为顶层系统闭环证据

执行层级：

- `top`

推荐优先级：

1. subsystem 级先跑全量 `10000`
2. `top` 级先跑大批量（如 `100` / `1000`）
3. 如果仿真时间允许，再扩到 `top` 级全量 `10000`

---

## 4. fixture 生成策略

## 4.1 不建议一开始就为 10000 样本生成完整逐层 memh

因为完整逐层 fixture 会显著增加：

- 生成时间
- 磁盘占用
- 仿真准备时间

## 4.2 推荐拆成两种模式

### A. manifest-only

只生成：

- 样本索引
- 标签
- 输入路径
- 预期分类
- 必要 meta

适合：

- 全量 `10000` 样本批处理
- 准确率统计

### B. full-fixture

生成完整层级文件：

- `input.memh`
- `conv1_out.memh`
- `pool1_out.memh`
- `conv2_input.memh`
- `conv2_out.memh`
- `pool2_out.memh`
- `fc1_out.memh`
- `fc2_logits.memh`
- `argmax.txt`
- `summary.json`

适合：

- 小批量抽样对拍
- debug
- 答辩展示

---

## 5. 推荐修改点

## 5.1 数据脚本

优先扩展：

- `datasets/scripts/generate_lenet_real_fixture.py`

建议支持：

- `--count`
- `--offset`
- `--manifest-only`
- `--full-fixture`
- `--batch-size`

## 5.2 subsystem 回归脚本

扩展：

- `sim/run_lenet_fixture.sh`

建议支持：

- `sample`
- `batch`
- `all`
- `--count`
- `--offset`
- `--manifest`

## 5.3 `top` 回归脚本

扩展：

- `sim/run_top_lenet.sh`

建议支持：

- `sample`
- `batch`
- `all`
- `--count`
- `--offset`
- `--manifest`

---

## 6. 执行顺序

## Step 1：扩展 fixture 生成模式

先让 real-weight fixture 具备：

- 全量 manifest
- 可选 full fixture
- 可按 count/offset 切片导出

## Step 2：先跑 subsystem 级试运行

建议：

- 先跑 `100` 样本
- 检查：
  - 运行时间
- 日志规模
- 统计格式

当前已完成的正式结果：

- `results/mnist_full_subsystem_100_accuracy_only/summary.json`
- `target_total = 100`
- `correct = 37`
- `accuracy = 0.37`
- `total_cycles = 85,837,000`
- `avg_cycles = 858,370`
- `total_mac = 229,300,000`
- `avg_mac = 2,293,000`

说明：

- 当前 checkpoint 是 `fixture8` 微调模型，不应把该 `37%` 结果表述成最终可提交的 MNIST 精度结论
- 该结果证明 `accuracy-only` full-eval 路径已正式可用

## Step 3：跑 subsystem 级全量 `10000`

输出：

- total
- correct
- accuracy
- total cycles
- avg cycles/sample
- total MAC
- avg MAC/sample

现实执行前应先接受一个事实：

- 按 `100` 样本正式回归的 wall-clock 粗估，`10000` 样本大约需要 `30` 小时量级
- 因此 `10000` 更适合作为长跑任务，不适合作为当前轮交互式立即闭环目标

这是最终完整测试集结果的主来源。

额外验收门槛：

- 完整 `MNIST test set` accuracy `>= 80%`
- 如果未达到该门槛，应先回到 software checkpoint / training quality gate，而不是继续消耗 RTL full-set 长跑时间

## Step 4：跑 `top` 级大批量

建议先跑：

- `100`

如果仿真时间可接受，再扩到：

- `1000`
- 或 `10000`

## Step 5：汇总正式结果

建议生成：

- `summary.json`
- `per_sample.csv`
- `perf_summary.md`

---

## 7. 输出文件建议

建议统一输出到：

- `results/mnist_full_subsystem/`
- `results/mnist_full_top/`

每次回归至少生成：

### `summary.json`

包含：

- total
- correct
- accuracy
- total_cycles
- avg_cycles
- total_mac
- avg_mac

### `per_sample.csv`

包含：

- sample_name
- label
- predicted
- pass_fail
- cycles

### `perf_summary.md`

包含：

- 统计摘要
- 关键性能指标
- 必要的文字说明

---

## 8. 日志策略

全量运行时不要为每个样本打印过多分层日志。

建议：

- 默认逐样本输出：
  - sample
  - predicted
  - expected
  - PASS/FAIL
- 分层详细性能：
  - 只对前 `1~5` 个样本输出
  - 后续只做累计统计

---

## 9. 交付口径建议

### 9.1 最理想

- subsystem：`10000` / `10000`
- `top`：`10000` / `10000`

### 9.2 更现实且通常足够答辩

- software：完整测试集 `10000`
- subsystem RTL：representative full-set chunks
- `top`：大批量 `100` 或 `1000`
- 文档中明确写出 subsystem / top 层级差异

当前 W3 已采用该口径收口：

- software full-set：`9885/10000 = 98.85%`
- RTL subsystem representative chunk evidence：正式 merged `3000/10000` 样本窗口，`summary.json` 为 `2944/3000 = 98.1333%`
- 停止时 write-out 观测值：`3000/3057 = 98.1354%`，partial chunk 不计入正式 merged
- 完整 RTL `10000/10000` 可作为后续增强项继续执行，但不是当前 W3 关闭阻塞项

### 9.3 不允许的表述

如果只跑了：

- `8` 样本
- `100` 样本
- `1000` 样本
- partial chunk

则不得写成：

- “完整 MNIST 测试集结果”
- “全量测试集准确率”
- “完整 RTL full-set 已完成”

---

## 10. 一句话结论

如果赛题要求完整测试集结果，正确做法是：

**以 software full-set 固定最终全量准确率，再用 RTL subsystem representative chunks 和 `top` 级大批量/全量回归补齐硬件侧证据链。**
