# NPU MatrixOp Phase U1 — FC Streaming Baseline

**Phase**: U1 — FC as MatrixOp through streaming GEMM pipeline
**Date**: 2026-07-02
**Baseline Commit**: last commit on `feature/npu-fc-as-matrixop-streaming`
**Base**: `main` `2f607c0` (Phase U0 audit merged)

---

## 1. What Phase U1 Implements

Phase U1 adds an **optional FC streaming path**. When:

```
is_fc_mode && conv_cfg[5] && no FC post-op
```

FC is routed as MatrixOp through the existing streaming GEMM pipeline.
Legacy FC remains the fallback path for all other configurations.

---

## 2. FC Streaming Trigger (RTL Gate)

```verilog
// rtl/npu/npu_top.v
wire fc_streaming_en    = is_fc_mode && conv_cfg[5] && !bias_enabled && !relu_en;
wire matrix_streaming_en = gemm_row_streaming_en || fc_streaming_en;
```

| Condition | Path |
|-----------|------|
| `conv_cfg[5]=1`, no post-op | Streaming MatrixOp path |
| `conv_cfg[5]=0` | Legacy FC path |
| `bias_enabled=1` | Legacy FC path (post-op) |
| `relu_en=1` | Legacy FC path (post-op) |
| `requant` enabled via bias | Legacy FC path |

### Post-op Gate Rationale

- **bias_enabled**: `conv_cfg[4] && (task_type==Conv || task_type==FC)`. FC bias+requant path enters `FSM_REQUANT_COMPUTE` → uses `acc_buffer` → legacy STORE.
- **relu_en**: `NPU_REG_POSTPROC[0]`. Can be set independently of `bias_enabled`. In legacy path, `array_relu_final` applies ReLU at the acc_buffer write stage. Streaming path (c_tile → GST) has no ReLU — thus `!relu_en` is required in the gate.
- **Requant without bias**: NOT independently possible for FC. FC requant requires `bias_enabled && rq_mode_internal`.

---

## 3. FC → MatrixOp Mapping

```
M = input_h                     (1 for single FC, >1 for batch)
K = input_c                     (input feature dimension)
N = output_c                    (output feature dimension)

A layout: K-contiguous input activation  — A[m][k] at byte (m*K + k)
B layout: K-major B[k][n]                — B[k][n] at byte (k*N + n)
C layout: row-major INT32 output         — 32B-aligned row stride
```

---

## 4. Reused Hardware

FC streaming reuses existing streaming GEMM infrastructure:

| Component | Reused? | Notes |
|-----------|---------|-------|
| `input_tile_bank0/1` | ✅ | Double-buffered input activation tiles |
| `wgt_load_reg` / `WGT_LD` | ✅ | Weight loading into PE array |
| PE array (`compute_core`/`pe_cluster`/`mac_pe`) | ✅ | Weight-stationary systolic array |
| `c_tile_bank0/1` | ✅ | Double-buffered output accumulation (INT32) |
| `store_desc_*` | ✅ | Tile descriptor locked at STORE start |
| GST per-beat STORE micro-FSM | ✅ | Row-by-row, beat-by-beat DMA launch |
| `write_beat_fifo` | ✅ | 256-bit FIFO (depth 64) |
| `dma_axi_writer` | ✅ | AXI4 write master (Phase B2 skid buffer) |

---

## 5. Explicitly Unchanged Hardware

| Component | Status |
|-----------|--------|
| `mac_pe.v` | Unchanged |
| `dma_axi_writer.v` | Unchanged |
| `write_beat_fifo.v` | Unchanged |
| `acc_buffer` | Preserved (legacy consumers) |
| Legacy FC FSM (`FSM_FC_TILE_PREP` → `FSM_STORE`) | Preserved |
| Legacy FC STORE (`store_pack` state machine) | Preserved |
| Conv path | Unchanged |
| Requant path | Unchanged |
| Add/GAP/Pool paths | Unchanged |
| Postproc path | Unchanged |

---

## 6. Modifications Summary

**File: `rtl/npu/npu_top.v`** (+30/-24 lines)

1. New gates: `fc_streaming_en`, `matrix_streaming_en`
2. `gemm_row_streaming_en` → `matrix_streaming_en` at 10 gate points:
   - Output routing (`cluster_routed_sum_out_all_flat`)
   - `compute_core` `.continuous_mode()` / `.stream_active()`
   - `stream_drive` (activation feeder)
   - Weight staging `out_idx` / `row_idx` / `buf_byte_idx` (3 sites)
   - `wgt_rd_addr` mux (2 sites)
   - Weight staging unpack (2 sites)
   - `FSM_FC_TILE_PREP` tile init
   - `FSM_LOAD_ARRAY` weight staging entry
   - `FSM_FC_LOAD_WGT` DMA size
   - `FSM_WGT_LD` routing + fallback guard
3. `fc_tile_outputs`: uses `min(N, PE_COLS)` for `is_gemm_mode || matrix_streaming_en`

**New files:**
- `verif/uvm_top/tests/npu_fc_streaming_smoke_test.sv` — 6-level FC streaming functional test
- `verif/uvm_top/tests/npu_fc_streaming_fallback_test.sv` — post-op FC fallback verification

**Modified files:**
- `verif/uvm_top/pkg/soc_top_uvm_pkg.sv` — import new test files

---

## 7. Test Coverage

### FC Streaming Smoke (6 levels)

| Level | M | K | N | Feature | Result | Cycles |
|-------|---|---|---|---------|--------|--------|
| FCS0 | 1 | 4 | 4 | Smoke (all-1) | PASS | 123 |
| FCS1 | 1 | 16 | 16 | Non-uniform | PASS | 174 |
| FCS2 | 1 | 128 | 16 | K>64 cross-chunk | PASS | 506 |
| FCS3 | 1 | 64 | 128 | N-tiling (2 tiles) | PASS | 1456 |
| FCS4 | 4 | 64 | 64 | Batch M=4 | PASS | 1070 |
| FCS5 | 1 | 8 | 8 | Signed INT8 | PASS | 131 |

### FC Streaming Fallback

| Test | Condition | Result |
|------|-----------|--------|
| Fallback | FC + bias + `conv_cfg[5]=1` | PASS — legacy path used |

### Legacy FC

| Test | Result |
|------|--------|
| `npu_fc_smoke_test` | PASS |
| `npu_fc_16x16_full_array_test` | PASS |
| `npu_fc_128x128_peak_test` | PASS |

### GEMM

| Test | Result |
|------|--------|
| `npu_task_gemm_func_test` | 6/6 PASS |
| `npu_task_gemm_row_streaming_test` | 37/37 PASS |

### 7-Key Regression

| Test | Result |
|------|--------|
| `npu_conv_smoke_test` | PASS |
| `npu_requant_smoke_test` | PASS |
| `npu_pool_smoke_test` | PASS |
| `npu_add_smoke_test` | PASS |
| `npu_gap_smoke_test` | PASS |
| `npu_conv_1x1_smoke_test` | PASS |
| `npu_fc_smoke_test` | PASS |

**UVM_ERROR=0, UVM_FATAL=0** across all tests.

---

## 8. Performance Observation

| Workload | Cycles |
|----------|--------|
| Legacy FC (4→1, via `npu_fc_task_seq`) | 868 |
| FCS0 (1×4×4 streaming) | 123 |
| FCS4 (4×64×64 streaming) | 1070 |

*Note: Legacy FC and FCS0 may not be identical workloads due to layout differences. Functional correctness is confirmed; detailed performance characterization is Phase U2 scope.*

---

## 9. Known Limitations

1. **Pure matmul only** — FC streaming supports INT8×INT8→INT32 matmul. No post-op.
2. **Bias/ReLU/requant FC** remains on legacy path (fallback).
3. **Conv** is not migrated. Conv remains on its own legacy path.
4. **acc_buffer** is not removed. Legacy post-op and non-GEMM/FC operations still use it.
5. **c_tile** is not renamed to `result_tile`. Deferred to Phase U3.
6. **MatrixOp CSR (control/status register)** is not introduced. FC uses existing `task_type=1` + `conv_cfg[5]`.
7. **FC streaming expects K-major B[k][n] weight layout** — different from legacy FC N-major W[n][k] layout.
8. **N-tiling B/weight background prefetch** (`1'b0` gated) remains deferred.
9. **Descriptor queue** / multiple outstanding STOREs not implemented.

---

## 10. Recommended Next Step

```
Phase U2 — FC streaming robustness and performance characterization

Scope:
  - Expand FC streaming coverage (boundary tests, corner cases)
  - Compare legacy FC vs streaming FC on matched workloads
  - Characterize performance (TOPS, bus utilization)
  - Confirm post-op fallback behavior end-to-end
  - Do not migrate post-op yet
  - Do not rename c_tile yet
  - Do not migrate Conv yet
```
