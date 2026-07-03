# Next Task Worklist

本文档用于固定 `Project_npu` 当前主线之后的后续工单顺序、执行规则和每轮汇报模板。

目的不是重复历史规划，而是避免后续会话变长后出现：

- 工单顺序漂移
- 验收口径变化
- 把已完成事项重新当作未完成事项
- 把 legacy/debug 结果混入正式证据

---

## 1. 当前基线

当前仓库已经确认：

- `HB1`：完成
- `HB2`：按当前边界完成
- `AXI-1`：完成
- `AXI-2`：完成
- `AXI-3`：完成
- `AXI-4`：完成

当前已经成立的正式基线：

- `top/subsystem` 的 single-cluster 功能回归成立
- `top16/top32/subsystem8` performance replay 成立
- 协议级 `AXI-Lite` / `AXI4 INCR burst` 子集测试成立
- shared memory 正式口径为 `32768 x 256-bit beat`
- CPU 控制面为 `32-bit AXI-Lite`
- NPU DMA 数据面为 `256-bit AXI4 burst`

当前已知后续增强项：

- 正式 coverage 报告
- FPGA / 综合交付材料
- 最终答辩/交付文档固化

当前统一口径：

- `W1/W2/W3` 已完成并可关闭。
- `W4/W5/W6` 保留为后续增强项。
- 当前不默认继续执行 W4/W5/W6；如需推进，必须重新显式立项并确认目标、资源和验收范围。

---

## 2. 执行规则

后续只允许按以下规则推进：

1. 一次只执行一个工单。
2. 当前工单没有 review 关闭前，不进入下一个工单。
3. 每轮结果必须附带：
   - 修改摘要
   - 修改文件列表
   - 运行命令
   - 运行结果
   - 是否达到完成标准
   - 残留风险
4. legacy/debug/micro 结果不能替代正式 top/subsystem/protocol 证据。
5. 不允许把小批量 replay 包装成 full-set 结论。
6. 不允许把 unit/cluster 覆盖包装成 top-level 完整网络级性能结论。

---

## 3. 工单总表

### W0 当前状态固化与基线确认

目标：

- 固定当前正式入口、expected 口径、结果目录与引用边界

产出：

- 当前正式基线说明摘要

状态：

- 已完成

---

### W1 Top-Level Non-Single-Cluster Evidence

目标：

- 在 `top` 级正式 LeNet 入口下补至少一组 non-single-cluster 网络级运行证据

优先级：

- 最高

最低要求：

1. `dual-cluster top1`
2. `dual-cluster top8`

如 dual 稳定，可选补：

3. `full-cluster top1`

必须产出：

- 正确性结果
- `cluster_cfg` 或等价 non-single-cluster 证据
- `cycle/mac/read_beats/write_beats/util`
- 对应 `summary.json` / `per_sample.csv`

完成标准：

- 至少拿到一组 `top` 级完整 LeNet non-single-cluster 运行级证据
- `dual-cluster top1` 通过
- `dual-cluster top8` 尽量通过；若失败，必须明确 first failing point
- 不破坏当前 single-cluster 基线

状态：

- 已完成

完成结果：

- `dual-cluster top1` PASS
- `dual-cluster top8` PASS
- `full-cluster top1` 作为可选证据 PASS
- 该结论证明 `top` 级完整 LeNet 在 non-single-cluster 配置下可运行；不应表述为完整 dual/full-cluster top-level performance full-set 结论

---

### W2 Medium-Scale Regression Expansion

目标：

- 在 full-set 之前先用中等规模回归暴露长尾问题

建议范围：

1. `top64`
2. `subsystem64`

最低要求：

- 至少完成其中一条稳定回归

必须产出：

- `per_sample.csv`
- `summary.json`
- expected 口径说明

完成标准：

- 结果稳定可复现
- 能给出第一失败样本或明确全通过

状态：

- 已完成

完成结果：

- `top64`：`64/64 PASS`
- `subsystem64`：`64/64 PASS`
- 该结论证明中等规模回归稳定；不等同于 full-set 结果

---

### W3 Full-Set Evaluation

目标：

- 形成可引用的完整测试集结果链，并给出 RTL 侧代表性 full-set chunk evidence

建议顺序：

1. software full-set
2. subsystem representative full-set chunks
3. 视成本再评估 `top` full-set

必须产出：

- `correct/total`
- `accuracy`
- 运行命令
- expected 口径说明

完成标准：

- software full-set 作为当前最终全量准确率主证据
- RTL subsystem 形成 representative chunk evidence，且不显示 RTL 回归趋势
- 若完整 RTL `10000/10000` 仿真成本过高，可降级为后续增强项，不作为当前 W3 关闭阻塞项

说明：

- 不允许把 `8/16/32/64` 样本结果当成 full-set 结果
- 不允许把 partial chunk 计入正式 merged 结果
- observed fail 需要区分模型错分与 RTL/software 偏差，不能默认视为 RTL 回归

状态：

- 已完成，可关闭

完成结果：

- software full-set 主证据：`results/mnist_lenet_soc6_requant_candidate_final_eval.json`
  - `9885/10000`
  - `accuracy = 98.85%`
  - 已超过当前 `80%` accuracy gate
- RTL subsystem representative chunk evidence：
  - 结果目录：`results/w3_subsystem_full_10000_candidate_final_chunked/merged/`
  - 完整 merged chunk：`12`
  - 正式 merged 样本窗口：`3000/10000`
  - `summary.json` 口径：`2944/3000 = 98.1333%`
  - 停止时 write-out 观测值：`3000/3057 = 98.1354%`，其中 `chunk_03000_03249` 为 partial chunk，不计入正式 merged
- 完整 RTL `10000/10000` full-set 因仿真成本过高，降级为后续增强项
- 当前不自动进入 `W4 Coverage Flow`；W4 保留为后续增强项，需要重新显式立项

---

### W4 Coverage Flow

目标：

- 建立正式 coverage 收集、merge、report 流程

必须产出：

- coverage 收集入口
- merge 流程
- coverage summary
- coverage 引用边界说明

完成标准：

- 当前仓库可输出正式 coverage 报告

---

### W5 FPGA / Synthesis Delivery Material

目标：

- 补齐综合/资源/频率/约束/实现说明

必须产出：

- 一版可答辩引用的实现摘要
- 资源/频率/约束说明

完成标准：

- 形成可提交的实现侧材料

---

### W6 Final Delivery Hardening

目标：

- 固化最终答辩/交付文档与固定回归入口

必须产出：

- 最终 README / runbook / delivery 文档口径一致
- 固定答辩入口命令
- 最终能力边界说明

完成标准：

- 文档、脚本、结果引用边界统一

---

## 4. 推荐执行顺序

如项目决定继续交付增强，建议顺序如下：

1. `W1` top-level non-single-cluster evidence：已完成
2. `W2` medium-scale regression expansion：已完成
3. `W3` full-set evaluation：已完成，可关闭
4. `W4` coverage flow：后续增强项，当前不默认执行
5. `W5` FPGA / synthesis delivery material：后续增强项
6. `W6` final delivery hardening：后续增强项

不允许把 W3 的 representative RTL chunk evidence 表述为“RTL `10000/10000` full-set 已完整完成”。

---

## 5. 后续增强项启动条件

当前没有默认正在执行的 W4/W5/W6 工单。

若项目决定启动交付增强，优先重新立项：

- `W4: Coverage Flow`

W4 执行重点：

1. 建立正式 coverage 收集入口
2. 建立 coverage merge/report 流程
3. 明确 coverage 引用边界

不允许回头把 RTL full-set 长跑重新设为 W3 关闭阻塞项，也不允许在未重新立项时直接跳到 FPGA 或 unrelated cleanup。

---

## 6. 每轮汇报模板

后续 coding agent 每轮必须使用：

- 当前任务：
- 当前工单：
- 修改摘要
- 修改文件列表
- 运行命令
- 运行结果
- 是否达到完成标准
- 当前卡在哪个验收项
- 是否影响现有 HB / AXI 基线
- 残留风险

---

## 7. Review 规则

每个工单完成后，必须先做一次 review，再决定是否进入下一工单。

review 至少判断：

1. 结果是否符合当前工单目标
2. 结果是否被 legacy/debug 证据污染
3. 是否破坏当前 `HB/AXI` 基线
4. 是否可以正式关闭该工单
