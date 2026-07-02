# NPU MatrixOp Phase U4-d — result_tile INT8 Packing Baseline

**Phase**: U4-d — INT8 output_dtype + GST_INT8 packing infrastructure
**Date**: 2026-07-02
**Base**: `main` `06b860b` (Phase U4-c merge)
**Branch**: `feature/npu-result-tile-int8-pack`

---

## 1. Phase U4-d Goals

Add INT8 output format support to the result_tile GST path as infrastructure.
No bias, no requant, no arithmetic post-op — only beat packing format validation.

1. Add `store_desc_output_dtype` (0=INT32, 1=INT8)
2. GST supports dual-format beat packing (8×INT32 or 32×INT8 per 256-bit beat)
3. Correct `dma_wr_bytes`, `row_stride`, and address per output_dtype
4. N-tiling with last partial beat handling
5. No changes to dma_axi_writer, write_beat_fifo, or legacy paths

---

## 2. RTL Changes

### Files Modified

| File | Change |
|------|--------|
| `rtl/npu/npu_top.v` | `store_desc_output_dtype` + GST dual-format packing |
| `rtl/npu/npu_ctrl.v` | Extend `conv_cfg` mask 0x3f→0x7f (bit[6] internal hook) |

### New Signals

```verilog
// npu_top.v
reg store_desc_output_dtype;  // 0=INT32 (default), 1=INT8
wire int8_test_hook = fc_streaming_en && conv_cfg[6];  // internal test hook
```

### Latch Points (2 sites, same as store_desc_relu_en)

```verilog
store_desc_output_dtype <= int8_test_hook;
```

### GST_PUSH_BEAT Dual-Format

```
INT32: beat_cols_max=8,  base_col=beat_idx*8,  n_base_addr={n_base,2'b0}
       8 values × 32-bit → 256-bit beat
       dma_wr_bytes = this_beat_cols * 4

INT8:  beat_cols_max=32, base_col=beat_idx*32, n_base_addr=n_base
       32 values × 8-bit → 256-bit beat
       dma_wr_bytes = this_beat_cols
```

### GST_ADVANCE

```verilog
beats_per_row = store_desc_output_dtype ?
                ceil(N/32) : ceil(N/8)
```

### row_stride

```verilog
store_desc_row_stride = int8_test_hook ?
    ceil(N/32)*32 : ceil(N*4/32)*32
```

---

## 3. INT8 Path Trigger

- `conv_cfg[6]` = internal test hook (NOT a public CSR)
- Only active when `fc_streaming_en=1` (FC mode, streaming enabled, no bias)
- `conv_cfg` mask extended from `0x3F` to `0x7F` in `npu_ctrl.v`
- Default: `conv_cfg[6]=0` → all paths remain INT32

---

## 4. INT8 Byte Source

```
INT8 byte = result_tile_bank[row][col][7:0]
```

This is infrastructure-only truncation from INT32. It does NOT implement:
- Numerical requantization (multiplier/shift)
- Bias add
- Saturation/clamp
- Zero-point
- Rounding

INT8 output is for packing format and addressing validation only.

---

## 5. What is NOT Changed

| Component | Status |
|-----------|--------|
| `dma_axi_writer.v` | Unchanged |
| `write_beat_fifo.v` | Unchanged |
| `mac_pe.v` | Unchanged |
| `acc_buffer` | Preserved |
| Legacy FC path | Unchanged |
| FC bias/requant | Still legacy |
| Conv path | Unchanged |
| GEMM path | Unchanged (always INT32) |
| Default FC streaming output dtype | INT32 (unchanged) |
| Public CSR | No new CSR added |

---

## 6. Test Results (npu_fc_streaming_int8_pack_test)

| Level | M | K | N | Feature | Result | Cycles |
|-------|---|---|---|---------|--------|--------|
| INT8_BASIC | 1 | 8 | 8 | Basic INT8 pack | PASS | 131 |
| INT8_NTILE | 1 | 64 | 65 | N-tiling, last partial beat | PASS | 811 |
| INT8_KCHUNK | 1 | 128 | 16 | K>64 accumulation + INT8 | PASS | 495 |
| INT8_BATCH | 4 | 16 | 16 | Multi-row INT8 | PASS | 209 |

### Regression

| Test | Result |
|------|--------|
| FC Streaming ReLU | 5/5 PASS |
| FC Streaming smoke | 6/6 PASS |
| FC Robustness | 11/11 PASS |
| Legacy FC | PASS |
| GEMM row-streaming | 37/37 PASS |
| GEMM_FUNC | 6/6 PASS |
| Conv smoke | PASS |

**UVM_ERROR=0, UVM_FATAL=0**

---

## 7. Cycle Impact

INT8 packing: zero cycle delta vs INT32 for same workload (same GST state sequence, different beat count but same overall throughput). For N=8: INT32 uses 1 beat, INT8 also uses 1 beat — no difference.

---

## 8. Known Limitations

1. INT8 byte = INT32[7:0] only. No requantization.
2. Bias is not supported on INT8 path.
3. Requant is not supported on INT8 path.
4. Trigger requires `conv_cfg[6]` (internal test hook, not public CSR).
5. FC default output remains INT32.
6. Legacy FC bias/requant path unchanged.
7. acc_buffer not removed.

---

## 9. Recommended Next Phase

```
Phase U4-e:
    bias_tile_bank + requant descriptor design/audit
    (may involve additional audit before coding)
```
