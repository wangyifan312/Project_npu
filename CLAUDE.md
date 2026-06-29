# CLAUDE.md — Project_npu Working Baseline
每次回答问题前都要加上“王天才”，这样我才能确保你读了CLAUDE.md
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
- NPU：`1 x 64x64 PE cluster`
- 总 PE：`4,096`
- 理论峰值：`1.6384 TOPS @ 200MHz`
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

### ResNet-20 当前口径

ResNet-20 不改变当前 LeNet/MNIST formal baseline，但它已经不再停留在
`R0.5 in progress` 或 `RTL not started` 的阶段。当前统一口径：

- `R0.5` software golden / export / handoff 已完成。
- software fixed-point full-test accuracy gate 已通过：
  - `8639/10000 = 86.39%`
- F6b handoff contract 已关闭。
- F6c/F6g export package 已生成并验证。
- F6d/F6e final task sequence 和 `1 MB` memory map 已生成并验证。
- R1a-R1e foundations 已实现。
- R1g compact residual slice exact match 已完成。
- R1h package-faithful full-shape `input.image -> conv1` exact match 已完成。
- R1i package-faithful early residual multi-task exact match 已完成。
- 当前仍未完成：
  - full 32-task package-faithful exact match
  - full ResNet-20 RTL end-to-end closure

当前已实现的 ResNet RTL 能力边界：

- `task_type` 全链路 `3 bit`
- generalized Conv foundation：
  - `1x1 / 3x3 / 5x5`
  - `stride1 / stride2`
  - `valid / same`
- Conv/FC folded INT32 bias + requant
- Residual ADD foundation
- GAP8x8 foundation
- package-faithful exact-match 证据：
  - full-shape `input.image -> conv1`
  - early residual multi-task slice

当前仍不能写成：

- full 32-task ResNet-20 exact match complete
- full ResNet-20 RTL end-to-end closure complete

因此，后续文档或报告不得再写：

- `ResNet RTL implementation has not started`
- `ResNet package is only handoff-ready for RTL R1 review`

更准确的口径应是：

- ResNet RTL staged implementation/evidence exists through R1i
- full-sequence closure is still open

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
- dma_axi_writer.v W-channel skid buffer logic (Phase B2)
- write_beat_fifo.v (depth parameter 64, from P2; do NOT reduce)
- store_pack lane ordering
- acc_buffer structure (32-bit, single-port; 128-bit widening is separate project)
- requant_i32_to_i8.v formula (round-half-away-from-zero, clamp [-128,127])
- Golden/reference/scoreboard
- Timeout values
- FC Phase 1 preload bypass (B1 fix: FSM_FC_TILE_PREP forces fresh DMA per tile)
- P4 FEED_ACT 32B broadcast latch block (is_fc_mode gated)
- P4 COLLECT pipelined (acc_collect_wait removed for FC — writes col_results, not buffer data)

runtime `CLUSTER_MODE / CLUSTER_MASK` 已支持 AXI-Lite 配置，但这不等同于 task queue、descriptor FIFO 或 shadow config 架构。

### AXI Preload Rule for 256-bit Data Plane

Formal integration/NPU data-plane testbenches that preload 256-bit AXI RAM MUST use:
  - 256-bit WDATA
  - AWSIZE = 3'd5 (32-byte beat encoding for 256-bit AXI4)
  - AW/W in separate cycles (WREADY depends on AW handshake)

Already fixed: tb_npu_top.v, tb_task_requant.v, tb_task4_shared_mem.v

Legacy tb_task1/2/3/6 series are micro/debug entries, NOT formal baseline.
Do not batch-modify them.

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

## 8. DMA Write Optimization Closure

Phase A, B, B2 completed. DMA regression 13/13 PASS (10 Verilog directed + 3 UVM smoke).
Structural UVM regression: 5/5 new structural tests PASS, structural+smoke closure 8/8 PASS.
Conv diagnostic tests: 2/2 PASS (single/dual-cluster Conv verified).
npu_cluster_mode_test: 4/4 PASS (RESOLVED — root cause was back-to-back start bug in npu_ctrl.v, not Conv multi-cluster mapping. See docs/known_issues/conv_multicluster_mismatch.md).
Conv multi-window spatial output drain hang: RESOLVED — root cause DMA writer S_WAIT_DATA tail-burst deadlock (dma_axi_writer.v + npu_top.v, 2026-06-25). Hang A (conv_frontend lb_base_row) confirmed harmless.

Phase A: Added write transaction-level counters.
  - write_data_cycles (WVALID && WREADY)
  - write_txn_cycles (AW→B transaction window)
  - Readable at NPU registers 0xD0 (PERF_WRITE_DATA_CYC), 0xD4 (PERF_WRITE_TXN_CYC).
  - 0x88 = CLUSTER_MODE (RW), 0x8C = CLUSTER_MASK (RW).

Phase B: Store-pack first-word optimization (IDLE→CAPTURE direct, saves 1 cycle).

Phase B2: dma_axi_writer W-channel next-beat preload (skid buffer).
  Eliminated 1-cycle bubble between W beats in burst.
  Long burst 16-beat:
    Before: write_transaction_util = 45.71%  (35 txn_cycles, 16 data_cycles)
    After:  write_transaction_util = 80.00%  (20 txn_cycles, 16 data_cycles)
    W channel: ~2 cycles/beat → ~1 beat/cycle.

IMPORTANT: 80.00% is AXI write TRANSACTION-level utilization (AW→B window).
System-level write throughput is still limited by 32-bit acc_buffer/store_pack path.
Do NOT write "system-level utilization is 80%".

REQ-1 requant testbench failure resolved:
  Root cause: testbench 32-bit AXI preload (awsize=2) rejected by 256-bit axi4_ram.
  NOT a requant_i32_to_i8 RTL bug. Formula confirmed correct.
  Fix: tb_task_requant.v rewritten for 256-bit AXI preload.

### Back-to-Back Task Execution

npu_ctrl.v back-to-back fix: Writing CTRL bit[0]=1 while idle now auto-clears
done/error flags. Back-to-back task execution no longer requires an explicit
CTRL=0x10 (clear done/error) write before CTRL=0x01 (start). A single CTRL=1
write is sufficient; the RTL auto-clears done/error and starts the new task.
UVM npu_start_poll_seq simplified accordingly (workaround removed).

### Structural UVM Regression

5 new structural UVM tests added (all FC-based, output-compare verified):

- npu_fc_16x16_full_array_test: Single-cluster 16x16 FC. Sticky probe verifies
  cluster0 busy=1, enable=1, tile clock enable active during NPU busy window.
  Output 64 bytes matched vs DPI-C golden.

- npu_fc_full_cluster_96out_test: 6-cluster 96-output FC. Sticky probe verifies
  all 6 clusters simultaneously active (enable=111111, all_active=1).
  **B1 FIXED 2026-06-28**: FC multi-tile preload produced 'x' weights for tile 2+.
  Root cause: FC Phase 1 ping-pong preload wrote weights to alternate wgt_buffer
  bank, but bank content was consumed as 'x' by FSM_FC_TILE_PREP.
  Fix: bypass preload in FSM_FC_TILE_PREP; each tile does fresh DMA.
  Output 384 bytes (96 INT32) matched.  See §8.3 for details.

- npu_cluster_mask_sweep_test: 4 modes (single/dual/full/mask).
  Sticky mask matches expected per mode. All 4 output compares PASS.

- npu_perf_counter_scaling_test: 3 configs (1/2/6 clusters, identical workload).
  Counters non-zero across all configs. Reads use new 0xD0/0xD4 addresses.

- npu_back_to_back_task_test: Two sequential tasks without explicit clear.
  Both outputs independently verified, no stale contamination.

Sticky probe mechanism: soc_probe_if OR-accumulates cluster busy/enable/tile
signals during NPU busy window. Cleared before each task. Provides evidence
that clusters/tiles were active at some point during the task, even if not
simultaneously sampled.

Structural UVM tests: 5/5 PASS.
Existing UVM smoke regression: 3/3 PASS.
Structural closure total: 8/8 PASS.
npu_cluster_mode_test: 4/4 PASS (RESOLVED — root cause back-to-back start bug,
  verified 2026-06-25. See docs/known_issues/conv_multicluster_mismatch.md).

### 8.3. P0-P4 Bug Fixes & Performance (2026-06-26 ~ 2026-06-28)

Six rounds of targeted RTL improvements.  All changes verified with
regression (FC/Conv/Requant smoke, bandwidth 60% stress, DMA writer directed).

**P0: vector_int8_relu_256b correctness & 60% bandwidth target**
  - P0-1/P0-2: dma_axi_writer.v Phase B2 preload next_last off-by-one +
    promote_now gating + eff_level + spurious beat discard.  Write beats
    480→512, output PASS.
  - P0-3: npu_top.v double DMA start in FSM_TASK_SETUP→FSM_LOAD_ACT.
    Read beats 1024→512.
  - P0-4: system_task_bus_active_ratio = 64.04% (≥60% target met).
  Commit: 26eaa0b

**P0 follow-up: FC K-streaming Phase 1+2**
  - Phase 1: FC ping-pong weight DMA preload (wgt_buffer alternate bank)
  - Phase 2: FC shadow weight register (wgt_load_reg_shadow, 32Kbit)
  Commit: 60790b7

**P1: Writer protocol hardening & stress test verdict**
  - P1-1: dma_axi_writer.v ERR_UNDERFLOW detection, S_WAIT_DATA priority reorder
    (full burst > partial tail > underflow error)
  - P1-2: npu_bandwidth_60pct_stress_test 3-tier verdict
    (functional_pass / bandwidth_pass / PASS_TARGET)
  Commits: b1b74a0, e90efaf

**P2: FIFO depth 16→64, bandwidth +2.4pp**
  - write_beat_fifo.v, dma_axi_writer.v, npu_top.v port widths updated
  - Eliminates vector_relu producer backpressure (fifo_full_stall: 63→0)
  - bandwidth: 61.61% → 64.04%
  Commit: f0b2815

**P3/P4: FEED_ACT 32B broadcast + COLLECT pipeline (FC compute acceleration)**
  - P4 FEED_ACT: 256-bit act_buffer broadcast latches 32 bytes/cycle.
    FC rows per chunk: 64→3-4 cycles (was 64 cycles byte-by-byte).
  - P4 COLLECT: pipelined 1 column/cycle (remove acc_collect_wait between cols).
    FC columns per chunk: 64→33 cycles (was 64 cycles, 2 per col).
  - P3 store_pack pipeline: DEFERRED.  Consecutive acc_buffer reads break
    1-cycle buffer latency.  Requires acc_buffer 128-bit widening.
  - FC 1K→96 bandwidth: ~18% (pre-optimization) → 50.57% (with FEED+COLLECT)
  Commits: e982a5b, 03c94bc, a61410e (reverted in B1 fix branch)

**B1: FC multi-tile mismatch FIX**
  - Symptom: FC 16→96 (and 1K→96) with output_c > 1 had mismatches.
    Pre-existing since commit 4312bcf (not introduced by P0-P4).
  - Root cause: FC Phase 1 ping-pong preload wrote tile 2+ weights into
    wgt_buffer alternate bank, but bank content read as 'x' by FSM_LOAD_ARRAY.
  - Fix: FSM_FC_TILE_PREP bypasses preload; each tile does fresh weight DMA.
    Cost: ~1024 cycles per additional tile.
  - FC 16→96: 190/384 mismatches → 0/384 matched.
  Commits: 4ff89f4, 992bec1 (on fix/fc-multi-output-bug, merged to main)

**Regression status (2026-06-29):  38/38 UVM tests PASS (0 mismatch)**
  npu_fc_smoke_test:              PASS
  npu_conv_smoke_test:            PASS (5×5)
  npu_requant_smoke_test:         PASS
  npu_cluster_mode_test:          4/4 PASS
  npu_fc_full_cluster_96out_test: PASS
  npu_perf_counter_scaling_test:  PASS
  npu_cluster_mask_sweep_test:    PASS
  npu_back_to_back_task_test:     PASS
  npu_fc_16x16_full_array_test:   PASS
  npu_gap_smoke_test:             PASS
  npu_conv_stride2_test:          PASS
  npu_conv_1x1_smoke_test:        PASS
  npu_conv_3x3_same_test:         PASS
  npu_conv_5x5_singlewindow_diag_test: PASS
  npu_pool_smoke_test:            PASS
  npu_add_smoke_test:             PASS
  npu_lenet_1_test:               PASS
  tb_dma_writer_long_burst:       5/5 PASS (80.00%)
  tb_dma_writer_*:                4/4 PASS
  +19 additional diagnostic/stress/perf tests: all PASS

### 8.4. Architecture Refactor: 64×64 Single-Cluster + Bug Fixes (2026-06-29)

**Architecture refactor**: Reverted to 64×64 PE single-cluster (CLUSTER_COUNT 6→1).
TILE_ROWS=16, TILE_COLS=16, PE_ROWS=64, PE_COLS=64, total PE=4,096.
Peak: 1.6384 TOPS @ 200MHz. Supports native 5×5 Conv for LeNet-5.

- cluster_scheduler.v: parameterized for CLUSTER_COUNT (1..N)
- output_arbiter.v: CLUSTER_OUT_W default 64*32=2048 for 64 PE columns
- npu_top.v: CLUSTER_COUNT=1, perf_cluster_enable width auto-scaled
- Hardcoded 64 values already parameterized to PE_COLS (from previous fix)
- 5×5 Conv restored: KERNEL_SPATIAL=25, task_checker 5×5 re-enabled
- Testbenches synced: tb_soc_top_uvm.sv NPU_TILE_ROWS=16, LeNet tb uses 16

**Bug fixes retained from 16×16 phase:**
  - GAP acc_wr_en/data/addr fix (fsm_state timing race)
  - conv_frontend stride2 row transition shift count fix
  - FC total_global_cols reverted to output_c (correct for PE_COLS=64, single cluster)

## 9. Future Work & Known Blockers

### Active
  - **P2 Phase B 1 beat/cycle**: blocked by act_buffer 2-cycle read latency.
    Requires registered pipeline (vec_relu_pipe + vec_relu_pipe2) or dual-port
    buffer.  vector_relu bandwidth theoretical cap ~87% (current: 64%).
  - **P3 store_pack 128-bit**: blocked by acc_buffer 32-bit single-port.
    Requires buffer DATA_WIDTH 32→128 + byte-enable writes + COLLECT column
    packing.  ~150 lines across npu_buffer.v + npu_top.v (6 writer paths).
    Expected: store_pack 16→~5 cycles/beat.

### Deferred (post-FPGA)
  1. FPGA synthesis / timing check
  2. UVM full regression
  3. Coverage flow
  4. Delivery hardening
  5. acc_buffer 128-bit widening (Phase C)
  6. read/compute/write overlap (ping-pong buffer architecture)
