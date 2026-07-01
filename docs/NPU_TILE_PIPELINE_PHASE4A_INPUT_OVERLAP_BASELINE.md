# NPU Tile Pipeline — Phase 4a Input Overlap Baseline

## Metadata

- **Commit**: `fdb7171`
- **Tag**: `npu-tile-pipeline-phase4a-input-overlap`
- **Branch**: `feature/npu-tile-pipeline-input-pingpong`
- **Date**: 2026-07-01
- **Status**: **INPUT TILE PING-PONG CORRECTNESS BASELINE**

## Phase History

| Phase | Commit | Description |
|-------|--------|-------------|
| 4a-1 | `d579e81` | Beat-level input tile load from act_buffer |
| 4a-2 | `f6ba6b8` | Double-buffered input_tile_bank[2] structure |
| 4a-3 | `fdb7171` | LOAD_A(next) ∥ RUN(current) overlap |

Tags:
- `npu-tile-pipeline-phase4a1-beat-loader` → `d579e81`
- `npu-tile-pipeline-phase4a2-input-banks` → `f6ba6b8`
- `npu-tile-pipeline-phase4a-input-overlap` → `fdb7171`

## Base

- Phase 3c: `4945d1d` (tag: `gemm-streaming-phase3c-general-kchunk`)
  - K>64 streaming GEMM with non-uniform A pattern
  - Byte-by-byte input-tile-loader from act_buffer raw data

## Supports

| Feature | Status |
|---------|:------:|
| Beat-level act_buffer raw read (32 bytes/beat) | ✅ 4a-1 |
| Non-aligned 256-bit beat access (cross-3-beat support) | ✅ 4a-1 |
| K=65 boundary (K_tile=1 last chunk) | ✅ 4a-1 |
| input_tile_bank0 / input_tile_bank1 | ✅ 4a-2 |
| Bank valid / k_base / k_tile metadata | ✅ 4a-2 |
| Bank ownership (load_bank ≠ compute_bank) | ✅ 4a-2 |
| Background prefetch during FSM_GEMM_STREAM_RUN | ✅ 4a-3 |
| Independent prefetch micro-sequencer | ✅ 4a-3 |
| ACCUM prefetch hit → skip foreground LOAD_A | ✅ 4a-3 |
| ACCUM prefetch stall (if not done) | ✅ 4a-3 |
| Bank valid cleared at task start (no stale carryover) | ✅ 4a-3 |
| K=512 with 7 prefetch hits, 0 stalls | ✅ 4a-3 |
| Multiple non-uniform A tests (RS14/RS16) with prefetch | ✅ 4a-3 |
| Signed INT8 multi-chunk with prefetch | ✅ 4a-3 |

## Verified

### Streaming GEMM (RS0-RS16)
```
21/21 PASS
UVM_ERROR=0, UVM_FATAL=0
```

### GEMM_FUNC (G0-G3)
```
6/6 PASS
UVM_ERROR=0, UVM_FATAL=0
```

### Full 7/7 UVM Regression
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

## Performance

| Test | Phase 3c | Phase 4a-1 | Phase 4a-2 | Phase 4a-3 | Total Δ |
|------|:--:|:--:|:--:|:--:|:--:|
| RS9 (K=128,M=8) | 3484 | 508 | 508 | 458 | -87% |
| RS10 (K=512,M=8) | 13684 | 1780 | 1780 | 1430 | -90% |
| RS14 (K=128,M=2) | 1032 | 288 | 288 | 274 | -73% |
| RS15 (K=65,M=2) | 632 | 263 | 263 | 255 | -60% |
| RS16 (K=128,M=2) | 1032 | 288 | 288 | 274 | -73% |

Phase 4a-3 improvement limited by sequential B weight loading
and WGT_LD, which dominate the chunk switching time.

## Prefetch Statistics (from regression)

| Test | Chunks | Prefetch Start | Prefetch Hit | Stall |
|------|:---:|:---:|:---:|:---:|
| RS9 | 2 | 1 | 1 | 0 |
| RS10 | 8 | 7 | 7 | 0 |
| RS12 | 2 | 1 | 1 | 0 |
| RS14 | 2 | 1 | 1 | 0 |
| RS15 | 2 | 1 | 1 | 0 |

100% hit rate, 0 stall cycles across all multi-chunk tests.

## Limitations

| Limitation | Plan |
|------------|------|
| B weight load is sequential | Phase 4b |
| WGT_LD is sequential | Phase 4b |
| STORE is after all chunks | Phase 4c |
| No output/result buffer ping-pong | Phase 4c |
| FC/Conv/Vector not yet migrated | Phase 4+ |
| No performance optimization for 2-chunk case | Phase 4b |

## Implementation Summary

### RTL: `rtl/npu/npu_top.v`

**Bank structure**: Two independent 8×64 byte arrays
```verilog
reg [7:0] input_tile_bank0 [0:7][0:63];
reg [7:0] input_tile_bank1 [0:7][0:63];
```

**Bank ownership**:
```verilog
reg input_load_bank;       // loader writes
reg input_compute_bank;    // compute reads
reg input_bank0_valid;     // metadata per bank
reg input_bank1_valid;
reg [15:0] input_bank0_k_base;
reg [15:0] input_bank1_k_base;
reg [15:0] input_bank0_k_tile;
reg [15:0] input_bank1_k_tile;
```

**Foreground loader**: 4-phase beat-level micro-sequencer in `FSM_GEMM_STREAM_LOAD_A`

**Background prefetch**: Independent 4-phase micro-sequencer triggered
in `FSM_GEMM_STREAM_RUN`, running during compute.

**act_rd_addr priority**: LOAD_A > prefetch > legacy

**ACCUM routing**: Hit → LOAD_ARRAY (skip LOAD_A) / Stall / Fallback → LOAD_A

## Next Step

**Phase 4b**: B weight prefetch / staging
- Pre-load next chunk's B weights during compute
- Hide LOAD_ARRAY → WGT_LD latency
- Branch: `feature/npu-tile-pipeline-weight-prefetch`
