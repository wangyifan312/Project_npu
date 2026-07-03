# NPU 架构与功能总览

## 1. 项目版本信息

| 项目 | 值 |
|------|-----|
| 最终交付 tag | `npu-final-delivery-v1.5-clean` |
| main HEAD | `d5d2828` |
| 架构基线 | single-cluster 64×64 PE NPU (CLUSTER_COUNT=1) |
| active registered tests | **61** |
| archived tests | **6** |
| orphan tests | **0** |
| UVM_ERROR | **0** |
| UVM_FATAL | **0** |

## 2. SoC 顶层架构

```
top
├── PicoRV32 CPU (picorv32_axi)
├── AXI interconnect
├── shared_ram (1MB, 32768×256-bit)
└── NPU (npu_top)
```

**CPU/NPU 关系：**
- PicoRV32 通过 AXI-Lite 访问 shared_ram 和 NPU CSR
- NPU 通过 256-bit AXI4 DMA 访问 shared_ram
- 验证环境支持双模式：
  - `tb_axil_enable=1`（默认）：AXI-Lite BFM 驱动 NPU CSR（56 个 tests 的默认模式）
  - `tb_axil_enable=0`：PicoRV32 CPU 驱动 NPU CSR（U8-b 3 个 tests 的 CPU-running 模式）
  - CPU-running mode 通过 `run_uvm.sh ... +TB_AXIL_ENABLE=0` 启动（plusarg 由脚本透传至 simv）
- CPU reset vector = `0x00000000`（shared_ram 基址）
- CPU IRQ vector = `0x00000010`

## 3. NPU 整体架构

```
npu_top
├── npu_ctrl (AXI-Lite CSR register file)
├── task_checker (参数合法性检查)
├── act_read_path → dma_axi_reader (activation DMA)
├── weight_read_path → dma_axi_reader (weight DMA)
├── dma_axi_writer (output DMA)
├── write_beat_fifo (256-bit beat buffer, depth 64)
├── npu_buffer × 3 (act/wgt/acc double-buffer)
├── conv_frontend (legacy sliding-window Conv)
├── fc_frontend (FC weight load)
├── block_scheduler (output block split)
├── cluster_scheduler (cluster enable, CLUSTER_COUNT=1)
├── compute_core → pe_cluster → array_top → mac_tile_4x4×256 → mac_pe×4096
├── output_arbiter (cluster result merge)
├── postproc (ReLU + 2×2 MaxPool)
├── requant_i32_to_i8
├── bias_add_requant_i32_to_i8
├── residual_add_requant_i8
├── gap8x8_requant_i8
└── perf_counter
```

**核心参数：**
- PE array: 64×64 INT8 systolic array, 4096 PEs
- 16×16 tiles of 4×4 MAC tiles
- INT8 activation × INT8 weight → INT32 accumulation
- 200 MHz 仿真时钟
- 理论峰值: 1.6384 TOPS
- 256-bit AXI4 DMA (BEAT_BYTES=32)

## 4. 数据通路

```
Input:  shared_ram → AXI4 read DMA → [data_strb zero-pad] → act_buffer → PE array
Weight: shared_ram → AXI4 read DMA → [data_strb zero-pad] → wgt_buffer → wgt_load_reg → PE array
Output: PE array → output_arbiter → acc_buffer → store_pack → write_beat_fifo → AXI4 write DMA → shared_ram
```

**DMA read-side partial beat zero-padding (U9-a1):**
- `dma_axi_reader` 输出 `data_strb`（与 `data_out`/`data_valid` 同拍）
- `data_strb` 基于 transfer-level `bytes_remaining` 计算，不使用 burst-level `RLAST`
- full beat: `data_strb` 全 1
- partial final beat: `data_strb` 仅有效 byte 为 1
- `act_read_path` / `weight_read_path` 写 buffer 前 `dma_data_out & strb_mask` 清零无效 byte
- AXI read 保持 256-bit full-width INCR burst（ARSIZE=3'd5）
- **不是 narrow burst，不是 variable-size burst，不是 unaligned DMA**

**DMA buffer capacity guard (U9-a2):**
- `task_checker` 在任务启动前检查 `input_bytes` 和 `weight_bytes` 是否超过单 buffer bank 容量
- `BUF_ENTRIES = 16384`, `DMA_DATA_W = 256`, `BUF_BANK_BYTES = 512 KiB`
- 超过则拒绝任务并返回 `ERR_BUF_OVERFLOW (0x0D)`
- 等于 BUF_BANK_BYTES 允许，大于则拒绝

**AXI4 4KB boundary burst split (U9-a3):**
- DMA reader 和 writer 的 burst 计算均加入 4KB boundary 限制
- 跨 4KB 时自动拆分 burst，不返回 error
- 所有 AR/AW burst 满足: `(addr[11:0] + ((len+1) << size)) <= 4096`
- ARSIZE/AWSIZE 保持 3'd5, ARBURST/AWBURST 保持 INCR
- **不是 narrow burst，不是 variable-size burst，不是 unaligned DMA**

**MatrixOp streaming path (GST):**
```
PE array → result_tile_bank → GST store engine → write_beat_fifo → DMA writer → shared_ram
```

## 5. 控制通路

1. CPU/BFM 写 NPU CSR → npu_ctrl 锁存
2. task_checker 验证参数 → checks_pass → task_start
3. npu_top FSM 根据 task_type 选择路径
4. MatrixOp streaming: FSM_GEMM_STREAM_RUN
5. Legacy FC/Conv: FSM_COMPUTE + FSM_STORE
6. 完成后 task_done_r → npu_ctrl.done → CTRL[2]=1

## 6. MatrixOp Fast Path

**当前覆盖：**

| 功能 | 状态 |
|------|------|
| GEMM | ✅ |
| pure FC | ✅ |
| FC + ReLU-only | ✅ |
| result_tile_bank double-buffer | ✅ |
| GST INT32 output | ✅ |
| GST ReLU (store_desc_relu_en) | ✅ |
| GST INT8 packing (conv_cfg[6] test hook) | ✅ |
| K>64 K-chunk accumulation (K=65,127,128,129,192,255) | ✅ |
| N-tiling (N>64) + non-uniform weight data (Bug B1 fixed) | ✅ |
| M-tiling (M>8) | ✅ |
| partial-beat / row_stride / byte_count (INT32/INT8) | ✅ |
| back-to-back task transitions (8 streaming combos) | ✅ |
| enhanced performance counters (K2 fixed) | ✅ |

## 7. Legacy Operator Path

**保留路径（非 MatrixOp）：**

| 操作 | Task Type | 路径 |
|------|-----------|------|
| Conv | 0 | conv_frontend + legacy compute + acc_buffer store |
| FC (with bias/requant) | 1 | legacy FC + bias_add_requant + acc_buffer store |
| Pool | 2 | legacy postproc + store |
| Requant | 3 | standalone requant path |
| GAP | 4 | gap8x8_requant_i8 |
| ADD | 5 | residual_add_requant_i8 |
| VecReLU | 6 | 256-bit streaming DMA path |

**Conv 当前实现说明：**
- Conv 不是 MatrixOp fast path
- 通过 legacy `conv_frontend` 生成滑动窗口输入流
- 复用 64×64 INT8 systolic PE array 做 MAC
- 输出走 legacy accumulation / postproc / requant / store path
- 类似 hardware sliding-window / implicit-window generation
- 不是显式 materialized im2col + GEMM
- 不是已完成的 general Conv MatrixOp

## 8. Low-Power Clock Gating (U6-a)

- PE array dynamic clock gating：NPU idle/done/error 时关闭 PE array tile clock enable
- `array_top.v` 中有 per-tile AND-gate: `gated_clk[ti] = clk & tile_clk_en_latched[ti]`
- 动态使能: `pe_array_clk_en_comb = (fsm_state != IDLE) && (fsm_state != DONE) && (fsm_state != ERROR)`
- `npu_pe_array_clock_gating_test` PASS：idle tile_clk_en=0，active≠0，done=0
- RTL clock-enable behavior verification，不是门级功耗测量

## 9. NPU IRQ Reporting (U8-a + U8-b)

**IRQ CSR：**

| Register | Address | Width | Access | Description |
|----------|---------|-------|--------|-------------|
| IRQ_EN | 0x100 | [1:0] | RW | bit0=done_irq_en, bit1=error_irq_en |
| IRQ_STATUS | 0x104 | [1:0] | RO | bit0=done_pending, bit1=error_pending |
| IRQ_CLEAR | 0x108 | [1:0] | W1C | write 1 clears corresponding pending bit |

**IRQ 语义：**
- IRQ_STATUS: sticky pending，不受 IRQ_EN 影响
- IRQ_EN: 仅 gate npu_irq 输出，默认 0（向后兼容）
- IRQ_CLEAR: write-1-clear，写 0 不清
- `npu_irq = |(IRQ_STATUS & IRQ_EN)`
- NPU CSR window = 512B (NPU_MASK=0xFFFF_FE00)

**信号连接：**
- `npu_irq` → `cpu_irq[4]` → PicoRV32 `.irq(cpu_irq)`
- PicoRV32 IRQ vector = `0x00000010`
- `ENABLE_IRQ=1` (U8-b 打开)

**验证层级：**
- U8-a: AXI-Lite BFM IRQ protocol verification (npu_irq_reporting_test, 7 sub-tests PASS)
- U8-b0: PicoRV32 boot magic smoke PASS
- U8-b1: PicoRV32 CPU NPU polling smoke PASS
- U8-b2: PicoRV32 CPU NPU IRQ smoke PASS
  - CPU 写 NPU_IRQ_EN + maskirq[4]=0
  - NPU done → npu_irq 拉高 → CPU irq[4] 接收
  - CPU IRQ handler 读取 IRQ_STATUS=0x01
  - CPU handler 写 IRQ_CLEAR → npu_irq 拉低
  - MAGIC_IRQ_SEEN 写入

**范围限制：**
- U8-b 是 minimal bare-metal firmware smoke verification
- 不是完整软件驱动栈
- IRQ return-to-main 不是 primary pass criterion

## 10. 当前能力边界

| 维度 | 状态 |
|------|------|
| MatrixOp GEMM/FC/FC+ReLU | ✅ 冻结基线 |
| legacy Conv/Add/Pool/GAP/Requant | ✅ 保留 |
| PE array clock gating | ✅ U6-a |
| NPU IRQ reporting | ✅ U8-a + U8-b |
| DMA read partial beat zero-padding | ✅ U9-a1 |
| DMA buffer capacity guard | ✅ U9-a2 |
| AXI4 4KB boundary split | ✅ U9-a3 |
| multi-cluster | ❌ CLUSTER_COUNT=1 最终基线 |
| 512-bit AXI | ❌ 未实现 |
| general Conv MatrixOp | ❌ 未实现 |
| descriptor queue | ❌ 未实现 |
| full software driver stack | ❌ 仅 minimal bare-metal firmware smoke |
| 4KB boundary split (AXI4) | ✅ U9-a3 (auto-split, not error) |
| narrow burst | ❌ 未实现 |
| variable-size burst | ❌ 未实现 |
| unaligned DMA | ❌ 未实现 |

## 11. 最终 Tag 链

```
npu-final-delivery-v1.5-clean → d5d2828 (baseline for U9-a1)
npu-final-delivery-v1.4-irq   → 30ea955 (CPU IRQ smoke delivery)
npu-cpu-irq-smoke-u8b         → 30ea955
npu-irq-reporting-u8a         → 3bf787c
npu-final-delivery-v1.3-docsync → 9f09709
npu-final-delivery-v1.2-clean → a458a7f
npu-final-delivery-v1.0       → fbfb3f2
npu-lowpower-clock-gating-u6a → fbfb3f2
```
