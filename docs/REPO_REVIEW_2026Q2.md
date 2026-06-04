# Repository Review 2026Q2

本文件是 `Project_npu` 当前仓库的**正式代码审查与整改清单**。

定位固定为：

- 当前仓库 `HEAD` 的事实性 review
- 面向**赛题最终提交 / 答辩交付**
- 输出可执行的整改问题清单，而不是历史规划回放

使用规则：

- 后续整改应逐条对照本文件关闭问题
- 未明确关闭的问题，默认仍视为开放
- 不允许再用“基本完成”“结构已接通”“小样本可跑”替代问题关闭

---

## 0. HB Closure Update

本 review 的早期问题清单中，部分 AXI/shared RAM/buffer/performance 口径风险已经通过 HB 256-bit 重构关闭或降级。

当前已确认：

- `HB1` 完成：256-bit 数据面功能闭环已恢复，top 单样本/top8/top16 在 `predicted_class` 口径下通过
- `HB2` 按当前边界完成：top16/top32/subsystem8 performance summary 非零且线性自洽
- shared memory 正式组织为 `32768 x 256-bit beat`，CPU 为 `32-bit AXI-Lite`，NPU DMA 为 `256-bit AXI4 burst`
- top-level LeNet performance replay 仍是 `single-cluster` 网络级口径
- multi-cluster 证据来自 util counter 与 compute-core/cluster-mode 运行级覆盖，不代表完整 LeNet dual/full performance replay

因此：

- P1-1 “AXI/Shared RAM 仍是 32-bit 功能模型”在 HB 主线下已关闭
- P1-2 “npu_buffer 仍是 32-bit 功能模型”在 HB 主线下已关闭到 256-bit beat 接入口径
- 最终交付层面的 full-set accuracy、固件驱动、FPGA/coverage 报告仍可作为后续交付增强项

---

## 1. 总体结论

当前仓库已经不是“算子原型”，而是一个**功能较完整的 CPU + NPU SoC 原型**：

- `CPU + AXI-Lite + NPU + shared memory` 主结构真实存在
- `Conv / Pool / ReLU / FC` 功能链路已建立
- `LeNet/MNIST` 的 software、fixture、subsystem、top 级验证资产已基本齐备
- 新 requant 语义的软件基线已建立，当前正式候选模型 software full-test accuracy 已达 `98.85%`

但它距离“赛题最终可提交版本”仍有明确差距：

1. 正式阵列规格与当前 RTL 实例化不一致
2. `6-cluster` Conv 主路径已完成正式收口
3. FC 已完成正式阵列化强切
4. AXI / Shared RAM / buffer 的 `256-bit` HB 主线已经收口
5. 性能计数和 HB2 小批量 replay 已闭环，但低功耗、覆盖率和最终报告证据链仍需后续交付补强

当前最准确的状态定义是：

- **工程原型可运行**：是
- **NPU/SoC 小批量真实推理闭环成立**：是
- **赛题最终交付收敛**：否

---

## 2. 当前完成度评估

| 维度 | 当前评估 | 说明 |
| --- | --- | --- |
| 工程结构与目录组织 | `85%` | `rtl/tb/docs/datasets/sim` 边界总体清楚，但历史资产仍偏多 |
| RTL 功能完整度 | `85%` | Conv/Pool/ReLU/FC/LeNet 主链已具备，requant 与 256-bit 数据面已接入 |
| SoC 集成完整度 | `80%` | shared memory、AXI-Lite、256-bit DMA、top LeNet 小批量 replay 已成立 |
| 验证体系完整度 | `85%` | unit/integration/golden/fixture/top/subsystem 较完整，但 coverage 无正式报告 |
| 赛题指标匹配度 | `70%` | 理论目标、HB2 performance replay 和 multi-cluster 运行级覆盖已具备 |
| 最终交付准备度 | `70%` | HB 主线已收口，但 full-set、FPGA/coverage/报告材料仍需交付补强 |

---

## 3. 赛题要求匹配矩阵

| 赛题要求 | 当前状态 | 证据 | 判断 | 主要差距 |
| --- | --- | --- | --- | --- |
| `CPU + NPU` 异构处理器 | `top.v` 中 PicoRV32 + NPU + shared RAM 已成立 | `rtl/soc/top.v` | 基本满足 | 仍主要依赖 testbench AXI-Lite master 驱动，而非完整固件链 |
| 以 `4x4` 脉动阵列为基础 | `mac_pe -> mac_tile_4x4 -> array_top` 明确存在 | `rtl/npu/mac_pe.v`, `mac_tile_4x4.v`, `array_top.v` | 满足 | 无 |
| AXI-Lite + AXI Burst | CPU 控制面为 `32-bit AXI-Lite`，NPU DMA 为 `256-bit AXI4 burst` | `rtl/bus/axi_interconnect.v`, `rtl/npu/dma_axi_reader.v`, `dma_axi_writer.v` | 满足当前 HB 口径 | 后续仍可补更完整压力/coverage 报告 |
| CPU/NPU 共享一份 memory | CPU port 和 NPU DMA port 指向同一 `32768 x 256-bit beat` shared memory | `rtl/soc/shared_ram.v` | 满足当前 HB 口径 | 后续仍可补综合/FPGA 语义说明 |
| 支持卷积/矩阵/FC 推理 | Conv/Pool/ReLU/FC 都能跑，FC 已阵列化 | `rtl/npu/npu_top.v`, `docs/LENET_MNIST_SPEC.md` | 基本满足 | 完整 full-set/交付报告仍需后续补强 |
| 标准测试集推理 | MNIST 已有完整链路 | `datasets/mnist`, `tb_top_lenet.v`, `tb_lenet_network.v` | 部分满足 | CIFAR-10 尚无完整闭环 |
| `>=0.5 TOPS @ INT8 @ 200MHz` | 文档理论值满足 | `ARCHITECTURE_SPEC.md`, `docs/PERFORMANCE_SUMMARY.md` | 理论满足 | 必须与正式 `16x16 / 1536 PE` RTL 基线收敛 |
| Burst 带宽利用率 `>=60%` | read bandwidth util 在 top/subsystem replay 下已非零且达到当前引用口径 | `rtl/npu/perf_counter.v`, `docs/PERFORMANCE_SUMMARY.md` | 满足当前 HB2 边界 | write util 反映当前 store 形态，不作为单独优化结论 |
| 低功耗设计 | tile/cluster 级 enable/gating 语义存在 | `rtl/npu/array_top.v`, `cluster_scheduler.v` | 部分满足 | 仍非正式可论证实现 |
| 详细文档、RTL、仿真/FPGA 报告 | 文档与仿真材料较多 | `docs/`, `tb/`, `sim/` | 基本满足 | 仍需继续统一口径并补正式覆盖率/性能报告 |

---

## 4. P0 问题清单

### P0-1 正式阵列规格与当前 RTL 实例化不一致

- 涉及：
  - `ARCHITECTURE_SPEC.md`
  - `rtl/soc/top.v`
  - `tb/integration/tb_lenet_network.v`
  - `tb/integration/tb_top_lenet.v`
  - `tb/integration/tb_top.v`
  - `tb/integration/tb_top_cluster_modes.v`
- 代码事实：
  - 文档正式口径是 `6-cluster × 16x16 PE = 1536 PE`
  - P0-1 整改后，`top.v` 默认值已收敛为 `NPU_TILE_ROWS = 16`, `NPU_TILE_COLS = 16`
  - P0-1 整改后，当前正式 LeNet / SoC testbench 入口已显式使用 `16x16`
- 原因：
  - 多轮架构迭代后，形式规格和现役实例化参数没有统一收口
- 影响：
  - 峰值算力、PE 数量、cluster 含义、buffer 供数压力、性能口径都会失真
- 正式修改策略：
  - **正式规格不回退**
  - 保留 `16x16 cluster / 1536 PE / 0.6144 TOPS`
  - 采用**一次性切换**
  - 正式入口全部切到 `16x16`
  - 小阵列局部测试不删除，但统一降级为 `legacy micro-tests`
- 建议验收：
  - `top.v`
  - `tb_lenet_network.v`
  - `tb_top_lenet.v`
  - `tb_top.v`
  - `tb_top_cluster_modes.v`
  全部使用 `16x16` 正式基线
  - legacy 小阵列测试不再作为正式阵列规模证据

P0-1 入口分层口径：

- 正式规格：`16x16 cluster / 1536 PE / 0.6144 TOPS @ 200MHz`
- 正式入口：只认 `16x16`，包括 `rtl/soc/top.v`、`tb_lenet_network.v`、`tb_top_lenet.v`、`tb_top.v`、`tb_top_cluster_modes.v`
- Legacy micro-tests：`tb_fc_accept`、`tb_fc_reject`、`tb_task_requant`、`tb_task4_fc_tiled_signed`、`tb_npu_top`、`tb_task1_illegal`、`tb_task3_pool`、`tb_task4_system`、`tb_task2_multiblock`、`tb_task2_weight_layout`、`tb_task6_pingpong`、`tb_task2_strict`、`tb_task4_fc_signed`、`tb_task2_multichannel`、`tb_requant_conv_handoff` 允许保留局部/小阵列实例化，但不再代表正式基线
- `tb_task4_fc` 已升级为阵列化 FC formal sanity 入口

### P0-2 `6-cluster` Conv 主路径已完成正式收口

- 涉及：
  - `rtl/npu/npu_top.v`
  - `rtl/npu/compute_core_6cluster.v`
  - `rtl/npu/output_arbiter.v`
- 代码事实：
  - Conv 正式路径已接入 `cluster_scheduler -> compute_core_6cluster -> output_arbiter`
  - `npu_top` 不再用 first-enabled cluster compatibility 选择器作为正式 Conv 结果来源
  - cluster mode/mask 参与正式 Conv 列段分配、cluster 使能和输出聚合
- P0-2/P0-3 后状态：
  - Conv / FC 都已切到正式 6-cluster 主路径
  - 标量 FC 不再作为正式结论来源

### P0-3 FC 已完成正式阵列化强切

- 涉及：
  - `rtl/npu/npu_top.v`
  - `rtl/npu/fc_frontend.v`
  - `ARCHITECTURE_SPEC.md`
- 代码事实：
  - `npu_top` 已移除 `fc_act_q/fc_wgt_q/fc_accum` 标量正式路径
  - FC task flow 按 output tile / input chunk 复用 `cluster_scheduler -> compute_core_6cluster -> output_arbiter`
  - `fc_frontend.v` 降级为 legacy/debug stream formatter，不再承担正式主路径职责
- 边界：
  - P0-3 不重写 requant 算法
  - P0-4 继续负责 top 小批量真实样本闭环

### P0-4 SoC 级 HB 小批量已收敛，但最终交付仍需补强

- 涉及：
  - `tb/integration/tb_top_lenet.v`
  - `docs/DELIVERY_CHECKLIST.md`
  - `docs/PERFORMANCE_SUMMARY.md`
- 代码事实：
  - requant 软件 gate 已通过
  - subsystem8 performance replay 已恢复
  - top 单样本、top8、top16、top32 小批量 replay 已恢复
  - top16/top32 使用 `predicted_class` 口径与 software/fixture 对齐
- 原因：
  - HB 主线已经完成小批量功能/性能闭环
  - 最终赛题交付仍需要 full-set、报告、coverage/FPGA 等材料补强
- 影响：
  - 当前可以描述为“HB1/HB2 已按既定范围收敛”
  - 当前仍不能描述为“最终赛题交付全量材料已完成”
- 正式修改策略：
  - SoC 级收敛采用**严格最终收敛**
  - HB 阶段验收规模锁定为：
    - `top` 层在正式 `16x16 + 6-cluster + 阵列化 FC + requant + 256-bit data plane` 路径下完成小批量真实样本闭环
    - top/subsystem performance summary 非零且线性自洽
  - full-set、FPGA、coverage 和最终报告作为交付补强项继续跟踪
- 建议验收：
  - 已完成：`top` 小批量真实样本结果与 subsystem/software `predicted_class` 口径一致
  - 后续：不得把小批量 replay 包装成完整 MNIST full-set 或完整 LeNet dual/full-cluster 性能结论

---

## 5. P1 问题清单

### P1-1 AXI/Shared RAM 的位宽参数化不完整，当前 `32-bit` 更像功能模型（HB 后已关闭）

- 涉及：
  - `rtl/soc/shared_ram.v`
  - `rtl/soc/axi4_ram.v`
  - `rtl/npu/dma_axi_writer.v`
  - `rtl/soc/top.v`
- 代码事实：
  - HB 前：虽有 `AXI_DATA_W` 参数，但实现中大量逻辑仍写死 `32-bit` 和 `4-bit wstrb`
  - HB 后：shared memory / AXI4 RAM / interconnect / DMA 已收敛到 `256-bit` beat，CPU 仍为 `32-bit AXI-Lite`
- 原因：
  - 现阶段以功能验证为主，宽总线性能版未真正落地
- 影响：
  - HB 前不可直接用“改参数”方式升级到 `128/256-bit`
  - 当前 HB 主线已完成 `256-bit` 正式数据面，不再以 `32-bit` 功能模型作为性能基线
- 正式修改策略：
  - **宽 AXI / Shared RAM 整改并入当前主线**
  - 不再接受 `32-bit` 长期作为正式性能基线
  - 必须真正参数化：
    - `AXI_DATA_W`
    - `wstrb`
    - byte-lane slice
    - DMA beat packing
    - RAM 模型
- 建议验收：
  - 已完成：宽 AXI smoke/burst 回归通过
  - 已完成：正式性能结论不再建立在 `32-bit` 功能模型之上

### P1-2 `npu_buffer` 更偏功能模型，不像大阵列供数子系统（HB 后已关闭到 256-bit beat 接入口径）

- 涉及：
  - `rtl/npu/npu_buffer.v`
- 代码事实：
  - HB 前：双 bank 32-bit 数组 + 组合读
  - HB 后：默认 entry 已切到 `256-bit` beat，正式读路径和 feeder 接入按宽 beat 语义工作
- 原因：
  - 设计目标更偏功能模型
- 影响：
  - HB 前性能真实性、lint 质量、可综合性表达较弱
  - 当前 HB 范围已解决正式数据面带宽接入问题；更深层 SRAM 宏/综合质量仍可作为后续实现质量增强
- 正式修改策略：
  - **`npu_buffer` 并入当前主线重构**
  - 不再接受大数组组合读的 `32-bit` 功能模型作为正式基线
  - 必须重构成更接近真实片上供数子系统的模型
- 建议验收：
  - 已完成：供数带宽语义与大阵列/宽 AXI 正式匹配
  - 后续增强：若进入综合/FPGA 阶段，再补 SRAM 宏化与 lint/coverage 收敛

### P1-3 Conv 能力当前主要适配 LeNet，而非通用 CNN

- 涉及：
  - `rtl/npu/conv_frontend.v`
  - `docs/LENET_MNIST_SPEC.md`
- 代码事实：
  - 当前前端围绕 `5x5 valid stride=1`、HWC 布局实现
- 原因：
  - 目标网络就是 LeNet
- 影响：
  - 不能把当前实现表述成“任意 CNN 卷积后端”
- 正式修改策略：
  - **当前主线直接抽象成更通用的 Conv 能力**
  - 不再长期停留在 LeNet 专用 `5x5 valid stride=1`
  - 至少要求向：
    - kernel 规模
    - stride
    - padding/valid 语义
    - frontend 窗口组织
    做正式抽象
- 建议验收：
  - 正式文档和正式实现不再只绑定 LeNet 专用卷积语义

### P1-4 低功耗只完成了功能级 gating 语义，不是正式可论证实现

- 涉及：
  - `rtl/npu/array_top.v`
  - `rtl/npu/cluster_scheduler.v`
  - `rtl/npu/npu_top.v`
- 代码事实：
  - `tile_clk_en` 使用 `clk && en` 类功能性 gating
  - `cluster_enable` 已存在
- 原因：
  - 当前更偏功能性低功耗语义验证
- 影响：
  - 可以证明有 tile/cluster 级关闭能力
  - 但不能直接当成正式低功耗实现报告
- 正式修改策略：
  - **tile / cluster gating 当前主线做到正式可论证实现**
  - 不再接受纯功能性 `clk && en` 作为正式交付口径
- 建议验收：
  - gating 方案达到可综合、可解释、可答辩层级
  - 文档与实现一致

### P1-5 性能计数齐了，但赛题级性能证据链仍不完整

- 涉及：
  - `rtl/npu/perf_counter.v`
  - `docs/PERFORMANCE_SUMMARY.md`
  - `tb/integration/tb_top.v`
  - `tb/integration/tb_top_cluster_modes.v`
- 代码事实：
  - `cycle/mac/beats/active/stall` 都已经存在
  - Conv top 级结果已来自正式 6-cluster 主路径
  - 多模式完整网络级性能覆盖仍需后续单独补齐
- 原因：
  - 当前性能证明链还停留在“原型级可解释”
- 影响：
  - 答辩可用，但最终赛题性能结论还不够硬
- 正式修改策略：
  - **当前主线补到答辩级正式性能证据**
  - 必须统一：
    - 理论值
    - cluster-level
    - top-level
  三层口径
  - 不要求本条同时完成 full-set RTL 性能统计
- 建议验收：
  - `PERFORMANCE_SUMMARY.md` 可直接支撑答辩，不需额外口头修正

---

## 6. P2 问题清单

### P2-1 历史文档和 legacy 资产仍较多，维护成本偏高

- 涉及：
  - `docs/`
  - `datasets/`
  - `rtl/npu/fc_frontend.v`
  - `rtl/soc/axi_ram.v`
- 代码事实：
  - 仓库已历经多轮迭代，存在历史规划、旧 prompt、旧展示链、兼容模块共存
- 原因：
  - 为保留演化过程和调试资产，没有进一步归档分层
- 影响：
  - 新读者容易误判当前正式基线
- 正式修改策略：
  - **保留历史与 legacy 资产，但彻底分层归档**
  - 统一降级为：
    - `legacy`
    - `historical`
    - `demo-only`
  - 不允许与当前正式基线并列
- 建议验收：
  - `README` 与正式导航能清楚区分 current / legacy / historical

### P2-2 存在少量陈旧常量、陈旧接口和未完全使用信号

- 涉及：
  - `rtl/npu/task_checker.v`
  - `rtl/npu/npu_ctrl.v`
- 代码事实：
  - 有旧错误码、保留接口、未完全进入核心逻辑的信号
- 原因：
  - 多轮功能演进后的残留
- 影响：
  - 代码洁净度与可读性下降
- 正式修改策略：
  - **死代码、陈旧常量、未用接口并入当前主线清理**
  - 不后置
  - 随正式主路径重构同步完成
- 建议验收：
  - 无明显陈旧常量、未使用参数、无效正式接口残留
  - lint 结果明显改善

### P2-3 覆盖率 `>=95%` 目前没有正式证据

- 涉及：
  - `tb/`
  - `sim/`
  - `docs/`
- 代码事实：
  - 已有大量测试，但没有正式 coverage merge / report 流
- 原因：
  - 目前更重功能与链路闭环
- 影响：
  - 不能对外宣称达到赛题覆盖率要求
- 正式修改策略：
  - **覆盖率体系补到正式可引用报告**
  - 当前主线内必须建立：
    - coverage 收集
    - merge
    - 报告输出
- 建议验收：
  - 有正式 coverage 报告与说明
  - 可直接引用到最终交付材料

---

## 7. 建议重构路线

### 短期目标

1. 统一正式规格与 RTL 实例化口径
2. 把 `6-cluster` 收成唯一正式主路径
3. 完成 requant candidate 的 `top` 小批量 sanity
4. 补齐完整多模式网络级性能覆盖
5. 统一正式性能和架构表述
6. 建立 current / legacy / historical 的正式分层

### 中期目标

1. 完成宽 AXI + 共享内存性能版收口
2. 完成 `npu_buffer` 正式供数模型重构
3. 完成 Conv 通用化能力抽象
4. 完成正式 gating 实现
5. 输出真正可提交的 coverage、性能、验证报告

---

## 8. 哪些模块可以保留

建议保留并继续演进：

- `mac_pe / mac_tile_4x4 / array_top`
- `cluster_scheduler / compute_core_6cluster`
- `dma_axi_reader / dma_axi_writer`
- `postproc`
- `requant_i32_to_i8`
- `axi_interconnect`
- `shared_ram` 的共享语义骨架
- `tb` 中现有的 unit/integration/golden/fixture 骨架

---

## 9. 哪些模块应重写或拆分

建议重点重构：

- `npu_top`
  - 当前承担编排、requant、调度、perf 等过多职责
- `npu_buffer`
  - 当前偏功能模型，不适合作为正式性能基线
- `fc_frontend`
  - 已降级为 legacy/debug stream formatter，后续可归档
- `axi4_ram / shared_ram`
  - 若追求宽总线和性能版，需要重构数据位宽实现
- 关键网络级 testbench
  - 应继续压缩为 strict / accuracy-only / perf-heavy 三类更清晰模式

---

## 10. 最终建议的短期目标和中期目标

### 短期目标

- 用一套真实一致的阵列规模口径收敛仓库
- 完成 `top` 层正式新路径的小批量真实样本闭环
- 统一正式性能、架构、主路径和 legacy 分层口径
- 把当前开放问题从“口头结论”转成逐条关闭

### 中期目标

- 让正式 `6-cluster` 主路径与文档完全一致
- 建立宽 AXI + 高带宽 memory 子系统
- 建立真正通用的 Conv/FC 正式执行链
- 输出可提交的 coverage、性能、验证报告

---

## 11. 文档使用规则

本文件用于后续逐条过审与关闭问题。

后续任何整改结论都必须明确写清：

- 关闭了哪条问题
- 改了哪些文件/模块
- 用什么测试或证据关闭

不允许用以下说法替代关闭：

- “基本完成”
- “结构完整”
- “功能已经差不多”
- “理论上没问题”
