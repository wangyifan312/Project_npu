# NPU MatrixOp Phase U2 — FC Streaming Robustness Baseline

**Phase**: U2 — FC streaming robustness and performance characterization
**Date**: 2026-07-02
**Base**: `main` `b4d01d0` (Phase U1 merge)
**Branch**: `feature/npu-fc-streaming-robustness`

---

## 1. Phase U2 Goals

Evolve FC streaming path from "functional proof" to "robustness-trusted baseline" by:

1. Expanding FC streaming test coverage with boundary cases
2. Adding legacy FC vs streaming FC matched workload comparison
3. Confirming post-op fallback behavior (covered by Phase U1 test)
4. Characterizing FC streaming cycle counts
5. No architecture changes; no post-op/Conv/c_tile migration

---

## 2. Phase U1 Baseline (Reference)

| Component | Status |
|-----------|--------|
| `fc_streaming_en` gate | `is_fc_mode && conv_cfg[5] && !bias_enabled && !relu_en` |
| `matrix_streaming_en` gate | `gemm_row_streaming_en \|\| fc_streaming_en` |
| FC→MatrixOp mapping | M=`input_h`, K=`input_c`, N=`output_c` |
| Weight layout | K-major B[k][n] |
| Output format | INT32 row-major |
| Legacy FC fallback | Preserved |

---

## 3. New Tests (Phase U2)

### 3.1 `npu_fc_streaming_robustness_test.sv`

**Boundary tests (FCR0-FCR7):**

| Level | M | K | N | Feature | Result | Cycles |
|-------|---|---|---|---------|--------|--------|
| FCR0 | 1 | 1 | 1 | Minimal FC | PASS | 120 |
| FCR1 | 1 | 63 | 64 | K below 64 | PASS | 771 |
| FCR2 | 1 | 64 | 64 | Exact K/N=64 | PASS | 779 |
| FCR3 | 1 | 65 | 64 | K just above 64 | PASS | 936 |
| FCR4 | 1 | 64 | 65 | N just above 64 | PASS | 811 |
| FCR5 | 8 | 64 | 64 | Exact M=8 (tile boundary) | PASS | 1458 |
| FCR6 | 9 | 64 | 64 | M just above 8 | PASS | 1550 |
| FCR7 | 9 | 65 | 65 | Combined M/N/K boundary | PASS | 2560 |

All 8 boundary tests PASS. K-chunk crossing, N-tiling, and M-tiling all work correctly at and near boundaries.

**Legacy vs Streaming matched workload (MATCH0-2):**

| Level | K | N | Legacy cycles | Streaming cycles | Ratio |
|-------|---|---|---------------|------------------|-------|
| MATCH0 | 16 | 16 | 158 | 174 | 0.91x |
| MATCH1 | 64 | 64 | 634 | 779 | 0.81x |
| MATCH2 | 128 | 64 | 1287 | 1448 | 0.89x |

All matched workloads PASS. Legacy FC is slightly faster for single-row (M=1) workloads due to lower overhead (no c_tile management, no GST micro-FSM, simpler state machine).

---

## 4. Regression Results

| Test Category | Result |
|---------------|--------|
| FC Streaming smoke (6 levels) | 6/6 PASS |
| FC Streaming fallback | PASS |
| FC Streaming robustness (8 boundary + 3 matched) | 11/11 PASS |
| Legacy FC smoke | PASS |
| Legacy FC 16×16 | PASS |
| Legacy FC 128×128 | PASS |
| GEMM row-streaming | 37/37 PASS |
| GEMM_FUNC | 6/6 PASS |
| Conv smoke | PASS |
| Requant smoke | PASS |
| Pool smoke | PASS |
| Add smoke | PASS |
| GAP smoke | PASS |

**UVM_ERROR=0, UVM_FATAL=0** across key functional tests.

---

## 5. Performance Summary

| Workload | M | K | N | Streaming Cycles | Notes |
|----------|---|---|---|------------------|-------|
| FCR0 | 1 | 1 | 1 | 120 | Minimal; overhead dominates |
| Smoke FCS0 | 1 | 4 | 4 | 123 | |
| Smoke FCS5 | 1 | 8 | 8 | 131 | Signed INT8 |
| MATCH0 | 1 | 16 | 16 | 174 | Legacy: 158 |
| FCR1 | 1 | 63 | 64 | 771 | K<64, one chunk |
| FCR2 | 1 | 64 | 64 | 779 | Exact K=64 |
| FCR3 | 1 | 65 | 64 | 936 | K>64, two chunks |
| FCR4 | 1 | 64 | 65 | 811 | N>64, two tiles |
| Smoke FCS4 | 4 | 64 | 64 | 1070 | Batch M=4 |
| MATCH1 | 1 | 64 | 64 | 779 | Legacy: 634 |
| MATCH2 | 1 | 128 | 64 | 1448 | K=128, 2 chunks |
| FCR5 | 8 | 64 | 64 | 1458 | M=8 tile boundary |
| FCR6 | 9 | 64 | 64 | 1550 | M-tiling active |
| Smoke FCS3 | 1 | 64 | 128 | 1456 | N=128, 2 tiles |
| FCR7 | 9 | 65 | 65 | 2560 | Combined tiling |

**Key observation**: For single-row (M=1) workloads, legacy FC has a slight cycle advantage due to lower overhead. Streaming FC becomes more competitive with larger M (batch), K (cross-chunk), and N (tiling) — the infrastructure cost amortizes over more compute.

---

## 6. Modifications

### Files Changed

| File | Change |
|------|--------|
| `verif/uvm_top/tests/npu_fc_streaming_robustness_test.sv` | New: 8 boundary + 3 matched workload tests |
| `verif/uvm_top/pkg/soc_top_uvm_pkg.sv` | Register new test |

### No RTL Changes

No changes to `npu_top.v`, `mac_pe.v`, `dma_axi_writer.v`, `write_beat_fifo.v`, or any other RTL file.

---

## 7. Issues Found

None. All boundary tests, matched comparisons, and regression tests pass consistently.

---

## 8. Known Limitations (post-Phase U2)

1. FC streaming supports pure INT8×INT8→INT32 matmul only. No post-op.
2. Post-op FC (bias/ReLU) correctly falls back to legacy path.
3. Single-row (M=1) workloads: legacy FC has cycle advantage.
4. K-major B[k][n] weight layout required for FC streaming; differs from legacy N-major.
5. N-tiling B/weight background prefetch remains deferred (gated `1'b0`).
6. c_tile not yet renamed to result_tile.
7. MatrixOp CSR not introduced.

---

## 9. Recommended Next Phase

```
Phase U3 — result_tile_bank abstraction

Scope:
  - Rename c_tile_bank0/1 → result_tile_bank0/1
  - No acc_buffer removal
  - No post-op migration
  - No Conv migration
  - No RTL behavior change
```

Phase U2 confirmed FC streaming boundary and matched behavior is correct. The path is ready for semantic cleanup (naming) before post-op migration.
