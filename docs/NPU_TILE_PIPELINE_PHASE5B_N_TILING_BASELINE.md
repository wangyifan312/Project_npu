# NPU Tile Pipeline — Phase 5-2 N-Tiling Baseline

## Metadata

- **Commit**: `c2e915f`
- **Tag**: `npu-tile-pipeline-phase5b-n-tiling`
- **Date**: 2026-07-01
- **Status**: **N-TILING CORRECTNESS BASELINE**

## Base

| Phase | Tag/Commit | Description |
|-------|-----------|-------------|
| Phase 4a | `npu-tile-pipeline-phase4a-input-overlap` | Input tile ping-pong |
| Phase 4b | `npu-tile-pipeline-phase4b-weight-overlap` | Weight prefetch / DUAL_HIT |
| Phase 5-1 | `npu-tile-pipeline-phase5a-m-tiling` | M-tiling |

## Supports

| Feature | Status |
|---------|:------:|
| M > 8 tiling | ✅ 5-1 |
| N > 64 tiling | ✅ 5-2 |
| K > 64 chunking | ✅ 3c |
| M tiling by 8 rows | ✅ |
| N tiling by 64 columns | ✅ |
| Last M tile < 8 | ✅ MT2 |
| Last N tile < 64 | ✅ NT1/NT6 |
| Full B matrix DMA (K×N bytes) | ✅ |
| B global K-major layout | ✅ |
| N-major weight staging iteration | ✅ |
| N-aware weight metadata | ✅ |
| Global output row/col addressing | ✅ |
| Non-uniform B by global column | ✅ NT3 |
| M/N/K combined tiling | ✅ NT5 |
| Signed B cancellation | ✅ NT6 |
| M/N boundary guard checks | ✅ NT1/NT6 |

## Key Formulas

```
A address:
  A[gemm_tile_m_base + local_m][gemm_stream_k_base + local_k]

B address:
  B[gemm_stream_k_base + local_k][gemm_tile_n_base + local_n]

B byte offset in wgt_buffer:
  (gemm_stream_k_base + local_k) * gemm_N_val + gemm_tile_n_base + local_n

STORE row address:
  blk_out_addr + (gemm_tile_m_base + local_row) * row_stride
  + gemm_tile_n_base * 4

row_stride:
  align32(gemm_N_val * 4)
```

## N-major Weight Staging

```
row = idx / n_tile   (local K)
out = idx % n_tile   (local N)
```

Replaced old K-major `row=idx%k_tile, out=idx/k_tile` which caused
beat-misalignment with full-B strided reads.

## Verified

```
RS0-RS19:  24/24 PASS
MT0-MT5:    6/6  PASS
NT0-NT6:    7/7  PASS
---
Streaming:  37/37 PASS
GEMM_FUNC:   6/6  PASS
7/7 regression:   PASS
UVM_ERROR:  0
UVM_FATAL:  0
```

### NT Tests

| Test | M | K | N | Pattern | Key Validation |
|------|---|---|---|---------|------|
| NT0 | 8 | 64 | 128 | all-1 | Basic N tiling |
| NT1 | 8 | 64 | 65 | all-1+guard | N boundary |
| NT2 | 8 | 128 | 128 | all-1 | N+K tiling |
| NT3 | 8 | 64 | 128 | B[n]=n+1 | Non-uniform B by col |
| NT4 | 16 | 64 | 128 | A[m]=m+1 | M+N combined |
| NT5 | 16 | 128 | 128 | B split 1/2 | M+N+K triple |
| NT6 | 9 | 128 | 65 | B split 1/-1 | Signed M+N boundary |

## Known Limitation

Background weight prefetch for K-chunk1 under N-tiling is **deferred**.
Foreground LOAD_ARRAY handles all weight staging correctly.
Performance impact: ~30-50 cycles per K-chunk transition.
This is a PERFORMANCE limitation, not a correctness limitation.

## Next Options

- **Phase 5-2b**: Restore background weight prefetch under N-tiling
  (branch: `feature/npu-tile-pipeline-n-tiling-weight-prefetch`)

- **Phase 5-3**: Formalize M×N output tile descriptor

- **Return to Phase 4c**: c_tile double buffer + background STORE engine
