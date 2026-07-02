# NPU Phase U5-b: Bug B1 Root Cause and Fix

**Date:** 2026-07-02  
**Branch:** `feature/npu-system-baseline-stabilization`  
**Bug ID:** `U5-B1-GEMM-NTILE-NONUNIFORM`

---

## 1. Bug Summary

| Field | Detail |
|-------|--------|
| **Symptom** | GEMM streaming with N>64 and non-uniform weight data produces incorrect results |
| **Severity** | Functional correctness (pre-existing, masked by all-1 test data) |
| **Reproducibility** | 100% for any GEMM config with N>64 and non-uniform B/weight data |
| **First detected** | Phase U5-a Task C (extreme value stress test, P5-P8 patterns) |

## 2. Reproduction Conditions

```text
M = 1
K = 64
N = 65
B[k,n] = n (column-coded pattern)
```

Expected: C[0,n] = K × n = 64 × n  
Actual before fix: C[0,0] = 3904 = 64 × 61 (reads column 61's data)

## 3. Mismatch Fingerprint

### Pattern D1 (column-coded B: B[k,n] = n)

| Column | Expected | Actual | col_read | Tile |
|--------|----------|--------|----------|------|
| 0 | 0 | 3904 | 61 | T0 |
| 1 | 64 | 4 | -1 | T0 |
| ... | ... | ... | -1 | T0 |
| 64 | 4096 | 1058 | -1 | T1 |

Total: 32/65 mismatches. Column 0 reads B data from column 61.

### Pattern D2 (k-column-coded B: B[k,n] = 1000×n + k)

Column 0: k_sum = 1955 (expected 2016), difference = 61 → one row's k value read incorrectly.

### Why all-1 data masked the bug

With all-1 data (A=1, B=1), every weight byte is 1. Regardless of which B byte is read, the product is always 1, and C[m,n] = K. The weight layout bug is invisible to all-1 tests. Uniform-pattern tests (P1-P4 in extreme value test) also pass because the column value is the same for all columns, making the sum invariant under column permutation.

## 4. Root Cause

### Location

`rtl/npu/npu_top.v`, weight staging micro-sequencer in `WGT_STAGE_CAPTURE` (line ~2058) and weight prefetch `WGT_PREF_CAPTURE` (line ~1973).

### Mechanism

The weight staging micro-sequencer unpacks B matrix weights from `wgt_buffer` into `wgt_load_reg` (the PE array weight register). It iterates through "lanes" (weight elements), reading 256-bit beats from the buffer.

**Original code (line 2058):**
```verilog
ws_count = (ws_remain > 32'd32) ? 32'd32 : ws_remain;
```

This caps the per-beat capture at 32 bytes, assuming all 32 bytes in a beat correspond to 32 consecutive weight lanes. This assumption is only valid when n_tile ≥ 32 (at least 32 PE columns active, so 32 consecutive bytes in the same B row).

**For n_tile = 1 (second N-tile when N=65):**

B matrix layout in wgt_buffer: B[k][n] at byte offset `k × 65 + n`.

For the second N-tile (n_base=64), weight staging needs B[0..63][64]:
- Lane 0: B[0][64] at byte offset 0×65+64 = 64 (beat 2)
- Lane 1: B[1][64] at byte offset 1×65+64 = 129 (beat 4)
- ...

Each lane's byte is in a DIFFERENT beat (since N=65 > 32). But the original code captures 32 bytes from beat 2, interpreting bytes 64-95 as lanes 0-31:
- Byte 64 = B[0][64] → lane 0: CORRECT
- Byte 65 = B[0][65] = B[1][0] → interpreted as lane 1: WRONG
- Byte 66 = B[1][1] → interpreted as lane 2: WRONG
- ... (all subsequent bytes are wrong)

### Why n_tile ≥ 32 works

For n_tile ≥ 32, lanes 0..31 all have the same B row (row 0) with consecutive out values (0..31). Their byte offsets are consecutive (0..31), all within the same 32-byte beat. The per-beat capture of 32 bytes is correct.

## 5. Fix

### Modified file

`rtl/npu/npu_top.v` — 2 sites (WGT_STAGE_CAPTURE at line ~2058, WGT_PREF_CAPTURE at line ~1973)

### Code change

```verilog
// ADDED: compute lanes remaining in current B-matrix row
ws_lanes_in_beat = (wgt_stage_n_tile == 16'd0) ? 32'd32 :
    {16'd0, wgt_stage_n_tile} - (wgt_stage_lane_idx % {16'd0, wgt_stage_n_tile});

// EXISTING limits
ws_count = (ws_remain > 32'd32) ? 32'd32 : ws_remain;
if (ws_beatsz < ws_count) ws_count = ws_beatsz;

// ADDED: new limit — don't cross B-matrix row boundaries within a beat
if (ws_lanes_in_beat < ws_count) ws_count = ws_lanes_in_beat;
```

### Effect

| n_tile | ws_lanes_in_beat | ws_count (before) | ws_count (after) |
|--------|------------------|-------------------|-------------------|
| 64 | 64 | 32 | 32 (unchanged) |
| 33 | 33 | 32 | 32 (unchanged) |
| 1 | 1 | 32 | **1** (fixed) |

For n_tile=1: captures 1 byte per beat × 64 beats = correct loading of all 64 K-weights.

## 6. Why Fix Doesn't Break Other Paths

| Concern | Answer |
|---------|--------|
| N≤64 (single tile) | n_tile=N≤64, unchanged behavior (ws_lanes_in_beat ≥ 32 for most cases, min with existing 32 cap) |
| all-1 data | Works both before and after; fix doesn't change data, only which bytes are read |
| K>64 (K-chunk) | Per-chunk staging is independent; fix applies identically to each chunk |
| FC streaming | Same code path (matrix_streaming_en=1); fix is correct for all n_tile values |
| FC+ReLU | GST post-op path unaffected; weight staging identical |
| INT8 packing | conv_cfg[6] only affects GST output, not weight staging |
| Legacy FC/Conv | matrix_streaming_en=0 → different code path entirely |
| dma_axi_writer | Not modified |
| write_beat_fifo | Not modified |
| mac_pe | Not modified |

## 7. Regression Results (Post-Fix)

| Test | Status | UVM_ERROR | Notes |
|------|--------|-----------|-------|
| `npu_int8_extreme_value_stress_test` | **192/192 PASS** | 0 | Was 168/192 (24 failures pre-fix) |
| `npu_gemm_kchunk_stress_test` | 36/36 PASS | 0 | Unchanged |
| `npu_matrixop_partial_beat_stress_test` | 60/60 PASS | 0 | Unchanged |
| `npu_back_to_back_task_stress_test` | 16/16 PASS | 0 | Unchanged |
| `npu_gemm_ntile_nonuniform_diag_test` | **6/6 PASS** | 0 | New test |
| `npu_task_gemm_func_test` | PASS | 0 | Unchanged |
| `npu_task_gemm_row_streaming_test` | PASS | 0 | Unchanged |
| `npu_fc_streaming_smoke_test` | PASS | 0 | Unchanged |
| `npu_fc_streaming_relu_test` | PASS | 0 | Unchanged |
| `npu_fc_streaming_robustness_test` | PASS | 0 | Unchanged |
| `npu_fc_streaming_fallback_test` | FAIL | 1 | **Pre-existing** (unchanged from U5-a) |
| `npu_fc_smoke_test` | PASS | 0 | Unchanged |
| `npu_conv_smoke_test` | PASS | 0 | Unchanged |

**UVM_FATAL = 0** across all tests.  
**No new regressions introduced.**

## 8. Files Modified

| File | Change | Lines |
|------|--------|-------|
| `rtl/npu/npu_top.v` | +10 lines (2 sites × ~5 lines each) | +14 total |
| `verif/uvm_top/tests/npu_gemm_ntile_nonuniform_diag_test.sv` | New diagnostic test | 350 lines |
| `verif/uvm_top/pkg/soc_top_uvm_pkg.sv` | Added test include | +3 lines |

## 9. Commit

```
226e546 fix: correct GEMM N-tiling weight staging lane-per-beat limit
```

## 10. Conclusion

Bug B1 is **resolved**. The root cause was a lane-per-beat assumption in the weight staging micro-sequencer that broke for narrow N-tiles (n_tile < 32). The fix is minimal (14 lines), validated by comprehensive regression, and does not modify any architecture boundary, DMA writer, FIFO, or MAC PE.

**U5-b exit criteria met:**
- ✅ Bug B1 reproduced and root cause identified
- ✅ Minimal RTL fix applied
- ✅ All stress tests PASS (including 192/192 extreme value)
- ✅ Core regression PASS (no new regressions)
- ✅ No architecture boundary changes
