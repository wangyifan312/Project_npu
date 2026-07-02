# NPU MatrixOp Phase U4-b — result_tile GST ReLU Baseline

**Phase**: U4-b — ReLU-only post-op on result_tile GST path
**Date**: 2026-07-02
**Base**: `main` `e9aff5f` (Phase U4-a merge)
**Branch**: `feature/npu-result-tile-relu-postop`

---

## 1. Phase U4-b Goals

Add ReLU post-op on the streaming MatrixOp result_tile GST path:

1. Remove `!relu_en` from `fc_streaming_en` gate
2. Add `store_desc_relu_en` — per-tile ReLU flag latched at STORE launch
3. Apply INT32 ReLU in GST_PUSH_BEAT (combinational, zero-cycle overhead)
4. Preserve INT32 output format, row_stride, dma_wr_bytes
5. Keep bias/requant on legacy path

---

## 2. RTL Changes

### 2.1 `fc_streaming_en` gate

```verilog
// Before (Phase U1):
wire fc_streaming_en = is_fc_mode && conv_cfg[5] && !bias_enabled && !relu_en;

// After (Phase U4-b):
wire fc_streaming_en = is_fc_mode && conv_cfg[5] && !bias_enabled;
```

### 2.2 `store_desc_relu_en` register

```verilog
reg store_desc_relu_en;  // latched with store_desc_* at STORE launch
```

### 2.3 Latch points (2 sites)

In `FSM_GEMM_STREAM_DONE` and `FSM_GEMM_STREAM_STORE` pending launch:
```verilog
store_desc_relu_en <= fc_streaming_en && relu_en;
```

### 2.4 GST_PUSH_BEAT ReLU

```verilog
reg signed [31:0] gst_val;
gst_val = store_desc_bank ? result_tile_bank1[...] : result_tile_bank0[...];
beat[lane*32 +: 32] = (store_desc_relu_en && gst_val[31]) ? 32'sd0 : gst_val;
```

### 2.5 Why NOT use raw `relu_en` in GST

GST is a background STORE engine. `STORE(previous)` may overlap `RUN(current)`. The post-op setting must belong to the tile being stored (locked in `store_desc_*`), not to a live global control register that may change between tiles.

---

## 3. What is Unchanged

| Component | Status |
|-----------|--------|
| Output dtype | INT32 (unchanged) |
| Beat format | 8×INT32 per 256-bit beat (unchanged) |
| `dma_wr_bytes` | `this_beat_cols * 4` (unchanged) |
| `row_stride` | `ceil(N*4/32)*32` (unchanged) |
| GST state sequence | Unchanged |
| `acc_buffer` | Preserved (legacy post-op) |
| `mac_pe` | Unchanged |
| `dma_axi_writer` | Unchanged |
| `write_beat_fifo` | Unchanged |
| Bias/requant path | Legacy only |
| Conv path | Legacy only |

---

## 4. Test Results

### FC Streaming ReLU Tests (5 levels)

| Level | M | K | N | Feature | Result | Cycles |
|-------|---|---|---|---------|--------|--------|
| RELU_MIXED | 1 | 8 | 8 | Mixed signs, relu=1 | PASS | 131 |
| RELU_ALLPOS | 1 | 8 | 8 | All-positive, relu=1 | PASS | 131 |
| RELU_BATCH | 4 | 16 | 16 | Batch M=4, mixed signs | PASS | 253 |
| RELU_NTILE | 1 | 64 | 65 | N-tiling, mixed signs | PASS | 811 |
| RELU_KCHUNK | 1 | 128 | 16 | K-chunking, mixed signs | PASS | 506 |

### Regression

| Test | Result |
|------|--------|
| FC Streaming smoke (6 levels) | 6/6 PASS |
| FC Streaming robustness (11 levels) | 11/11 PASS |
| FC Streaming fallback | PASS |
| Legacy FC smoke | PASS |
| GEMM row-streaming | 37/37 PASS |
| GEMM_FUNC | 6/6 PASS |
| 7-key regression | All PASS |

**UVM_ERROR=0, UVM_FATAL=0**

---

## 5. Cycle Impact

**Zero cycle delta** vs Phase U1-U3 baseline. ReLU is pure combinational logic (sign-bit check) with no pipeline or state overhead.

---

## 6. Path Verification

| Configuration | Path |
|:--|:--|
| FC + `conv_cfg[5]=1`, no bias, no ReLU | Streaming MatrixOp (unchanged) |
| FC + `conv_cfg[5]=1`, no bias, `relu_en=1` | **Streaming MatrixOp + store_desc_relu_en** ← NEW |
| FC + `conv_cfg[5]=1`, `bias_enabled=1` | Legacy FC (fallback unchanged) |
| FC + `conv_cfg[5]=0` | Legacy FC (fallback unchanged) |
| GEMM + `conv_cfg[5]=1` | GEMM Streaming (unchanged) |

---

## 7. Known Limitations

1. ReLU only on INT32 output. No INT8 requant.
2. Bias is not migrated (still legacy path).
3. Requant / INT8 output is not migrated.
4. Conv is not migrated.
5. `acc_buffer` remains for legacy post-op.
6. `store_desc_relu_en` only latched for FC streaming (`fc_streaming_en && relu_en`).
   GEMM ReLU not yet supported (can be added later with same mechanism).

---

## 8. Recommended Next Phase

```
Phase U4-c — bias migration audit (AUDIT ONLY)

Evaluate whether bias can be added to the result_tile GST path
using the same pattern: store_desc_bias_en + bias_reg read in GST.
```
