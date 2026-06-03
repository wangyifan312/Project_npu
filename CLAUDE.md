# CLAUDE.md — Project_npu Working Baseline

本文件是项目内的工程约束与架构工作基线，服务于本轮 `6-cluster + SoC` 正式重构。

## 1. 不可逾越约束

1. 所有修改必须限制在 `/root/Project_npu/` 内。
2. RTL 使用 Verilog / 可综合 SystemVerilog 子集。
3. 默认仿真工具链为 `iverilog + vvp`，可保留其他已有后端用于大回归。
4. CPU 核固定为 `PicoRV32`，不得改成自研 CPU。
5. 一次只收敛一个任务；当前任务严格测试未通过，禁止进入下一任务。
6. 关键规模、位宽、cluster 数量和 shared memory 容量必须参数化。
7. 以赛题交付为导向，优先保证可验证性与闭环。
8. 不允许把“结构已接通”当成完成。
9. 本项目最终目标是赛题/答辩交付，不是一般性的工程阶段性交付。
10. 当“工程上可运行”和“赛题证据链完整”冲突时，优先补齐赛题/答辩所需证据链。

## 2. 本轮重构目标

- 正式废弃旧阵列目标口径
- 切换为 `6-cluster` 动态可调脉动阵列
- 每个 cluster = `16x16 PE`
- 总计 `1536 PE`
- `200MHz` 理论峰值 `0.6144 TOPS`
- `npu_top` 从大一统结构重构为“编排层 + compute hierarchy”
- `top/shared_ram` 升级到可承载完整 LeNet 地址图
- 用真实训练权重闭合 `LeNet/MNIST`
- 一次补齐性能统计与验证体系

### 2.1 正式阵列规格与入口分层

- 正式规格固定为 `16x16 cluster / 1536 PE / 0.6144 TOPS @ 200MHz`，不回退到历史小阵列口径。
- 正式入口只认 `16x16`：`rtl/soc/top.v`、`tb/integration/tb_lenet_network.v`、`tb/integration/tb_top_lenet.v`、`tb/integration/tb_top.v`、`tb/integration/tb_top_cluster_modes.v` 必须显式或默认落在 `16/16`。
- `tb_fc_accept`、`tb_fc_reject`、`tb_task_requant`、`tb_task4_fc_tiled_signed`、`tb_npu_top`、`tb_task1_illegal`、`tb_task3_pool`、`tb_task4_system`、`tb_task2_multiblock`、`tb_task2_weight_layout`、`tb_task6_pingpong`、`tb_task2_strict`、`tb_task4_fc_signed`、`tb_task2_multichannel`、`tb_requant_conv_handoff` 统一定位为 `legacy micro-tests`，允许用于局部回归，不得代表正式阵列基线或性能证据。
- `tb_task4_fc` 已升级为阵列化 FC formal sanity 入口，不能再作为 legacy 标量 FC 证据使用。

## 3. 顶层架构

### SoC 层

- `rtl/soc/top.v`
- `rtl/soc/shared_ram.v`
- `rtl/bus/axi_interconnect.v`
- `rtl/cpu/picorv32/...`

### NPU 编排层

- `npu_ctrl`
- `task_checker`
- `block_scheduler`
- DMA read/write path
- `npu_buffer`
- `conv_frontend`
- 阵列化 FC 执行流
- `postproc`
- `perf_counter`
- `npu_top`

### 新 compute hierarchy

- `cluster_16x16.v`
- `compute_core_6cluster.v`
- `cluster_scheduler.v`
- `output_arbiter.v`

要求：

- `cluster_16x16` 复用现有 `array_top` / `4x4 tile` 资产
- `compute_core_6cluster` 必须真正例化 6 个 cluster
- `cluster_enable[5:0]` 是正式接口，不是测试专用信号
- Conv / FC 都必须走新 compute hierarchy
- `fc_frontend.v` 当前只作为 legacy/debug stream formatter 保留，不承担正式 FC 主路径职责

## 4. 验证层级与口径

### NPU 子系统级

`npu_top + axi4_ram` 用于：

- deterministic fixture
- 层级黄金对拍
- 大容量 LeNet 回归

### SoC 顶层级

`top` 用于：

- CPU/NPU/shared memory 统一语义
- AXI-Lite 控制闭环
- 完整 LeNet 地址图
- shared memory 预加载与结果回读
- Conv / FC 正式执行流必须走 `cluster_scheduler -> compute_core_6cluster -> output_arbiter`
- `single / dual / full / mask` cluster mode 必须在同一 Conv 主路径上生效，不能只作为寄存器读数存在

正式 SoC 顶层 testbench 必须使用 `16x16` 阵列参数；历史小阵列测试只作为 legacy debug/regression 资产。

本轮 SoC 级默认方法：

- testbench `AXI-Lite master` 模拟 CPU 软件行为
- memory preload 提前写入输入和权重
- 不要求 PicoRV32 固件先驱动完整 LeNet

补充口径：

- `single / dual / full / dynamic mask` 的 cluster 模式覆盖当前主要来自 compute-core / cluster-level 回归
- 不应将这部分覆盖表述成“完整 SoC 顶层已覆盖所有 cluster 模式”

## 4.1 赛题/答辩交付优先口径

后续所有任务以“可用于赛题提交与答辩陈述”为最终完成标准，而不是只达到仓库内部可运行。

这意味着必须优先补齐以下证据链：

1. SoC 顶层证据链
   - 不仅要有 `npu_top + axi4_ram` 子系统级闭环
   - 还要有 `top` 层共享内存、寄存器配置、结果回读的可证明闭环
2. 真实模型证据链
   - deterministic fixture 只能作为快速回归
   - 最终必须能用真实训练权重与真实 `MNIST` 样本给出可解释结果
3. 性能证据链
   - 不仅要有理论峰值
   - 还要有 `MAC count / cycle count / utilization / AXI bandwidth` 的正式统计
   - 并明确区分 compute-core 级与 SoC 顶层级覆盖范围
4. 验收口径证据链
   - 文档、RTL、testbench、脚本、日志表述必须一致
   - 不允许用“基本完成”“结构完整”“单样本可跑”替代赛题级完成

如果某项工作只能支持“阶段性工程交付”而不能支持“赛题/答辩交付”，必须在汇报中明确写出，不得默认视为最终完成。

最终收尾时，必须同步对照：

- `docs/DELIVERY_CHECKLIST.md`
- `docs/MNIST_FULL_EVAL_PLAN.md`（当赛题明确要求完整测试集结果时）
- `docs/REQUANTIZATION_PLAN.md`（当 software full-test 长期低于 `80%` gate 时）

该清单高于一般工程里程碑，用于判断是否已经达到“可用于赛题最终提交 / 答辩展示”的标准。
其中：

- `DELIVERY_CHECKLIST.md` 用于判断是否达到答辩展示级交付
- `MNIST_FULL_EVAL_PLAN.md` 用于判断是否已经完成完整测试集结果交付
- `REQUANTIZATION_PLAN.md` 用于判断当前是否已进入“模型-硬件数值语义 blocker”阶段，以及后续是否允许切换到新 requant 语义
- `REPO_REVIEW_2026Q2.md` 用于判断当前仓库的正式问题清单、架构一致性缺口和整改优先级；后续清理与派工应优先对照该文档，而不是依赖零散会话结论

## 5. 固定网络与数据规则

- 网络：`LeNet(MNIST)`
- feature map layout：`HWC`
- conv weight layout：`[in_c][k_h][k_w][out_c]` + per-`in_c` 32-bit 对齐
- fc weight layout：`[out_neuron][in_neuron]`
- activation / weight：`INT8`
- accumulate / output：`INT32`
- 层间 `INT32 -> INT8` 规则：layer-wise requant
- requant 算术：`multiplier + shift + round-half-away-from-zero + clamp`
- `Pool = 2x2 MaxPool, stride=2`
- `ReLU` 在 `INT32` 域
- `bias` 本轮不支持

补充说明：

- 上述 requant 语义是当前正式基线
- 旧 direct-saturate 路径不再作为正式交付语义保留
- software / fixture / RTL 必须共同使用同一组 per-layer requant 参数

## 6. Shared Memory 基线

- `top` 不允许继续停留在默认 `64KB` 小容量模型
- 默认共享内存窗口必须覆盖 LeNet 地址图
- 当前基线按至少 `1MB` 共享内存窗口规划
- `task_checker` 地址合法范围必须与 `shared_ram` 容量一致

## 7. 不回退门槛

以下项目视为本轮强制不回退约束：

- 参数检查必须先于 DMA / compute 启动
- `block_scheduler` 必须接入真实主数据路径
- `AXI-Lite interconnect` 必须保持事务目标锁存安全
- CPU / NPU 必须继续共享同一份内存语义
- FC 不能再按“未支持”处理
- deterministic fixture 不能被真实权重流替代掉

## 8. 调试与验收规则

### 完成判定

以下都不算完成：

- `done=1`
- `no error`
- 输出非 `x`
- accepted / framework exists / structure complete

必须同时满足：

1. 严格 testbench PASS
2. 数值与 golden/reference 一致
3. 退出原因为正确完成，而不是偶然结束
4. 相关回归未破坏
5. 文档、RTL、testbench 口径一致

### 调试顺序

出现 mismatch 时，优先检查：

1. 地址计算
2. byte count
3. 对齐
4. stride / channel 跨度
5. block 尺寸
6. valid/ready 握手
7. start/done 时序
8. 同周期旧值使用

简单问题未排除前，不要先归因为深层阵列时序。

### 最小闭环优先

- 先最小空间尺寸
- 先最小通道数
- 先单 block
- 先手算 golden
- 先单层再整网

## 9. 任务完成后必须报告

每完成一个任务，必须报告：

- Task 编号
- 修改摘要
- 修改文件列表
- 新增/修改的测试
- 运行命令
- 仿真/验证结果
- 是否满足该任务验收标准
- 残留风险
