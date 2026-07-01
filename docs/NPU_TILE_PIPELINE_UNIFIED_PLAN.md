# NPU Tile-Level Pipeline — Unified Plan

## 1. 目标与抽象

本次工作不是为了做 GEMM-only 优化，而是开始建设 **NPU general tile-level pipeline**。

统一抽象为：

```
LOAD / PREFETCH  →  COMPUTE  →  STORE
```

最终目标是对所有操作类型实现：

```
LOAD(next tile) || COMPUTE(current tile) || STORE(previous tile)
```

适用对象包括：

- **GEMM** — 第一个落地对象（最先暴露 K>64 chunk reload 问题）
- **FC** — 共享同一 FC/GEMM 基础设施
- **Conv** — 未来扩展到 conv_frontend tile-level 流式
- **Vector / elementwise** — 带宽路径
- **Pool / special op** — 特殊算子

## 2. 通用 LOAD / COMPUTE / STORE 抽象

| 阶段 | GEMM | FC | Conv | Vector | Pool |
|------|------|----|------|--------|------|
| **LOAD** | a_tile + B weights | fc input rows + weights | conv window + kernel weights | act_buffer beats | spatial window samples |
| **COMPUTE** | mac_pe 2D systolic | mac_pe (FC mode) | mac_pe (Conv mode) | relu/comparison | compare/sum |
| **STORE** | c_tile → DMA writer | acc_buffer → DMA writer | acc_buffer → DMA writer | vec_relu → DMA writer | pool → DMA writer |

GEMM/FC/Conv 的 COMPUTE 阶段共享 `mac_pe` 阵列（通过 `fc_or_gemm` / `is_conv_mode` 区分）。
GEMM/FC 的 STORE 阶段可以是 direct c_tile STORE（streaming path）或 acc_buffer → DMA writer（legacy path）。

## 3. 各操作类型的映射

### 3.1 GEMM (Matrix Multiply)

```
C[m][n] = Σ_k A[m][k] × B[k][n]

M_tile ≤ 8, K ≤ PE_ROWS(64), N ≤ PE_COLS(64)
K>64: chunked across K dimension (K-chunk streaming)
```

GEMM 使用 FC 基础设施：
- PE rows = K chunk inputs (≤ 64)
- PE cols = N outputs (≤ 64)
- streaming compute: a_tile row-skewed feed → wavefront output → c_tile collect
- direct row-major STORE from c_tile via DMA writer

### 3.2 FC (Fully Connected)

```
Y[n] = Σ_i X[i] × W[i][n] + bias[n]
```

FC 复用 GEMM 基础设施，input_c > 64 时也多 chunk 处理。
目前 FC 多 chunk 有已知的 shadow register bug（见 `docs/CURRENT_PROJECT_STATUS.md` §7）。

### 3.3 Conv (Convolution)

```
Conv: spatial kernel sliding across channels
```

Conv 使用 `conv_frontend` 和 `cf_act_data` 逐字节馈送激活数据。
Conv 的 weight 加载支持多 output channel（tile）和多 input channel（cin loop）。

### 3.4 Vector / Elementwise

Vector INT8 ReLU 256b streaming path 直接从 act_buffer 读取 beats，
处理完推入 write_beat_fifo → DMA writer。不需要 a_tile / c_tile。

### 3.5 Pool / GAP

Pool 使用 `act_feed_ptr` 逐字节读取窗口，比较/累加后写入 acc_buffer。
GAP 使用 `gap_byte_idx` 逐样本读取，累加后写入 acc_buffer。

## 4. 当前 Phase 3c 的定位

### 4.1 为什么先从 GEMM K-chunk A reload 落地？

1. GEMM 是 NPU 核心操作之一，streaming v1 已经验证了 row-streaming compute
2. K>64 streaming 是最先暴露的 chunk reload 问题
3. GEMM 的 a_tile 加载路径最清晰（row-major contiguous access from act_buffer）
4. K-chunk 的 B weight reload 已有基础设施（FSM_LOAD_ARRAY → WGT_LD → PREP）
5. 成功后可推广到 FC 多 chunk 和 Conv 多 cin 的 input tile reload

### 4.2 为什么 act_feed / conv_frontend 不适合作为通用 input tile loader？

`act_feed` / `conv_frontend` 是 task-level single-stream pipeline：

- `act_feed` 使用 `act_feed_ptr` 和 `act_feed_done_cnt` 逐字节前进
- `act_feed_done_cnt` 达到 `blk_in_bytes` 后停止
- `cf_done` 锁住 `conv_frontend`
- `cf_start` 只在 task 开始时有效
- **不支持 reliable mid-task restart**
- 尝试 reset counter / pulse cf_start / restart act_dma 均失败

因此，K>64 A reload 绕过 `act_feed` / `conv_frontend` / `cf_act_data`，
直接从 act_buffer raw data 构建 input tile。

## 5. Phase 3c 实现：Input Tile Loader (GEMM 首个落地)

### 5.1 设计原则

- 不算 new FSM state — 复用 `FSM_GEMM_STREAM_LOAD_A`
- 在 `FSM_GEMM_STREAM_LOAD_A` 内部实现 4-phase micro-sequencer
- 数据来源：**act_buffer raw read**（byte-by-byte beat access）
- 绕过 `act_feed` / `conv_frontend`
- 命名当前为 `gemm_a_load_*`（GEMM-scoped），Phase 4 升级为通用 `input_tile_loader`

### 5.2 Micro-sequencer 设计

```
localparam A_LOAD_IDLE    = 2'd0;
localparam A_LOAD_REQ     = 2'd1;
localparam A_LOAD_WAIT    = 2'd2;
localparam A_LOAD_CAPTURE = 2'd3;

State machine:
  IDLE → REQ → WAIT → CAPTURE → REQ → ... → IDLE (done)
```

每个字节的时序：
1. **REQ**: 设置 `act_rd_addr = beat_addr`（combinational mux）
2. **WAIT**: 等待 synchronous buffer read latency（1 cycle）
3. **CAPTURE**: 从 `act_rd_data[byte_sel*8 +: 8]` 捕获字节到 `a_tile[row][col]`
   - 同时设置下一字节地址，直接跳转到 REQ

### 5.3 Byte Index 计算

```
byte_idx  = row * input_c + gemm_stream_k_base + col
beat_addr = byte_idx >> 5          (within act_buffer address space)
byte_sel  = byte_idx & 0x1F        (byte lane within 256-bit beat)

a_tile[row][col] = act_rd_data[byte_sel * 8 +: 8]
```

### 5.4 K-chunk Routing

```
Chunk 0 (first):
  PREP → LOAD_A → RUN → ACCUM

Chunk 1+ (subsequent):
  ACCUM → LOAD_A → LOAD_ARRAY → WGT_LD → PREP → RUN → ACCUM
```

关键要求：
1. chunk0 执行 LOAD_A ✓
2. chunk1+ 也执行 LOAD_A ✓
3. 每个 chunk 都重新加载 B ✓（ACCUM→LOAD_A→LOAD_ARRAY→WGT_LD）
4. chunk0 前 clear c_tile ✓（PREP, gemm_stream_first_chunk）
5. chunk1+ 不 clear c_tile ✓（PREP skip when !first_chunk）
6. chunk1+ 对 c_tile 做 signed accumulate ✓（GEMM_STREAM_RUN）
7. STORE 只在所有 K chunks 完成后执行一次 ✓（ACCUM all-done → DONE → STORE）

### 5.5 act_buffer Read Override

```verilog
assign act_rd_addr = (fsm_state == FSM_GEMM_STREAM_LOAD_A) ? gemm_a_load_beat_addr : ...;
```

在 `FSM_GEMM_STREAM_LOAD_A` 期间，`act_rd_addr` 由 micro-sequencer 的 beat address 驱动。
其余时间使用原有路径（`fc_act_beat_addr` / `act_feed_beat_addr` / etc.）。

## 6. 当前不做哪些优化（Phase 4）

本轮只解决 **correctness**，不做 overlap：

1. ❌ A_tile ping-pong（double buffering）
2. ❌ B weight prefetch（提前加载下一 chunk B）
3. ❌ STORE overlap（STORE || COMPUTE）
4. ❌ result_tile_buffer unify
5. ❌ STORE Scheme A burst（多 beat 合并为单 txn）
6. ❌ M_tile 扩展（>8 行）
7. ❌ 主 FSM 拆分重构
8. ❌ beat-level bulk read（目前 byte-by-byte, ~2 cycles/byte）

## 7. Phase 4 规划

### Phase 4a: 通用 input tile ping-pong

- 将 `gemm_a_load_*` 升级为通用 `input_tile_loader`
- 支持 double-buffered a_tile: COMPUTE on bank A while LOAD bank B
- 支持 beat-level bulk read（~1 cycle/32 bytes）
- GEMM / FC / Conv 统一接口

### Phase 4b: Weight prefetch

- 下一 chunk B weight 在当前 chunk COMPUTE 期间预加载
- 消除 LOAD_ARRAY → WGT_LD 序列延迟

### Phase 4c: STORE overlap

- COMPUTE(current tile) || STORE(previous tile)
- 需要 c_tile double-buffering 或 result_tile_buffer

### Phase 4d: 三级流水全开

```
LOAD(next tile) || COMPUTE(current tile) || STORE(previous tile)
```

## 8. 验收测试

### Phase 3c 新增测试

| 测试 | 描述 | 预期结果 |
|------|------|---------|
| **RS14** | M=2, K=128, N=4, B=all-1, A: k=0..63=1, k=64..127=2 | C = 192 (non-uniform A) |
| **RS15** | M=2, K=65, N=4, B=all-1, A: k=0..63=1, k=64=7 | C = 71 (K%64=1 boundary) |
| **RS16** | M=2, K=128, N=4, B=all-1, A: k=0..63=1, k=64..127=-1 | C = 0 (signed non-uniform) |

### 回归要求

1. RS0-RS16 全部 PASS（UVM_ERROR=0, UVM_FATAL=0）
2. GEMM_FUNC 6/6 PASS
3. 完整 7/7 regression PASS

## 9. 参考资料

- `docs/CURRENT_PROJECT_STATUS.md` — 项目当前状态
- `CLAUDE.md` — 工程约束与基线
- `rtl/npu/npu_top.v` — 主 FSM 与 GEMM streaming 状态机
- `verif/uvm_top/tests/npu_task_gemm_row_streaming_test.sv` — RS 测试套件
