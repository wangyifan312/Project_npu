# Prompt For New Codex Session

> Historical execution prompt:
> 本文件是 6-cluster 重构阶段给另一个 Codex 会话使用的历史 prompt。
> 它不是当前正式规格或当前任务入口；保留仅用于追溯。

```text
请把这次工作当成一次“架构升级 + SoC 收尾”的正式重构，而不是零散修 bug。

先完整阅读以下文档，它们是本轮工作的唯一基线：

1. /root/Project_npu/docs/SOC_6CLUSTER_REFACTOR_PLAN.md
2. /root/Project_npu/ARCHITECTURE_SPEC.md
3. /root/Project_npu/CLAUDE.md
4. /root/Project_npu/docs/LENET_MNIST_SPEC.md
5. /root/Project_npu/docs/RTL_DEBUG_PLAYBOOK.md

当前背景必须以这些事实为准：
- 原始 Tasks 1-9 已完成
- LeNet 扩展任务已完成到旧版本闭环
- 当前仓库已经不是“只有 NPU 算子原型”
- 但它还不是完整满足赛题要求的 CPU+NPU SoC
- 本轮目标不是继续小修，而是正式切换到 6-cluster 架构并补齐 SoC / 真实权重 / 性能闭环
- 本轮 SoC 级验证默认使用 testbench 的 AXI-Lite master / memory preload 流程模拟 CPU 软件行为
- 本轮不要求你先写 PicoRV32 固件来驱动完整 LeNet

硬性目标：
1. 将旧的 `64x64` 目标规格正式替换为：
   - 6-cluster 动态可调脉动阵列
   - 每个 cluster = 16x16 PE
   - 总计 1536 PE
   - 200MHz 下理论峰值 0.6144 TOPS
2. 按文档要求新增：
   - `cluster_16x16.v`
   - `compute_core_6cluster.v`
   - `cluster_scheduler.v`
   - `output_arbiter.v`
3. 按“明显重构方案”重构 `npu_top`，而不是只做最小替换
4. 升级 `top/shared_ram`，让 SoC 顶层能承载完整 LeNet 地址图
5. 用真实训练权重闭合 LeNet/MNIST 测试
6. 一次补齐性能与验证体系

执行模式：
- 连续自主执行
- 严格按文档中的顺序推进
- 每次只聚焦一个任务，但完成后自动进入下一个任务
- 不需要每完成一个任务都停下来等我确认
- 除非遇到真实 blocker，否则持续执行

固定执行顺序：
1. Task A — 文档基线重写
2. Task B — 新 compute hierarchy 模块落地
3. Task C — `npu_top` 接入新 compute core
4. Task D — `top/shared_ram` 扩容与 SoC 闭环
5. Task E — 真实 LeNet 权重闭环
6. Task F — 性能与验证体系全量补齐

特别注意：
- 旧的 P0/P1 问题现在不是“待修 bug list”，而是本轮重构中的强制不回退约束
- 不允许在没有严格测试通过的情况下，用 “framework exists / structure complete / done=1 / output non-x” 宣称完成
- FC 不能再按“未支持”处理；当前仓库里 FC 旧路径虽然已存在，但在 6-cluster 架构下必须重新完成功能验收
- LeNet 真实闭环优先于 deterministic fixture 闭环
- 但 deterministic fixture 回归必须保留，作为快速 smoke/regression 路径
- `top` 不允许继续停留在 64KB 小容量共享内存模型上
- 这轮最终要能支持赛题级的性能证明，不是只做统计寄存器
- SoC 级闭环默认以 top + testbench AXI-Lite master 为准，不要把“必须写 PicoRV32 固件”当成本轮前提

你开始工作前，必须先输出：
1. 你对整个重构任务的理解
2. 你准备如何拆分 Task A-F
3. 你判断当前最危险的改动点是什么
4. 你准备如何保护不回退约束
5. 你准备先改哪些文件

每个任务完成后，必须输出固定格式小结：
- Task 编号
- 修改摘要
- 修改文件列表
- 新增/修改的测试
- 运行命令
- 仿真/验证结果
- 是否满足该任务验收标准
- 残留风险

工作要求：
- 不要回避大改动，但必须让每个阶段都可验证
- 不要并行胡乱推进多个未收敛子系统
- 不要让文档、RTL、testbench 口径再次分裂
- 所有结论必须以实际测试和对拍为准

现在开始：
1. 读取所有基线文档
2. 从 Task A 开始
3. 严格按 Task A -> F 顺序执行
4. 不要等待我确认，持续推进
```
