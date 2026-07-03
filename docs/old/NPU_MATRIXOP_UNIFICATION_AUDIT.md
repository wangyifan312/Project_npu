# NPU MatrixOp Unification Audit

**Phase**: U0 (audit only, no RTL change)
**Date**: 2026-07-02
**Baseline**: `main` HEAD = `868e196`, tag = `npu-streaming-gemm-pipeline-frozen-baseline`
**Branch**: `feature/npu-weight-prefetch-ntiling-future`

---

## Executive Summary

经过全面代码审计，**GEMM 和 FC 可以并且应该统一到通用 MatrixOp pipeline**。两条路径共享相同的 PE 阵列、相同的 weight-stationary 计算模型和相同的 INT8→INT32 数据路径。主要差异在于输出累积 (`c_tile` vs `acc_buffer`)、存储引擎 (GST micro-FSM vs legacy `store_pack`) 和后处理 (GEMM 无后处理 vs FC 可选 bias/ReLU/requant)。

**推荐下一步：Phase U1 — FC 作为 MatrixOp 运行在 streaming GEMM pipeline 上，保留 legacy FC fallback。**

---

## 1. GEMM 当前路径

### 1.1 任务类型和入口

```verilog
// npu_top.v:671
wire is_gemm_mode = (task_type == 3'd7);

// npu_top.v:672 — streaming mode gate
wire gemm_row_streaming_en = is_gemm_mode && conv_cfg[5];
```

GEMM 使用专用 FSM 状态序列，完全不同于 legacy FC/Conv 路径。

### 1.2 FSM 状态序列

```
FSM_GEMM_STREAM_PREP   (6'd34) — 初始化 tile 描述符，清除 c_tile，选择 bank
FSM_GEMM_STREAM_LOAD_A (6'd35) — 微序列器：从 act_buffer 逐 beat 加载输入 tile
FSM_GEMM_STREAM_RUN    (6'd36) — 流式计算：在 PE 阵列上进行激活馈送和部分和累积
FSM_GEMM_STREAM_ACCUM  (6'd40) — K-chunk 循环检查：检查是否还有更多 K-chunks
FSM_GEMM_STREAM_DONE   (6'd37) — tile 完成：锁定 store_descriptor，启动 GST
FSM_GEMM_STREAM_STORE  (6'd38) — 等待 GST 引擎完成当前 tile；合并存储
```

GEMM 永远不会进入 legacy `FSM_COMPUTE`, `FSM_STORE`, `FSM_LOAD_ARRAY` 或 `FSM_WGT_LD`，除了当后续 K-chunk 需要权重重新加载时进入 FSM_WGT_LD。

### 1.3 数据路径图

```
A/Input:
    shared_ram → act_buffer (double-buffered, bank A/B)
        → act_read_path DMA (256-bit AXI4 read)
        → input_tile_bank0 / input_tile_bank1 [0:7][0:63] INT8
        → 每周期 64 字节广播到 PE 阵列激活输入 (array_act_in)

B/Weight:
    shared_ram → wgt_buffer (double-buffered, bank A/B)
        → weight_read_path DMA (256-bit AXI4 read)
        → wgt_load_reg (WGT_REG_BITS = 64×64×8 = 32,768 bits)
        → array_weight (展平到全阵列)
        → FSM_WGT_LD 置位 array_weight_ld=1
        → PE.weight_reg (weight-stationary, 每个 PE 存储 1 字节 INT8 权重)

C/Output (GEMM streaming — 新路径):
    PE array_sum_out (64×32-bit = 2,048-bit 宽)
        → c_tile_bank0 / c_tile_bank1 [0:7][0:63] INT32
            (第一 K-chunk：写一次；后续 K-chunk：累加)
        → 计算完成
        → store_desc_* 锁定 tile 元数据
        → GST per-beat STORE micro-FSM:
            GST_PUSH_BEAT → GST_START → GST_START_CLR →
            GST_WAIT_DONE → GST_ADVANCE
        → write_beat_fifo (depth=64, 256-bit wide)
        → dma_axi_writer (Phase B2 skid buffer, 1 beat/cycle W-channel)
        → shared_ram (256-bit AXI4 write)

C/Output (GEMM legacy — 已弃用，仅当 gemm_row_streaming_en=0):
    PE array_sum_out → acc_buffer (COLLECT/DRAIN 期间) →
        legacy store_pack (SP_IDLE/SP_FIRST/SP_STREAM/SP_PUSH) →
        write_beat_fifo → dma_axi_writer → shared_ram
```

### 1.4 支持的 GEMM 特性

| 特性 | 状态 | 实现 |
|--------|--------|-----------|
| M > 8 (M-tiling) | ✅ | `gemm_tile_M` ≤ 8, outer loop over `gemm_M_val` |
| N > 64 (N-tiling) | ✅ | `gemm_tile_N` ≤ 64, outer loop over `gemm_N_val` |
| K > 64 (K-chunking) | ✅ | `gemm_stream_k_base`, K-chunk loop with cross-chunk accumulation in c_tile |
| M/N/K combined tiling | ✅ | Nested tile loops in `FSM_GEMM_STREAM_DONE`/`FSM_GEMM_STREAM_STORE` |
| Last M tile | ✅ | `gemm_tile_M = min(8, gemm_M_val - gemm_tile_m_base)` |
| Last N tile | ✅ | `gemm_tile_N = min(64, gemm_N_val - gemm_tile_n_base)` |
| Signed INT8 | ✅ | `$signed()` in mac_pe.v |
| Non-uniform A | ✅ | 从 act_buffer 逐字节读取 |
| Non-uniform B | ✅ | N-major weight layout `(k_base+kk)*N + n` |
| LOAD_A ∥ RUN | ✅ | 输入 tile 预取在 RUN 期间进入不活跃 bank |
| STORE ∥ RUN | ✅ | GST 引擎在 RUN/PREP 期间以后台方式运行 |
| c_tile double buffer | ✅ | Bank toggling via `compute_c_bank`/`store_c_bank` |
| Store descriptor | ✅ | 7 个寄存器：`store_desc_{m_base,n_base,M,N,base_addr,row_stride,bank}` |
| Per-beat GST micro-FSM | ✅ | 每行每 beat 向 `dma_axi_writer` 发起新的 DMA 事务 |
| K > 64 cross-chunk accum | ✅ | 后续 chunk 在 `c_tile` 中累加 (`$signed(c_tile[...]) + $signed(array_sum_out[...])`) |

### 1.5 维度映射

```verilog
// npu_top.v:600-603
wire [15:0] gemm_M_val = input_h;      // M = input_h
wire [15:0] gemm_N_val = output_c;      // N = output_c
// K = input_c (implied by fc_chunk_inputs)
```

GEMM 的数学关系：`C[M,N] = A[M,K] × B[K,N]` 其中 `M=input_h, K=input_c, N=output_c`。

### 1.6 测试覆盖

| 测试 | 配置 | 状态 |
|------|-------------|--------|
| `npu_task_gemm_func_test` | M=1-32, K=4-512, N=4-32, all-1 数据 | PASS — 6/6 levels |
| `npu_task_gemm_row_streaming_test` | 全面 M/N/K tiling | PASS — 37/37 tests |
| `npu_gemm_pipeline_bw_tops_test` | 大规模性能 | 实验性 |
| `npu_axi_gemm_peak_test` | AXI 峰值 BW | PASS |

---

## 2. FC 当前路径

### 2.1 任务类型

```verilog
// npu_top.v:664
wire is_fc_mode = (task_type == 3'd1);
```

### 2.2 FSM 状态序列 (FC legacy)

```
FSM_TASK_SETUP → FSM_LOAD_ACT (预加载权重)
    → FSM_FC_TILE_PREP — 计算 tile 边界，决定是否预加载命中
        → [FSM_LOAD_BIAS → FSM_BIAS_WAIT → FSM_BIAS_EXTRACT] (optional)
        → FSM_FC_LOAD_WGT — 发起权重 DMA 到 wgt_buffer
        → FSM_FC_LOAD_WAIT — 等待权重 DMA 完成
        → FSM_LOAD_ARRAY — 将 wgt_buffer 字节加载到 wgt_load_reg (128 cycles)
        → FSM_WGT_LD — 通过 array_weight_ld=1 将 wgt_load_reg 锁存到 PE 阵列
        → FSM_COMPUTE (CP_FEED_ACT → CP_DRAIN → CP_COLLECT)
            → 输出写入 acc_buffer (COLLECT 期间)
        → FSM_STORE — 通过 store_pack 从 acc_buffer 读取 → write_beat_fifo → dma_axi_writer
        → 如果更多输出 tiles：循环回 FSM_FC_TILE_PREP
        → FSM_BLK_DONE → FSM_DONE
```

### 2.3 FC 数据路径

```
Input activation:
    shared_ram → act_buffer
        → 在 CP_FEED_ACT 期间，FC 从 act_buffer 按字节索引逐字节馈送
        → fc_act_byte_idx = fc_in_base + comp_feed_cnt (逐行简单的 K 偏移)

Weight:
    shared_ram → wgt_buffer (DMA 整个 tile: fc_tile_outputs * input_c 字节)
        → FSM_LOAD_ARRAY 逐字节提取：W[n][k] 布局
        → wgt_load_reg

Output:
    PE array_sum_out → acc_buffer (COLLECT 写入)
        → FSM_STORE: legacy store_pack (SP_FIRST/SP_STREAM/SP_PUSH)
        → write_beat_fifo → dma_axi_writer → shared_ram
```

### 2.4 FC 特性矩阵

| 特性 | 状态 | 详情 |
|--------|--------|---------|
| 复用 PE 阵列 | ✅ | 与 GEMM/Conv 使用相同的 `compute_core` + `pe_cluster` + `mac_pe` |
| Input 来源 | act_buffer | 在 CP_FEED_ACT 期间逐字节读取 |
| Weight 来源 | wgt_buffer → wgt_load_reg | 每 tile 一次完整的权重 DMA |
| Output 写入位置 | acc_buffer | COLLECT 写入，STORE 读取 |
| 使用 acc_buffer | ✅ | 是 — FC 的 COLLECT 写入 + STORE 读取 |
| 使用 c_tile | ❌ | 否 — FC 从不使用 c_tile_bank0/1 |
| 使用 legacy STORE | ✅ | 是 — `store_pack` 状态机 |
| 支持 bias | ✅ | 是 — `FSM_LOAD_BIAS`/`FSM_BIAS_EXTRACT` |
| 支持 ReLU | ✅ | 是 — 在 `bias_add_requant_i32_to_i8` 中 |
| 支持 requant | ✅ | 是 — `requant_i32_to_i8.v` (远离零的四舍五入半，clamp [-128,127]) |
| Supported scale/zero-point | ❌ | 否 — 仅 multiplier+shift requant |
| Smoke test | ✅ | `npu_fc_smoke_test` — 4-element input → 1-output |
| Functional test | ✅ | `npu_fc_16x16_full_array_test` — 16×16 |
| Peak test | ✅ | `npu_fc_128x128_peak_test` |
| Batch > 1 | ⚠️ | `gemm_row_idx` 循环存在但用于 legacy GEMM；FC 直接映射 M=1 |
| 数学等价于 | ✅ | FC(M=1, K=input_c, N=output_c) ≡ GEMM(1, K, N) |

### 2.5 FC STORE 路径（legacy `store_pack`）

FC 使用 legacy `store_pack` 状态机 (`SP_IDLE → SP_FIRST → SP_STREAM → SP_PUSH`)，该状态机：
1. 每次从 `acc_buffer` 读取一个 32-bit 字（流水线：预取指针 1 个周期领先）
2. 将 8 个 32-bit 字打包成 256-bit DMA beat
3. 推送到 `write_beat_fifo`
4. `dma_axi_writer` 将 beats 写入 AXI 内存

此路径将 `acc_buffer` 用作整个结果块的持久的中间存储。

---

## 3. GEMM 和 FC 的数学统一关系

### 3.1 线性代数映射

```
GEMM:  C[M,N] = A[M,K] × B[K,N]

FC:    Y[batch,out] = X[batch,in] × W[in,out] + optional bias/post-op

Mapping:
  M  = batch / token count / output rows
  K  = input feature count
  N  = output feature count
  A  = FC input activation
  B  = FC weight matrix
  C  = FC output (pre post-op)
```

### 3.2 当前代码证据

```verilog
// npu_top.v:842 — FC 和 GEMM 已经在多处共享基础设施：
wire fc_or_gemm = is_fc_mode || is_gemm_mode;

// 共享计算：
// - 阵列激活行数 (line 845)
// - 激活馈送数据路径 (lines 1203-1207)
// - 阵列累积控制 (lines 1541-1542)
// - COLLECT 控制 (lines 852-854)
// - 性能计数器 (lines 1108-1112)
// - Bias DMA 地址计算 (line 1394)
```

### 3.3 结论

```
FC can be represented as MatrixOp / GEMM with optional post-processing.
FC(1, input_c, output_c) ≡ GEMM(1, input_c, output_c)
```

---

## 4. 候选 MatrixOp Descriptor

### 4.1 提议字段

```verilog
// MatrixOp descriptor — candidate for Phase U1+
typedef struct packed {
    // --- 操作类型 ---
    logic [2:0] op_type;       // GEMM=7, FC_as_MatrixOp=new_code, CONV1x1=future

    // --- 矩阵维度 ---
    logic [15:0] M;            // 输出行数 (FC: batch, GEMM: 行)
    logic [15:0] N;            // 输出列数/通道数 (FC: output_c, GEMM: N)
    logic [15:0] K;            // 约简维度 (FC: input_c, GEMM: K)

    // --- 数据指针 ---
    logic [31:0] A_base;       // 激活/输入基地址
    logic [31:0] B_base;       // 权重基地址
    logic [31:0] C_base;       // 输出基地址

    // --- 步长 (用于多维视图) ---
    logic [31:0] A_row_stride; // A 行之间字节数 (= K 用于紧凑布局)
    logic [31:0] B_row_stride; // B 行之间字节数 (K-major: N; 行优先: K)
    logic [31:0] C_row_stride; // C 行之间字节数 (= ceil(N*4/32)*32)

    // --- Tile 描述符 (配置 + 状态) ---
    logic [15:0] tile_M;       // M tile 大小 (≤ 8)
    logic [15:0] tile_N;       // N tile 大小 (≤ 64)
    logic [15:0] tile_K;       // K chunk 大小 (≤ 64)

    // --- 布局提示 ---
    logic [1:0] input_layout;  // COMPACT_MATRIX, ACTIVATION_BUFFER, FEATURE_MAP
    logic [1:0] weight_layout; // K_MAJOR (GEMM), N_MAJOR (FC legacy), CONV_KERNEL
    logic [1:0] output_layout; // ROW_MAJOR_INT32, ROW_MAJOR_INT8, FEATURE_MAP

    // --- 后处理 ---
    logic [3:0] post_op;       // NONE, BIAS, RELU, REQUANT, BIAS_RELU_REQUANT, CLAMP
    logic [31:0] requant_multiplier;
    logic [5:0]  requant_shift;
    logic [31:0] bias_addr;
    logic [31:0] bias_bytes;
} matrixop_desc_t;
```

### 4.2 覆盖范围评估

| 用例 | 覆盖状态 | 备注 |
|--------|--------|--------|-------|
| 当前 streaming GEMM | ✅ | 映射到 op_type=GEMM，所有字段已使用 |
| 当前 legacy FC | ✅ | M=batch, K=input_c, N=output_c |
| Future 1×1 Conv | ✅ | 作为 MatrixOp，无需滑动窗口生成器 |
| Future general Conv backend | ⚠️ | 需要 frontend (im2col/window generator) |

---

## 5. 评估 `c_tile` 与 `acc_buffer` 统一

### 5.1 当前结构

**acc_buffer** (`npu_buffer #(DATA_WIDTH=32, ENTRIES=1024)`):
- 宽度：32-bit
- 组织方式：单端口，双 bank (load/comp)
- 容量：1024 × 32-bit = 4 KB
- 消费者：FC/Conv COLLECT→DRAIN 写入，legacy `store_pack` 读取，requant/add/gap 也使用
- STORE 路径：`store_pack` (32-bit → 256-bit 打包，P5 流水线化)
- 关键限制：单端口，32-bit 宽，每个 256-bit beat 的 store 吞吐量受 ~4 cycles 限制

**c_tile_bank0/1** (`reg [31:0] c_tile_bank0 [0:7][0:63]`):
- 宽度：32-bit
- 组织方式：双缓冲 (compute_c_bank / store_c_bank)
- 容量：8×64×32-bit = 2 KB / bank (2 banks = 4 KB total)
- 生产者：`FSM_GEMM_STREAM_RUN` (可选的交叉 chunk 累加)
- 消费者：GST micro-FSM (per-beat direct DMA launch)
- 关键限制：触发器数组（不是 BRAM），固定 8×64 维度

### 5.2 比较

| 属性 | acc_buffer | c_tile_bank0/1 |
|----------|------------|------------------|
| 宽度 | 32-bit | 32-bit |
| 容量 | 1024 words (4 KB) | 每个 512 words (2 KB) |
| 技术 | BRAM (npu_buffer) | 触发器数组 (reg) |
| 端口 | 单端口 | 多端口 (by row/col) |
| 访问模式 | 顺序地址 | 直接行列索引 |
| 写入源 | COLLECT/DRAIN (PE 累积) | FSM_GEMM_STREAM_RUN |
| 读取源 | store_pack (legacy STORE) | GST micro-FSM (GEMM STORE) |
| 消费者延迟 | 1 个周期读取延迟 | 组合读取 |
| 共享？ | Conv/FC/Requant/Add/GAP/Pool | GEMM only |

### 5.3 统一评估

**结论：选项 B — `c_tile` 和 `acc_buffer` 不能立即统一，但 FC streaming 路径可以使用 `c_tile`。**

原因：
1. `c_tile` 是触发器数组 (8×64)，足以容纳最大的 GEMM M-tile × N-tile 输出 footprint
2. `acc_buffer` 是 BRAM，服务于不产生 `c_tile` 格式输出的遗留消费者（requant、pool、add、gap）
3. 遗留路径（requant、add、gap、pool）通过 acc_buffer 运行并依赖其 BRAM 语义
4. 移除 `acc_buffer` 需要将所有这些操作迁移到使用基于 `c_tile` 或等价物的新路径
5. 低风险路径：FC streaming 直接写入 `c_tile`（如 GEMM），同时保持 legacy FC+acc_buffer 作为 fallback

**阻断因素**：
- FC 后处理（bias、ReLU、requant）通过 `acc_buffer` 路径运行 (`rq_internal_write_phase`、`bias_add_requant_i32_to_i8`)
- 如果 FC 切换到 `c_tile`，这些后处理需要适配或在新路径中重新实现
- 混合使用 `c_tile`（用于纯矩阵乘法）+ `acc_buffer`（用于后处理）最初是可行的

---

## 6. FC 迁移到 Streaming GEMM Pipeline 的风险评估

### 6.1 逐项分析

| 问题 | 评估 | 详情 |
|---------|--------|---------|
| FC input layout vs GEMM A layout | ✅ 相同 | 两者都从 act_buffer 以 K-contiguous 布局读取激活 |
| FC weight layout vs GEMM B layout | ⚠️ 不同 | FC 使用 N-major `W[n][k]`；GEMM 使用 K-major `B[k][n]`。GEMM 的 `wgt_stage_buf_byte_idx_gemm` 已处理此问题 |
| FC output layout vs GEMM C layout | ✅ 相同 | 两者都是 row-major INT32 |
| FC 是否需要后处理 | ⚠️ 需要条件处理 | 第一阶段仅统一纯矩阵乘法；后处理保留在遗留路径 |
| FC 是否需要低延迟 M=1 路径 | ✅ 已处理 | 单行的 GEMM streaming（M=1，N=任意，K=任意）按原样工作 |
| Legacy tests 可供对比 | ✅ | 已有 `npu_fc_smoke_test`、`npu_fc_16x16_full_array_test`、`npu_fc_128x128_peak_test` |
| FC streaming 可作为可选模式引入 | ✅ | 是的 — 通过 `conv_cfg[5]` 门控，类似于 `gemm_row_streaming_en` |
| Legacy FC fallback | ✅ 保留 | `is_fc_mode` 路径不变，直到新路径验证 |

### 6.2 核心问题解答

```
Can FC be mapped to streaming GEMM pipeline without changing PE array?
  YES — FC uses the exact same PE array, weight-stationary architecture.
  Each PE computes MAC(a, w) where a∈INT8, w∈INT8 → accum∈INT32.
  No PE changes are needed.

Can FC reuse input_tile_bank0/1?
  YES — FC activation loading is the same beat-level bulk unpack as GEMM.
  fc_act_byte_idx is already computed for fc_or_gemm in the feeder.

Can FC reuse wgt_load_reg / WGT_LD / PE.weight_reg?
  YES — The weight-loading path (wgt_buffer → wgt_load_reg → array_weight_ld)
  is already shared via fc_or_gemm gating.

Can FC reuse c_tile_bank0/1?
  YES — With one limitation: c_tile is 8×64 max. FC with M>8 or N>64
  would need tiling, which GEMM already supports via M-tile and N-tile loops.

Can FC reuse store_desc_* and GST STORE micro-FSM?
  YES — store_desc captures tile dimensions and addresses; GST performs
  per-beat DMA launches. Same mechanism works for FC output.
```

### 6.3 风险矩阵

| 风险 | 严重程度 | 缓解措施 |
|------|----------|-----------|
| Weight layout mismatch (N-major vs K-major) | 中等 | GEMM 已经有两种布局的 wgt_stage_buf_byte_idx 计算 |
| 后处理丢失 (bias/ReLU/requant) | 高 | 第一阶段：纯矩阵乘法无后处理。Phase U4 添加后处理 |
| Multi-chunk FC (K>64) shadow register bug | 中等 | GEMM K-chunking 已经更稳定（cross-chunk 累加在 c_tile 中） |
| FC 测试回归 | 低 | Legacy FC 路径保留；新路径可以作为 `task_type` 或模式位 |
| M>8 FC batch | 低 | GEMM M-tiling 已经处理此问题 |
| N>64 FC | 低 | GEMM N-tiling 已经处理此问题 |

---

## 7. 后处理策略

### 7.1 当前 FC 后处理路径

FC 支持通过 `bias_add_requant_i32_to_i8` 进行可选的 bias + ReLU + requant：

```
PE array_sum_out → COLLECT 写入 acc_buffer
    → FSM_REQUANT_COMPUTE:
        → 从 acc_buffer 读取 INT32
        → bias_add_requant_i32_to_i8: bias + ReLU + requant → INT8
        → 打包并写回 acc_buffer (INT8)
    → FSM_STORE: 从 acc_buffer 读取 → store_pack → DMA
```

后处理由 `fsm_state == FSM_REQUANT_COMPUTE` 触发，且 `rq_mode_internal=1` 且 `bias_enabled=1`。

### 7.2 推荐策略

```
Phase U1:
  — 仅统一纯 FC 矩阵乘法（无 bias、无 ReLU、无 requant）
  — 默认输出 INT32（与 GEMM 输出相同）
  — Post-op FC 继续使用遗留路径

Phase U4:
  — 将 bias/ReLU/requant 支持直接添加到 result_tile (c_tile) 路径
  — 选项 A：GST STORE 读取 result_tile 之前进行组合后处理
  — 选项 B：纯矩阵乘法后，将 final result_tile 流式传输到 acc_buffer 进行后处理
```

**第一阶段不应同时迁移所有后处理。** 纯矩阵乘法统一降低了大部分风险，同时提供了一条清晰的路径。

---

## 8. Conv 排除在第一阶段之外

### 8.1 明确立场

```
GEMM + FC should be first unification target.
Conv should NOT be included in first coding phase except as future design reference.
```

### 8.2 理由

1. **1×1 Conv 可以稍后映射** — `conv1x1(in, w, out)` ≡ `MatrixOp(H*W, Cin, Cout)`，但需要 frontend 来排列 feature-map 张量
2. **通用 Conv 需要 window generator** — `conv_frontend` 生成 5×5 sliding window；这从根本上不同于直接的矩阵地址生成
3. **Padding / stride / dilation** — 这些会显著增加地址计算的复杂性；它们应该在 `conv_frontend` 中得到充分 debug，而不是在 GEMM pipeline 内部
4. **Feature-map 布局** — NHWC vs NCHW、tensor 步长、边界处理 — 比简单的行主序 A[M][K] 布局复杂得多
5. **混合 GEMM+Conv 统一第一阶段会造成不必要的延迟** — FC 是更简单、最即时的胜利

---

## 9. 推荐分阶段路线

### 阶段 U0：仅审计（当前）

```
✓ 不在此时序下更改 RTL
✓ 生成 NPU_MATRIXOP_UNIFICATION_AUDIT.md
✓ 回答所有核心架构问题
```

### Phase U1：FC 作为 MatrixOp，不移除遗留代码

**目标**：添加一个可选的 FC streaming 路径，通过 `conv_cfg[5]` 位映射到 MatrixOp

**映射**：
```
M = batch    (input_h, 默认 = 1)
K = input_c
N = output_c
```

**复用**：
- `input_tile_bank0/1` 用于 FC 激活加载
- `wgt_load_reg` / `WGT_LD` 用于 FC 权重加载（使用 K-major 重新排序）
- PE 阵列（无变化）
- `c_tile_bank0/1` 用于 FC 输出累积
- `store_desc_*` + GST micro-FSM 用于 FC 输出 STORE

**保留**：
- 遗留 FC FSM（`FSM_FC_TILE_PREP` → `FSM_STORE`）作为 fallback
- `acc_buffer` 路径用于所有后处理和非 GEMM/FC 操作

**最小实现范围**：
1. 当 `is_fc_mode && conv_cfg[5]` 时，将 FC 路由到 GEMM 流式 FSM
2. 将 FC 映射到 M=1（或 M=batch，如果支持批量 FC）
3. 为 FC 输入/权重复用流式 tile 调度器
4. 保留遗留 FC fallback（`conv_cfg[5]=0`）
5. 无 acc_buffer 移除
6. 无 Conv 迁移

### Phase U2：FC Streaming Tests

**目标**：验证 FC-as-MatrixOp 在各种配置下的正确性

**测试**：
- Small FC M=1（典型单样本推理）
- Batch FC M>1（多 token 或 batch 推理）
- N>64 FC（tile columns > 1 个 PE 阵列宽度）
- K>64 FC（cross-chunk 累积）
- Signed weights（负值输入/权重）
- Non-uniform input/weight（非全 1）
- 在可能的情况下，对比 legacy FC vs streaming FC
- 将 `npu_fc_smoke_test` 与新的 streaming 路径交叉验证

### Phase U3：result_tile_bank Abstraction

**目标**：重命名/抽象 `c_tile_bank0/1` → `result_tile_bank0/1`

**更改**：
- 将 `c_tile` 重命名为 `result_tile`（或 `out_tile`）
- 在遗留消费者和块调度器中保持 `acc_buffer` 不变
- 不要立即移除 `acc_buffer`

### Phase U4：结果 Tile 路径上的后处理迁移

**目标**：在 GEMM/FC 的 `result_tile` 路径上支持可选的 bias/ReLU/requant

**选项**：
- A. 组合后处理：在 GST 读取 `result_tile[row][col]` 之前，应用 bias+ReLU+requant，然后打包字节
- B. 双阶段：先完成纯矩阵乘法填充 `result_tile`，然后将 `result_tile` 流式传输到 `acc_buffer` 进行后处理（仅限后处理任务）

### Phase U5：1×1 Conv 作为 MatrixOp

**目标**：FC 稳定后，将 Conv1x1 映射到 MatrixOp

**映射**：`Conv1x1(H,W,Cin,Cout)` ≡ `MatrixOp(H*W, Cin, Cout)`，其中：
- M = H*W（输出空间像素）
- K = Cin
- N = Cout

需要：将 feature map 重新排列成 GEMM 期望的紧凑 [M×K] 布局的 frontend。

### Phase U6：通用 Conv Frontend

**目标**：评估 window generator / im2col 风格的 frontend 用于通用 Conv 作为矩阵乘法后端

**超出当前审计范围**。

---

## 10. 最终建议

### Recommended Next Coding Phase

```
Phase U1: FC as MatrixOp through streaming GEMM pipeline
```

### Phase U1 最小实现范围

```
1. 添加 FC streaming 模式（例如，当 conv_cfg[5]=1 时，is_fc_mode 路由到
   GEMM streaming FSM）
2. 将 FC 描述符映射到 M/K/N（batch=input_h, K=input_c, N=output_c）
3. 尽可能多地复用流式 GEMM tile 调度器（M-tile、N-tile、K-chunk）
4. 保持遗留 FC fallback（conv_cfg[5]=0 或未设置）
5. 添加 FC streaming smoke + functional tests
6. U1 中不移除 acc_buffer
7. U1 中不迁移 Conv
8. U1 中不迁移后处理（bias/ReLU/requant）
```

### 不可变约束

```
1. PE 阵列                — 不变
2. mac_pe.v              — 不变
3. dma_axi_writer.v      — 不变
4. write_beat_fifo.v     — 不变
5. acc_buffer 结构       — 不移除（遗留消费者）
6. Requant 公式          — 不变
7. Legacy FC 路径         — 保留并保持功能
8. All 34/34 UVM tests    — 必须继续 PASS
```

---

## 11. 证据和来源

### 审计覆盖的文件

| 文件 | 行数 | 审计状态 |
|------|---------|--------------|
| `rtl/npu/npu_top.v` | 4568 | ✅ 全面审计 |
| `rtl/npu/mac_pe.v` | 54 | ✅ 全面审计 |
| `rtl/npu/compute_core.v` | 62 | ✅ 全面审计 |
| `rtl/npu/pe_cluster.v` | 81 | ✅ 全面审计 |
| `rtl/npu/dma_axi_writer.v` | 434 | ✅ 全面审计 |
| `rtl/npu/write_beat_fifo.v` | — | ✅ 审查了接口 |
| `verif/uvm_top/tests/npu_fc_*` | 3 tests | ✅ 审查了测试 |
| `verif/uvm_top/tests/npu_task_gemm_*` | 3 tests | ✅ 审查了测试 |
| `rtl/npu/acc_buffer.v` (via npu_buffer) | — | ✅ 审查了接口 |
| `rtl/npu/requant_i32_to_i8.v` | — | ✅ 审查了公式 |
| `rtl/npu/bias_add_requant_i32_to_i8.v` | — | ✅ 审查了路径 |

### 关键代码位置

| 项 | 文件:行 |
|-----|---------|
| `is_fc_mode` 定义 | `npu_top.v:664` |
| `is_gemm_mode` 定义 | `npu_top.v:671` |
| `fc_or_gemm` gate | `npu_top.v:842` |
| GEMM streaming FSM 状态 | `npu_top.v:159-164` |
| FC FSM 状态 | `npu_top.v:109-111` |
| `c_tile_bank0/1` 定义 | `npu_top.v:687-690` |
| `store_desc_*` 寄存器 | `npu_top.v:701-707` |
| GST micro-FSM 定义 | `npu_top.v:709-713` |
| GST micro-FSM tick | `npu_top.v:4425-4507` |
| GEMM RUN 中的 c_tile 累积 | `npu_top.v:3923-3940` |
| Legacy `store_pack` 状态机 | `npu_top.v:1614-1617, 4269-4362` |
| `acc_buffer` 实例化 | `npu_top.v:562-572` |
| `write_beat_fifo` 实例化 | `npu_top.v:1724` |
| `dma_axi_writer` 实例化 | `npu_top.v:491-507` |
| PE 阵列激活驱动 | `npu_top.v:1452-1504` |
| 权重加载到 PE | `npu_top.v:1487-1504` |
| FC weight DMA 地址 | `npu_top.v:1384-1392` |
| GEMM weight buffer byte index | `npu_top.v:1241-1252` |
| Bias load FSM | `npu_top.v:2730-2751` |
| Requant 内部写入阶段 | `npu_top.v:1064-1067` |
| `mac_pe` 算术 | `mac_pe.v:37-48` |

---

## 12. 提议的提交

```bash
git add docs/NPU_MATRIXOP_UNIFICATION_AUDIT.md
git commit -m "docs: audit GEMM FC MatrixOp unification

Phase U0 — audit only, no RTL change.

Comprehensive review of streaming GEMM and legacy FC paths.
Conclusion: FC can and should be unified as MatrixOp on the
streaming GEMM pipeline. Recommended Phase U1: add FC streaming
mode with legacy fallback. No acc_buffer removal in first phase.
No Conv migration in first phase.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## 附录 A：FSM 状态图（简化版）

### GEMM Streaming Path

```
FSM_IDLE
  └→ FSM_TASK_SETUP
      └→ FSM_GEMM_STREAM_PREP ────────────────┐
          ├→ FSM_GEMM_STREAM_LOAD_A            │
          │   └→ FSM_GEMM_STREAM_RUN ◄────────┤ (K-chunk loop)
          │       └→ FSM_GEMM_STREAM_ACCUM ────┘
          │           └→ FSM_GEMM_STREAM_DONE
          │               └→ FSM_GEMM_STREAM_STORE
          │                   └→ FSM_GEMM_STREAM_PREP (next M/N tile)
          │                       └→ ...
          └→ FSM_DONE
```

### FC Legacy Path

```
FSM_IDLE
  └→ FSM_TASK_SETUP
      └→ FSM_LOAD_ACT (preload)
          └→ FSM_FC_TILE_PREP ◄───────────────┐
              ├→ [FSM_LOAD_BIAS (optional)]    │
              ├→ FSM_FC_LOAD_WGT               │
              │   └→ FSM_FC_LOAD_WAIT          │
              ├→ FSM_LOAD_ARRAY                │
              │   └→ FSM_WGT_LD                │
              ├→ FSM_COMPUTE                   │
              │   └→ FSM_STORE ────────────────┘ (next tile)
              │       └→ FSM_BLK_DONE
              │           └→ FSM_DONE
              └→ FSM_ERROR
```

---

## 附录 B：数据宽度汇总

| 路径 | 宽度 | 周期/beat |
|------|-------|-----------|
| PE input (activation) | 64×8-bit = 512-bit | 每周期广播 |
| PE weight loading | 64×64×8-bit = 32,768-bit | 一次性加载（每 chunk） |
| PE output (sum) | 64×32-bit = 2,048-bit | 每周期每列 1 个 |
| c_tile 写入 | 每列 32-bit | 每周期每列 1 个 |
| GST beat 组装 | 8×32-bit → 256-bit | ~8 周期/beat (顺序) |
| Write beat FIFO | 256-bit | 深度 64 |
| AXI write | 256-bit, max 16-beat burst | ~1 beat/cycle (Phase B2) |
| Legacy store_pack | 8×32-bit → 256-bit | ~1 word/cycle (P5) |

---

## 附录 C：委托项（当前冻结基线中未完成）

```
❌ N-tiling B/weight background prefetch  — 代码存在但已门控关闭 (1'b0)
❌ 512-bit AXI / acc_buffer widening       — feature/512bit 分支
❌ Descriptor queue / multiple outstanding STOREs
❌ c_tile / acc_buffer unification         — 本审计已评估
❌ Broader FC/Conv tile descriptor unification
```
