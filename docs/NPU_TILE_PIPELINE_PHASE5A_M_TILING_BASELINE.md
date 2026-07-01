# NPU Tile Pipeline — Phase 5-1 M-Tiling Baseline

## Metadata

- **Commit**: `a4b080a`
- **Tag**: `npu-tile-pipeline-phase5a-m-tiling`
- **Branch**: `feature/npu-tile-pipeline-store-overlap`
- **Date**: 2026-07-01
- **Status**: **M-TILING CORRECTNESS BASELINE**

## Phase History

| Phase | Commit | Description |
|-------|--------|-------------|
| 5-0 | `58b1bed` | Multi-tile audit + design doc |
| 5-1 | `c2749a5` | M-tiling implementation |
| 5-1a | `a4b080a` | M-tiling address/signed coverage + weight reload fix |

Tag: `npu-tile-pipeline-phase5a-m-tiling` → `a4b080a`

## Base

- Phase 4a: `fdb7171` — input tile ping-pong
- Phase 4b: `2aeb0d5` — weight prefetch / DUAL_HIT
- Merged at: `63223e8`

## Supports

| Feature | Status |
|---------|:------:|
| M > 8 tiling | ✅ |
| M tiling by groups of 8 rows | ✅ |
| Last M tile with tile_M < 8 | ✅ |
| K arbitrary via K-chunk loop | ✅ |
| N ≤ 64 only | ✅ |
| A global row addressing | ✅ |
| STORE global row addressing | ✅ |
| K chunk reset per M tile | ✅ |
| Input prefetch scoped within current M tile | ✅ |
| Weight prefetch scoped within current M tile | ✅ |
| Non-uniform A by global row | ✅ MT3 |
| Non-uniform B across K chunks per M tile | ✅ MT4 |
| Signed B cancellation + M boundary | ✅ MT5 |

## Verified

### Streaming GEMM (30/30)
```
RS0-RS19: 24/24 PASS
MT0-MT5:   6/6  PASS
Total:    30/30 PASS
UVM_ERROR=0, UVM_FATAL=0
```

### GEMM_FUNC
```
6/6 PASS
UVM_ERROR=0, UVM_FATAL=0
```

### Full 7/7 UVM Regression
```
npu_task_gemm_row_streaming_test    30/30 PASS
npu_task_gemm_func_test              6/6  PASS
npu_fc_smoke_test                          PASS
npu_conv_smoke_test                        PASS
npu_fc_128x128_peak_test                   PASS
npu_conv_multiblock_test                   PASS
npu_bandwidth_60pct_stress_test      PASS_TARGET
---
UVM_ERROR: 0   UVM_FATAL: 0
```

## Key Tests

| Test | M | K | N | Pattern | Expected |
|------|---|---|---|---------|----------|
| MT0 | 16 | 64 | 8 | A=1, B=1 | C=64 |
| MT1 | 16 | 128 | 8 | A=1, B=1 | C=128 |
| MT2 | 9 | 64 | 8 | A=1, B=1 | C=64 |
| MT3 | 16 | 64 | 4 | A[row]=row+1 | C[row]=64×(row+1) |
| MT4 | 16 | 128 | 4 | B k=0..63=1, k=64..127=2 | C=192 |
| MT5 | 9 | 128 | 4 | B k=0..63=1, k=64..127=-1 | C=0 |

## Fixed Issues

1. **Second M tile skipped first K-chunk weight load**: LOAD_A routing only checked
   `gemm_stream_first_chunk` to go to RUN, but subsequent M tiles need LOAD_ARRAY for
   their first K-chunk weight reload. Fix: check `gemm_tile_m_base == 0` for RUN path.

2. **first_chunk caused PREP to re-clear c_tile**: When LOAD_A→LOAD_ARRAY→WGT_LD→PREP
   was entered for subsequent M tile, first_chunk was still 1, causing PREP to clear
   c_tile a second time. Fix: clear first_chunk before LOAD_ARRAY for subsequent tiles.

## M Tile Descriptor

```verilog
reg [15:0] gemm_tile_m_base;   // global starting row of current M tile
reg [15:0] gemm_tile_M;        // rows in current tile (≤ 8)
```

Initialized in FSM_FC_TILE_PREP (once per task).
Advanced in STORE done path for next M tile.

## A Address Formula

```
global_m = gemm_tile_m_base + local_row
byte_idx = global_m * input_c + k_base + col
```

## STORE Address Formula

```
row_addr = blk_out_addr + (gemm_tile_m_base + local_row) * row_stride
```

## Limitations

| Limitation | Plan |
|------------|------|
| N > 64 not supported | Phase 5-2 |
| N-tiling not implemented | Phase 5-2 |
| STORE overlap not implemented | Phase 4c (after multi-tile) |
| c_tile double buffer not implemented | Phase 4c |
| Background STORE engine not implemented | Phase 4c |
| No weight retention across M tiles | Future optimization |

## Next Step

**Phase 5-2**: Sequential N-tiling for streaming GEMM (N > 64).
Branch: `feature/npu-tile-pipeline-n-tiling`
