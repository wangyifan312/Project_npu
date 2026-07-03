# NPU Phase U5: Final Baseline Freeze Summary

**Date:** 2026-07-02  
**Branch:** `feature/npu-system-baseline-stabilization`  
**Tag:** `npu-matrixop-final-baseline-u5`

---

## 1. Final Baseline Scope

### MatrixOp Fast Path (Frozen)

| Component | Status | Verification |
|-----------|--------|-------------|
| GEMM streaming | ✅ | K>64 stress 36/36, partial-beat 60/60, extreme value 192/192 |
| pure FC streaming | ✅ | Smoke, robustness, back-to-back all PASS |
| FC+ReLU-only streaming | ✅ | ReLU test PASS, zero overhead confirmed |
| result_tile_bank | ✅ | K-chunk accumulation, double-buffer verified |
| GST INT32 output | ✅ | Partial-beat: all row_stride/byte_count correct |
| GST ReLU | ✅ | FC streaming ReLU test PASS |
| GST INT8 packing infrastructure | ✅ | Test hook (conv_cfg[6]) verified |
| K>64 accumulation | ✅ | K=65,127,128,129,192,255 all PASS |
| N-tiling (including N>64 non-uniform) | ✅ | Bug B1 fixed, 192/192 extreme value PASS |
| partial-beat / row_stride / byte_count | ✅ | INT32 N=1-65, INT8 N=1-65, all correct |
| back-to-back task transitions | ✅ | 8 streaming transitions, zero overhead |

### Legacy Fallback Path (Retained)

- FC + bias/requant
- FC + bias + ReLU + requant
- Conv
- Add / Pool / GAP
- standalone requant
- VecReLU / auxiliary path
- acc_buffer path

### No-Go / Not Pursued

- FC bias/requant GST migration
- bias_tile_bank
- full GST post-op
- FC legacy deletion
- acc_buffer removal
- descriptor queue
- multiple outstanding STORE
- 512-bit AXI
- general Conv MatrixOp
- MatrixOp CSR expansion

---

## 2. U5 Phase Summary

### U5-a: Baseline Stress Tests and Performance

**New tests:**
- `npu_gemm_kchunk_stress_test` — K>64 accumulation (36 cases)
- `npu_matrixop_partial_beat_stress_test` — INT32/INT8 partial beat (60 cases)
- `npu_int8_extreme_value_stress_test` — signed INT8 extremes (192 cases)
- `npu_back_to_back_task_stress_test` — back-to-back transitions (16 tasks)
- `npu_matrixop_pipeline_checker` — documented assertion plan (10 categories)

**Results:** 256/280 sub-cases PASS, 24 FAIL due to Bug B1.

### U5-b: Bug B1 Root Cause and Fix

**Bug B1:** GEMM with N>64 + non-uniform weight data produces incorrect results.

**Root cause:** Weight staging micro-sequencer (`WGT_STAGE_CAPTURE` in `npu_top.v`) captured up to 32 bytes per beat regardless of `n_tile`. For n_tile=1 (second N-tile when N=65), consecutive bytes within a beat span multiple B-matrix rows (65 bytes/row), so only the first byte is valid.

**Fix:** Limit per-beat lane capture to `n_tile - (lane_idx % n_tile)` — the number of lanes remaining within the current B-matrix row. 2 sites in `npu_top.v`, +14 lines total.

**Results:** Extreme value stress 192/192 PASS (was 168/192). All other tests unchanged.

### U5-c: Final Regression and Performance Re-measure

**Final regression:** 12/13 PASS, 1 pre-existing legacy fallback failure.

**Performance:**
- N≤64, n_tile≥32: **zero performance change**
- N=65, n_tile=1: expected +366 cycles/K-chunk (correctness trade-off)
- ReLU: zero overhead confirmed
- Back-to-back: zero overhead confirmed

---

## 3. Bug B1 — Closed

| Field | Detail |
|-------|--------|
| **ID** | U5-B1-GEMM-NTILE-NONUNIFORM |
| **Discovered** | Phase U5-a, Task C (extreme value stress) |
| **Root cause** | Weight staging per-beat lane count not limited to n_tile |
| **Fixed in** | Phase U5-b, commit `226e546` |
| **Files modified** | `rtl/npu/npu_top.v` (+14 lines, 2 sites) |
| **Verification** | 192/192 extreme value PASS, diag test 6/6 PASS |
| **Status** | **CLOSED** |

---

## 4. Final Regression Summary

| # | Test | Status |
|---|------|--------|
| 1 | `npu_gemm_ntile_nonuniform_diag_test` | **PASS** (6/6) |
| 2 | `npu_int8_extreme_value_stress_test` | **PASS** (192/192) |
| 3 | `npu_gemm_kchunk_stress_test` | **PASS** (36/36) |
| 4 | `npu_matrixop_partial_beat_stress_test` | **PASS** (60/60) |
| 5 | `npu_back_to_back_task_stress_test` | **PASS** (16/16) |
| 6 | `npu_task_gemm_func_test` | **PASS** |
| 7 | `npu_task_gemm_row_streaming_test` | **PASS** |
| 8 | `npu_fc_streaming_smoke_test` | **PASS** |
| 9 | `npu_fc_streaming_relu_test` | **PASS** |
| 10 | `npu_fc_streaming_robustness_test` | **PASS** |
| 11 | `npu_fc_streaming_fallback_test` | **Pre-existing FAIL** (known issue K1) |
| 12 | `npu_fc_smoke_test` | **PASS** |
| 13 | `npu_conv_smoke_test` | **PASS** |

**UVM_FATAL = 0**  
**UVM_ERROR = 1** (only pre-existing K1)

---

## 5. Performance Summary

| Workload | M | K | N | Cycles | bus_ratio | Status |
|----------|---|---|---|--------|-----------|--------|
| GEMM large | 8 | 255 | 64 | 3,544 | 22.6% | PASS |
| GEMM medium | 8 | 128 | 64 | 2,149 | 23.2% | PASS |
| GEMM K-chunk | 4 | 129 | 32 | 1,122 | 15.5% | PASS |
| FC streaming | 4 | 64 | 16 | 464 | 11.1% | PASS |
| FC+ReLU | 4 | 64 | 16 | 464 | 11.1% | PASS |
| GEMM B2B | 4 | 64→129 | 16 | 464→918 | — | PASS |

---

## 6. Known Issues

### K1: Legacy FC+Bias Fallback Test Failure

| Field | Detail |
|-------|--------|
| **Test** | `npu_fc_streaming_fallback_test` |
| **Symptom** | `FALLBACK ERROR code=0x00` |
| **Introduced by U5?** | **No** — pre-existing before U5 |
| **Affects MatrixOp fast path?** | **No** — only legacy FC+bias path |
| **Affects GEMM?** | **No** |
| **Affects FC streaming?** | **No** |
| **Affects FC+ReLU streaming?** | **No** |
| **Blocker for final freeze?** | **No** — not in frozen scope |
| **Recommendation** | Fix in optional U5-d (test config: add requant mult=1/shift=0) |

### K2: Enhanced Perf Counters Return 0

`array_active`, `compute_cycles`, `store_cycles`, `collect_cycles` at registers 0xE8-0xFC report 0. Counter wiring verification needed. Not a functional issue.

### K3: INT8 Packing Back-to-Back Instability

`conv_cfg[6]=1` test hook shows instability in back-to-back transitions. This is a test hook only, not a production feature.

### Pre-existing (from CLAUDE.md §9)

| Issue | Impact | Status |
|-------|--------|--------|
| Conv multi-channel weight preload bug | Legacy Conv path only | Pre-existing |
| Multi-chunk FC shadow register bug | input_c > 64 only | Pre-existing |

---

## 7. Architecture Boundaries Preserved

| Constraint | Verified |
|------------|----------|
| No dma_axi_writer modification | ✅ |
| No write_beat_fifo modification | ✅ |
| No mac_pe modification | ✅ |
| No bias/requant migration | ✅ |
| No bias_tile_bank | ✅ |
| No full GST post-op | ✅ |
| No FC legacy deletion | ✅ |
| No acc_buffer removal | ✅ |
| No descriptor queue | ✅ |
| No multiple outstanding STORE | ✅ |
| No 512-bit AXI | ✅ |
| No general Conv MatrixOp | ✅ |
| No MatrixOp CSR expansion | ✅ |
| No conv_cfg[6] production expansion | ✅ |

---

## 8. U5-a/b/c Commit Chain

```
f584e25 — docs: U5-c final regression and performance re-measure
0ba521c — docs: Bug B1 root cause analysis and fix
226e546 — fix: correct GEMM N-tiling weight staging lane-per-beat limit
6b2d30e — docs: U5-a stabilization test report and performance characterization
6e36013 — test: U5-a baseline stress tests and MatrixOp pipeline checker
```

Base: `ef03802` — Merge Phase U4-e

---

## 9. Files Changed in U5

### RTL (1 file)
```
rtl/npu/npu_top.v  (+14 lines, weight staging lane-per-beat limit)
```

### Verification (7 files — 6 new + 3 modified)
```
verif/uvm_top/tests/npu_gemm_kchunk_stress_test.sv            [NEW]
verif/uvm_top/tests/npu_matrixop_partial_beat_stress_test.sv   [NEW]
verif/uvm_top/tests/npu_int8_extreme_value_stress_test.sv      [NEW]
verif/uvm_top/tests/npu_back_to_back_task_stress_test.sv       [NEW]
verif/uvm_top/tests/npu_gemm_ntile_nonuniform_diag_test.sv     [NEW]
verif/uvm_top/checkers/npu_matrixop_pipeline_checker.sv        [NEW]
verif/uvm_top/pkg/soc_top_uvm_pkg.sv                           [MODIFIED]
verif/uvm_top/filelist.f                                        [MODIFIED]
verif/uvm_top/scripts/run_uvm.sh                                [MODIFIED]
```

### Documentation (5 files)
```
docs/NPU_PHASE_U5_STABILIZATION_TEST_REPORT.md
docs/NPU_PHASE_U5_PERFORMANCE_CHARACTERIZATION.md
docs/NPU_PHASE_U5B_BUG_B1_ROOT_CAUSE_AND_FIX.md
docs/NPU_PHASE_U5C_FINAL_REGRESSION_AND_PERF_REMEASURE.md
docs/NPU_PHASE_U5_FINAL_BASELINE_FREEZE_SUMMARY.md
```

---

## 10. Final Tag

```
npu-matrixop-final-baseline-u5
```

This tag marks the MatrixOp fast path final baseline freeze. All GEMM, FC streaming, and ReLU post-op paths are verified with comprehensive stress testing. One known pre-existing legacy fallback issue (K1) does not affect the frozen scope.

---

## 11. Optional U5-d

If further work is desired before submission:

1. Fix legacy FC+bias fallback test configuration (K1)
2. Verify enhanced perf counter wiring
3. Activate SVA assertions in pipeline checker
4. Add multi-cluster regression pass

**None of these are blocking for final baseline freeze.**
