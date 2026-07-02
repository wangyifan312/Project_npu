# NPU MatrixOp Phase U3 — result_tile_bank Abstraction

**Phase**: U3 — result_tile_bank abstraction (behavior-preserving rename)
**Date**: 2026-07-02
**Base**: `main` `619158f` (Phase U2 merge)
**Branch**: `feature/npu-result-tile-bank-abstraction`

---

## 1. Phase U3 Goals

Semantically abstract the streaming output accumulator from "c_tile" to "result_tile_bank":

1. Rename `c_tile_bank0/1` → `result_tile_bank0/1`
2. Rename `c_tile_valid_bank0/1` → `result_tile_valid_bank0/1`
3. Rename `compute_c_bank` → `compute_result_bank`
4. Rename `store_c_bank` → `store_result_bank`
5. Zero behavior change
6. No new features

---

## 2. Rename Mapping

| Old Signal | New Signal | Width | Description |
|-----------|-----------|-------|-------------|
| `c_tile_bank0` | `result_tile_bank0` | `[0:7][0:63]` INT32 | Double-buffer bank 0 for partial sums |
| `c_tile_bank1` | `result_tile_bank1` | `[0:7][0:63]` INT32 | Double-buffer bank 1 for partial sums |
| `c_tile_valid_bank0` | `result_tile_valid_bank0` | `[0:7][0:63]` | Write-once tracking for bank 0 |
| `c_tile_valid_bank1` | `result_tile_valid_bank1` | `[0:7][0:63]` | Write-once tracking for bank 1 |
| `compute_c_bank` | `compute_result_bank` | 1-bit | Which bank the collector writes |
| `store_c_bank` | `store_result_bank` | 1-bit | Which bank STORE reads |

**Not renamed** (different semantics, not c_tile):
- `fc_tile_outputs` — FC output tile column count
- `fc_tile_capacity*` — FC tile capacity calculation
- `gemm_tile_M/N/...` — MatrixOp tile descriptors
- `store_desc_bank` — already abstract descriptor field

---

## 3. Storage Structure (Unchanged)

```
result_tile_bank0 [0:7][0:63]  =  8 rows × 64 cols × 32-bit  =  2 KB
result_tile_bank1 [0:7][0:63]  =  8 rows × 64 cols × 32-bit  =  2 KB
Total: 4 KB (dual-bank for double-buffered STORE/RUN overlap)
```

**Behavior unchanged**:
- Bank toggle logic: `compute_result_bank` toggles at N/M tile boundaries
- `store_result_bank` latched from `compute_result_bank` at tile completion
- First K-chunk: write-once with valid tracking
- Subsequent K-chunks: signed accumulate
- GST STORE reads from `store_result_bank`

---

## 4. Data Paths (All Verified Identical)

### GEMM Streaming Output Path
```
PE array_sum_out
  → result_tile_bank0 / result_tile_bank1  (double-buffer accumulation)
  → store_desc_* (locked at tile STORE start)
  → GST per-beat STORE micro-FSM (GST_PUSH_BEAT → ... → GST_ADVANCE)
  → write_beat_fifo (depth 64)
  → dma_axi_writer (AXI4 256-bit write)
```

### FC Streaming Output Path
```
PE array_sum_out
  → result_tile_bank0 / result_tile_bank1  (same path as GEMM)
  → store_desc_*
  → GST per-beat STORE micro-FSM
  → write_beat_fifo
  → dma_axi_writer
```

### Legacy FC/Conv Path (Untouched)
```
PE array_sum_out
  → acc_buffer  (via acc_wr_data/en, COLLECT/DRAIN)
  → legacy store_pack (SP_FIRST → SP_STREAM → SP_PUSH)
  → write_beat_fifo
  → dma_axi_writer
```

### Post-Op Fallback Path (Untouched)
```
bias_enabled=1 or relu_en=1:
  → legacy FC FSM
  → acc_buffer path
  → optional FSM_REQUANT_COMPUTE for bias+requant
```

---

## 5. Why acc_buffer is NOT Removed

1. **Legacy post-op consumers**: Requant, Add, GAP, Pool read/write `acc_buffer`
2. **Legacy FC/Conv**: COLLECT/DRAIN writes to `acc_buffer`
3. **Different access pattern**: `acc_buffer` is sequential single-port BRAM; `result_tile` is multi-port register array
4. **Different capacity**: `acc_buffer` = 1024 × 32-bit = 4 KB; `result_tile` = 2 × 512 × 32-bit = 4 KB but organized differently
5. **Unification**: Requires restructuring post-op pipeline — deferred to Phase U4

---

## 6. Test Results

| Category | Result |
|----------|--------|
| FC Streaming smoke (6 levels) | 6/6 PASS |
| FC Streaming robustness (8 boundary + 3 matched) | 11/11 PASS |
| FC Streaming fallback | PASS |
| Legacy FC smoke | PASS |
| GEMM row-streaming | 37/37 PASS |
| GEMM_FUNC | 6/6 PASS |
| Conv smoke | PASS |
| Requant smoke | PASS |
| Pool smoke | PASS |
| Add smoke | PASS |
| GAP smoke | PASS |

**UVM_ERROR=0, UVM_FATAL=0**

---

## 7. Cycles Comparison (Identical to Pre-Rename)

| Workload | Pre-U3 cycles | Post-U3 cycles | Delta |
|----------|:---:|:---:|:---:|
| FCS0 (1×4×4) | 123 | 123 | 0 |
| FCR2 (1×64×64) | 779 | 779 | 0 |
| MATCH0 streaming | 174 | 174 | 0 |
| MATCH1 streaming | 779 | 779 | 0 |
| GEMM NT5 | 5839 | 5839 | 0 |

Zero cycle delta — confirms behavior-preserving rename.

---

## 8. Issues Found

None. Pure mechanical rename. All tests pass with identical cycle counts.

---

## 9. Recommended Next Phase

```
Phase U4 — Post-op migration audit (AUDIT ONLY, no RTL change)

Scope:
  - Evaluate how bias/ReLU/requant can operate on result_tile path
  - Evaluate result_tile → acc_buffer bridge for post-op
  - Evaluate INT32 vs INT8 output on same STORE engine
  - Legacy post-op continued as fallback

Do NOT begin Phase U4-a coding until audit is complete and approved.
```
