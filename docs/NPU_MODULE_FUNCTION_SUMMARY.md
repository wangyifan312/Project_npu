# NPU 模块功能汇总

## SoC 层

| 模块 | 文件 | 功能 |
|------|------|------|
| `top` | `rtl/soc/top.v` | SoC 顶层：PicoRV32 + AXI interconnect + shared_ram + NPU。支持 BFM mode (`tb_axil_enable=1`) 和 CPU-running mode (`tb_axil_enable=0`) |
| `picorv32_axi` | `rtl/cpu/picorv32/picorv32.v` | PicoRV32 RISC-V CPU。`ENABLE_IRQ=1`, `PROGADDR_RESET=0x0`, `PROGADDR_IRQ=0x10`, `irq[4]` 接 NPU IRQ |
| `axi_interconnect` | `rtl/bus/axi_interconnect.v` | AXI 地址解码 + 多路复用。NPU CSR window = 512B (`NPU_MASK=0xFFFF_FE00`) |
| `shared_ram` | `rtl/soc/shared_ram.v` | 32768×256-bit 双端口 RAM。CPU 端口 32-bit AXI-Lite，NPU 端口 256-bit AXI4 |

## NPU 控制

| 模块 | 文件 | 功能 |
|------|------|------|
| `npu_ctrl` | `rtl/npu/npu_ctrl.v` | AXI-Lite CSR register file (128 registers, 7-bit address)。含 task 控制、地址/维度配置、perf counter readout、requant/add/gap 配置、CLUSTER_MODE/MASK (reserved)、**IRQ CSR (0x100/0x104/0x108)** |
| `task_checker` | `rtl/npu/task_checker.v` | 任务参数合法性检查。验证 task_type、地址对齐、地址范围、bias/requant 参数、Conv/Pool 维度。输出 checks_pass/error_code |
| `block_scheduler` | `rtl/npu/block_scheduler.v` | 输出 block 拆分。Conv 按输出行拆分，FC/GEMM 直通 |
| `cluster_scheduler` | `rtl/npu/cluster_scheduler.v` | Cluster enable 控制。CLUSTER_COUNT=1 时始终 enable cluster[0] |
| `perf_counter` | `rtl/npu/perf_counter.v` | 性能计数器。记录 cycle、DMA beats、array/compute/store/collect active cycles、bus active、MAC count、stall 统计、valid bytes |

## NPU 主控制器

| 模块 | 文件 | 功能 |
|------|------|------|
| `npu_top` | `rtl/npu/npu_top.v` | NPU 主 FSM + 数据通路编排。MatrixOp streaming (FSM_GEMM_STREAM_*)、legacy fallback (FSM_COMPUTE/FSM_STORE)、DMA coordination、GST store engine (GEMM Store Engine)、result_tile_bank double-buffer、**PE array clock gating enable**、**IRQ signal export** |

## DMA 通路

| 模块 | 文件 | 功能 |
|------|------|------|
| `dma_axi_reader` | `rtl/npu/dma_axi_reader.v` | AXI4 read master。支持 INCR burst (max 16 beats)，RLAST 验证。**U9-a1: 新增 `data_strb` 输出，基于 transfer-level `bytes_remaining` 计算 partial final beat 有效 byte mask** |
| `act_read_path` | `rtl/npu/act_read_path.v` | Activation DMA reader wrapper。**U9-a1: 使用 `data_strb` 展开 bit-level mask，写入 act_buffer 前清零无效 byte** |
| `weight_read_path` | `rtl/npu/weight_read_path.v` | Weight DMA reader wrapper。**U9-a1: 使用 `data_strb` 展开 bit-level mask，写入 wgt_buffer 前清零无效 byte** |
| `dma_axi_writer` | `rtl/npu/dma_axi_writer.v` | AXI4 write master。Phase B2 next-beat preload，WSTRB 计算，burst splitting |
| `write_beat_fifo` | `rtl/npu/write_beat_fifo.v` | 256-bit beat FIFO (depth 64)。store_pack → DMA writer 缓冲 |

## Buffer / Memory

| 模块 | 文件 | 功能 |
|------|------|------|
| `npu_buffer` × 3 | `rtl/npu/npu_buffer.v` | Generic double-bank ping-pong buffer。act_buffer (256-bit×16384)、wgt_buffer (256-bit×16384)、acc_buffer (32-bit×16384) |

## 计算阵列

| 模块 | 文件 | 功能 |
|------|------|------|
| `compute_core` | `rtl/npu/compute_core.v` | PE array wrapper。CLUSTER_COUNT=1 时单实例 |
| `pe_cluster` | `rtl/npu/pe_cluster.v` | 单 cluster 控制。`local_enable` gate，pipeline latency counter，tile clock enable 分发 |
| `array_top` | `rtl/npu/array_top.v` | 16×16 mac_tile_4x4 脉动阵列。**Per-tile clock gating**: `gated_clk[ti] = clk & tile_clk_en_latched[ti]` |
| `mac_tile_4x4` | `rtl/npu/mac_tile_4x4.v` | 4×4 MAC tile，weight-stationary，activation 左→右，sum 上→下 |
| `mac_pe` | `rtl/npu/mac_pe.v` | 单 MAC：INT8 × INT8 → INT32 accumulation |

## 前端

| 模块 | 文件 | 功能 |
|------|------|------|
| `conv_frontend` | `rtl/npu/conv_frontend.v` | Legacy Conv sliding-window frontend。根据 Conv 参数生成 activation window stream。**不是 MatrixOp fast path** |
| `fc_frontend` | `rtl/npu/fc_frontend.v` | FC weight load frontend |

## 后端 / 结果处理

| 模块 | 文件 | 功能 |
|------|------|------|
| `output_arbiter` | `rtl/npu/output_arbiter.v` | Cluster 结果仲裁。CLUSTER_COUNT=1 时直通 cluster[0] |
| `postproc` | `rtl/npu/postproc.v` | ReLU + 2×2 MaxPool |
| `requant_i32_to_i8` | `rtl/npu/requant_i32_to_i8.v` | INT32→INT8 重量化: `clamp((acc × mult) >> shift, -128, 127)` |
| `bias_add_requant_i32_to_i8` | `rtl/npu/bias_add_requant_i32_to_i8.v` | Bias add + ReLU + requant |
| `residual_add_requant_i8` | `rtl/npu/residual_add_requant_i8.v` | Residual ADD with pre/post requant |
| `gap8x8_requant_i8` | `rtl/npu/gap8x8_requant_i8.v` | 8×8 Global Average Pool with requant |

## 验证基础设施

| 组件 | 位置 | 功能 |
|------|------|------|
| `tb_soc_top_uvm` | `verif/uvm_top/tb/` | UVM top-level testbench。实例化 DUT + interfaces + probes |
| `soc_probe_if` | `verif/uvm_top/interfaces/` | UVM probe interface: npu_status, npu_irq, cpu_trap, tile_clk_en_flat, DMA signals |
| `backdoor_if` | `verif/uvm_top/interfaces/` | Backdoor shared_ram access: load_memh(), read32() |
| `axil_if` | `verif/uvm_top/interfaces/` | AXI-Lite BFM interface |
| `soc_base_seq` | `verif/uvm_top/sequences/` | axil_write32/axil_read32 封装 |
| `npu_matrixop_pipeline_checker` | `verif/uvm_top/checkers/` | Documented assertion plan (stub, 10 categories)。Functional coverage from stress tests |
| `run_uvm.sh` | `verif/uvm_top/scripts/` | VCS compile-and-run script。**U9-a1: 支持透传额外 plusarg（`"${@:3}"`），如 `+TB_AXIL_ENABLE=0`** |
```
