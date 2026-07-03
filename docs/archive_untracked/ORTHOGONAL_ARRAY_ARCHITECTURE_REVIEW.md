# Orthogonal-flow 64×64 Systolic Array — Architecture Review

**Date**: 2026-06-30  
**Author**: Architecture audit before RTL refactoring  
**Status**: Step 1 complete — entering Step 2

---

## 1. Current PE Module

**File**: `rtl/npu/mac_pe.v`  
**Module**: `mac_pe`

Current PE is **weight-stationary**:

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `act_in/act_out` | left→right | 8-bit | Activation flows horizontally |
| `sum_in/sum_out` | top→bottom | 32-bit | Partial sum flows vertically |
| `weight` | input | 8-bit | Pre-loaded into weight_reg |
| `weight_ld` | input | 1-bit | Load strobe |

```
act_in ──→ [act_reg] ──→ act_out
                │
                ├──×── product (INT8×INT8 → INT16)
                │
           [weight_reg] ←── weight (load once, stay stationary)
                │
sum_in ──→ [+] ──→ [sum_out_reg] ──→ sum_out
```

**Key property**: PE row = K (input dimension), PE col = N (output dimension).  
C = A × B where one row of C is computed per pass.

**Missing for orthogonal flow**:
- No `b_in/b_out` vertical port (B dataflow)
- No local accumulator (C doesn't stay in PE; sum flows through)
- Weight is stationary, not streaming

---

## 2. Current Array / Cluster / Compute Fabric Modules

| File | Module | Role |
|------|--------|------|
| `rtl/npu/mac_tile_4x4.v` | `mac_tile_4x4` | 4×4 PE tile (flat ports for iverilog) |
| `rtl/npu/array_top.v` | `array_top` | TILE_ROWS×TILE_COLS tile grid interconnect |
| `rtl/npu/pe_cluster.v` | `pe_cluster` | Cluster wrapper: array + latency counter |
| `rtl/npu/compute_core.v` | `compute_core` | Multi-cluster wrapper (CLUSTER_COUNT=1 default) |
| `rtl/npu/cluster_scheduler.v` | `cluster_scheduler` | Cluster mode/mask scheduling |
| `rtl/npu/output_arbiter.v` | `output_arbiter` | Routes cluster outputs to single stream |
| `rtl/npu/npu_top.v` | `npu_top` | Top-level NPU FSM + feeders + DRAIN/COLLECT |

**Parameterization**:
```
TILE_ROWS = 16, TILE_COLS = 16
  → PE_ROWS = 64, PE_COLS = 64
  → N_TILES = 256
  → Total PE = 4,096
```

---

## 3. Current PE Row/Col Interconnect

### 3.1 Within a tile (mac_tile_4x4.v)

```
PE[r][c]:
  act_in  ← act_h[r][c]
  act_out → act_h[r][c+1]     (horizontal flow)
  sum_in  ← sum_v[r][c]
  sum_out → sum_v[r+1][c]     (vertical flow)
  weight  ← weight[r][c]      (per-PE, stationary)
```

### 3.2 Between tiles (array_top.v)

- **Activation**: Flows left-to-right across tile columns:
  - `act_tile_flat[(tr*(TILE_COLS+1)+tc)*4*8 +: 32]` → tile(tr,tc)
  - Tile output → `act_tile_flat[(tr*(TILE_COLS+1)+tc+1)*4*8 +: 32]`

- **Partial sum**: Flows top-to-bottom across tile rows:
  - `sum_tile_flat[(tr*TILE_COLS+tc)*4*32 +: 128]` → tile(tr,tc)
  - Tile output → `sum_tile_flat[((tr+1)*TILE_COLS+tc)*4*32 +: 128]`

- **First tile row gets sum_in from external** (= 0 for initial accumulation)

### 3.3 Array boundary (from npu_top.v)

```verilog
assign array_sum_in = {PE_COLS{32'h0}};  // zero initial partial sums
```

Array output: `cluster_arb_sum_out` from output_arbiter.

---

## 4. Current Weight Load Path

1. **Weight DMA**: AXI read → wgt_buffer (256-bit beats)
2. **wgt_load_reg**: 64×64×8-bit = 32 Kbit register array in npu_top
3. **LOAD_ARRAY**: Per-byte loading from wgt_buffer → wgt_load_reg
   - Conv: `wgt_load_reg[(sp * PE_COLS + out_c)*8 +: 8]` — spatial × output_ch layout
   - FC/GEMM: `wgt_load_reg[(row_idx * PE_COLS + out_idx)*8 +: 8]` — K × N layout
4. **WGT_LD**: `array_weight_ld = 1` → weights loaded into PE weight_reg
5. **Weight-stationary**: Weights stay in PEs during entire compute

**Key observation**: For FC/GEMM, weight[K][N] maps to PE[K][N], i.e.:
- PE row = K (weight row / input dimension)
- PE col = N (weight col / output dimension)

---

## 5. Current Activation Feed Path

### Skewed feeding (CP_FEED_ACT)

```verilog
// For FC/GEMM:
// comp_feed_cnt iterates 0..K-1
// Each cycle: one activation element A[m, k] fed to row k
act_held[comp_feed_cnt] <= cf_act_data;  // latch
// All rows continue to drive held values during DRAIN
array_act_in[ai*8 +: 8] = act_held[ai];
```

### Conv feeding
```
25 spatial positions → 25 PE rows
cf_window[0:24] → act_held[0:24] → array_act_in
```

**Key property**:
- `array_active_rows = fc_or_gemm ? fc_chunk_inputs : conv_kernel_area`
- For FC/GEMM: active rows = input_c (K dimension) ≤ 64
- For Conv: active rows = kernel_area (25 for 5×5)

---

## 6. Current Partial Sum / DRAIN / COLLECT Output Path

### DRAIN (CP_DRAIN)
```
Each cycle after drain_offset:
  col_results[global_col] <= array_sum_out[global_col]
  // Captures one column of PE output per cycle
```

### COLLECT (merged into CP_DRAIN, P2 overlap)
```
Each cycle after first valid column:
  acc_wr_data = array_first_accum ? col_results[acc_col_idx] 
                                 : (acc_rd_data + col_results[acc_col_idx])
  acc_wr_en, acc_partial_addr++
  // Accumulates columns into acc_buffer (partial sums for multi-c_in Conv)
```

### Output dimensions
- Conv: `collect_total_cols = total_global_cols = output_c` (all N output channels)
- FC/GEMM: `collect_total_cols = array_active_cols = fc_tile_outputs`
- Always collects **1 row × N columns** (single output row)

### STORE path
```
GEMM row-by-row:
  Row stride = ceil(N*4/32)*32 for 32B-aligned DMA
  fc_store_addr = output_base + gemm_row_idx * row_stride
  fc_store_bytes = N * 4
```

---

## 7. Evidence: PE row = K, PE col = N

All evidence is in `rtl/npu/npu_top.v`:

| Line(s) | Code | Meaning |
|---------|------|---------|
| 644 | `is_gemm_mode = (task_type == 3'd7)` | GEMM=7, separate task type |
| 649 | `fc_or_gemm = is_fc_mode \|\| is_gemm_mode` | GEMM reuses FC path |
| 674 | `array_active_rows = fc_or_gemm ? fc_chunk_inputs : conv_kernel_area` | PE rows = K for FC/GEMM |
| 1003-1004 | `fc_chunk_inputs_next = (input_c > PE_ROWS_16) ? PE_ROWS_16 : input_c` | Chunk inputs = min(K, 64) |
| 1001-1002 | `fc_tile_outputs_next = ... : fc_tile_capacity` | Tile outputs ≤ PE_COLS = N |
| 585-589 | `gemm_row_idx`, `gemm_M_val = input_h`, `gemm_N_val = output_c` | M iterates over rows |
| 2605-2608 | GEMM store: row_stride per output row | One row per GEMV pass |
| 2288-2299 | FSM_LOAD_ARRAY: `wgt_load_reg[(row*PE_COLS+col)*8]` | Weight[K][N] → PE[K][N] |

The register mapping for GEMM is:
```
M (output rows)     = input_h
K (inner dimension) = input_c
N (output cols)     = output_c
```

But the **hardware mapping** is:
```
PE row index = k (0..K-1)     ← THIS MUST CHANGE TO m (0..M-1)
PE col index = n (0..N-1)     ← stays as N
```

---

## 8. What Must Change for Orthogonal Flow

### 8.1 PE module (mac_pe.v) — MUST REWRITE

| Change | Old | New |
|--------|-----|-----|
| Ports | `act_in/out, sum_in/out, weight, weight_ld` | `a_in/out, b_in/out, valid_in, clear` |
| A flow | left→right (exists) | left→right (keep, rename) |
| B flow | none | top→bottom (add) |
| C storage | none (flows through) | local 32-bit accumulator (add) |
| Weight | stationary register | removed (B streams through) |
| Output | sum_out (flows out bottom) | c_out = local acc (combinational read) |

### 8.2 Tile module (mac_tile_4x4.v) — MUST REWRITE

| Change | Old | New |
|--------|-----|-----|
| Ports | 4 act_in, 4 sum_in, 16 weight, weight_ld | 4 a_in, 4 b_in, valid_in, clear |
| Interconnect | sum vertical (retained), act horizontal (retained) | a horizontal, b vertical (swapped from sum) |
| Outputs | 4 sum_out (bottom) | 4×4 c_out (all PEs) |
| Weight | per-PE load | removed |

### 8.3 Array module (array_top.v) — MUST REWRITE

| Change | Old | New |
|--------|-----|-----|
| Inputs | act_in_flat, sum_in_flat, weight_flat, weight_ld | a_left_flat, b_top_flat, valid_in, clear |
| Outputs | sum_out_flat (1×N columns bottom row) | c_out_flat (M×N grid, all PEs) |
| Interconnect | sum passes down through tiles | b passes down through tiles |
| Clock gating | per-tile (keep) | per-tile (keep, optional) |

### 8.4 Feeder (in npu_top.v) — MUST REWRITE

| Change | Old | New |
|--------|-----|-----|
| A feed | skewed act_held per row (already skewed) | skewed A[m,k] per row (keep pattern, change data source) |
| B feed | none (weights preloaded) | skewed B[k,n] per column (new) |
| Weight load | LOAD_ARRAY → WGT_LD → PE weight_reg | removed for GEMM (B streamed from buffer) |
| wgt_load_reg | 64×64×8-bit register | may repurpose for tile A/B buffers |

### 8.5 DRAIN/COLLECT (in npu_top.v) — MUST REWRITE

| Change | Old | New |
|--------|-----|-----|
| Output dims | 1×N per pass | M×N per tile |
| DRAIN | capture col_results[0:N-1] from bottom | capture c_out[m,n] from all PE[m,n] |
| COLLECT | accumulate 1 column/cycle to acc_buffer | collect M×N results, write to acc_buffer |
| STORE | 1 row at a time (row_stride) | all M rows in one pass |

### 8.6 GEMM control (in npu_top.v) — MUST REWRITE

| Change | Old | New |
|--------|-----|-----|
| Loop | M iterations (row-by-row GEMV) | single pass (full GEMM in array) |
| active_rows | fc_chunk_inputs (= K) | active_m (= M_tile ≤ 64) |
| active_cols | fc_tile_outputs (= N) | active_n (= N_tile ≤ 64) |
| compute cycles | ~K (feed) + drain_offset + N (collect) | K + M + N - 2 (systolic latency + flush) |

---

## 9. Impact on Existing Tests

### Directly affected (will FAIL after refactor):

| Test | Impact | Reason |
|------|:--:|------|
| `npu_fc_smoke_test` | **WILL FAIL** | FC maps to orthogonal GEMM with M=1 |
| `npu_conv_smoke_test` | **WILL FAIL** | Conv currently uses weight-stationary path, PE changed |
| `npu_fc_128x128_peak_test` | **WILL FAIL** | FC path restructured |
| `npu_conv_multiblock_test` | **WILL FAIL** | Conv path restructured |
| `npu_task_gemm_func_test` | **WILL FAIL** | Old row-by-row GEMV replaced |

### Indirectly affected:

| Test | Impact | Reason |
|------|:--:|------|
| `npu_bandwidth_60pct_stress_test` | **Should NOT fail** | VecReLU path doesn't use PE array |
| `npu_gap_smoke_test` | **Should NOT fail** | GAP doesn't use PE array |
| `npu_add_smoke_test` | **Should NOT fail** | ADD doesn't use PE array |
| `npu_pool_smoke_test` | **Should NOT fail** | Pool doesn't use PE array |
| `npu_requant_smoke_test` | **Should NOT fail** | Requant doesn't use PE array |
| `npu_lenet_1_test` | **WILL FAIL** | Uses FC + Conv paths |

---

## 10. FC / Conv Mapping Risk Assessment

### FC mapping to orthogonal GEMM

```
FC: y = W × x + b  (M=1, K=input_c, N=output_c)
```

Can map to orthogonal array as:
```
M_tile = 1 (use row 0 only)
K_time = input_c
N_tile = output_c
```

**Risk**: LOW. This is a degenerate case of GEMM with M=1. The array's row 0 computes one output row. All other rows idle.

### Conv mapping to orthogonal GEMM

Conv currently uses weight-stationary with im2col. Converting to orthogonal flow requires:

1. im2col → GEMM lowering (already conceptually done in conv_frontend)
2. Then feed the lowered matrix as GEMM to orthogonal array

**Risk**: HIGH. This is a major change that touches:
- conv_frontend (window extraction → matrix lowering)
- Weight feeding (per-spatial-position → per-GEMM-tile)
- Multi-c_in accumulation (currently using acc_buffer accumulation across c_in)

**Recommendation**: Keep old Conv path as legacy fallback for now. Orthogonal array is for GEMM first. Conv migration is a separate task.

### Implementation strategy

1. Create new PE, tile, array as separate modules (e.g., `ortho_pe.v`, `ortho_tile.v`, `ortho_array.v`)
2. Add new feeder/writer modules for orthogonal path
3. Add `TASK_GEMM=3'd7` that routes to orthogonal path
4. Keep old compute path for FC/Conv as legacy (with old `TASK_GEMM_FUNC` or separate branch)
5. Once orthogonal GEMM is verified, migrate FC → orthogonal (M=1)
6. Conv migration is a separate project

---

## 11. Summary of Changes Needed

| # | Module | Change Severity | New File? |
|---|--------|:--:|:--:|
| 1 | `mac_pe.v` | REWRITE | `ortho_pe.v` (or replace) |
| 2 | `mac_tile_4x4.v` | REWRITE | `ortho_tile.v` (or replace) |
| 3 | `array_top.v` | REWRITE | `ortho_array.v` (or replace) |
| 4 | `pe_cluster.v` | MODIFY | Adapt to new array |
| 5 | `compute_core.v` | MINOR | Port width changes |
| 6 | `npu_top.v` FEED_ACT | REWRITE | Skewed A+B stream |
| 7 | `npu_top.v` DRAIN/COLLECT | REWRITE | M×N collection |
| 8 | `npu_top.v` GEMM FSM | REWRITE | Single-pass GEMM |
| 9 | `npu_top.v` wgt_load_reg | REPURPOSE | A/B tile buffers |
| 10 | `conv_frontend.v` | UNCHANGED | Legacy path preserved |
| 11 | `fc_frontend.v` | UNCHANGED | Legacy path preserved |

---

## 12. Recommended Approach

1. **Branch**: `orthogonal_array_rewrite` from main
2. **Phase A**: New `ortho_pe.v` + unit test (verify PE behavior)
3. **Phase B**: New `ortho_tile.v` (4×4) + unit test
4. **Phase C**: New `ortho_array.v` (64×64) + `ortho_array_unit_test`
5. **Phase D**: New skewed feeder in npu_top (A and B streams)
6. **Phase E**: New DRAIN/COLLECT for M×N output
7. **Phase F**: Wire `TASK_GEMM=3'd7` to orthogonal path
8. **Phase G**: NPU-level GEMM tests
9. **Phase H**: FC migration (M=1 GEMM)
10. **Phase I**: Regression assessment

Each phase verified independently before moving to next.
