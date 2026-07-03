# NPU Tile Pipeline — Phase 6-0 Full Pipeline Audit

## Metadata

- **Date**: 2026-07-02
- **Main HEAD**: `e0909f7` (Merge Phase 4c-3: STORE/RUN overlap)
- **Branch**: `feature/npu-tile-pipeline-audit`
- **Status**: **AUDIT COMPLETE — DOCUMENT ONLY, NO RTL CHANGES**

## 1. Baseline

| Item | Value |
|------|-------|
| Main HEAD | `e0909f7` |
| Regression baseline | 37/37 streaming + 6/6 GEMM_FUNC + 7/7 key |
| UVM_ERROR | 0 |
| UVM_FATAL | 0 |
| RTL modified in this phase | None |

## 2. Phase Tags Inventory

| Tag | Phase | Content |
|-----|-------|---------|
| `npu-tile-pipeline-phase4a-input-overlap` | 4a-3 | LOAD_A(next) \|\| RUN(current) |
| `npu-tile-pipeline-phase4a1-beat-loader` | 4a-1 | Beat-level bulk A loader |
| `npu-tile-pipeline-phase4a2-input-banks` | 4a-2 | Double-buffered input banks |
| `npu-tile-pipeline-phase4b-weight-overlap` | 4b-2 | Basic weight prefetch (N≤64) |
| `npu-tile-pipeline-phase4b1-kmajor-weight` | 4b-1 | K-major weight staging |
| `npu-tile-pipeline-phase4c1-c-tile-double-buffer` | 4c-1 | c_tile double buffer |
| `npu-tile-pipeline-phase4c2-store-micro-fsm` | 4c-2 | Per-beat GEMM STORE micro-FSM |
| `npu-tile-pipeline-phase4c3-store-run-overlap` | 4c-3 | STORE(prev) \|\| RUN(curr) |
| `npu-tile-pipeline-phase5a-m-tiling` | 5-1 | M-tiling |
| `npu-tile-pipeline-phase5b-n-tiling` | 5-2 | N-tiling |
| `npu-tile-pipeline-phase5b-weight-prefetch-deferred` | 5-2b | B/weight prefetch deferred |
| `npu-tile-pipeline-phase5c-output-descriptor` | 5-3 | Output tile descriptor |

## 3. Current Tile Pipeline Overview

### Conceptual Model

```
                    Tile i-1          Tile i            Tile i+1
                 ┌───────────┐    ┌───────────┐    ┌───────────┐
    LOAD_A       │           │    │ LOAD_A[i] │    │ LOAD_A[i+1]│  ◄── overlap with RUN
                 │           │    │   (overlap)│    │   (overlap)│
    RUN          │           │    │  RUN[i]   │    │            │
                 │           │    │           │    │            │
    STORE        │STORE[i-1] │    │ STORE[i]  │    │            │  ◄── overlap with RUN
                 │ (overlap) │    │ (overlap) │    │            │
                 └───────────┘    └───────────┘    └───────────┘
```

### Implemented Overlaps

| Overlap | Phase | Status |
|---------|-------|:------:|
| LOAD_A(next) \|\| RUN(current) | Phase 4a-3 | ✅ Complete |
| STORE(previous) \|\| RUN(current) | Phase 4c-3 | ✅ Complete |
| LOAD_B(next K/N tile) \|\| RUN(current) | Phase 5-2b | ❌ Deferred |

### Effective Pipeline

The current pipeline achieves **2-sided overlap around RUN**:
- **Input side**: A/input ping-pong (Phase 4a)
- **Output side**: STORE background engine (Phase 4c)

The **weight side** (B/weight prefetch under full N-tiling) is the
remaining deferred optimization.

## 4. LOAD_A Pipeline Status

### Implementation (Phase 4a)

```
Implemented:
    input_tile_bank0 / input_tile_bank1          (double buffer)
    input_load_bank / input_compute_bank          (ownership)
    input_bank0_valid / input_bank1_valid         (valid bits)
    input_bank0_k_base / input_bank1_k_base       (k-chunk tags)
    Beat-level bulk loader from act_buffer        (32 bytes/cycle)
    Background prefetch micro-sequencer           (PREF_IDLE/REQ/WAIT/CAPTURE)

Status:
    ✅ Complete and stable.

Safety:
    A/input is streaming activation — not stationary.
    A does not live inside PE.weight_reg — loaded via act_buffer.
    A address depends on M-tile and K-chunk only, not N-tile.
    Bank ownership is straightforward: load_bank ≠ compute_bank.
    Bank valid bits prevent stale data reuse.
    k_base tags ensure correct K-chunk matching.

Conclusion:
    A/input read pipeline is not a current bottleneck.
    No further A-side overlap work is needed at this stage.
```

## 5. RUN Pipeline Status

### Compute Capability (Phase 5)

```
Implemented:
    Row-streaming GEMM compute                (a_tile skewed feed → wavefront)
    K>64 chunk accumulation                   (ACCUM → LOAD_A → LOAD_ARRAY loop)
    M-tiling                                  (M > 8: gemm_tile_m_base advance)
    N-tiling                                  (N > 64: gemm_tile_n_base advance)
    c_tile accumulation                       (c_tile_bank[0:1][0:7][0:63])
    Output tile descriptors                   (store_desc_* locked at DONE)
    DUAL_HIT path                             (input + weight both prefetched)

Supported test patterns:
    ✅ M > 8, N > 64, K > 64
    ✅ M/N/K combined tiling
    ✅ Last M-tile, last N-tile
    ✅ Signed B (INT8)
    ✅ Non-uniform A (per-K-chunk)
    ✅ Non-uniform B (K-major layout)

Limitations:
    Single c_tile bank for compute (compute_c_bank).
    No double-buffered weight register for K-chunk streaming.
    Foreground LOAD_ARRAY for B under N-tiling (correct but slower).
```

## 6. STORE Pipeline Status

### Implementation (Phase 4c)

```
Phase 4c-1 — c_tile double buffer:
    c_tile_bank0 / c_tile_bank1
    compute_c_bank / store_c_bank

Phase 4c-2 — Per-beat GEMM STORE micro-FSM:
    GST_PUSH_BEAT → GST_START → GST_START_CLR → GST_WAIT_DONE → GST_ADVANCE
    Integrated into main FSM always block (zero multi-driver)
    256-bit per-beat DMA transaction (Scheme B)
    dma_wr_start 1→0 pulse (default assignment)
    producer_done aligned with GST_START
    store_desc_* used for STORE pack

Phase 4c-3 — STORE(previous) || RUN(current):
    GST moved to after-case background tick
    producer_done fsm_state guard removed
    gemm_store_pending backpressure
    store_desc_* only locked when GST idle
    Launch STORE → advance to next tile → overlap
    Final tile: wait for STORE completion before task_done
```

### Current Limitations

| Limitation | Impact |
|------------|--------|
| Single outstanding STORE | Pipeline stalls if STORE > compute |
| No store descriptor queue | Cannot enqueue multiple tiles for STORE |
| Only two c_tile banks | Third tile must wait for bank0 to free |
| dma_axi_writer shared | STORE competes with legacy paths (mutually exclusive in practice) |

### Performance Evidence

| Metric | Phase 4c-2 | Phase 4c-3 | Delta |
|--------|:--:|:--:|:--:|
| Overall (37 tests) | 296,314 | 289,424 | **-2.3%** |
| NT0 (N=128) | 2,887 | 2,299 | **-20.4%** |
| NT4 (M+N tiling) | 5,492 | 3,726 | **-32.2%** |
| NT5 (M+N+K tiling) | 7,950 | 5,839 | **-26.6%** |

N-tiling cases benefit substantially because previous-tile STORE latency
is hidden under next-tile compute. The overall 2.3% reduction is driven
by the 7 N-tiling tests within the 37-test suite.

## 7. B/Weight Prefetch Status

### Architecture

```
B matrix (weight) path:
    shared_ram → wgt_buffer → wgt_load_reg/staging → WGT_LD → PE.weight_reg

B layout:
    K-major: B[k][n] at byte k * N + n
    N-major iteration for staging: row = idx / n_tile, out = idx % n_tile

Weight staging:
    wgt_stage micro-sequencer (WGT_STAGE_IDLE/REQ/WAIT/CAPTURE)
    Reads from wgt_buffer raw bytes
    256-bit beat-level bulk load
```

### Current State

| Aspect | Status | Notes |
|--------|:------:|-------|
| Basic weight prefetch (N ≤ 64) | ✅ Complete | Phase 4b-2, DUAL_HIT path |
| DUAL_HIT skip | ✅ Complete | Skips LOAD_A + LOAD_ARRAY when both prefetched |
| N-tiling background B prefetch | ❌ Deferred | Phase 5-2b tag |
| Foreground LOAD_ARRAY fallback | ✅ Active | Correctness path for N > 64 |

### Why B/Weight Prefetch Is Harder Than A/Input Prefetch

```
A/input prefetch:
    A is streaming — each K-chunk has a fresh A tile.
    A goes into act_buffer, not PE registers.
    A address: M-tile + K-chunk only (no N-tile dependency).

B/weight prefetch:
    B is stationary — must be committed into PE.weight_reg by WGT_LD.
    WGT_LD must NOT occur during current RUN (would corrupt weights mid-compute).
    B address depends on K-chunk AND N-tile.
    Under N-tiling:
        B base address shifts by n_base for each N-tile.
        Prefetch descriptor must match: k_base, n_base, tile_N.
        Previous attempt (Phase 5-2b) failed NT5/NT6.
        Root cause: bg weight prefetch timing issue — not isolated.
```

### Deferred Rationale (Phase 5-2b)

```
Decision: deferred via 1'b0 guard on wgt_pref trigger under N-tiling.

Reason:
    Foreground LOAD_ARRAY provides correct weight loading for all N>64 cases.
    The N-tiling B prefetch timing issue requires waveform-level debugging.
    STORE/RUN overlap was prioritized as higher-impact.
    B prefetch is a performance optimization, not a correctness requirement.

Status:
    Correctness: ✅ (foreground fallback)
    Performance: ⚠️  (B DMA cycles visible in K-chunk transitions)
    Priority:   Later (below STORE/RUN overlap and pipeline freeze)
```

## 8. Current Effective Pipeline

### What Is Working

```
                   ┌─────────────────────────────────────────┐
                   │         STREAMING GEMM PIPELINE         │
                   │                                         │
    LOAD_A(next) ──┤  input_tile_bank[2]  ping-pong          │
                   │  background prefetch during RUN          │
                   │  ✅ Phase 4a-3                           │
                   │                                         │
    RUN(current) ──┤  row-streaming GEMM compute             │
                   │  K-chunk accumulation                    │
                   │  M/N tiling                              │
                   │  c_tile accumulation                     │
                   │  ✅ Phase 5-1, 5-2                       │
                   │                                         │
    STORE(prev) ───┤  c_tile_bank[2]  double buffer          │
                   │  per-beat DMA micro-FSM                  │
                   │  background GST tick during RUN          │
                   │  ✅ Phase 4c-1, 4c-2, 4c-3               │
                   │                                         │
    LOAD_B(next) ──┤  foreground LOAD_ARRAY (N>64)           │
                   │  basic wgt prefetch (N≤64, DUAL_HIT)     │
                   │  ⚠️  bg prefetch deferred (Phase 5-2b)   │
                   └─────────────────────────────────────────┘
```

### Overlap Coverage Matrix

| | LOAD_A | RUN | STORE | LOAD_B |
|---|---|---|---|---|
| **LOAD_A** | — | ✅ overlap | N/A | N/A |
| **RUN** | ✅ overlap | — (serial) | ✅ overlap | ✅ (N≤64) / ❌ (N>64) |
| **STORE** | N/A | ✅ overlap | — | N/A |

### Single-Tile vs Multi-Tile Behavior

```
Single-tile task (M ≤ 8, N ≤ 64, K ≤ 64):
    All phases sequential.
    No overlap possible (no next tile to overlap with).

Multi-tile task (M > 8 or N > 64):
    LOAD_A(next) || RUN(current): active from tile 2 onward.
    STORE(previous) || RUN(current): active from tile 2 onward.
    DUAL_HIT: SKIP when both input and weight prefetched.

K > 64 (multi-chunk):
    ACCUM → LOAD_A → LOAD_ARRAY → WGT_LD → PREP → RUN loop.
    Input prefetch within K-chunk loop (bank ping-pong).
    B/wgt foreground LOAD_ARRAY per chunk.
```

## 9. Bottleneck Analysis

### By Workload Type

| Workload | Dominant Phase | Bottleneck | Mitigation |
|----------|:---:|------|------|
| M/N-heavy (many tiles) | RUN + STORE | STORE time hidden by Phase 4c-3 ✅ | Already improved ~20-32% |
| K-heavy (deep K) | LOAD_B + WGT_LD | Foreground B DMA per K-chunk ⚠️ | Deferred B prefetch |
| Single-tile | RUN (compute-bound) | PE array utilization (~48% P3) ⚠️ | acc_buffer widening, 512-bit AXI |
| Small compute | DMA overhead | Fixed DMA latency per tile ⚠️ | Descriptor queue, pipelining |

### By Phase

| Phase | Bottleneck | Severity | Resolution Status |
|-------|-----------|:--------:|-------------------|
| LOAD_A | act_buffer bandwidth (256-bit) | Low | Adequate for current workload |
| LOAD_B | Foreground DMA per K-chunk under N>64 | Medium | Deferred (Phase 5-2b) |
| RUN | PE array utilization (48% multi-block, 19.5% single) | Medium | Requires hardware widening |
| STORE | 256-bit DMA + 32-bit acc_buffer path | Medium-High | Partially addressed by overlap; hardware widening needed |
| Tile transition | Fixed DMA overhead per tile | Low-Medium | Reduced by overlap |
| c_tile bank | 2-bank limit for 3-tile pipeline | Low | Sufficient for 2-level overlap |

### Priority Assessment

```
High-impact, completed:
    ✅ STORE/RUN overlap (Phase 4c-3): 20-32% in N-tiling tests

Medium-impact, deferred:
    ⚠️  B/weight N-tiling prefetch (Phase 5-2b): reduces K-chunk transition stalls

Low-impact, hardware-dependent:
    ⚠️  acc_buffer 128-bit widening: requires hardware change
    ⚠️  512-bit AXI: requires bus fabric change
    ⚠️  Descriptor queue: adds complexity for marginal gain
```

## 10. Recommended Next Steps

### Option A: Freeze Current Streaming GEMM Pipeline Baseline (Recommended)

```
Action:
    Generate final architecture summary document.
    Collect all performance numbers.
    Tag as streaming GEMM frozen baseline.

Pros:
    ✅ Correctness strong: 37/37 + 6/6 + 7/7, UVM_ERROR=0
    ✅ LOAD_A/RUN/STORE pipeline already meaningful
    ✅ N-tiling performance improved 20-32%
    ✅ Suitable for reporting/documentation/deliverables
    ✅ Clean break point for next project phase

Cons:
    ⚠️  B/weight prefetch under N-tiling still deferred
    ⚠️  TOPS < 1.3 theoretical peak (hardware-limited)

Recommendation:
    **FREEZE NOW.** The current streaming GEMM pipeline is correct,
    well-structured, and has demonstrable overlap. It is a strong
    baseline for deliverables. B/weight prefetch is a performance
    optimization that should not block pipeline freeze.
```

### Option B: Resume N-Tiling B/Weight Background Prefetch

```
Action:
    Debug and restore Phase 5-2b B prefetch for N>64.
    Requires waveform-level analysis of NT5/NT6 failures.

Pros:
    ✅ May reduce K-chunk transition stalls
    ✅ Moves toward full LOAD/RUN/STORE pipeline

Cons:
    ❌ Higher implementation risk
    ❌ Must handle descriptor matching (k_base, n_base, tile_N)
    ❌ Must respect WGT_LD commit timing
    ❌ Previous attempt failed in NT5/NT6

Recommendation:
    **DEFER to separate phase after freeze.** The correctness
    baseline is strong without it. Should not gate pipeline freeze.
```

### Option C: Generalize Tile Descriptors for Broader NPU Operators

```
Action:
    Unify Conv/FC/GEMM tile descriptors.
    Extend store_desc to support non-GEMM output layouts.

Pros:
    ✅ Broader architecture cleanup
    ✅ Useful for Conv/FC unification

Cons:
    ❌ Less immediate GEMM performance gain
    ❌ Touches many modules

Recommendation:
    **DEFER.** Current GEMM-specific descriptors work correctly.
    Generalization should follow GEMM pipeline freeze.
```

## 11. Pipeline Freeze Recommendation

### Decision: FREEZE Current Streaming GEMM Pipeline

```
Rationale:
    1. Correctness: 37/37 + 6/6 + 7/7, zero UVM errors.
    2. Structure: LOAD_A(next) || RUN(current) || STORE(previous) implemented.
    3. Performance: STORE overlap delivers 20-32% in N-tiling cases.
    4. Audit: All phases tagged, documented, and merge-verified.
    5. Deferred items are performance-only, not correctness.

Freeze scope:
    ✅ LOAD_A ping-pong + overlap (Phase 4a)
    ✅ Basic B prefetch + DUAL_HIT (Phase 4b)
    ✅ c_tile double buffer (Phase 4c-1)
    ✅ Per-beat STORE micro-FSM (Phase 4c-2)
    ✅ STORE/RUN overlap (Phase 4c-3)
    ✅ M/N tiling (Phase 5-1, 5-2)
    ✅ Output tile descriptors (Phase 5-3)
    ✅ dma_producer_done restructuring

Not included in freeze (explicitly deferred):
    ❌ N-tiling B/weight background prefetch (Phase 5-2b)
    ❌ 512-bit AXI migration
    ❌ acc_buffer 128-bit widening
    ❌ Descriptor queue / multiple outstanding STOREs
    ❌ c_tile/acc_buffer unification
```

### Next Phase: Final Architecture Summary

```
Recommended next step after audit:
    Generate docs/NPU_STREAMING_GEMM_PIPELINE_FROZEN_BASELINE.md
    Include:
        ✅ Final architecture diagram
        ✅ All phase tags
        ✅ Performance tables
        ✅ Known limitations
        ✅ Deferred optimization roadmap

Then proceed to FPGA synthesis, coverage flow, or B/weight prefetch
as a separate dedicated phase.
```

## 12. Summary

The streaming GEMM tile pipeline has achieved its primary design goal:
**2-sided overlap around RUN with correct, verified behavior.**

| Dimension | Status |
|-----------|:------:|
| Input overlap (LOAD_A) | ✅ |
| Output overlap (STORE) | ✅ |
| Weight overlap (LOAD_B) | ⚠️ Partial (N≤64 only) |
| Correctness | ✅ 37+6+7 PASS, UVM=0 |
| Performance (N-tiling) | ✅ 20-32% improvement |
| Multi-driver safety | ✅ Zero multi-driver |
| Architecture clarity | ✅ Tagged, documented, audited |

**Recommendation**: Freeze the streaming GEMM pipeline as the current
correctness-and-performance baseline. Address B/weight prefetch under
N-tiling as a separate, dedicated phase after freeze.
