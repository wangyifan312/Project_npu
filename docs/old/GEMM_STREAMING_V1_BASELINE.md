# GEMM Streaming v1 Clean Baseline

## Stable baseline

```
Stable commit: 34952db
Branch: test-gemm-streaming-coverage
Tag: gemm-streaming-v1-clean
Date: 2026-06-30
```

## Implemented path

```
CPU / npu_ctrl config (AXI-Lite)
    ↓
TASK_GEMM (task_type=7, conv_cfg[5]=1 → row_streaming_en)
    ↓
A/B DMA preload (input_addr, weight_addr → shared RAM)
    ↓
Phase 1a+ gemm_weight_valid cache (skip redundant B weight DMA)
    ↓
a_tile[0:7][0:63] skewed activation feed
    ↓
weight-stationary PE array (64×64, INT8×INT8→INT32)
    ↓
wavefront output (PIPE_OFFSET = PE_ROWS - K + 1)
    ↓
c_tile[0:7][0:63] wavefront collect
    ↓
FSM_GEMM_STREAM_STORE: direct c_tile row-major pack
    ↓
256-bit beat packing (lane=0..7, base_col=beat_idx*8)
    ↓
write_beat_fifo (depth 64)
    ↓
dma_axi_writer (Scheme B: 1 beat = 1 AXI transaction)
    ↓
AXI4 write data channel → shared RAM (32B-aligned row stride)
    ↓
AXI-Lite readback → memory verification PASS
```

## Implemented features

1. **Phase 1a+** GEMM weight retention cache (parameterized 5-field cache hit detection)
2. **Phase 2b-1** row-streaming compute (skewed a_tile feed, wavefront c_tile collection)
3. **c_tile[0:7][0:63]** wavefront collect with correct PIPE_OFFSET
4. **Phase 2b-2** direct c_tile STORE (bypasses acc_buffer, store_pack, output_arbiter)
5. **Multi-beat STORE** for N=16/32/64 (scheme B: 1 beat per transaction)
6. **Signed INT8** streaming GEMM coverage (negative A, negative B, mixed signs)
7. **Memory output verification** (row-major readback, signed INT32 comparison)
8. **Guard region check** (pre-guard CAFE_BABE, post-guard FEED_F00D)
9. **Legacy regression compatibility** (GEMM_FUNC, FC, Conv, Bandwidth all PASS)

## Supported scope

| Parameter | Limit |
|-----------|-------|
| M (rows per tile) | ≤ 8 |
| K (inner dimension) | ≤ 64 (single chunk, no cross-chunk accumulation) |
| N (output columns) | ≤ 64 |
| A/B input | INT8 |
| C output | INT32 |
| N STORE coverage | 4 / 8 / 16 / 32 / 64 |
| Signed INT8 | verified |
| Row stride | 32B-aligned |
| PE array | 64×64 weight-stationary systolic |

## Current limitations

1. **K > 64** streaming cross-chunk accumulation not implemented
2. **c_tile / acc_buffer / col_results** unified result_tile_buffer refactor not done
3. **Ping-pong buffering** not implemented (no compute/STORE overlap)
4. **STORE burst optimization** (Scheme A: one AXI burst per row) not implemented
5. **M_tile > 8** requires larger a_tile/c_tile (currently depth=8)
6. **Non-multiple-of-8 N** (e.g. N=10) WSTRB tail handling not tested (but packer supports it)

## Test results

### Row streaming: 12/12 PASS

```
RS0:  M=4, K=4,  N=4,  cycles=159, beats/row=1,  mem_OK PASS
RS1:  M=8, K=8,  N=8,  cycles=255, beats/row=1,  mem_OK PASS
RS2:  M=8, K=16, N=8,  cycles=327, beats/row=1,  mem_OK PASS
RS3:  M=8, K=64, N=8,  cycles=759, beats/row=1,  mem_OK PASS
RS4:  M=8, K=16, N=16, cycles=419, beats/row=2,  mem_OK PASS
RS5:  M=8, K=16, N=32, cycles=603, beats/row=4,  mem_OK PASS
RS6:  M=8, K=16, N=64, cycles=972, beats/row=8,  mem_OK PASS
RS7a: M=2, K=4,  N=4,  cycles=131, A=-1 B=1,     mem_OK PASS
RS7b: M=2, K=4,  N=4,  cycles=131, A=1 B=-1,     mem_OK PASS
RS7c: M=1, K=4,  N=4,  cycles=117, mixed signed, mem_OK PASS
RS8a: M=1, K=1,  N=8,  cycles=118, boundary min, mem_OK PASS
RS8b: M=7, K=63, N=8,  cycles=676, boundary high,mem_OK PASS

UVM_ERROR=0
UVM_FATAL=0
```

### Legacy regression: 7/7 PASS

```
GEMM_FUNC 6/6:            PASS (G0a, G0b, G0, G1, G2, G3)
npu_fc_smoke_test:        PASS (golden model verified)
npu_conv_smoke_test:      PASS (golden model verified)
npu_fc_128x128_peak_test: PASS (512 bytes matched)
npu_conv_multiblock_test: PASS (9216 bytes matched)
npu_bandwidth_60pct_stress_test: PASS_TARGET (functional + bandwidth)
```

## RS test matrix

| Level | M | K | N | beats/row | write_beats | valid_bytes/row | row_stride | Result |
|-------|---|---|---|:---------:|:-----------:|:---------------:|:----------:|:------:|
| RS0 | 4 | 4 | 4 | 1 | 4 | 16 | 32 | PASS |
| RS1 | 8 | 8 | 8 | 1 | 8 | 32 | 32 | PASS |
| RS2 | 8 | 16 | 8 | 1 | 8 | 32 | 32 | PASS |
| RS3 | 8 | 64 | 8 | 1 | 8 | 32 | 32 | PASS |
| RS4 | 8 | 16 | 16 | 2 | 16 | 64 | 64 | PASS |
| RS5 | 8 | 16 | 32 | 4 | 32 | 128 | 128 | PASS |
| RS6 | 8 | 16 | 64 | 8 | 64 | 256 | 256 | PASS |
| RS7a | 2 | 4 | 4 | 1 | 2 | 16 | 32 | PASS |
| RS7b | 2 | 4 | 4 | 1 | 2 | 16 | 32 | PASS |
| RS7c | 1 | 4 | 4 | 1 | 1 | 16 | 32 | PASS |
| RS8a | 1 | 1 | 8 | 1 | 1 | 32 | 32 | PASS |
| RS8b | 7 | 63 | 8 | 1 | 7 | 32 | 32 | PASS |

## Unmodified critical modules

The following modules are **unchanged** in the streaming GEMM v1 implementation:

```
mac_pe.v         — PE MAC unit ($signed INT8×INT8→INT32)
mac_tile_4x4.v   — 4×4 MAC tile
array_top.v      — systolic array top
pe_cluster.v     — PE cluster (continuous_mode added in earlier baseline)
compute_core.v   — compute core (stream_active passthrough added earlier)
block_scheduler.v — task dispatch (TASK_GEMM pass-through fix earlier)
```

The PE array remains a **weight-stationary systolic array**. The row-streaming GEMM implementation is achieved through top-level control (`npu_top.v` FSM), `a_tile` skewed feeder, `c_tile` wavefront collector, and direct STORE path — all without modifying the PE array fabric.

## Commit history (test-gemm-streaming-coverage branch)

```
34952db test: fix signed INT8 golden for streaming GEMM
cbfa455 fix: support multi-beat c_tile STORE for streaming GEMM
52d1b3e Phase 2b-2: direct c_tile row-major STORE for streaming GEMM
366c862 pkg: add npu_task_gemm_row_streaming_test include
fe057b9 Phase 2b-1: GEMM row-streaming compute + c_tile collect (no STORE)
```

## Stable conclusion

**GEMM streaming v1 is a clean stable baseline.** It completes compute-to-DMA-writeback closure for M_tile≤8, K≤64, N≤64, with signed INT8 coverage and full regression PASS (UVM_ERROR=0, UVM_FATAL=0).
