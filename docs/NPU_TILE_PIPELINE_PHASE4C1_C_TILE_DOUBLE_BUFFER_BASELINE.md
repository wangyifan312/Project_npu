# NPU Tile Pipeline — Phase 4c-1 c_tile Double Buffer Baseline

## Metadata

- **Commit**: `dfdf2a5`
- **Base**: main `5bbf2bb`
- **Date**: 2026-07-01
- **Status**: **C_TILE DOUBLE BUFFER COMPLETE**

## What Phase 4c-1 Implements

```
c_tile_bank0[0:7][0:63]   INT32 × 8 rows × 64 columns
c_tile_bank1[0:7][0:63]
c_tile_valid_bank0 / c_tile_valid_bank1

compute_c_bank   — collector writes
store_c_bank     — STORE reads
```

## Bank Timing

```
init:  compute_c_bank=0, store_c_bank=0
PREP:  clear compute bank only
DONE→STORE: store_c_bank = compute_c_bank
STORE done + more tile: toggle compute_c_bank
```

## What Phase 4c-1 Does NOT Implement

- No background STORE engine (deferred)
- No STORE(previous) || RUN(current)
- No c_tile/acc_buffer unification
- No DMA writer changes

## Verified

```
RS0-RS19 + MT0-MT5 + NT0-NT6: 37/37 PASS
GEMM_FUNC: 6/6 PASS
7/7 regression: PASS
UVM_ERROR: 0, UVM_FATAL: 0
Cycles: unchanged
```

## Phase 4c-2 Deferred

Background STORE engine attempted, deferred due to DMA writer protocol complexity.
WIP saved on branch `wip/phase4c2-store-engine-debug` (commit `8dbf8dd`).
Requires independent protocol audit of `producer_done` / per-beat `dma_wr_start`.
