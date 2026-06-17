# CLAUDE.md — Project_npu Working Baseline

本文件是后续 coding agent 的工程约束和接手基线。当前项目状态总表见：

- `docs/CURRENT_PROJECT_STATUS.md`

新会话应先读 `CURRENT_PROJECT_STATUS.md`，再进入对应专题文档。不要把 README 或 CLAUDE 当作完整状态总表。

## 1. 不可逾越约束

1. 所有修改必须限制在 `/root/Project_npu/` 内。
2. RTL 使用 Verilog / 可综合 SystemVerilog 子集。
3. CPU 核固定为 `PicoRV32`，不得改成自研 CPU。
4. 一次只收敛一个任务；当前任务未验收前，不进入下一任务。
5. 关键规模、位宽、cluster 数量和 shared memory 容量必须参数化。
6. 不允许把“结构已接通”“done=1”“输出非 x”当成完成。
7. 本项目最终目标是赛题/答辩交付，不是一般工程阶段性交付。
8. 当“工程上可运行”和“赛题证据链完整”冲突时，优先补齐赛题/答辩证据链。

## 2. 固定架构基线

- SoC：`PicoRV32 + AXI interconnect + shared_ram + NPU`
- NPU：`6 x 16x16 PE cluster`
- 总 PE：`1536`
- 理论峰值：`0.6144 TOPS @ 200MHz`
- shared memory：`1 MB = 32768 x 256-bit beat`
- CPU 控制面：`32-bit AXI-Lite`
- NPU DMA 数据面：`256-bit AXI4 INCR burst`
- 正式计算路径：`cluster_scheduler -> compute_core_6cluster -> output_arbiter`
- FC 正式路径：arrayized FC

正式入口只认 `16x16` 基线：

- `rtl/soc/top.v`
- `tb/integration/tb_lenet_network.v`
- `tb/integration/tb_top_lenet.v`
- `tb/integration/tb_top.v`
- `tb/integration/tb_top_cluster_modes.v`

历史 `tb_task*`、`tb_npu_top`、`tb_fc*` 等只作为 legacy/debug/micro 入口，不能代表正式阵列规模、性能峰值或交付基线。

## 3. 当前状态入口

完整当前状态以 `docs/CURRENT_PROJECT_STATUS.md` 为准。简要边界如下：

- `HB1/HB2` 已按当前边界完成。
- `AXI-1/2/3/4` 已按当前项目子集边界完成。
- `W1/W2/W3` 已完成并可关闭。
- `W4/W5/W6` 当前降级为后续增强项，不作为正在执行的正式工单。
- NPU RTL `Workstream A/B/C` 已完成。
- first-pass full-cluster 优化已达到 `top32 + subsystem64 stronger regression stable`。

## 4. 不能乱动的 contract

以下内容不允许在普通修复或优化中顺手改变：

- LeNet 地址图。
- requant 算法语义。
- shared memory 物理组织：`32768 x 256-bit beat`。
- NPU task base address `64B` 对齐契约。
- `acc_buffer -> DMA writer` 的 `32-bit word -> 256-bit beat` packing。
- last-beat `WSTRB` 根据实际 byte count 生成的语义。
- output layout / layer memory map。
- 单任务寄存器触发模型。

runtime `CLUSTER_MODE / CLUSTER_MASK` 已支持 AXI-Lite 配置，但这不等同于 task queue、descriptor FIFO 或 shadow config 架构。

## 5. 证据边界

- software full-set 是当前全量 accuracy 主证据。
- RTL 侧是 representative chunk evidence，不能表述为 RTL `10000/10000` full-set 已完成。
- multi-cluster correctness 已收口，runtime bottleneck evidence 已增强，但不能表述为 full LeNet-wide performance attribution complete。
- AXI 当前是标准化项目子集，不是完整通用 AXI4 / AXI-Lite IP。

## 6. 后续工作口径

当前默认不是继续 W4/W5/W6 主线开发；它们已降级为后续增强项。

如果后续继续推进，应先明确立项：

- coverage flow
- FPGA / synthesis delivery material
- final delivery hardening
- 第二轮 NPU 性能优化
- 更高强度 runtime cluster mode 长回归

涉及地址对齐、store packing、output layout、控制模型的修改必须单独立项。

## 7. 调试与验收规则

出现 mismatch 时，优先检查：

1. 地址计算
2. byte count
3. 对齐
4. stride / channel 跨度
5. block 尺寸
6. valid/ready 握手
7. start/done 时序
8. 同周期旧值使用

完成必须同时满足：

1. 指定 testbench 严格 PASS
2. 数值与 golden/reference 一致
3. 退出原因为正确完成
4. 相关回归未破坏
5. 文档、RTL、testbench、脚本口径一致

每轮完成后必须报告：

- 当前任务 / 工单
- 修改摘要
- 修改文件列表
- 新增/修改的测试
- 运行命令
- 运行结果
- 是否满足验收标准
- 残留风险
