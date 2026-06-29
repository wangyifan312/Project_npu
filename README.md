# Project_npu

`Project_npu` 是面向赛题"CPU + NPU 异构处理器设计"的 RTL 仓库。当前正式基线是 `PicoRV32 CPU + 6-cluster NPU + shared memory` SoC，目标网络为 `LeNet(MNIST)`。

当前项目状态的唯一总表入口是：

- [docs/CURRENT_PROJECT_STATUS.md](docs/CURRENT_PROJECT_STATUS.md)

README 只保留导航、关键边界和常用入口；不要把 README 当作完整状态总表使用。

## 固定硬件基线

- NPU：`1 x 64x64 PE cluster`
- 总 PE：`4,096`
- 理论峰值：`1.6384 TOPS @ 200MHz`
- shared memory：`1 MB = 32768 x 256-bit beat`
- CPU 控制面：`32-bit AXI-Lite`
- NPU DMA 数据面：`256-bit AXI4 INCR burst`
- 正式计算路径：`cluster_scheduler -> compute_core_6cluster -> output_arbiter`
- FC 正式路径：arrayized FC，不回退到 legacy scalar FC

## 当前状态摘要

完整结论见 [docs/CURRENT_PROJECT_STATUS.md](docs/CURRENT_PROJECT_STATUS.md)。当前可简述为：

- `HB1/HB2` 已按当前边界完成。
- `AXI-1/2/3/4` 已按当前项目子集边界完成。
- `W1/W2/W3` 已完成并可关闭。
- `W4/W5/W6` 当前降级为后续增强项，不作为正在执行的正式工单。
- NPU RTL `Workstream A/B/C` 已完成。
- first-pass full-cluster 优化已达到 `top32 + subsystem64 stronger regression stable`。

### 赛题关键指标

| 指标 | 目标 | 达成 | 证据 |
|------|:--:|:--:|------|
| AXI bus bandwidth | ≥60% | **64.04%** | `npu_bandwidth_60pct_stress_test` PASS_TARGET |
| FC 带宽 (1K→96) | — | **50.57%** | `npu_system_bus_util_test` (read-dominated) |
| DMA writer burst util | ≥80% | **80.00%** | `tb_dma_writer_long_burst` 5/5 PASS |
| vector_relu output | exact | 512/512 | 16384 bytes vs golden |
| write_beat_fifo depth | — | 64 | 消除 producer 背压 |

ResNet-20 当前也已经不再停留在"只做 software handoff"阶段。当前 ResNet 迁移线可准确表述为：

- `R0.5` software golden / export / handoff 已完成。
- software fixed-point full-test gate 已通过：`8639/10000 = 86.39%`。
- export package / task sequence / `1 MB` memory map 已生成并验证。
- R1a-R1e RTL foundations 已实现。
- R1g compact residual slice exact match 已完成。
- R1h package-faithful full-shape `input.image -> conv1` exact match 已完成。
- R1i package-faithful early residual multi-task exact match 已完成。
- full `32-task` / full ResNet-20 RTL end-to-end closure 仍未完成。

关键证据边界：

- software full-set 是当前全量 accuracy 主证据：`9885/10000 = 98.85%`。
- RTL 侧是 representative chunk evidence，不能表述为 RTL `10000/10000` full-set 已完成。
- multi-cluster correctness 已收口，runtime bottleneck evidence 已增强，但不能表述为 full LeNet-wide performance attribution complete。
- 当前 AXI 实现是标准化 `AXI-Lite` / `AXI4 INCR burst` 项目子集，不是完整通用 AXI IP。
- ResNet 当前 exact-match 证据只覆盖：
  - compact residual directed slice
  - package-faithful full-shape `conv1`
  - package-faithful early residual multi-task slice
  不能表述为 full ResNet-20 exact match 已完成。

## ResNet RTL 已实现功能

以下是当前已经落地到 RTL 的 ResNet 相关能力，口径以当前 `main` 为准：

- `task_type` 全链路已扩到 `3 bit`
  - `0=Conv`
  - `1=FC`
  - `2=Pool`
  - `3=Requant`
  - `4=ADD`
  - `5=GAP`
  - `6=VectorReLU` (新增：256-bit streaming INT8 ReLU)
- append-only AXI-Lite 控制寄存器已加入：
  - `VERSION / CAPABILITY`
  - `CONV_CFG`
  - `BIAS_ADDR / BIAS_BYTES`
  - `SRC1_ADDR / SRC1_BYTES`
  - `ADD_CFG / GAP_CFG / POSTPROC_CFG`
  - `ADD_SRC0/SRC1/OUT MULT/SHIFT`
- generalized Conv foundation 已实现：
  - kernel: `1x1 / 3x3 / 5x5`
  - stride: `1 / 2`
  - padding: `valid / same`
- folded INT32 bias + requant integration 已接入 Conv/FC 路径：
  - `accumulator INT32 -> optional bias -> optional ReLU -> requant_i32_to_i8`
- Residual ADD foundation 已实现：
  - two-source read
  - pre-alignment multiplier/shift
  - INT32 add
  - optional ReLU
  - post-requant to INT8
- GAP8x8 foundation 已实现：
  - INT8 input
  - per-channel INT32 sum
  - divide-by-64
  - optional requant to INT8
- package-faithful compare 当前已证明：
  - `input.image -> conv1` full-shape exact match
  - `conv1 -> layer1.0.conv1 -> layer1.0.conv2 -> layer1.0.add` 连续 multi-task exact match

这些能力已经实现，但仍不代表 full ResNet-20 32-task 连续 exact match 已完成。

## DMA Write Optimization

DMA 写通道已完成 Phase A/B/B2 优化：

- Phase A：新增 write transaction-level performance counters。
  - NPU 可读寄存器：0xD0 (PERF_WRITE_DATA_CYC)、0xD4 (PERF_WRITE_TXN_CYC)。
  - 0x88 = CLUSTER_MODE (RW)、0x8C = CLUSTER_MASK (RW)。
- Phase B：store-pack first-word optimization（首拍等待优化）。
- Phase B2：dma_axi_writer W-channel next-beat preload / skid buffer。
  - 消除 W channel burst 内固定 bubble。
  - 16-beat long burst：write_transaction_util 45.71% → 80.00%。
  - write_txn_cycles：35 → 20（write_data_cycles = 16 不变）。
  - W channel 从约 2 cycles/beat 改善为约 1 beat/cycle。

重要说明：
- 80.00% 是 AXI write TRANSACTION-level utilization（AW→B 窗口内 W beat 占比）。
- system-level write throughput 仍受 32-bit acc_buffer/store_pack 路径限制。
- 不要把 80.00% 说成 system-level utilization。

### P2: write_beat_fifo 深度 16→64

FIFO 深度升级消除了 vector_relu producer 背压（fifo_full_stall: 63→0）。
端口宽度同步更新（write_beat_fifo.v, dma_axi_writer.v, npu_top.v）。
Bandwidth 收益：61.61% → 64.04%（+2.43pp）。

### P0: dma_axi_writer Phase B2 correctness fixes

P0-1/P0-2: next_last off-by-one、promote_now gating、eff_level、spurious beat
discard。修复前 write beats 480/482 of 512 → 修复后 512/512。
P0-3: npu_top.v 双 DMA read → 修复后 read beats 512/512。
详细见 `CLAUDE.md §8.3`。

### P4: FC compute acceleration

- **FEED_ACT 32B broadcast**: 256-bit act_buffer 广播 latches 32 bytes/cycle，
  FC 64 rows → 3-4 cycles（原 64 cycles byte-by-byte）。
- **COLLECT pipeline**: 1 column/cycle（原 2 cycles/col）。
- FC 1K→96 带宽：~18% → **50.57%**。

### B1: FC multi-tile mismatch (FIXED 2026-06-28)

- 症状: FC 16→96 (output_c > 1) 输出 mismatch (190/384 bytes)。
- 根因: FC Phase 1 ping-pong preload 写权重到 wgt_buffer 备用 bank，
  但 bank 内容被读为 'x'。
- 修复: FSM_FC_TILE_PREP bypass preload，每 tile fresh DMA。
- 结果: 0/384 mismatches。

REQ-1 requant testbench 失败已结案：
- 不是 requant_i32_to_i8 RTL bug。RTL 公式（round-half-away-from-zero + clamp [-128,127]）正确。
- 根因：testbench 32-bit AXI preload（awsize=2）被 256-bit axi4_ram 拒绝，RAM 读出 X。
- 修复：tb_task_requant.v 改为 256-bit AXI preload。
- 修复后 Verilog tb_task_requant PASS，UVM npu_requant_smoke_test PASS。

## 验证状态

### 回归 (2026-06-29)

| 测试 | 状态 |
|------|:--:|
| `npu_bandwidth_60pct_stress_test` | PASS_TARGET (64.04%) |
| `npu_fc_smoke_test` | PASS |
| `npu_conv_smoke_test` | PASS |
| `npu_requant_smoke_test` | PASS |
| `npu_cluster_mode_test` | 4/4 PASS |
| `npu_fc_full_cluster_96out_test` | PASS |
| `npu_perf_counter_scaling_test` | 3/3 PASS |
| `npu_cluster_mask_sweep_test` | 4/4 PASS |
| `npu_back_to_back_task_test` | PASS |
| `npu_fc_16x16_full_array_test` | PASS |
| `npu_gap_smoke_test` | PASS |
| `npu_conv_stride2_test` | PASS |
| `npu_conv_1x1_smoke_test` | PASS |
| `npu_conv_3x3_same_test` | PASS |
| `npu_pool_smoke_test` | PASS |
| `npu_add_smoke_test` | PASS |
| `tb_dma_writer_long_burst` | 5/5 PASS |
| `tb_dma_writer_tail_burst` | PASS |
| `tb_dma_writer_awlen_wlast` | PASS |
| `tb_dma_writer_backpressure` | PASS |
| `tb_dma_writer_zero_byte` | PASS |
| `tb_top_lenet` (LeNet) | 1/1 correct |

### 2026-06-29: 架构修正与 Bug 修复

**架构修正**: RTL TILE_ROWS/COLS 16→4，修正每个 cluster 从 64×64 PE (4096 PE) 到 16×16 PE (256 PE)。
总 PE 从 24,576 修正为 **1,536**，与 CLAUDE.md 基线一致。

**RTL Bug 修复**:
- `npu_top.v`: `total_global_cols` — FC multi-tile 时使用 `fc_tile_outputs` 替代 `output_c`，
  修复 cluster weight routing 越界访问 wgt_load_reg。
- `npu_top.v`: GAP `acc_wr_en/data/addr` — 改用 `gap_acc_wr_en_r` 直接选通，
  修复 fsm_state 跳转与写使能同周期的时序竞争（数据从未写入 acc_buffer）。
- `conv_frontend.v`: stride2 行切换 — 新增 `stride_shift_cnt`，line buffer 按 `stride_r` 次 shift，
  修复 stride=2 时第 2 个 output row 数据不完整。

### Back-to-Back Task Execution

npu_ctrl.v 已修复 back-to-back：写入 CTRL bit[0]=1 时若 NPU idle，RTL 自动
清除 done/error 标志并启动新任务。不再需要先写 CTRL=0x10 再写 CTRL=0x01。
UVM npu_start_poll_seq 已简化为单次 CTRL=1 写入。

### Sticky Probe 机制

soc_probe_if 在 NPU busy 窗口内对 cluster busy/enable/tile 信号做 OR-累积
（sticky probe）。每次任务前清零。用于证明集群/PE tile 在任务期间的活跃性，
不等同于实时逐拍采样。

## 不可随意改动的 contract

- LeNet 地址图不变。
- requant 算法语义不变。
- shared memory 继续固定为 `32768 x 256-bit beat`。
- NPU task base address contract 继续维持 `64B` 对齐。
- `acc_buffer -> DMA writer` packing 固定为 `32-bit word -> 256-bit AXI beat`。
- last-beat `WSTRB` 由实际 byte count 决定。
- write_beat_fifo depth = 64（P2 升级，不得减小）。
- FC Phase 1 preload bypass（B1 fix，FSM_FC_TILE_PREP 强制 fresh DMA）。
- P4 FEED_ACT 32B broadcast latch block（is_fc_mode gated）。
- P4 COLLECT pipelined（FC 写 col_results 不依赖 buffer 读数据）。
- runtime `CLUSTER_MODE / CLUSTER_MASK` 已支持 AXI-Lite 配置。

AXI Preload 规则：
  正式 256-bit data-plane testbench 写 axi4_ram 必须使用 256-bit WDATA + AWSIZE=3'd5。
  已修复：tb_npu_top.v、tb_task_requant.v、tb_task4_shared_mem.v。
  Legacy tb_task1/2/3/6 系列为 micro 入口，不属 formal baseline，不批量修改。

## 关键文档入口

- [ARCHITECTURE_SPEC.md](ARCHITECTURE_SPEC.md)：总体架构基线。
- [docs/CURRENT_PROJECT_STATUS.md](docs/CURRENT_PROJECT_STATUS.md)：当前状态总表。
- [docs/soc_fs.md](docs/soc_fs.md)：SoC 功能规格与寄存器/地址口径。
- [docs/NPU_RTL_TODO.md](docs/NPU_RTL_TODO.md)：NPU RTL Workstream A/B/C 详细证据。
- [docs/FULL_CLUSTER_OPT_PLAN.md](docs/FULL_CLUSTER_OPT_PLAN.md)：first-pass full-cluster 优化方案。
- [docs/PERFORMANCE_SUMMARY.md](docs/PERFORMANCE_SUMMARY.md)：性能证据与引用边界。
- [docs/LENET_MNIST_SPEC.md](docs/LENET_MNIST_SPEC.md)：LeNet 网络、数据布局和地址规则。
- [docs/REAL_WEIGHT_FLOW.md](docs/REAL_WEIGHT_FLOW.md)：真实权重与 candidate-final 资产链。
- [docs/MNIST_FULL_EVAL_PLAN.md](docs/MNIST_FULL_EVAL_PLAN.md)：full-set evaluation 口径。
- [docs/DELIVERY_CHECKLIST.md](docs/DELIVERY_CHECKLIST.md)：答辩/交付收尾清单。
- [docs/NEXT_TASK_WORKLIST.md](docs/NEXT_TASK_WORKLIST.md)：历史 W1-W6 工单定义。
- [docs/AXI_COMPLIANCE_SPEC.md](docs/AXI_COMPLIANCE_SPEC.md)：AXI 支持范围。
- [docs/HB_256BIT_REFACTOR_SPEC.md](docs/HB_256BIT_REFACTOR_SPEC.md)：256-bit HB 数据面基线。
- [CLAUDE.md](CLAUDE.md)：coding agent 工程约束与基线。

## 目标网络

固定网络：

```text
Input(28x28x1)
-> Conv1(20, 5x5, valid)
-> Pool1(2x2 max, s=2)
-> Conv2(50, 5x5, valid)
-> Pool2(2x2 max, s=2)
-> Flatten(800)
-> FC1(500)
-> ReLU
-> FC2(10)
-> Argmax
```

固定数据规则：

- feature map layout：`HWC`
- conv weight layout：`[in_c][k_h][k_w][out_c]`
- fc weight layout：`[out_neuron][in_neuron]`
- activation / weight：`INT8`
- accumulate / output：`INT32`
- 层间 handoff：layer-wise requant，`multiplier + shift + round-half-away-from-zero + clamp`

## 仓库结构

```text
rtl/       RTL source
tb/        unit and integration testbenches
sim/       official simulation scripts
datasets/  MNIST fixtures, manifests, exported assets
docs/      specs, status, checklists, runbooks
results/   retained evidence and run outputs
```

## 常用入口

基础回归：

```bash
bash sim/run_sim.sh all
```

UVM 测试（需要 VCS）：

```bash
# 单个测试
bash verif/uvm_top/scripts/run_uvm.sh npu_fc_smoke_test

# 带宽测试
bash verif/uvm_top/scripts/run_uvm.sh npu_bandwidth_60pct_stress_test

# FC 带宽测试
bash verif/uvm_top/scripts/run_uvm.sh npu_system_bus_util_test
```

LeNet subsystem / top：

```bash
SIMULATOR=vcs bash sim/run_lenet_fixture.sh sample
SIMULATOR=vcs bash sim/run_top_lenet.sh sample
```

Makefile 入口：

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

- `Makefile` 是对现有 `sim/*.sh` 的薄封装。
- `tb_top`、`tb_top_lenet`、`tb_top_cluster_modes` 是正式 SoC 入口。
- 历史 `tb_task*`、`tb_npu_top`、`tb_fc*` 等只作为 legacy/debug/micro 入口，不能作为正式功能或性能基线。

性能计数器读取（通过 AXI-Lite，基址 0x1000_0000）：
  - 0xD0: PERF_WRITE_DATA_CYC（WVALID && WREADY 周期数）
  - 0xD4: PERF_WRITE_TXN_CYC（AW→B 事务窗口周期数）
  - 0x88: CLUSTER_MODE（RW）
  - 0x8C: CLUSTER_MASK（RW）
  - write_transaction_util = PERF_WRITE_DATA_CYC / PERF_WRITE_TXN_CYC

## 已知限制与后续工作

- **P2 Phase B 1 beat/cycle**: act_buffer 2-cycle 读延迟阻塞。
  vector_relu 理论带宽上限约 87%（当前 64%）。
- **P3 store_pack 128-bit**: acc_buffer 32-bit 单端口阻塞。
  需 buffer 128-bit 宽 + byte-enable + COLLECT packing。
  预期 store_pack 16→~5 cycles/beat。
- Phase C (acc_buffer 256-bit widening)：暂缓。
- FPGA synthesis / timing check：待完成。
- UVM full regression：待扩展。
- ResNet/CIFAR end-to-end RTL：不宣称完成。仅 foundation / directed smoke 已实现。

## 完成标准

以下都不算完成：

- `done=1`
- 输出非 `x`
- framework exists
- structure complete

完成必须以严格测试、数值对拍、回归不破坏和文档口径一致为准。
