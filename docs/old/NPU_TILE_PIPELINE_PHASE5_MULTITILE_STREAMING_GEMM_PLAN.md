# NPU Tile Pipeline — Phase 5 Multi-Tile Streaming GEMM Plan

## 1. Current Tile Limits (Audit)

### 1.1 Hardware Constraints

| Parameter | Value | Source |
|-----------|:-----:|--------|
| PE_ROWS | 64 | `TILE_ROWS(16) × 4` |
| PE_COLS | 64 | `TILE_COLS(16) × 4` |
| a_tile rows | 8 | `[0:7][0:63]`, s_m[2:0] = 3 bits |
| wgt_load_reg | 64×64 | `PE_ROWS × PE_COLS × 8` |
| c_tile | 8×64 | `[0:7][0:63]` INT32 |
| input_tile_bank | 8×64 | `[0:7][0:63]` × 2 banks |
| wgt_buffer entries | 1024 | 256-bit beats, 2 banks |

### 1.2 Streaming GEMM Tile Limits

| Limit | Value | RTL Source |
|-------|:-----:|------------|
| **M_tile ≤ 8** | a_tile row count | `a_tile[0:7]`, `s_m[2:0]` |
| **N_tile ≤ 64** | PE columns | `fc_tile_outputs = min(PE_COLS, output_c)` |
| **K_tile ≤ 64** | PE rows | `fc_chunk_inputs = min(PE_ROWS, input_c - fc_in_base)` |
| **K unlimited** | chunked | K-chunk streaming loop |

### 1.3 What IS Supported

```
✅ K > 64: chunked via K-chunk streaming loop
✅ Non-uniform A across K chunks
✅ Non-uniform B across K chunks (K-major layout)
✅ Signed INT8
✅ M ≤ 8, single-pass through streaming pipeline
✅ N ≤ 64, single N tile
```

### 1.4 What IS NOT Supported

```
❌ M > 8: a_tile only has 8 rows, s_m uses 3 bits
❌ N > 64: fc_tile_outputs capped at PE_COLS, no N tile advancement in streaming path
❌ Multi-output-tile: no fc_out_start advancement in streaming GEMM
❌ Multi-M-tile: no M tile base address computation
```

### 1.5 Legacy GEMM (non-streaming) Comparison

Legacy GEMM (GEMM_FUNC, gemm_row_streaming_en=0) supports M>8 by iterating
`gemm_row_idx` per row (GEMV-style). Each row is an independent FC/GEMV pass.
N>64 is handled by fc_tile_outputs and fc_out_start advancement in the FC tile
prep path. But this path does NOT use streaming, input prefetch, or weight prefetch.

### 1.6 Why M ≤ 8 in Streaming GEMM

The streaming GEMM architecture is fundamentally tiled:

```
a_tile[0:7][0:63] — holds 8 rows × 64 K elements
  ↓ row-skewed feed
PE array (64×64)
  ↓ wavefront collector  
c_tile[0:7][0:63] — holds 8 rows × 64 N elements
```

`s_m[2:0]` indexes into `a_tile` rows. 3 bits = 0..7 = 8 rows maximum.
To support M > 8, need either larger a_tile (e.g., 16×64) or M tiling.

### 1.7 Why N ≤ 64 in Streaming GEMM

`fc_tile_outputs = min(PE_COLS(64), output_c)`. For streaming GEMM,
`fc_out_start` is always 0. There's no N tile advancement loop in the
streaming path. `fc_out_start` advancement exists only in the legacy FC path
(FSM_FC_TILE_PREP → FSM_FC_LOAD_WGT → ...), which is NOT used when
`gemm_row_streaming_en=1`.

---

## 2. Multi-Tile Architecture Design

### 2.1 Desired Tile Loop Structure

```
for m_tile_base in 0 .. M step M_TILE:
    for n_tile_base in 0 .. N step N_TILE:
        // Clear result for this output tile
        for k_base in 0 .. K step K_TILE:
            LOAD/PREFETCH A tile
            LOAD/PREFETCH B tile
            COMPUTE (MAC accumulate into c_tile)
        STORE C[m_tile_base : m_tile_base+M_TILE,
                n_tile_base : n_tile_base+N_TILE]
```

Current state:
- ✅ Inner loop (K-chunk): fully supported
- ❌ M tile loop: not supported
- ❌ N tile loop: not supported
- ❌ Output tile descriptor: not supported

### 2.2 M Tiling Design

For M > 8: divide M into tiles of M_TILE = 8 rows.

```
Tile 0: rows 0..7   → a_tile[0..7], c_tile[0..7]
Tile 1: rows 8..15  → a_tile reused, c_tile reused
Tile 2: rows 16..23 → ...
```

Each M tile:
- Input address offset: `m_tile_base * input_c` within the A matrix
- Output address offset: `m_tile_base * gemm_N_val * 4` within the C matrix
- Same wgt_buffer (B is shared across M tiles — B[K,N] is K×N)
- **Actually NO**: B is K-major B[k][n], weight DMA loads full K×N_tile.
  For different M tiles, the SAME B is used. B does NOT change with M tiling.

Wait — current weight DMA formula:
```
wgt_dma_bytes = fc_tile_outputs * input_c + offset
```
For different M tiles, input_c (K) stays the same, and N_tile stays the same.
B weights are IDENTICAL across M tiles. No weight reload needed!

For A matrix: different M tiles need different A slices:
```
A[tile_m_base : tile_m_base+M_TILE][0:K-1]
```

For C matrix: different M tiles write to different output rows:
```
C[tile_m_base : tile_m_base+M_TILE][0:N-1]
```

### 2.3 N Tiling Design

For N > 64: divide N into tiles of N_TILE = 64 columns.

```
Tile 0: cols 0..63
Tile 1: cols 64..127
```

Each N tile:
- Weight: different N slice `B[0:K-1][n_tile_base:n_tile_base+N_TILE]`
  Weight DMA base: `weight_addr + n_tile_base * input_c`
  Wait — the current formula uses `fc_out_start * input_c`:
  ```
  wgt_dma_addr = weight_addr + fc_out_start * input_c
  ```
  But this is the FC formula. For streaming GEMM, fc_out_start=0.
  
  For GEMM N tiling, the B matrix layout is K-major:
  B[k][n] at byte address: weight_addr + k * output_c + n
  
  For N tile at n_tile_base:
  DMA reads from: weight_addr + 0*output_c + n_tile_base = weight_addr + n_tile_base
  DMA bytes: K * N_TILE = K * 64
  
  But the current formula uses `fc_out_start * input_c` = fc_out_start * K,
  not fc_out_start. So for N tiling with n_tile_base=64:
  DMA should start at weight_addr + 64 (byte offset within the row)
  
  Hmm, this needs careful redesign for N tiling in GEMM streaming.
  
- A matrix: SAME across N tiles (A[M,K] doesn't depend on N)
  No A reload needed for N tiling!
  
- c_tile: different N slice. Output at cols 0..63 for tile0, cols 64..127 for tile1.
  STORE base address: output_addr + n_tile_base * 4 (INT32)
  
- PE columns: fc_tile_outputs = min(64, N - n_tile_base)

### 2.4 Output Tile Descriptor

Each output tile needs:

```verilog
reg [15:0] tile_m_base;      // output row base
reg [15:0] tile_n_base;      // output column base  
reg [15:0] tile_M;           // this tile's row count (≤ 8)
reg [15:0] tile_N;           // this tile's column count (≤ 64)
reg [31:0] tile_output_addr; // STORE base for this tile
reg [31:0] tile_input_addr;  // A data base for this tile
reg [31:0] tile_weight_addr; // B data base for this tile
reg        tile_is_last_m;   // last M tile in this column
reg        tile_is_last_n;   // last N tile in this row
```

### 2.5 Multi-Tile and Prefetch Interactions

For M tiling:
- A changes between M tiles → input prefetch works per-M-tile
- B is identical across M tiles → weight prefetch may skip (B already staged)
- K-chunk loop is per-M-tile

For N tiling:
- A is identical across N tiles → input prefetch may skip (A already loaded)
- B changes between N tiles → weight prefetch loads new N slice
- K-chunk loop is per-N-tile

Combined M×N tiling:
- Both A and B change → both prefetches needed
- Could overlap A/B load for tile(i+1,j) with compute for tile(i,j)

---

## 3. Recommended Staged Implementation

### Phase 5-0 (current): Audit

### Phase 5-1: M-tiling sequential

**Goal**: Support M > 8 by tiling M into groups of 8 rows.
Still sequential: M_tile0 → STORE → M_tile1 → STORE → ...

Changes needed:
- m_tile_base register
- A address offset: `m_tile_base * input_c`
- C address offset: `m_tile_base * gemm_N_val * 4`
- M tile loop in main FSM (or via block_scheduler)
- Each M tile runs full K-chunk streaming loop
- STORE after each M tile's K-chunks complete

New test: MT0 (M=16, K=64, N=8), MT1 (M=16, K=128, N=8)

### Phase 5-2: N-tiling sequential

**Goal**: Support N > 64 by tiling N into groups of 64 columns.

Changes needed:
- n_tile_base register
- Weight DMA address: `weight_addr + n_tile_base` (not `fc_out_start*K`)
- fc_tile_outputs recomputation per N tile
- N tile loop in main FSM
- STORE address offset: `n_tile_base * 4`

New test: MT2 (M=8, K=64, N=128)

### Phase 5-3: Output tile descriptor + M×N combined

**Goal**: Formalize output tile descriptor, support combined M×N tiling.

### Phase 4c (return): STORE overlap on multi-tile

After Phase 5-3, multi-tile streaming GEMM works sequentially.
Then apply Phase 4c:
- c_tile_bank[2]
- Background store engine
- STORE(tile i-1) || RUN(tile i)

---

## 4. Test Plan

| Test | M | K | N | Tiles | Validates |
|------|---|---|---|:---:|------|
| MT0 | 16 | 64 | 8 | M×2 | M tiling (2 tiles) |
| MT1 | 16 | 128 | 8 | M×2, K×2 | M tiling + K chunks + prefetch |
| MT2 | 8 | 64 | 128 | N×2 | N tiling (2 tiles) |
| MT3 | 16 | 128 | 128 | M×2, N×2, K×2 | Full M/N/K tiling |
| MT4 | 16 | 128 | 8 | M×2, K×2 | Non-uniform A/B across tiles |

Regression: RS0-RS19 must continue to PASS (single tile baseline).

---

## 5. Phase 4c Re-entry Point

```
Phase 5-1 (M tiling sequential)
    ↓
Phase 5-2 (N tiling sequential)  
    ↓
Phase 5-3 (M×N output tile descriptor)
    ↓
Phase 4c-1 (c_tile double buffer)       ← RE-ENTER HERE
    ↓
Phase 4c-2 (background store engine)
    ↓
Phase 4c-3 (STORE(prev) || RUN(curr))
```

Phase 4c-1 requires output tile descriptor (Phase 5-3).
Phase 4c-3 requires multiple output tiles to overlap (Phase 5-1/5-2).

---

## 6. Risk Assessment

| Risk | Severity | Mitigation |
|------|:--------:|------------|
| M tile A address offset wrong | **MED** | Verify against golden per-row |
| N tile B address differs from FC formula | **HIGH** | GEMM N tiling uses byte offset, not K*N_tile |
| wgt_buffer must reload for N tiles | **MED** | Weight DMA per N tile |
| input_tile_bank must reload for M tiles | **MED** | Input DMA or act_buffer already loaded |
| K-chunk loop per M×N tile combination | **MED** | Triple nested loop: M→N→K |
| c_tile accumulation across K chunks | **LOW** | Existing logic unchanged |
| STORE address for multi-tile output | **MED** | tile_m_base × row_stride + tile_n_base × 4 |
| RS0-RS19 single-tile regression | **LOW** | Single tile is unchanged path |
| GEMM_FUNC legacy path | **LOW** | Guard with gemm_row_streaming_en |
