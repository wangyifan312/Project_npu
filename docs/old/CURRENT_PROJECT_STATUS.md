# Current Project Status

本文档是 `Project_npu` 当前状态的统一入口。回答"已完成什么、证据在哪、什么未完成"。

---

## 1. 固定硬件基线

- SoC: `PicoRV32 + AXI interconnect + shared_ram + NPU`
- NPU: `1 x 64x64 PE cluster = 4,096 PE`
- 理论峰值: `1.6384 TOPS @ 200MHz`
- shared memory: `1 MB = 32768 x 256-bit beat`
- CPU 控制面: `32-bit AXI-Lite`
- NPU DMA 数据面: `256-bit AXI4 INCR burst`
- 正式计算路径: `cluster_scheduler -> compute_core -> output_arbiter`

---

## 2. NPU 优化状态

| 优化 | 状态 | 效果 |
|------|:--:|------|
| P1: FC 权重预加载 | ✅ | 多 tile FC 跳过 DMA (~20 cycles/tile) |
| P2: DRAIN+COLLECT 重叠 | ✅ | FC compute 197→69 cycles (-65%) |
| P3: 并行流水线 (FSM_PIPE_RUN) | ✅ | 多 block Conv TOPS 0.79 (2.5× vs 单 block) |
| 命名清理 | ✅ | compute_core_6cluster→compute_core, cluster_16x16→pe_cluster |

### 性能指标 (更新于 2026-06-29, P5 优化后)

| 指标 | 值 | 证据 |
|------|:--:|------|
| **赛题: AXI Burst BW ≥60%** | **64.04%** ✅ | `npu_bandwidth_60pct_stress_test` |
| **赛题: NPU TOPS ≥0.5** | **Conv: 1.02** ✅ | `npu_conv_multiblock_test` |
| VecReLU bus bandwidth | **64.04%** ✅ | `npu_bandwidth_60pct_stress_test` (PASS_TARGET) |
| Conv multi-block TOPS | **1.02** (P5 后提升) | `npu_conv_multiblock_test` |
| FC 64→128 TOPS | 0.35 | `npu_fc_128x128_peak_test` |
| Conv task-level BW | ~4.5% (compute-bound, 正常) | `npu_conv_multiblock_test` |
| FC task-level BW | ~31% | `npu_fc_128x128_peak_test` |
| DMA write burst util | **72.7%~84.2%** (P5 提升 3×) | UVM DMA monitor |
| DMA read burst util | 87.0%~93.9% | UVM DMA monitor |
| P5 pipelined store | ✅ 已修复 SP_PUSH bug, 所有 smoke PASS |

### 增强性能计数器 (新增 0xE8-0xFC)

| 寄存器 | 地址 | 说明 |
|--------|------|------|
| PERF_COMPUTE_CYCLES | 0xE8 | COMPUTE/PIPE_RUN 状态周期 |
| PERF_LOAD_CYCLES | 0xEC | 各类 LOAD 状态周期 |
| PERF_STORE_CYCLES | 0xF0 | STORE 状态周期 |
| PERF_COLLECT_CYCLES | 0xF4 | COLLECT 子状态周期 |
| PERF_READ_VALID_BYTES | 0xF8 | AXI 读有效 payload 字节 |
| PERF_WRITE_VALID_BYTES | 0xFC | AXI 写按 WSTRB 有效字节 |

---

## 3. 验证状态

### UVM 回归 (2026-06-29)

**34/34 正式 UVM 测试 PASS，0 mismatch。**

所有 smoke、feature、diagnostic、error-path、performance 测试全部通过。

已知 pre-existing issue: `npu_conv_multichannel_test` (cin=2, cout=2) 4/8 字节 mismatch，自原始基线 (9586d9e) 就存在，非 P1/P2/P3 引入。

### Verilog directed testbenches

- `tb_top` PASS
- `tb_top_lenet` 运行通过
- `tb_top_cluster_modes` PASS (single-cluster mode)
- DMA writer: 13/13 PASS (10 Verilog + 3 UVM smoke)
- Legacy `tb_task*` 为 micro 入口，不属正式基线

---

## 4. AXI Compliance

- 控制面: `AXI-Lite` 项目子集
- 数据面: `256-bit AXI4 INCR burst` 项目子集
- 当前不可表述为完整通用 AXI4/AXI-Lite IP

---

## 5. LeNet / MNIST 状态

- LeNet-5 完整兼容（5×5 Conv, 2×2 MaxPool, FC）
- Software full-set: `9885/10000 = 98.85%`
- RTL representative chunk: `3000/10000` merged, `2944/3000 = 98.13%`
- RTL full-set `10000/10000` 未完成（仿真成本）

---

## 6. ResNet-20 状态

- R0.5 software golden / export / handoff 已完成
- Software fixed-point gate: `8639/10000 = 86.39%`
- R1a-R1i RTL foundations 已实现（Conv/FC/Residual ADD/GAP/Requant）
- Full 32-task ResNet-20 RTL end-to-end closure 仍未完成
- 详细见 `docs/RESNET20_CURRENT_STATUS.md`

---

## 7. 已知问题

| 问题 | 状态 | 说明 |
|------|:--:|------|
| FC input_c > 64 多 chunk | ⚠️ | Phase 2 shadow register timing issue |
| Conv multi-c_in 权重 preload | ⚠️ | 原始基线 bug，cin=2 时 4/8 字节 mismatch |
| TOPS >1.3 (FC path) | ❌ | FC 0.35 TOPS，需 P3 double-buffering + 512-bit AXI |
| npu_gemm_pipeline_bw_tops_test | 🔬 | 实验性测试，暂不作为达标证据 |
| Conv/FC task-level BW | ⚠️ | ~4.5%~31%，compute-bound 场景下任务级 BW 天然低，非瓶颈 |

已解决的历史问题: `docs/known_issues/` (conv_multicluster_mismatch, conv_multiwindow_drain_hang)

---

## 8. 后续工作

### 高优先级
1. **512-bit AXI 迁移**: `feature/512bit` 分支。DMA 带宽翻倍，TOPS>1.3 和 bus≥60% 的前提
2. **acc_buffer 128-bit 拓宽**: STORE 路径吞吐瓶颈消除

### 低优先级
3. Coverage flow
4. FPGA synthesis / timing check
5. Delivery hardening
6. Conv multi-c_in weight preload bug fix
7. Multi-chunk FC shadow register bug fix

---

## 9. 不可改动的 Contract

- LeNet 地址图
- requant 算法语义（round-half-away-from-zero, clamp [-128,127]）
- shared memory: `32768 x 256-bit beat`
- NPU task base address `64B` 对齐
- `acc_buffer -> DMA writer` `32-bit word -> 256-bit beat` packing
- last-beat `WSTRB` 根据实际 byte count 生成
- dma_axi_writer.v W-channel skid buffer (Phase B2)
- write_beat_fifo.v depth=64 (P2, 不得减小)
- store_pack lane ordering
- acc_buffer structure (32-bit, single-port)
- requant_i32_to_i8.v formula
- Golden/reference/scoreboard

---

## 10. 专题文档入口

- `CLAUDE.md`: coding agent 工程约束
- `README.md`: 仓库导航和快速入口
- `docs/HB_256BIT_REFACTOR_SPEC.md`: 256-bit 数据面基线
- `docs/AXI_COMPLIANCE_SPEC.md`: AXI 支持范围
- `docs/soc_fs.md`: SoC 功能规格与寄存器
- `docs/LENET_MNIST_SPEC.md`: LeNet 网络和数据布局
- `docs/NPU_RTL_TODO.md`: Workstream A/B/C 证据
- `docs/PERFORMANCE_SUMMARY.md`: 性能证据
- `docs/MNIST_FULL_EVAL_PLAN.md`: Full-set evaluation
- `docs/RESNET20_CURRENT_STATUS.md`: ResNet-20 当前状态
- `docs/RTL_DEBUG_PLAYBOOK.md`: 调试手册
- `docs/DELIVERY_CHECKLIST.md`: 交付清单
- `docs/known_issues/`: 已解决的历史问题
