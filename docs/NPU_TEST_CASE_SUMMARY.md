# NPU 测试用例汇总

## 1. 总览

| 项目 | 数量 |
|------|------|
| active registered tests | **62** |
| archived tests | **6** |
| orphan tests | **0** |
| UVM_ERROR | **0** |
| UVM_FATAL | **0** |
| 运行命令 | `./verif/uvm_top/scripts/run_uvm.sh <test_name> UVM_NONE [plusargs...]` |
| CPU-running tests | `run_uvm.sh ... +TB_AXIL_ENABLE=0`（plusarg 由脚本透传） |

## 2. 测试分类统计

| 分类 | 数量 | 说明 |
|------|------|------|
| Smoke / basic | 5 | CSR, DMA, task start/poll, basic operators |
| GEMM / MatrixOp fast path | 7 | GEMM streaming, K>64, N-tile, extreme values, B1 |
| FC streaming | 5 | FC streaming, ReLU, INT8 pack, robustness, fallback |
| Legacy / auxiliary operators | 14 | Conv, Add, Pool, GAP, Requant, bias, VecReLU |
| Back-to-back / pipeline | 2 | Sequential tasks, store/compute overlap |
| Low-power / clock gating | 1 | PE array idle clock disable (U6-a) |
| Performance / bandwidth | 7 | Counters, throughput, TOPS |
| Error path | 2 | Misaligned addr, start-while-busy |
| Cluster / array structural | 2 | Full-array activation, multi-window diag |
| Diagnostic | 5 | Conv single/multi-window, 5×5 kernel diag |
| **NPU IRQ (U8-a)** | **1** | BFM-level IRQ protocol verification |
| **CPU-running smoke (U8-b)** | **3** | PicoRV32 boot/polling/IRQ smoke |
| **DMA read partial mask (U9-a1)** | **2** | DMA read-side data_strb partial beat zero-padding |
| **DMA buffer capacity guard (U9-a2)** | **1** | task_checker rejects input/weight exceeding buffer bank capacity |
| **AXI4 4KB boundary split (U9-a3)** | **4** | DMA reader/writer auto-split bursts at 4KB boundaries (incl. forced writer split) |
| **Total active** | **62** | — |

## 3. Smoke / Basic Tests

| Test | Purpose | Result |
|------|---------|--------|
| `soc_shared_ram_rw_test` | AXI-Lite path sanity: write/read shared RAM | PASS |
| `npu_fc_smoke_test` | Legacy FC: 4×1 INT8 input, DPI golden | PASS |
| `npu_conv_smoke_test` | Legacy Conv 5×5 valid: DPI golden | PASS |
| `npu_add_smoke_test` | INT8 element-wise ADD | PASS |
| `npu_gap_smoke_test` | 8×8 GAP | PASS |

## 4. GEMM / MatrixOp Fast Path Tests

| Test | Purpose | Key Coverage | Result |
|------|---------|-------------|--------|
| `npu_task_gemm_func_test` | TASK_GEMM functional | G0-G6 levels | PASS |
| `npu_task_gemm_row_streaming_test` | GEMM row-streaming | RS0-RS19 + MT0-MT5 + NT0-NT6 | PASS |
| `npu_gemm_kchunk_stress_test` | K>64 K-chunk accumulation | K=65,127,128,129,192,255; M=1,4,8; N=1,8,63,64,65 (36 cases) | PASS |
| `npu_matrixop_partial_beat_stress_test` | INT32/INT8 partial beat | N=1-65; byte-accurate compare (60 cases) | PASS |
| `npu_int8_extreme_value_stress_test` | Signed INT8 extremes | 8 patterns × 4 K × 6 M/N (192 cases) | PASS |
| `npu_gemm_ntile_nonuniform_diag_test` | N>64 non-uniform weight | Bug B1 fix verification (checkerboard, col-coded, k-col-coded) | PASS |
| `npu_axi_gemm_peak_test` | AXI-fed GEMM peak | Supplemental throughput | PASS |

## 5. FC Streaming Tests

| Test | Purpose | Key Coverage | Result |
|------|---------|-------------|--------|
| `npu_fc_streaming_smoke_test` | FC through streaming GEMM pipeline | MatrixOp unification | PASS |
| `npu_fc_streaming_relu_test` | FC streaming + ReLU via GST | store_desc_relu_en | PASS |
| `npu_fc_streaming_robustness_test` | Boundary, signed, legacy-vs-streaming | FCR0-FCR7 + MATCH | PASS |
| `npu_fc_streaming_int8_pack_test` | FC INT8 packing (conv_cfg[6] hook) | U4-d INT8 infrastructure | PASS |
| `npu_fc_streaming_fallback_test` | FC with bias falls back to legacy | K1/K1-b fix verified | PASS |

## 6. Legacy / Auxiliary Operator Tests

| Test | Purpose | Result |
|------|---------|--------|
| `npu_conv_1x1_smoke_test` | Conv 1×1 kernel, 3×3 input | PASS |
| `npu_conv_3x3_same_test` | Conv 3×3 kernel, same padding | PASS |
| `npu_conv_stride2_test` | Conv 3×3 kernel, stride=2 | PASS |
| `npu_conv_bias_requant_test` | Conv 5×5, bias + requant, 2 output channels | PASS |
| `npu_conv_multichannel_test` | Conv 3×3, Cin=2, Cout=2 multi-channel | PASS |
| `npu_pool_smoke_test` | 2×2 MaxPool, 1 channel | PASS |
| `npu_pool_multichannel_test` | 2×2 MaxPool, 4 channels | PASS |
| `npu_requant_smoke_test` | INT32→INT8 requant, multiplier/shift | PASS |
| `npu_requant_extreme_test` | Requant clamping at [-128,127] boundary | PASS |
| `npu_requant_partial_beat_test` | Requant 9 INT32→9 INT8, non-beat-aligned | PASS |
| `npu_add_requant_test` | INT8 ADD with pre/post-requant | PASS |
| `npu_bandwidth_test` | Conv bandwidth: DMA read/write traffic | PASS |
| `npu_bandwidth_60pct_stress_test` | VecReLU 256-bit streaming: 60% bus target | PASS |
| `npu_conv_bandwidth_test` | Conv bandwidth: 1×1, 128 output channels | PASS |

## 7. Back-to-Back / Pipeline Tests

| Test | Purpose | Result |
|------|---------|--------|
| `npu_back_to_back_task_test` | Two sequential FC tasks without reset | PASS |
| `npu_back_to_back_task_stress_test` | 8 streaming transitions: GEMM↔FC↔ReLU↔K-chunk | PASS |

## 8. Low-Power / Clock Gating Test (U6-a)

| Test | Purpose | Key Coverage | Result |
|------|---------|-------------|--------|
| `npu_pe_array_clock_gating_test` | PE array clock gating verification | saw_idle_zero=1, saw_active_one=1, saw_done_zero=1 | PASS |

## 9. Performance / Bandwidth Tests

| Test | Purpose | Result |
|------|---------|--------|
| `npu_peak_throughput_test` | FC 64→64: full 4096 PE throughput | PASS |
| `npu_fc_128x128_peak_test` | FC 128×128 peak TOPS measurement | PASS |
| `npu_conv_multiblock_test` | Conv multi-block: 3 blocks pipeline | PASS |
| `npu_lenet_1_test` | Full LeNet-5 9-layer pipeline | PASS |
| `npu_gemm_pipeline_bw_tops_test` | GEMM pipeline BW+TOPS (EXPERIMENTAL) | Historical |

## 10. Error Path Tests

| Test | Purpose | Expected Error | Result |
|------|---------|---------------|--------|
| `npu_error_misaligned_addr_test` | Non-64B-aligned address triggers error | ERR_ADDR_ALIGN (0x04) | PASS |
| `npu_start_while_busy_test` | CTRL.start while busy → error | ERR_START_WHILE_BUSY | PASS |

**注**: `npu_error_invalid_task_test` 已在 U9-a2 归档。`ERR_INVALID_TASK_TYPE (0x01)` 不可触发——硬件在 `npu_ctrl.v:526` 将 `cfg_task_type` 掩码至 `[2:0]`，所有 8 个值 (0-7) 均合法。

## 11. Cluster / Array Structural Tests

| Test | Purpose | Result |
|------|---------|--------|
| `npu_fc_16x16_full_array_test` | Full 16×16 tile array activation, sticky probe | PASS |
| `npu_fc_full_array_activation_test` | Full 64×64 PE array activation (renamed U7-a) | PASS |

## 12. Diagnostic Tests

| Test | Purpose | Result |
|------|---------|--------|
| `npu_conv_1x1_single_16oc_diag_test` | Single-cluster Conv 16oc baseline | PASS |
| `npu_conv_1x1_multiwindow_diag_test` | 1×1 Conv multi-window test | PASS |
| `npu_conv_3x3_multiwindow_diag_test` | 3×3 Conv multi-window test | PASS |
| `npu_conv_5x5_singlewindow_diag_test` | 5×5 Conv single-window baseline | PASS |
| `npu_conv_1x1_full_array_multiwindow_diag_test` | Full-array multi-window test (renamed U7-a) | PASS |
| `npu_conv_1x1_full_96oc_diag_test` | 1×1 Conv 96 output channels | PASS |

## 13. NPU IRQ Report Tests (U8-a)

| Test | Purpose | Key Coverage | Result |
|------|---------|-------------|--------|
| `npu_irq_reporting_test` | BFM-level IRQ protocol verification | 7 sub-tests: IRQ_EN reset=0, done pending, error pending, IRQ_EN gating, W1C clear, back-to-back | PASS |

**U8-a 说明：** AXI-Lite BFM modeled interrupt handling。不涉及 CPU-running firmware。

## 14. CPU-Running Smoke Tests (U8-b)

| Test | Purpose | Mode | Result |
|------|---------|------|--------|
| `soc_cpu_boot_magic_smoke_test` | PicoRV32 boot from shared RAM, write MAGIC_BOOT | `+TB_AXIL_ENABLE=0` | PASS |
| `soc_cpu_npu_polling_smoke_test` | CPU configures NPU CSR, starts GEMM, polls done | CPU mode | PASS |
| `soc_cpu_npu_irq_smoke_test` | CPU enables done IRQ, receives irq[4], handler clears | CPU mode (`+TB_AXIL_ENABLE=0`) | PASS |

**U8-b 说明：**
- Minimal bare-metal firmware smoke verification
- 不是完整软件驱动栈
- `riscv64-unknown-elf-gcc 8.1.0` 编译 firmware（`-march=rv32i -mabi=ilp32`）
- BFM 不在 CPU-running test 中写 NPU CSR
- IRQ return-to-main 不是 primary pass criterion
- **必须使用 `+TB_AXIL_ENABLE=0` 启动。不加此 plusarg 时 `tb_axil_enable=1`（BFM mode），CPU 处于 reset（`cpu_resetn = rst_n && !tb_axil_enable = 0`），MAGIC_BOOT timeout 是预期行为而非 bug**

**soc_cpu_npu_irq_smoke_test 关键验证链：**
1. CPU 写 MAGIC_BOOT
2. CPU 写 NPU_IRQ_CLEAR=3, NPU_IRQ_EN=1, maskirq[4]=0
3. CPU 配置 GEMM M=1,K=4,N=1, 写 CTRL.start
4. NPU done → npu_irq 拉高 → CPU irq[4] 接收
5. CPU 进入 IRQ vector 0x10 (irq_handler)
6. handler 读 IRQ_STATUS=0x01, 写 MAGIC_IRQ_STATUS
7. handler 写 IRQ_CLEAR=1 → npu_irq 拉低
8. handler 写 MAGIC_IRQ_SEEN=0x1A2B3C4D, MAGIC_TEST_DONE=0x55AA55AA
9. output=0x00000004, cpu_trap=0

## 15. DMA Read Partial Beat Mask Tests (U9-a1)

| Test | Purpose | Key Coverage | Result |
|------|---------|-------------|--------|
| `npu_dma_read_partial_poison_test` | Poison tail mask verification | GEMM M=1,K=4,N=1; 4B 0x01 valid + 28B 0x7F poison in one 32B beat; output=4 confirms mask works | PASS |
| `npu_dma_read_partial_mask_test` | Multi-size partial beat mask | K=4,8,12,20,36,68 (single/multi-beat partial); all output values correct despite poison tails; ARSIZE remains 3'd5 | 6/6 PASS |

**U9-a1 说明：**
- `dma_axi_reader` 新增 `data_strb` 输出，基于 transfer-level `bytes_remaining` 计算
- `data_strb` 与 `data_out`/`data_valid` 同拍
- full beat 时 `data_strb` 全 1；partial final beat 时仅有效 byte 为 1
- `act_read_path` / `weight_read_path` 写 buffer 前 `& strb_mask` 清零无效 byte
- **不是 narrow burst**（ARSIZE 保持 3'd5）
- **不是 variable-size burst**
- **不是 unaligned DMA**
- **不是 4KB boundary split**
- `soc_base_test` 是 abstract base class，不计入 active concrete tests 数量

## 16. DMA Buffer Capacity Guard Test (U9-a2)

| Test | Purpose | Key Coverage | Result |
|------|---------|-------------|--------|
| `npu_dma_buffer_capacity_guard_test` | Buffer capacity overflow rejection | Case A: input_bytes overflow → ERR_BUF_OVERFLOW; Case B: weight_bytes overflow → ERR_BUF_OVERFLOW; Case C/D: legal sizes NOT falsely rejected | 4/4 PASS |

**U9-a2 说明：**
- `task_checker` 新增 `BUF_ENTRIES`/`DMA_DATA_W` 参数，计算 `BUF_BANK_BYTES = 512 KiB`
- `input_bytes > BUF_BANK_BYTES` → `ERR_BUF_OVERFLOW (0x0D)`
- `weight_bytes > BUF_BANK_BYTES` → `ERR_BUF_OVERFLOW (0x0D)`
- 等于 BUF_BANK_BYTES 允许，大于则拒绝
- overflow 时不会启动 DMA
- **不是修改 DMA reader/writer**
- **不是修改 MatrixOp、PE array、IRQ CSR**

## 17. AXI4 4KB Boundary Split Tests (U9-a3)

| Test | Purpose | Key Coverage | Result |
|------|---------|-------------|--------|
| `npu_dma_read_4kb_boundary_split_test` | Reader AR burst 4KB split | input_addr=0x0F80, 256B read → 2 AR bursts (ARLEN=3 each); output correct | PASS |
| `npu_dma_write_4kb_boundary_split_test` | Writer AW burst 4KB split | output_addr=0x2F80, 256B write → 2 AW bursts (AWLEN=3 each); output correct | PASS |
| `npu_dma_4kb_boundary_mixed_test` | Mixed read+write 4KB split | All 3 channels near 4KB boundaries simultaneously; output correct | PASS |
| `npu_dma_writer_forced_4kb_split_test` | Writer forced 4KB split (VecReLU) | Proves calc_burst_beats_4kb truncates burst at 4KB: AW0=4 beats at 0x2F80→0x2FFF, AW1=4 beats at 0x3000→0x307F | PASS |

**U9-a3 说明：**
- DMA reader/writer 均实现 4KB boundary auto-split（不返回 error）
- ARSIZE/AWSIZE 保持 3'd5, ARBURST/AWBURST 保持 INCR
- DMA monitor 已添加 AR/AW 4KB boundary check
- **不是 narrow burst，不是 variable-size burst，不是 unaligned DMA**

## 18. Archived Tests

| Test | 归档原因 |
|------|----------|
| `npu_cluster_mode_test` | Multi-cluster modes; CLUSTER_COUNT=1 renders mode>0 as NO-OP |
| `npu_cluster_mask_sweep_test` | Multi-cluster mask sweep; only mask[0] valid for CLUSTER_COUNT=1 |
| `npu_perf_counter_scaling_test` | 1/2/6 cluster scaling; meaningless for CLUSTER_COUNT=1 |
| `npu_conv_1x1_dual_32oc_diag_test` | Dual-cluster Conv diagnostic; CLUSTER_COUNT=1 |
| `npu_fc_b1_diag` | Historical FC B1 multi-tile mismatch diagnostic; pre-fix fingerprint |
| `npu_error_invalid_task_test` (U9-a2) | ERR_INVALID_TASK_TYPE (0x01) unreachable: hardware masks cfg_task_type to [2:0], all 0-7 valid |

存档位置: `verif/uvm_top/tests/archive/`

## 19. 回归套件

| 套件 | 测试数 | 运行方式 |
|------|--------|----------|
| Core regression | 7 | 默认 BFM mode |
| MatrixOp fast path | 10 | 默认 BFM mode |
| Legacy / fallback | 6 | 默认 BFM mode |
| Low-power | 1 | 默认 BFM mode |
| NPU IRQ | 1 | 默认 BFM mode |
| CPU-running smoke | 3 | `+TB_AXIL_ENABLE=0`（由 run_uvm.sh 透传至 simv） |
| DMA read partial mask (U9-a1) | 2 | 默认 BFM mode |
| DMA buffer capacity guard (U9-a2) | 1 | 默认 BFM mode |
| AXI4 4KB boundary split (U9-a3) | 4 | 默认 BFM mode |
| Full active regression | 62 | 全部 |

**CPU-running test 运行注意：**
- `soc_cpu_npu_irq_smoke_test` 必须使用 `+TB_AXIL_ENABLE=0`
- 不加此 plusarg 时 CPU 处于 reset 状态，MAGIC_BOOT timeout 是预期行为
- 运行命令：`./verif/uvm_top/scripts/run_uvm.sh soc_cpu_npu_irq_smoke_test UVM_NONE +TB_AXIL_ENABLE=0`
