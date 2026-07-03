# NPU Streaming GEMM Pipeline — Frozen Baseline

## Identity

**Frozen baseline**: Streaming GEMM tile-level pipeline  
**Date**: 2026-07-02  
**Main HEAD**: `e0909f7` (Merge Phase 4c-3: STORE/RUN overlap)  
**Audit commit**: `443fbeb` (docs: audit full streaming GEMM tile pipeline)  
**Status**: **FROZEN — NO FURTHER RTL CHANGES WITHOUT NEW PHASE APPROVAL**

## Supported GEMM Capability

```
C[M,N] = A[M,K] × B[K,N]

Architecture:
    - Weight-stationary systolic array (64×64 PE)
    - PE rows map to K (input channels)
    - PE columns map to N (output channels)
    - Row-streaming over M (rows)
    - K > 64: K-chunk accumulation (ACCUM → LOAD_A → LOAD_ARRAY loop)
    - M > 8: M-tiling (gemm_tile_m_base advance)
    - N > 64: N-tiling (gemm_tile_n_base advance)
    - M/N/K combined tiling
    - INT8 operands
    - Signed B (INT8 weight)
    - Non-uniform A (per K-chunk)
    - Non-uniform B (K-major layout)
    - Last M-tile boundary
    - Last N-tile boundary
```

## Dataflow Summary

```
A/input path:
    shared_ram → act_buffer → input_tile_bank[2] → feeder → PE activation

B/weight path:
    shared_ram → wgt_buffer → wgt_load_reg / staging → WGT_LD → PE.weight_reg

C/output path:
    PE sum_out → c_tile_bank[2] → store_desc_* → GST micro-FSM
        → write_beat_fifo → dma_axi_writer → shared_ram

Control:
    PicoRV32 CPU → AXI-Lite → npu_ctrl → npu_top main FSM
```

## Effective Tile Pipeline

```
                   ┌─────────────────────────────────────────┐
                   │         STREAMING GEMM PIPELINE         │
                   │                                         │
    LOAD_A(next) ──┤  input_tile_bank[2] ping-pong           │
                   │  background prefetch during RUN         │
                   │  ✅ Phase 4a-3                          │
                   │                                         │
    RUN(current) ──┤  row-streaming GEMM compute             │
                   │  K-chunk accumulation                   │
                   │  M/N tiling, c_tile accumulation        │
                   │  ✅ Phase 3, 5-1, 5-2                   │
                   │                                         │
    STORE(prev) ───┤  c_tile_bank[2] double buffer           │
                   │  per-beat DMA GST micro-FSM             │
                   │  background tick during RUN             │
                   │  ✅ Phase 4c-1, 4c-2, 4c-3             │
                   │                                         │
    LOAD_B(next) ──┤  foreground LOAD_ARRAY (N>64)          │
                   │  basic bg prefetch + DUAL_HIT (N≤64)   │
                   │  ⚠️  N-tiling bg prefetch deferred      │
                   └─────────────────────────────────────────┘
```

Conceptual overlap:

```
    LOAD_A(tile i+1)  ||  RUN(tile i)  ||  STORE(tile i-1)
```

## Completed Pipeline Overlap

| Overlap | Phase | Tag | Status |
|---------|-------|-----|:------:|
| LOAD_A(next) \|\| RUN(current) | 4a-3 | `npu-tile-pipeline-phase4a-input-overlap` | ✅ |
| STORE(previous) \|\| RUN(current) | 4c-3 | `npu-tile-pipeline-phase4c3-store-run-overlap` | ✅ |
| Basic B weight prefetch + DUAL_HIT (N≤64) | 4b-2 | `npu-tile-pipeline-phase4b-weight-overlap` | ✅ |
| N-tiling B weight bg prefetch | 5-2b | `npu-tile-pipeline-phase5b-weight-prefetch-deferred` | ❌ |

## Major Implementation Milestones

| Phase | Milestone | Tag |
|-------|-----------|-----|
| 1a+ | GEMM weight retention cache | — |
| 2b | Row-streaming compute + c_tile collect + direct STORE | — |
| 3 | K>64 cross-chunk accumulation | — |
| 4a-1 | Beat-level bulk A loader | `phase4a1-beat-loader` |
| 4a-2 | Double-buffered input banks | `phase4a2-input-banks` |
| 4a-3 | LOAD_A(next) \|\| RUN(current) | `phase4a-input-overlap` |
| 4b-1 | K-major weight staging | `phase4b1-kmajor-weight` |
| 4b-2 | Basic weight prefetch + DUAL_HIT (N≤64) | `phase4b-weight-overlap` |
| 5-1 | M-tiling | `phase5a-m-tiling` |
| 5-2 | N-tiling | `phase5b-n-tiling` |
| 5-2b | N-tiling B prefetch deferred | `phase5b-weight-prefetch-deferred` |
| 5-3 | Output tile descriptor + locked store_desc_* | `phase5c-output-descriptor` |
| 4c-1 | c_tile double buffer | `phase4c1-c-tile-double-buffer` |
| 4c-2 | Per-beat GEMM STORE micro-FSM | `phase4c2-store-micro-fsm` |
| 4c-3 | STORE(prev) \|\| RUN(curr) | `phase4c3-store-run-overlap` |
| 6-0 | Full tile pipeline audit | — |

## Key Architecture Decisions

### STORE Engine Design

- GCC STORE micro-FSM integrated into main FSM always block (no multi-driver)
- 5 micro-states: GST_PUSH_BEAT → GST_START → GST_START_CLR → GST_WAIT_DONE → GST_ADVANCE
- Per-beat 256-bit DMA transaction (Scheme B: 1 txn per beat)
- `dma_wr_start` 1→0 pulse via default assignment (not explicit clear)
- `producer_done` aligned with GST_START
- Background tick gates on `gemm_store_eng_active`, not on `fsm_state`
- `gemm_store_pending` provides backpressure for single outstanding STORE

### Descriptor Management

- `store_desc_*` locked at tile DONE (Phase 5-3)
- Only updated when `gemm_store_eng_active == 0` (protects active STORE)
- c_tile bank ownership: `store_desc_bank` ≠ `compute_c_bank`
- Bank toggle on STORE launch: `compute_c_bank <= ~compute_c_bank`

### DMA Protocol

- dma_axi_writer: per-beat transaction with max 16-beat bursts
- `dma_wr_start` must be 1→0 pulse for S_DONE→S_IDLE
- 5 waveform cases characterized and confirmed (Phase 4c-2a)
- `dma_producer_done` structure: legacy OR GEMM (Phase 4c-2 prep)

## Correctness Baseline

| Test Suite | Levels | Result |
|------------|:------:|:------:|
| `tb_dma_writer_per_beat_protocol` | 5 | **PASS** |
| `npu_task_gemm_row_streaming_test` (RS0-19 + MT0-5 + NT0-6) | 37 | **PASS** |
| `npu_task_gemm_func_test` | 6 | **PASS** |
| 7-key regression (fc/conv/requant/gap/pool/add smoke + bw 60%) | 7 | **PASS** |
| **UVM_ERROR** | — | **0** |
| **UVM_FATAL** | — | **0** |

## Performance Baseline

| Metric | Phase 4c-2 (pre-overlap) | Phase 4c-3 (frozen) | Delta |
|--------|:--:|:--:|:--:|
| **Overall (37 tests)** | 296,314 | **289,424** | **-2.3%** |
| NT0 (N=128, M=8) | 2,887 | 2,299 | **-20.4%** |
| NT1 (N=65, M=8) | 1,703 | 1,556 | **-8.6%** |
| NT2 (N+K, M=8) | 4,252 | 3,549 | **-16.5%** |
| NT3 (B-by-col, M=8) | 2,887 | 2,299 | **-20.4%** |
| NT4 (M+N, M=16) | 5,492 | 3,726 | **-32.2%** |
| NT5 (M+N+K, M=16) | 7,950 | 5,839 | **-26.6%** |
| NT6 (signed boundary, M=9) | 3,877 | 3,457 | **-10.8%** |

STORE/RUN overlap has strong benefit in output-tiling-heavy cases.
N-tiling tests show 20-32% improvement because previous-tile STORE
latency is hidden under next-tile compute. The overall 2.3% reduction
is driven by the 7 N-tiling tests within the 37-test suite.

Single-tile and compute-bound tests show minimal improvement since
there is no next tile to overlap with.

## Known Limitations

1. **B/weight background prefetch under N-tiling remains deferred.** Foreground LOAD_ARRAY fallback provides correctness but is suboptimal for K-heavy workloads. Root cause isolated to bg prefetch timing with N-tiled weight addressing.

2. **Single outstanding STORE.** Only one STORE engine can be active. A second tile completing compute while the first is still storing must wait (`gemm_store_pending`).

3. **No store descriptor queue.** store_desc_* is a single register set. Cannot enqueue multiple tiles for deferred STORE.

4. **Two c_tile banks.** Bank0 must be freed (STORE complete) before bank0 can be reused for compute on a third tile. Limits overlap depth to one level.

5. **No c_tile/acc_buffer unification.** STORE reads from c_tile (32-bit word), packs into 256-bit beats via store_pack. acc_buffer remains separate.

6. **No generalized result_tile_buffer framework.** c_tile is GEMM-specific. Conv/FC output paths use separate mechanisms.

7. **No Conv/FC tile descriptor unification.** store_desc_* is streaming-GEMM-specific.

8. **System TOPS < 1.3 target.** Current effective TOPS ~0.32-0.79. Requires 512-bit AXI + acc_buffer 128-bit widening for >1.3 TOPS.

## Why Freeze Now

1. **Correctness is strong and repeatedly verified.** 37+6+7=50 tests, zero UVM errors across multiple merge-to-main cycles.

2. **LOAD_A/RUN/STORE pipeline is meaningful and measurable.** Two-sided overlap is implemented, tagged, and documented.

3. **STORE/RUN overlap delivers 20-32% improvement** in the output-tiling-heavy cases that matter for larger GEMM workloads.

4. **Deferred B/weight prefetch is a performance optimization**, not a correctness blocker. It should not gate pipeline freeze.

5. **Current baseline is suitable for project reporting** and architecture documentation. All phases are tagged and merge-verified.

## Deferred Future Work

In priority order:

### 1. N-tiling B/weight background prefetch (Phase 5-2b)

```
Re-enable bg weight prefetch for N>64.
Requires:
    - Waveform debug of NT5/NT6 failures
    - Weight prefetch descriptor: k_base, n_base, tile_N, gemm_N_val
    - staging_valid / commit_pending flags
    - WGT_LD commit timing guard (must not occur during RUN)
```

### 2. Hardware widening

```
- 512-bit AXI data bus (halves DMA beat count)
- acc_buffer 128-bit widening (accelerates STORE path)
- Target: >1.3 TOPS effective performance
```

### 3. Store descriptor queue

```
- Enable multiple outstanding STOREs
- Decouple STORE launch from tile DONE
- Requires queue depth ≥ 2, store_desc FIFO
```

### 4. Architecture generalization

```
- result_tile_buffer framework (unify c_tile with Conv/FC outputs)
- Conv/FC tile descriptor generalization
- Broader NPU operator pipeline support
```

## Important Tags

```
npu-tile-pipeline-phase4a-input-overlap          # LOAD_A(next) || RUN(current)
npu-tile-pipeline-phase4a1-beat-loader           # Beat-level bulk A loader
npu-tile-pipeline-phase4a2-input-banks           # Double-buffered input banks
npu-tile-pipeline-phase4b-weight-overlap         # Basic B prefetch + DUAL_HIT
npu-tile-pipeline-phase4b1-kmajor-weight         # K-major weight staging
npu-tile-pipeline-phase4c1-c-tile-double-buffer  # c_tile double buffer
npu-tile-pipeline-phase4c2-store-micro-fsm       # Per-beat STORE micro-FSM
npu-tile-pipeline-phase4c3-store-run-overlap     # STORE/RUN overlap
npu-tile-pipeline-phase5a-m-tiling               # M-tiling
npu-tile-pipeline-phase5b-n-tiling               # N-tiling
npu-tile-pipeline-phase5b-weight-prefetch-deferred  # B prefetch deferred
npu-tile-pipeline-phase5c-output-descriptor      # Output tile descriptor
npu-streaming-gemm-pipeline-frozen-baseline      # THIS FREEZE
```

## Frozen Baseline Scope

The following are **included in the frozen baseline** and should not be
modified without a new phase approval:

- ✅ A/input ping-pong + overlap (Phase 4a)
- ✅ Basic B prefetch + DUAL_HIT (Phase 4b)
- ✅ c_tile double buffer (Phase 4c-1)
- ✅ Per-beat STORE micro-FSM (Phase 4c-2)
- ✅ STORE/RUN overlap (Phase 4c-3)
- ✅ M/N tiling (Phase 5-1, 5-2)
- ✅ Output tile descriptors (Phase 5-3)
- ✅ dma_producer_done structure (Phase 4c-2 prep)

The following are **excluded from the frozen baseline** and may be
addressed in future dedicated phases:

- ❌ N-tiling B/weight background prefetch
- ❌ 512-bit AXI migration
- ❌ acc_buffer 128-bit widening
- ❌ Store descriptor queue
- ❌ c_tile/acc_buffer unification
- ❌ Conv/FC tile descriptor generalization
