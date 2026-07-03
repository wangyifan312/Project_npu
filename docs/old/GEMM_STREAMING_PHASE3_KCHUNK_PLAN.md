# GEMM Streaming Phase 3: K>64 Cross-Chunk Accumulation — Design Plan

**Date**: 2026-06-30
**Base**: GEMM streaming v1 clean baseline (tag: `gemm-streaming-v1-clean`, 34952db)
**Branch**: `feature/gemm-streaming-kchunk-accum`
**Status**: Design review — RTL not yet modified

---

## 1. Current v1 baseline

GEMM streaming v1 supports:

| Parameter | Limit |
|-----------|-------|
| M (rows) | ≤ 8 |
| K (inner dim) | ≤ 64 (single chunk) |
| N (output cols) | ≤ 64 |

FSM flow:
```
FSM_LOAD_ACT → FSM_WGT_LD → FSM_GEMM_STREAM_PREP
    → FSM_GEMM_STREAM_LOAD_A (populate a_tile)
    → FSM_GEMM_STREAM_RUN (skewed feed + wavefront collect)
    → FSM_GEMM_STREAM_DONE
    → FSM_GEMM_STREAM_STORE (direct c_tile→DMA)
    → FSM_DONE → FSM_IDLE
```

## 2. K>64 problem definition

When `K > 64`, the computation `C[m][n] = Σ_{k=0}^{K-1} A[m][k] * B[k][n]` exceeds the PE array's 64-row capacity. The computation must be split into multiple K-chunks:

```
for k_base = 0; k_base < K; k_base += 64:
    K_tile = min(64, K - k_base)
    partial[m][n] = Σ_{k=k_base}^{k_base+K_tile-1} A[m][k] * B[k][n]
    C[m][n] += partial[m][n]
```

Example target configurations:
- M=8, K=128, N=8   (2 chunks)
- M=8, K=512, N=8   (8 chunks)
- M=8, K=128, N=16  (2 chunks × 2 beats/row)
- M=7, K=65,  N=8   (2 chunks, boundary K%64≠0)

## 3. Current RTL review

### 3.1 Streaming FSM states (npu_top.v:159-163)

```
FSM_GEMM_STREAM_PREP   = 6'd34  — clear c_tile, a_tile preload setup
FSM_GEMM_STREAM_LOAD_A = 6'd35  — DMA A[m][k] into a_tile[8][64]
FSM_GEMM_STREAM_RUN    = 6'd36  — skewed feed + wavefront collect
FSM_GEMM_STREAM_DONE   = 6'd37  — transition to STORE
FSM_GEMM_STREAM_STORE  = 6'd38  — direct c_tile→DMA STORE
```

### 3.2 Entry point (npu_top.v:2425-2426)

```verilog
if (gemm_row_streaming_en) begin
    fsm_state <= FSM_GEMM_STREAM_PREP;
end
```

This executes in `FSM_WGT_LD` after weights are loaded to PE array. Only entered ONCE per task — no loop back.

### 3.3 a_tile preload (npu_top.v:3060-3072)

```verilog
if (stream_capture_count < (gemm_M_val * {16'd0, input_c})) begin
    a_tile[stream_capture_count / {16'd0, input_c}]
          [stream_capture_count % {16'd0, input_c}] <= cf_act_data;
```

Loads `M * input_c` bytes. Problem for K>64: `input_c` = K > 64, but a_tile only has 64 columns. First 64 bytes per row would be correct, rest overflow.

**Also**: a_tile load uses `stream_capture_count / input_c` for the row index. This divides by the FULL K, not by K_tile. With K=128: row index = capture_count / 128, which would put only M*64/128 = M/2 entries into a_tile — incorrect.

**Fix needed**: Load `M × K_tile` bytes, divide by `K_tile` (not `input_c`), advance DMA source address by `k_base`.

### 3.4 c_tile collect (npu_top.v:3074-3094)

```verilog
if (!c_tile_valid[str_m][str_n]) begin
    c_tile[str_m][str_n] <= array_sum_out[str_n*32 +: 32];
    c_tile_valid[str_m][str_n] <= 1'b1;
end
```

**Write-once semantics**: c_tile is only written when `!c_tile_valid`. After first capture, subsequent writes to the same cell are ignored. For K>64 accumulation, this must change to:
- First K-chunk: write (same as now)
- Subsequent K-chunk: `c_tile[m][n] <= c_tile[m][n] + partial_sum`

### 3.5 c_tile clear (npu_top.v:3043-3056)

```verilog
FSM_GEMM_STREAM_PREP:
    for (ci=0; ci<8; ci++)
        for (cj=0; cj<64; cj++)
            c_tile[ci][cj] <= 32'sd0;
            c_tile_valid[ci][cj] <= 1'b0;
```

c_tile is cleared once in PREP. For multi-chunk, clear should happen once at task start, NOT between K-chunks.

### 3.6 Weight cache (npu_top.v:662-668, 2433-2438)

```verilog
wire gemm_weight_hit = is_gemm_mode && gemm_weight_valid &&
    (gemm_weight_k_base_cached == 16'd0) &&    // always 0 in v1
    (gemm_weight_n_base_cached == 16'd0) &&    // always 0 in v1
    (gemm_weight_k_size_cached == ...) &&
    (gemm_weight_n_size_cached == ...) &&
    (gemm_weight_addr_cached == weight_addr);
```

Cache fields set in FSM_WGT_LD:2433-2438:
```verilog
gemm_weight_k_base_cached <= fc_in_base;    // currently 0
gemm_weight_n_base_cached <= fc_out_start;  // currently 0
```

**Assessment**: The cache already captures `k_base` (fc_in_base) and `n_base` (fc_out_start). For K>64 streaming, `fc_in_base` must advance with each K-chunk, making the cache key different per chunk — safe from false hits. **No change needed** to the cache comparison logic itself.

The cache is cleared at line 2676 when moving to next K-chunk in legacy mode:
```verilog
if (is_gemm_mode) gemm_weight_valid <= 1'b0;
```

### 3.7 Legacy GEMM K-chunk loop (npu_top.v:2665-2684)

```verilog
if (fc_in_base + fc_chunk_inputs < input_c) begin
    // More K-chunks: advance base, reload weights
    fc_in_base <= fc_in_base + fc_chunk_inputs;
    fc_chunk_inputs <= min(64, input_c - (fc_in_base + fc_chunk_inputs));
    fsm_state <= FSM_LOAD_ARRAY;  // reload next chunk weights
end else begin
    // All K-chunks done: STORE
    fsm_state <= FSM_STORE;
end
```

This legacy loop handles K>64 for regular GEMM but goes through `FSM_STORE` (acc_buffer path), NOT the streaming STORE. The streaming path would need analogous looping but with `FSM_GEMM_STREAM_PREP` as the loop target instead of `FSM_LOAD_ARRAY`.

### 3.8 B weight load (npu_top.v:1192, 2187-2189)

```verilog
wire fc_wgt_dma_base = blk_wgt_addr + fc_out_start * input_c;
wgt_dma_addr <= {fc_wgt_dma_base[31:5], 5'b0};
wgt_dma_bytes <= (fc_tile_outputs * input_c) + {27'd0, fc_wgt_dma_base[4:0]};
```

Weight DMA reads `N × K` bytes from `blk_wgt_addr + n_base × K`. The full K bytes are loaded — including data for all K-chunks. Then `fc_in_base` is used during WGT_LD to select the right chunk's weights. **This works for streaming too**: the same weight DMA can load all K bytes, and the PE weight load selects the right chunk via `fc_in_base`.

### 3.9 Answers to key questions

**Q1: Streaming path currently only single K-chunk?**
Yes. FSM enters PREP once, runs one compute, exits to DONE/STORE. No loop.

**Q2: K>64 — what happens today?**
a_tile preload divides by `input_c` (the full K), causing underfill. Weights for second chunk never loaded. STORE happens after first partial result.

**Q3: fc_in_base / fc_chunk_inputs reusable?**
Yes. These signals already track K-chunk state in legacy path. `fc_in_base` increments between chunks, `fc_chunk_inputs` = min(64, K - fc_in_base). These can be shared between legacy and streaming paths.

**Q4: c_tile overwrite or accumulate?**
Overwrite (write-once with `!c_tile_valid` guard). Must change to support accumulation for chunks 2+.

**Q5: STORE timing?**
Currently immediately after first (and only) chunk's DONE. Must defer to after all chunks.

**Q6: B weight reload per K-chunk?**
Legacy path: reloads through FSM_LOAD_ARRAY → FSM_WGT_LD. For streaming, each new K-chunk needs to re-enter this path.

**Q7: A_tile reload per K-chunk?**
Yes. Each K-chunk loads A[m][k_base : k_base+K_tile-1]. Requires DMA address offset by k_base.

**Q8: Which legacy signals are reusable?**
- `fc_in_base` / `fc_chunk_inputs` — K-chunk state ✅
- `fc_out_start` / `fc_tile_outputs` — N-tile state ✅
- `gemm_weight_valid` / cache fields — weight retention ✅
- `fc_load_byte_idx` / `fc_load_buf_byte_idx` — weight byte routing ✅

## 4. Recommended approach

### Principle: minimal changes, reuse legacy infrastructure

```
for each N tile (fc_out_start):
    c_tile clear (once)
    for each K chunk (fc_in_base):
        // 1. Advance K-chunk state
        K_tile = min(64, K - fc_in_base)
        fc_chunk_inputs = K_tile

        // 2. Load weights for this K-chunk
        DMA weight tile (if cache miss)
        FSM_WGT_LD → LOAD_ARRAY

        // 3. Load A_tile for this K-chunk
        DMA activation with fc_in_base offset
        populate a_tile[0:M-1][0:K_tile-1]

        // 4. Run streaming compute
        FSM_GEMM_STREAM_RUN
        wavefront collect → add to c_tile

        // 5. Next K-chunk or STORE
        fc_in_base += K_tile
    STORE c_tile (once, after all K-chunks)
next N tile (if any)
```

### FSM modification

Add two new states:
```
FSM_GEMM_STREAM_ACCUM = 6'd40   — K-chunk loop check + next-chunk setup
FSM_GEMM_STREAM_NEXT_K = 6'd41  — re-enter weight/activation load for next chunk
```

Modified FSM flow:
```
FSM_WGT_LD
    → FSM_GEMM_STREAM_PREP       (clear c_tile, first time only)
    → FSM_GEMM_STREAM_LOAD_A     (load a_tile for current K-chunk)
    → FSM_GEMM_STREAM_RUN        (compute + c_tile accumulate)
    → FSM_GEMM_STREAM_ACCUM      (NEW: check if more K-chunks)
        ├─ yes → FSM_GEMM_STREAM_NEXT_K → FSM_LOAD_ARRAY → FSM_WGT_LD
        └─ no  → FSM_GEMM_STREAM_DONE → FSM_GEMM_STREAM_STORE → FSM_DONE
```

## 5. Detailed implementation plan

### 5.1 c_tile accumulation

```verilog
// In FSM_GEMM_STREAM_RUN, change collect logic:
if (!c_tile_valid[str_m][str_n]) begin
    // First capture for this cell: direct write
    c_tile[str_m][str_n] <= array_sum_out[str_n*32 +: 32];
    c_tile_valid[str_m][str_n] <= 1'b1;
end else if (stream_k_chunk_idx > 0) begin
    // Subsequent K-chunk: accumulate
    c_tile[str_m][str_n] <= $signed(c_tile[str_m][str_n])
                          + $signed(array_sum_out[str_n*32 +: 32]);
end
```

**Key considerations:**
- Read-modify-write is safe: c_tile is a register array, each [m][n] is independent
- No double-write: each [m][n] receives exactly one partial sum per K-chunk
- Signed 32-bit add: use `$signed()` like the PE does
- Overflow: defer to INT32 wrap-around (same as legacy)
- stream_k_chunk_idx tracks which chunk we're on (0=first)

### 5.2 c_tile clear timing

Clear ONLY in first entry to `FSM_GEMM_STREAM_PREP`:
```verilog
reg gemm_stream_first_chunk;

FSM_GEMM_STREAM_PREP: begin
    if (gemm_stream_first_chunk) begin
        // Clear c_tile for fresh accumulation
        for (ci=0; ci<8; ci++)
            for (cj=0; cj<64; cj++) begin
                c_tile[ci][cj] <= 32'sd0;
                c_tile_valid[ci][cj] <= 1'b0;
            end
    end
    // Per-chunk: clear a_tile-related state
    stream_cycle <= 16'd0;
    stream_capture_count <= 16'd0;
    stream_active <= 1'b0;
    stream_a_tile_loaded <= 1'b0;
    stream_k_chunk_idx <= gemm_stream_k_chunk_idx;
    fsm_state <= FSM_GEMM_STREAM_LOAD_A;
end
```

### 5.3 New registers

```verilog
reg [15:0] gemm_stream_k_base;       // current K-chunk start offset
reg [15:0] gemm_stream_k_tile;       // current K-chunk size (≤64)
reg [15:0] gemm_stream_k_chunk_idx;  // 0, 1, 2, ...
reg [15:0] gemm_stream_num_k_chunks; // ceil(K/64)
reg        gemm_stream_first_chunk;  // true for first chunk
```

### 5.4 a_tile preload modification

```verilog
// Current: uses input_c (full K) for division
// Fix: use K_tile for division, offset DMA address by k_base

FSM_GEMM_STREAM_LOAD_A: begin
    if (!stream_a_tile_loaded) begin
        stream_a_tile_loaded <= 1'b1;
        stream_capture_count <= 16'd0;
        // Start DMA for A[m][k_base : k_base+K_tile-1]
        act_dma_addr <= blk_in_addr + {16'd0, gemm_stream_k_base};
        act_dma_bytes <= gemm_M_val * {16'd0, gemm_stream_k_tile};
        act_dma_start <= 1'b1;
    end else if (stream_capture_count < (gemm_M_val * gemm_stream_k_tile)) begin
        // Use K_tile for indexing, not input_c
        a_tile[stream_capture_count / gemm_stream_k_tile]
              [stream_capture_count % gemm_stream_k_tile] <= cf_act_data;
        stream_capture_count <= stream_capture_count + 16'd1;
    end else begin
        stream_active <= 1'b1;
        stream_cycle <= 16'd0;
        fsm_state <= FSM_GEMM_STREAM_RUN;
    end
end
```

### 5.5 B weight load for streaming K-chunks

For each new K-chunk:
1. Set `fc_in_base = gemm_stream_k_base`
2. Set `fc_chunk_inputs = gemm_stream_k_tile`
3. Go to `FSM_LOAD_ARRAY` → `FSM_WGT_LD`
4. In `FSM_WGT_LD`, `gemm_row_streaming_en` routes back to `FSM_GEMM_STREAM_PREP`

Weight cache hit detection: `fc_in_base` is part of the cache key, so different K-chunks will correctly miss and trigger a weight reload.

### 5.6 STORE timing

```verilog
FSM_GEMM_STREAM_ACCUM: begin
    // Check if more K-chunks remain
    if (gemm_stream_k_base + gemm_stream_k_tile < input_c) begin
        // Advance to next K-chunk
        gemm_stream_k_base <= gemm_stream_k_base + gemm_stream_k_tile;
        gemm_stream_k_tile <= min(64, input_c - (gemm_stream_k_base + gemm_stream_k_tile));
        gemm_stream_k_chunk_idx <= gemm_stream_k_chunk_idx + 16'd1;
        gemm_stream_first_chunk <= 1'b0;
        // Need to invalidate weight cache for new chunk
        gemm_weight_valid <= 1'b0;
        fc_in_base <= gemm_stream_k_base;
        fc_chunk_inputs <= gemm_stream_k_tile;
        fsm_state <= FSM_LOAD_ARRAY;  // re-enter weight load path
    end else begin
        // All K-chunks done: STORE
        gemm_store_row_idx <= 16'd0;
        gemm_store_beat_idx <= 16'd0;
        fsm_state <= FSM_GEMM_STREAM_STORE;
    end
end
```

### 5.7 K-chunk initialization

```verilog
// In FSM_WGT_LD, when entering streaming path for the first time:
if (gemm_row_streaming_en) begin
    gemm_stream_k_base       <= 16'd0;
    gemm_stream_k_tile       <= fc_chunk_inputs;  // = min(64, K)
    gemm_stream_k_chunk_idx  <= 16'd0;
    gemm_stream_num_k_chunks <= (input_c + 15'd63) >> 6;
    gemm_stream_first_chunk  <= 1'b1;
    fsm_state <= FSM_GEMM_STREAM_PREP;
end
```

## 6. Risk assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| c_tile read-modify-write timing | Medium | Each [m][n] gets one accumulation per K-chunk, no conflict. Use blocking assignment for accumulate value, non-blocking for c_tile write. |
| a_tile DMA address offset | Low | `act_dma_addr` can be overridden per chunk. Need to ensure DMA completes before LOAD_A reads data. |
| Weight cache false hit across K-chunks | Low | `fc_in_base` already in cache key. Different k_base → cache miss → fresh DMA. |
| fc_in_base conflict between streaming and legacy paths | Medium | Streaming and legacy share `fc_in_base` and `fc_chunk_inputs`. Streaming must set these before entering shared LOAD_ARRAY/WGT_LD path. |
| Signed accumulation overflow | Low | Same INT32 wrap-around as legacy PE MAC. Documented limitation. |
| K%64 != 0 boundary | Low | `fc_chunk_inputs` = min(64, remaining) handles last partial chunk. active_k tracks actual chunk size. PIPE_OFFSET = 64 - K_tile + 1 correct for partial chunks. |
| Regression impact on v1 tests | Low | K≤64 path unchanged (single chunk = same logic as v1). |
| RS0-RS8 must continue to PASS | Critical | Add `if (gemm_stream_k_chunk_idx == 0)` guards or keep single-chunk path identical. |

## 7. Test plan

| Level | M | K | N | Chunks | Beats/row | Expected C | Notes |
|-------|---|---|---|:------:|:---------:|-----------|-------|
| RS9 | 8 | 128 | 8 | 2 | 1 | 128 | 2 chunks × K_tile=64 |
| RS10 | 8 | 512 | 8 | 8 | 1 | 512 | 8 chunks, stress test |
| RS11 | 8 | 128 | 16 | 2 | 2 | 128 | K-chunk + multi-beat STORE |
| RS12 | 4 | 128 | 8 | 2 | 1 | signed golden | signed + K-chunk |
| RS13 | 7 | 65 | 8 | 2 | 1 | 65 | boundary K%64=1, last chunk K_tile=1 |
| RS14 | 8 | 64 | 8 | 1 | 1 | 64 | regression: single chunk still works |

Each test must verify:
- memory PASS (all C[m][n] = K for all-1, or = golden for signed)
- write_beat_count = M × beats_per_row
- K_chunk_count matches expected
- weight_load_count ≤ num_chunks (weight cache: first load counts, hits don't)
- UVM_ERROR=0, UVM_FATAL=0
- RS0-RS8 still PASS (regression)

## 8. Implementation phases

### Phase 3a: c_tile accumulation + K-chunk loop (core logic)

1. Add `gemm_stream_k_base`, `gemm_stream_k_tile`, `gemm_stream_k_chunk_idx`, `gemm_stream_first_chunk` registers
2. Modify `FSM_GEMM_STREAM_PREP` for first-chunk vs subsequent-chunk differentiation
3. Modify `FSM_GEMM_STREAM_RUN` for c_tile accumulation (chunk > 0 → add)
4. Add `FSM_GEMM_STREAM_ACCUM` state for K-chunk loop check
5. Route next-chunk path via `FSM_LOAD_ARRAY` → `FSM_WGT_LD`
6. Initial test: RS9 (M=8,K=128,N=8) all-1

### Phase 3b: a_tile preload with K-tile offset

1. Fix a_tile address calculation: use `K_tile` not `input_c` for indexing
2. Add `k_base` offset to act DMA address
3. Test: RS9, RS13 (boundary K=65)

### Phase 3c: multi-chunk regression + edge cases

1. RS10 (K=512 stress), RS11 (K-chunk + multi-beat N=16)
2. RS12 (signed + K-chunk)
3. RS13 (boundary K=65)
4. Full regression: RS0-RS13 + legacy 7/7

## 9. Files to modify

```
rtl/npu/npu_top.v                                  — core K-chunk logic
verif/uvm_top/tests/npu_task_gemm_row_streaming_test.sv — RS9-RS13 tests
```

**Not modified**: mac_pe.v, mac_tile_4x4.v, array_top.v, pe_cluster.v, compute_core.v, block_scheduler.v

## 10. Success criteria

1. RS9-RS13 all PASS with correct memory verification
2. RS0-RS8 regression all PASS (no degradation)
3. GEMM_FUNC 6/6 PASS
4. FC/Conv/BW regression PASS
5. UVM_ERROR=0, UVM_FATAL=0
6. mac_pe / mac_tile / array_top unchanged
