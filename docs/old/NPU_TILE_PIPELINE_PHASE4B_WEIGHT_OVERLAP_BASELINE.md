# NPU Tile Pipeline — Phase 4b Weight Overlap Baseline

## Metadata

- **Commit**: `2aeb0d5`
- **Tag**: `npu-tile-pipeline-phase4b-weight-overlap`
- **Branch**: `feature/npu-tile-pipeline-weight-prefetch`
- **Date**: 2026-07-01
- **Status**: **WEIGHT PREFETCH CORRECTNESS BASELINE**

## Phase History

| Phase | Commit | Description |
|-------|--------|-------------|
| 4b-0 | `758e530` | Weight path audit + 方案 A design doc |
| 4b-1 | `4630221` | Sequential weight staging micro-sequencer |
| 4b-1.5 | `441b16c` | K-major compact B layout fix (RS17-RS19) |
| 4b-2 | `1a8f813` | RUN(current) ∥ LOAD_B(next) overlap |
| 4b-2a | `2aeb0d5` | Fix wgt_pref_done sticky flag |

Tags:
- `npu-tile-pipeline-phase4b1-kmajor-weight` → `441b16c`
- `npu-tile-pipeline-phase4b-weight-overlap` → `2aeb0d5`

## Base

- Phase 4a: `fdb7171` (tag: `npu-tile-pipeline-phase4a-input-overlap`)
  - Input tile ping-pong: beat-level load + double-buffer + overlap

## Supports

| Feature | Status |
|---------|:------:|
| wgt_load_reg reused as next weight staging buffer | ✅ |
| RUN(current) writes B(next) into wgt_load_reg | ✅ |
| PE.weight_reg remains stable during RUN | ✅ |
| K-major compact B[K,N_tile] layout | ✅ |
| Non-uniform B across K chunks | ✅ |
| Signed B across K chunks | ✅ |
| K=65 B boundary (K_tile=1) | ✅ |
| Input prefetch and weight prefetch run simultaneously | ✅ |
| DUAL_HIT: skip LOAD_A and LOAD_ARRAY → WGT_LD | ✅ |
| Multiple chunks (8-chunk RS10 verified) | ✅ |
| WGT_LD executed at every chunk boundary | ✅ |
| STORE after all K chunks complete | ✅ |

## Verified

### Streaming GEMM (RS0-RS19)
```
24/24 PASS
UVM_ERROR=0, UVM_FATAL=0
```

### GEMM_FUNC (G0-G3)
```
6/6 PASS
UVM_ERROR=0, UVM_FATAL=0
```

### Full 7/7 UVM Regression
```
npu_task_gemm_row_streaming_test    24/24 PASS
npu_task_gemm_func_test              6/6  PASS
npu_fc_smoke_test                          PASS
npu_conv_smoke_test                        PASS
npu_fc_128x128_peak_test                   PASS
npu_conv_multiblock_test                   PASS
npu_bandwidth_60pct_stress_test      PASS_TARGET
---
UVM_ERROR: 0   UVM_FATAL: 0
```

## Key Counters (RS10, K=512, 8 chunks)

| Metric | Value |
|--------|:---:|
| DUAL_HIT | 7 |
| LOAD_ARRAY skipped | 7 |
| ACCUM→WGT_LD direct | 7 |
| WGT_LD entry | 8 |
| Stall | 0 |

## Performance

| Test | Phase 4a | Phase 4b-2 (buggy) | Phase 4b-2a (fixed) | Total Δ |
|------|:--:|:--:|:--:|:--:|
| RS9 (K=128,M=8) | 458 | 476 | 476 | +4% |
| RS10 (K=512,M=8) | 1430 | 1838 | **1250** | **-13%** |
| RS14 (K=128,M=2) | 274 | 324 | 324 | +18% |
| RS17 (K=128,M=2) | — | 324 | 324 | — |
| RS19 (K=65,M=2) | — | 281 | 281 | — |

RS10 improvement: 1838 → 1250 (-32% in 4b, -13% overall from 4a).
M=2 tests slightly slower than 4a due to additional micro-sequencer
overhead (IDLE→REQ→WAIT startup, 3 extra cycles per foreground staging).

RS10 key insight: weight staging overhead (~42 cycles/chunk × 7 chunks = ~294 cycles)
is fully eliminated by DUAL_HIT skip.

## Limitations

| Limitation | Plan |
|------------|------|
| STORE overlap not implemented | Phase 4c |
| Output/c_tile ping-pong not implemented | Phase 4c |
| Result_tile_buffer not unified | Phase 4c |
| STORE Scheme A burst | Phase 4c |
| FC/Conv/Vector not migrated | Phase 4+ |
| No weight DMA prefetch (B already in wgt_buffer) | N/A for GEMM K-chunk |

## Implementation Summary

### Architecture
```
RUN current chunk:
  ├─ Compute: input_tile_bank[current] × PE.weight_reg[current]
  ├─ Input prefetch: act_buffer → input_tile_bank[next]
  └─ Weight prefetch: wgt_buffer → wgt_load_reg[next]

ACCUM boundary:
  DUAL_HIT → WGT_LD → PREP → RUN  (skip LOAD_A + LOAD_ARRAY)
```

### Key safety property
PE.weight_reg is weight-stationary during RUN (`weight_ld=0`).
Background weight prefetch writes to wgt_load_reg (staging),
which does NOT affect PE computation.

### B layout (K-major compact)
```
wgt_buffer[k * N_tile + n_local] = B[k][n_start + n_local]
```

## Next Step

**Phase 4c**: STORE overlap
- STORE(previous output tile) || RUN(current tile)
- Requires output/c_tile ping-pong
- Branch: `feature/npu-tile-pipeline-store-overlap`
