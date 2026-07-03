# NPU Tile Pipeline — Phase 5-2b Weight Prefetch Deferred

## Metadata

- **Commit**: `1518c43`
- **Base**: `6a3fc70` (Merge Phase 5-2: N-tiling streaming GEMM)
- **Date**: 2026-07-01
- **Status**: **BG WEIGHT PREFETCH UNDER N-TILING DEFERRED**

## Base

| Phase | Commit | Description |
|-------|--------|-------------|
| Phase 5-2 | `c2e915f` | N-tiling correctness baseline |
| Phase 5-2b | `1518c43` | Deferred bg weight prefetch |

## What Was Attempted

- Restore background weight prefetch under N-tiling (M/N/K combined)
- N-major bg weight prefetch iteration (`row=idx/n_tile, out=idx%n_tile`)
- Full B matrix stride (`gemm_N_val`) for bg prefetch address
- `wgt_pref_n_base` / `wgt_pref_n_tile` metadata for N-tile aware DUAL_HIT
- DUAL_HIT path: skip both LOAD_A and LOAD_ARRAY → WGT_LD

## Observation

- Bg prefetch CAPTURE reads observed correct (`buf=8192 data0=2` for NT5 chunk1)
- DUAL_HIT display showed `wgt_load_reg[0]=1` (stale — NBA timing artifact)
- NT5/NT6 still FAIL after DUAL_HIT despite apparently correct CAPTURE reads
- Issue likely in bg prefetch write timing or wgt_load_reg write target at
  beat boundaries under N-major iteration with `gemm_N_val` stride
- Requires waveform-level timing debug to resolve

## Decision

**Defer bg weight prefetch under N-tiling.** Keep foreground LOAD_ARRAY fallback.

## Stable Behavior

- All K chunks staged through foreground LOAD_ARRAY under N-tiling
- No bg weight DUAL_HIT under N-tiling (`wgt_pref` trigger gated off)
- WGT_LD preserved at every chunk boundary
- Full M/N/K tiling correctness retained

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

## Known Limitation

~30–50 cycles additional per K-chunk transition due to foreground LOAD_ARRAY.
Performance limitation only; correctness not affected.

## Future Work

1. Waveform-level debug of bg prefetch wgt_load_reg writes
2. Verify write timing before WGT_LD latch
3. Verify DUAL_HIT state transition and flag clear timing
4. Restore RUN(current K chunk) || LOAD_B(next K chunk) under N-tiling
