# Project_npu

`Project_npu` 是一个面向赛题三的 `CPU + NPU` 异构处理器 RTL 仓库。本轮工作目标不是继续维护旧的阵列原型口径，而是正式切换到 `6-cluster` SoC 基线，并补齐 SoC、真实权重与性能闭环。

## 本轮固定目标

- `6-cluster` 动态可调脉动阵列
- 每个 cluster = `16x16 PE`
- 总计 `1536 PE`
- `200MHz` 理论峰值 `0.6144 TOPS`
- `top` 层 shared memory 默认口径为 `32768 x 256-bit beat`，容量 `1 MB`，覆盖完整 LeNet 地址图
- SoC 级验证采用 testbench `AXI-Lite master` + shared memory preload 模拟 CPU 软件行为
- FC 正式执行流已强切到 `6-cluster` compute hierarchy

## HB 256-bit 当前状态

当前高带宽主线已经收口：

- `HB1` 完成：256-bit 数据面功能闭环恢复，top 单样本/top8/top16 在 `predicted_class` 口径下通过
- `HB2` 按当前边界完成：top16/top32/subsystem8 performance summary 非零且线性自洽
- CPU 访问模式为 `32-bit AXI-Lite`
- NPU DMA 访问模式为 `256-bit AXI4 burst`
- shared memory 物理组织为 `32768 x 256-bit beat`

引用限制：

- top-level LeNet performance replay 仍是 `single-cluster` 网络级口径
- multi-cluster 证据来自 util counter 与 compute-core/cluster-mode 运行级覆盖，不等同于完整 LeNet dual/full performance replay

## 当前交付补强状态

在 `HB` 和 `AXI` 主线收口后，当前仓库已经开始进入交付补强阶段。

当前已完成：

- `W1` 完成：`top` 级完整 LeNet 的 non-single-cluster 网络级证据已补齐
  - `dual-cluster top1` 通过
  - `dual-cluster top8` 通过
  - `optional full-cluster top1` 通过
- `W2` 完成：中等规模回归已扩到
  - `top64`：`64/64 PASS`
  - `subsystem64`：`64/64 PASS`
- `W3` 完成，可关闭：full-set evaluation 采用 `software full-set + RTL representative chunk evidence` 口径收口
  - software full-set 主证据：`results/mnist_lenet_soc6_requant_candidate_final_eval.json`
  - software 结果：`9885/10000 = 98.85%`
  - RTL subsystem representative merged evidence：`results/w3_subsystem_full_10000_candidate_final_chunked/merged/`
  - RTL 正式 merged 样本窗口：`3000/10000`
  - RTL `summary.json` 口径：`2944/3000 = 98.1333%`
  - 停止时 write-out 观测值：`3000/3057 = 98.1354%`，其中 partial chunk 不计入正式 merged

当前下一条正式工单是：

- `W4`：coverage flow

引用限制：

- 当前 `W1` 证明的是 `top` 级完整 LeNet 在 non-single-cluster 配置下可运行且功能正确
- 当前 `W1` 结果不应直接表述为“top-level LeNet dual/full-cluster 吞吐提升结论”
- 当前 `W2` 证明的是中等规模回归稳定，不等同于 full-set 结果
- 当前 `W3` 的最终全量准确率主证据是 software full-set；RTL 侧是 representative chunk evidence，不应表述为“RTL `10000/10000` full-set 已完整完成”
- `chunk_03000_03249` 是停止时 partial chunk，没有 `summary.json / finished_at.txt`，不计入正式 merged 结果
- observed fail 需要区分模型错分与 RTL/software 偏差，不能默认视为 RTL 回归

## AXI 当前状态

当前仓库的 AXI compliance plan 已完成到当前项目正式支持边界。当前可准确表述为：

- 控制面：标准化 `AXI-Lite` 项目子集实现
- 数据面：标准化 `256-bit AXI4 INCR burst` 项目子集实现

这表示：

- 当前正式 top/subsystem/perf 回归已经覆盖上述支持范围
- 当前协议级、功能级、性能级证据已经可分开引用
- 当前实现仍不是“完整通用 AXI4 / AXI-Lite 兼容 IP”

如果后续要继续扩展到更通用的 AXI 兼容能力，仍应以：

- [docs/AXI_COMPLIANCE_SPEC.md](docs/AXI_COMPLIANCE_SPEC.md)
- [docs/AXI_COMPLIANCE_EXECUTION_CHECKLIST.md](docs/AXI_COMPLIANCE_EXECUTION_CHECKLIST.md)

作为支持范围与限制范围的正式基线。当前仍不应把该实现表述为“完整通用 AXI4 / AXI-Lite 兼容 IP”。

## NPU RTL follow-up 当前状态

当前 `docs/NPU_RTL_TODO.md` 中的 NPU RTL follow-up 已推进到：

- Workstream A 已完成：multi-cluster route / aggregate correctness 已收口，runtime bottleneck evidence 已增强。
  - 当前 6-cluster 路径不是 inter-cluster reduce，而是 `activation broadcast + weight split + routed global-column OR merge`。
  - first-pass full-cluster 优化已完成，并通过 `top32 + subsystem64` stronger regression stable。
- Workstream B 已完成：shared memory contract 和 store-path verification 已收口。
- shared memory contract 继续固定为 `1 MB = 32768 x 256-bit beat`。
- `acc_buffer -> DMA writer` 写回路径固定为 `32-bit word -> 256-bit AXI beat` packing，last-beat `WSTRB` 由实际 byte count 决定。
- NPU task base address contract 当前继续维持 `64B` 对齐；不在当前阶段放宽到 `32B`。
- Workstream C 已完成：cluster mode / mask 已支持 AXI-Lite runtime config，parameter 保留为 reset default。

引用限制：

- 当前 Workstream A 不应表述为 full LeNet-wide performance attribution complete；性能归因已有更强运行级证据，但后续若要做第二轮优化仍需单独评估。
- 当前 Workstream B 不应解读为“地址契约已放宽”或“store layout 可自由重排”。
- 当前 Workstream C 不等同于 task queue / descriptor / shadow config；当前仍是单任务寄存器触发模型。
- 后续若要修改地址对齐、输出 layout、写回 packing 或控制模型，必须单独立项并同步 RTL、脚本、文档和回归资产。

## 当前目录状态

当前仓库的正式源码与正式文档主要集中在：

- `rtl/`
- `tb/`
- `sim/`
- `datasets/`
- `docs/`

此外，根目录可能会保留一些本地调试或仿真生成产物，例如：

- `csrc/`
- `novas.fsdb`
- `novas_dump.log`
- `ucli.key`
- `tmp/`

这些不属于正式源码基线，也不应作为交付证据引用。若需要清理，应优先保留：

- `results/` 中的正式结果资产
- `sim/` 下的正式脚本入口

而将明显可再生的仿真产物单独清理。

## 阵列规格与入口分层

正式阵列规格固定为 `16x16 cluster / 1536 PE / 0.6144 TOPS @ 200MHz`，正式 RTL 和正式 testbench 入口只认 `16x16` 基线。正式入口文件为 `rtl/soc/top.v`、`tb/integration/tb_lenet_network.v`、`tb/integration/tb_top_lenet.v`、`tb/integration/tb_top.v`、`tb/integration/tb_top_cluster_modes.v`，不得再使用历史 `7/13` 小阵列口径。

以下历史小阵列/局部功能测试保留为 `legacy micro-tests`，允许继续使用小阵列或局部实例化，但不能作为正式阵列规模、性能峰值或交付基线证据：`tb_fc_accept`、`tb_fc_reject`、`tb_task_requant`、`tb_task4_fc_tiled_signed`、`tb_npu_top`、`tb_task1_illegal`、`tb_task3_pool`、`tb_task4_system`、`tb_task2_multiblock`、`tb_task2_weight_layout`、`tb_task6_pingpong`、`tb_task2_strict`、`tb_task4_fc_signed`、`tb_task2_multichannel`、`tb_requant_conv_handoff`。`tb_task4_fc` 已升级为阵列化 FC formal sanity 入口。

## 当前仓库基线

已完成且本轮不得回退：

- 原始 `Tasks 1-9`
- 多通道 `Conv`
- `Pool / ReLU`
- FC 阵列化正式路径
- `LeNet` 层级对拍与 deterministic fixture 流程
- `npu_top + axi4_ram` 子系统级网络回归资产

需要明确的是：

- 旧版“完整 LeNet 跑通”主要指 `npu_top + axi4_ram` 子系统级闭环
- 本轮目标是把完整地址图、shared memory 语义、AXI-Lite 驱动流程推进到 `top` 层
- 本轮默认不要求先写 PicoRV32 固件来驱动完整 LeNet

## 架构摘要

- SoC 顶层：`rtl/soc/top.v`
- NPU 编排层：`rtl/npu/npu_top.v`
- 新 compute hierarchy：
  - `rtl/npu/cluster_16x16.v`
  - `rtl/npu/compute_core_6cluster.v`
  - `rtl/npu/cluster_scheduler.v`
  - `rtl/npu/output_arbiter.v`

详细基线见：

- [ARCHITECTURE_SPEC.md](ARCHITECTURE_SPEC.md)
- [docs/SOC_6CLUSTER_ARCHITECTURE.md](docs/SOC_6CLUSTER_ARCHITECTURE.md)
- [docs/LENET_MNIST_SPEC.md](docs/LENET_MNIST_SPEC.md)
- [docs/PERFORMANCE_SUMMARY.md](docs/PERFORMANCE_SUMMARY.md)
- [docs/REAL_WEIGHT_FLOW.md](docs/REAL_WEIGHT_FLOW.md)
- [docs/REPO_REVIEW_2026Q2.md](docs/REPO_REVIEW_2026Q2.md)
- [docs/REQUANTIZATION_PLAN.md](docs/REQUANTIZATION_PLAN.md)
- [docs/REQUANTIZATION_CODEX_PROMPT.md](docs/REQUANTIZATION_CODEX_PROMPT.md)
- [docs/DEFENSE_REGRESSION.md](docs/DEFENSE_REGRESSION.md)
- [docs/RTL_DEBUG_PLAYBOOK.md](docs/RTL_DEBUG_PLAYBOOK.md)
- [docs/DELIVERY_CHECKLIST.md](docs/DELIVERY_CHECKLIST.md)
- [docs/MNIST_FULL_EVAL_PLAN.md](docs/MNIST_FULL_EVAL_PLAN.md)
- [docs/AXI_COMPLIANCE_SPEC.md](docs/AXI_COMPLIANCE_SPEC.md)
- [docs/AXI_COMPLIANCE_EXECUTION_CHECKLIST.md](docs/AXI_COMPLIANCE_EXECUTION_CHECKLIST.md)
- [docs/NEXT_TASK_WORKLIST.md](docs/NEXT_TASK_WORKLIST.md)

如果目标是对当前仓库做正式状态评估、逐条清理历史问题和规划整改路线，请优先阅读 [docs/REPO_REVIEW_2026Q2.md](docs/REPO_REVIEW_2026Q2.md)。这份文档是当前仓库级 review 与整改清单基线，高于零散会话结论。

如果目标是**赛题最终提交 / 答辩交付**，请优先以 [docs/DELIVERY_CHECKLIST.md](docs/DELIVERY_CHECKLIST.md) 为收尾标准，而不是只以“工程上已可运行”作为完成依据。

如果目标是继续按顺序推进后续补强工单，请优先使用 [docs/NEXT_TASK_WORKLIST.md](docs/NEXT_TASK_WORKLIST.md)；当前固定顺序是：

1. `W1` top-level non-single-cluster evidence：已完成
2. `W2` medium-scale regression expansion：已完成
3. `W3` full-set evaluation：已完成，可关闭
4. `W4` coverage flow：下一条执行
5. `W5` FPGA / synthesis delivery material
6. `W6` final delivery hardening

其中当前已完成 `W1/W2/W3`，下一条工单固定为 `W4`。

如果赛题书面要求**完整 `MNIST` 测试集结果**，当前可引用 software full-set 作为全量 accuracy 主证据，并引用 RTL subsystem representative chunk evidence 作为硬件侧代表性验证；不能把小批量回归或 partial chunk 包装成完整 RTL full-set。
此外，完整 `MNIST test set` 的最终交付 accuracy 门槛固定为 **`80%` 及以上**；低于该门槛的 full-test 结果只能算阶段性结果，不能算最终交付。
如果 software full-test 始终卡在 `80%` 以下，则必须优先对照 [docs/REQUANTIZATION_PLAN.md](docs/REQUANTIZATION_PLAN.md) 审视中间层 requant 语义，而不是继续盲跑 RTL full-set。

## 目标网络

固定网络为：

`Input(28x28x1) -> Conv1(20, 5x5, valid) -> Pool1(2x2 max, s=2) -> Conv2(50, 5x5, valid) -> Pool2(2x2 max, s=2) -> Flatten(800) -> FC1(500) -> ReLU -> FC2(10) -> Argmax`

固定规则：

- feature map layout：`HWC`
- conv weight layout：`[in_c][k_h][k_w][out_c]`，每个 `in_c` chunk 做 32-bit 对齐
- fc weight layout：`[out_neuron][in_neuron]`
- 层间 `INT32 -> INT8` handoff：使用 layer-wise requant
- requant 规则：`multiplier + shift + round-half-away-from-zero + clamp`

## 验证层级

- `npu_top + axi4_ram`
  - 大容量 deterministic fixture
  - 层级/网络级黄金对拍
  - compute-core / cluster-level 性能模式覆盖由 `tb_cluster_perf_modes` 提供，已覆盖 `single / dual / full / dynamic mask`
- `top`
  - CPU/NPU/shared memory 协同
  - AXI-Lite 配置与状态回读
  - 完整 LeNet 地址图闭环
  - Conv / FC 正式主路径使用 `cluster_scheduler -> compute_core_6cluster -> output_arbiter`
  - 当前 LeNet performance replay 是 `single-cluster` 口径
- `unit / micro`
  - `tb_cluster_perf_modes` 覆盖 compute-core `single / dual / full / dynamic mask`
  - `tb_hb2_cluster_util_counter` 覆盖 util counter 在 multi-cluster 下按 enabled cluster 数缩放

本轮最终要求同时保留：

- deterministic fixture 快速回归
- 真实训练权重 + 真实 MNIST 小批量回归

## 仓库结构

```text
rtl/
  bus/        AXI 互连
  cpu/        PicoRV32
  npu/        NPU 主体与 compute hierarchy
  soc/        SoC 顶层与 shared memory

tb/
  unit/       单元测试
  integration/集成测试与网络级测试

sim/
  run_sim.sh
  run_lenet_fixture.sh

datasets/
  mnist/
  scripts/

docs/
  架构、LeNet 规格、调试规则
```

## 常用入口

基础回归：

```bash
bash sim/run_sim.sh all
```

`sim/run_sim.sh` 中的 `tb_top`、`tb_top_lenet`、`tb_top_cluster_modes` 是正式 `16x16` SoC 入口；`tb_npu_top`、`tb_task*`、`tb_fc` 等历史局部测试属于 `legacy micro-tests`，只用于回归定位。

LeNet fixture：

```bash
bash sim/run_lenet_fixture.sh compile
SIMULATOR=vcs bash sim/run_lenet_fixture.sh sample
SIMULATOR=vcs PROGRESS=0 bash sim/run_lenet_fixture.sh all
SIMULATOR=vcs ACCURACY_ONLY=1 \
FIXTURE_DIR=datasets/mnist/lenet_real_manifest_100 \
MANIFEST_PATH=datasets/mnist/lenet_real_manifest_100/manifest.json \
SAMPLE_ROOT_DIR=datasets/mnist/exports_full \
WEIGHTS_ROOT_DIR=datasets/mnist/lenet_real_manifest_100/weights \
INPUT_MEMH_NAME=packed_words.memh EXPECTED_FILE_NAME=label.txt \
COUNT=100 RESULTS_DIR=results/mnist_full_subsystem_100_accuracy_only \
bash sim/run_lenet_fixture.sh batch
SIMULATOR=vcs bash sim/run_top_lenet.sh sample
SIMULATOR=vcs bash sim/run_top_lenet.sh all
```

说明：

- deterministic fixture 继续作为快速 smoke/regression 路径
- 如果目标是完整测试集 accuracy，请优先走 `ACCURACY_ONLY=1` 的 subsystem batch 路径；该模式跳过逐层 golden compare，但默认仍保留 perf register reads
- 如需显式跳过性能寄存器读取，使用 `SKIP_PERF_READS=1`
- `accuracy-only` 模式当前可统计 `total_cycles / total_mac / read/write beats / utilization`
- 真实权重流、性能表和答辩固定回归入口分别见：
  - [docs/REAL_WEIGHT_FLOW.md](docs/REAL_WEIGHT_FLOW.md)
  - [docs/PERFORMANCE_SUMMARY.md](docs/PERFORMANCE_SUMMARY.md)
  - [docs/DEFENSE_REGRESSION.md](docs/DEFENSE_REGRESSION.md)

当前常用正式入口也可以直接通过顶层 `Makefile` 调用：

```bash
make help
make top1
make top8
make top16
make top32
make subsystem8
make perf-top16
make perf-top32
make perf-subsystem8
make fullset-subsystem-status
```

说明：

- `Makefile` 是对现有 `sim/*.sh` 的薄封装
- 正式 replay / perf / utility target 已分组整理
- `fullset-subsystem-status` 用于查看 W3 candidate-final chunked full-set 当前 representative evidence；默认不会把 partial chunk 算入正式 merged
- 如需继续推进后续工单，仍以对应工单文档和结果目录口径为准

## 完成标准

以下都不算完成：

- `done=1`
- 输出非 `x`
- framework exists
- structure complete

完成必须以严格测试与数值对拍为准，并且不能破坏既有回归。
