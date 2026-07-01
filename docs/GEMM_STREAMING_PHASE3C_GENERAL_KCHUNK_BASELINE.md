# GEMM Streaming Phase 3c — General K-Chunk Correctness Baseline

## Metadata

- **Commit**: `4945d1d`
- **Tag**: `gemm-streaming-phase3c-general-kchunk`
- **Branch**: `feature/gemm-streaming-kchunk-accum`
- **Date**: 2026-07-01
- **Status**: **GENERAL K>64 STREAMING GEMM CORRECTNESS BASELINE**

## Overview

Phase 3c lifts the `gemm-streaming-phase3a-k128` baseline from uniform-pattern-only
to general non-uniform A pattern support across K chunks.

### Previous limitation (Phase 3a, tag: `gemm-streaming-phase3a-k128`)

```
K-chunk loop 可工作；
B weight per-chunk reload 可工作；
c_tile accumulation 可工作；
STORE after all chunks 可工作；
uniform A pattern 下 K=128/K=512/K=65/signed uniform 可通过。

BUT: non-uniform A across K chunks 静默算错。
chunk1+ 复用 chunk0 的 stale a_tile 数据。
```

### Phase 3c resolution

Implemented an input-tile-loader micro-sequencer within `FSM_GEMM_STREAM_LOAD_A`
that reads A_tile directly from act_buffer raw byte-level beat access,
bypassing `act_feed`/`conv_frontend`/`cf_act_data`.

## Supports

| Feature | Status |
|---------|:------:|
| K=128 two-chunk GEMM | ✅ |
| K=512 eight-chunk GEMM | ✅ |
| K=65 boundary, last K_tile=1 | ✅ |
| K-chunk + multi-beat STORE (N=16/32/64) | ✅ |
| signed INT8 + K>64 | ✅ |
| **non-uniform A across K chunks** | ✅ **NEW** |
| A_tile per-chunk reload from act_buffer raw data | ✅ **NEW** |
| act_feed / conv_frontend bypass | ✅ **NEW** |
| no new main FSM state | ✅ |

## Verified

### Streaming GEMM tests (RS0-RS16)
```
RS0-RS3:  baseline M/K/N combinations          4/4 PASS
RS4-RS6:  multi-beat STORE (N=16/32/64)         3/3 PASS
RS7a-c:   signed INT8 patterns                  3/3 PASS
RS8a-b:   boundary (M=1,K=1) (M=7,K=63)         2/2 PASS
RS9-RS13b: K>64 uniform/signed patterns         6/6 PASS
RS14-RS16: non-uniform / boundary / signed      3/3 PASS
---
TOTAL:                                          21/21 PASS
```

### GEMM_FUNC tests
```
G0-G3: 6/6 PASS
```

### Full UVM regression (7/7)
```
npu_task_gemm_row_streaming_test    21/21 PASS
npu_task_gemm_func_test              6/6  PASS
npu_fc_smoke_test                          PASS
npu_conv_smoke_test                        PASS
npu_fc_128x128_peak_test                   PASS
npu_conv_multiblock_test                   PASS
npu_bandwidth_60pct_stress_test      PASS_TARGET
---
UVM_ERROR: 0   UVM_FATAL: 0
```

## Implementation Summary

### RTL: `rtl/npu/npu_top.v`

- **Micro-sequencer**: 4-phase state machine (A_LOAD_IDLE/REQ/WAIT/CAPTURE)
  within `FSM_GEMM_STREAM_LOAD_A`
- **Data source**: act_buffer raw byte access via combinational `act_rd_addr` override
  - `byte_idx = row * input_c + gemm_stream_k_base + col`
  - `beat_addr = byte_idx >> 5`
  - `byte_sel = byte_idx & 0x1F`
  - `a_tile[row][col] = act_rd_data[byte_sel * 8 +: 8]`
- **Routing**: `ACCUM → LOAD_A → LOAD_ARRAY → WGT_LD → PREP → RUN → ACCUM`
- **No new main FSM states** (reuses `FSM_GEMM_STREAM_LOAD_A = 6'd35`)

### Test: `verif/uvm_top/tests/npu_task_gemm_row_streaming_test.sv`

Three new tests exercising non-uniform A reload:

| Test | M | K | N | A pattern | Expected C |
|------|---|---|---|-----------|------------|
| RS14 | 2 | 128 | 4 | k<64=1, k≥64=2 | 192 |
| RS15 | 2 | 65 | 4 | k<64=1, k=64=7 | 71 |
| RS16 | 2 | 128 | 4 | k<64=1, k≥64=-1 | 0 |

### Doc: `docs/NPU_TILE_PIPELINE_UNIFIED_PLAN.md`

Unified NPU tile-level pipeline plan covering LOAD/COMPUTE/STORE abstraction,
GEMM/FC/Conv/Vector/Pool mapping, Phase 3c rationale, and Phase 4 roadmap.

## Limitations

| Limitation | Plan |
|------------|------|
| No input tile ping-pong | Phase 4a |
| No LOAD/COMPUTE overlap | Phase 4b/4c |
| No B weight prefetch overlap | Phase 4b |
| No STORE/COMPUTE overlap | Phase 4c |
| Byte-by-byte micro-sequencer (correctness-first) | Phase 4a beat-level bulk read |
| FC/Conv/Vector not yet migrated to common tile pipeline | Phase 4+ |
| M_tile ≤ 8 | Phase 4+ |

## Next Step

**Phase 4a**: General input tile ping-pong
- Upgrade `gemm_a_load_*` to common `input_tile_loader`
- Beat-level bulk read (~1 cycle/32 bytes)
- Double-buffered a_tile for LOAD/COMPUTE overlap
- Branch: `feature/npu-tile-pipeline-input-pingpong`
