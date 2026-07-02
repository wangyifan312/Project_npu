# NPU MatrixOp Phase U4-a — result_tile Post-Op Migration Audit

**Phase**: U4-a — audit only, no RTL changes
**Date**: 2026-07-02
**Base**: `main` `759ec58` (Phase U3 merge)
**Branch**: `feature/npu-result-tile-postop-audit`

---

## 1. Executive Summary

经过完整审计，**推荐分阶段迁移：先做 ReLU-only (INT32)，再做 bias+requant (INT8)**。

**GST inline post-op (Option A) 是首选方案**：在 GST 读取 `result_tile_bank` 时，以组合逻辑插入 ReLU，不需要修改 beat 打包格式（保持 8×INT32/beat）。Bias 和 requant 因需要额外内存访问（bias buffer）和格式转换（INT32→INT8），应延期到后续 phase。

**最低风险起步点**：U4-b = ReLU-only on result_tile path (INT32 output)。

---

## 2. Current Post-Op Control Signals

### 2.1 bias_enabled

```verilog
// npu_top.v:235
wire bias_enabled = conv_cfg[4] && ((task_type == 3'd0) || (task_type == 3'd1));
```

- Conv (`3'd0`) or FC (`3'd1`) only — GEMM (`3'd7`) excluded.
- Controlled by `conv_cfg[4]`.

### 2.2 relu_en

```verilog
// npu_ctrl.v:638
relu_en_r <= cfg_postproc[0];
// npu_ctrl.v:710
assign relu_en = relu_en_r;
```

- From `NPU_REG_POSTPROC[0]` (addr `0x2C`).
- Can be set independently of `bias_enabled`.

**Two ReLU application points:**
1. `array_relu_final` (line 1550): `relu_en && !bias_enabled` — zeros negative accumulators at acc_buffer write time. INT32 domain.
2. `bias_add_requant_i32_to_i8` (lines 1318-1319): `bias_en_i(bias_enabled && rq_mode_internal)`, `relu_en_i(relu_en && rq_mode_internal)` — applies after bias add, before requant. INT32 domain.

### 2.3 rq_mode_internal

```verilog
// npu_top.v:1066 — reg set at FC post-op entry
reg rq_mode_internal;
```

- Set to `1'b1` when FC with `bias_enabled` enters `FSM_REQUANT_COMPUTE` (lines 3317, 3373).
- Cleared at task init (line 2228), requant standalone entry (line 2436), and STORE completion (line 4371).
- Gates `bias_en_i`, `relu_en_i` on `bias_add_requant_i32_to_i8`.
- Selects `rq_bias_q` over standalone `rq_q` (line 1288).

### 2.4 Post-Op Enabling Matrix

| Configuration | bias_enabled | relu_en | Streaming? | Path |
|:--|:--|:--|:--|:--|
| Pure FC matmul | 0 | 0 | Yes (conv_cfg[5]=1) | result_tile → GST → INT32 |
| FC + ReLU only | 0 | 1 | No (fc_streaming_en=0) | legacy acc_buffer → array_relu_final → INT32 |
| FC + bias only | 1 | 0 | No | legacy → FSM_REQUANT → INT8 |
| FC + bias + ReLU | 1 | 1 | No | legacy → FSM_REQUANT → INT8 |
| FC + bias + requant | 1 | * | No | legacy → FSM_REQUANT → INT8 |

**Key finding**: ReLU can be enabled independently of bias. When `relu_en=1, bias_enabled=0`, ReLU fires at `array_relu_final` (INT32, zeros negative accumulators). When `bias_enabled=1`, ReLU fires inside `bias_add_requant_i32_to_i8` (INT32, post-bias-add). **Requant is always coupled to bias** — no standalone FC requant path.

---

## 3. Current Legacy Post-Op Data Path

### 3.1 FC with bias (INT8 output)

```
PE array_sum_out
  → acc_buffer write (COLLECT/DRAIN, INT32 accumulator per column)
  → FSM_REQUANT_COMPUTE:
      for each output column (0..fc_tile_outputs-1):
        read INT32 from acc_buffer → acc_rd_data
        → bias_add_requant_i32_to_i8:
            acc_i  (INT32)  = acc_rd_data
            bias_i (INT32)  = bias_reg[rq_bias_idx]
            bias_en_i       = bias_enabled && rq_mode_internal
            relu_en_i       = relu_en && rq_mode_internal
            multiplier_i    = requant_multiplier  (from NPU register)
            shift_i         = requant_shift       (from NPU register)
          → biased_acc_o = acc_i + bias_i (optional)
          → post_relu_acc = relu && sign? 0 : biased_acc_o (optional, INT32)
          → requant_i32_to_i8:
              product = post_relu_acc * multiplier
              rounded = round_half_away_from_zero(product >> shift)
              q_o = clamp(rounded, -128, 127)  // INT8 signed
        → pack 4 INT8 per 32-bit word (rq_pack_idx 0-3)
        → write 32-bit word back to acc_buffer
  → FSM_STORE:
      legacy store_pack: read 32-bit words from acc_buffer
      → pack 8 words per 256-bit beat → write_beat_fifo → dma_axi_writer
      → store_bytes_active = rq_total_words (INT8 bytes) → output memory
```

### 3.2 FC without post-op (INT32 output)

```
PE array_sum_out
  → acc_buffer write (COLLECT/DRAIN, INT32)
  → FSM_STORE:
      legacy store_pack: pack 8 INT32 per 256-bit beat
      → store_bytes_active = fc_tile_outputs * 4 (INT32 bytes)
      → output memory
```

---

## 4. Current result_tile_bank STORE Path (Streaming)

```
PE array_sum_out
  → result_tile_bank0/1 (first chunk: write-once; subsequent: signed accumulate)
  → GST PUSH_BEAT:
      beat[lane*32 +: 32] = result_tile_bank[row][base_col + lane]
      packs 8 INT32 per 256-bit beat
      dma_wr_bytes = this_beat_cols * 4  (INT32 → 4 bytes per column)
      dma_wr_addr = base + row * row_stride + n_base*4 + beat*32
  → GST_START → GST_WAIT_DONE → GST_ADVANCE
  → per-beat DMA launch to dma_axi_writer
```

**No post-op logic in GST** — raw INT32 values from result_tile_bank are written directly.

---

## 5. Option A: GST Inline Post-Op (Recommended, Phased)

### Architecture

```
result_tile_bank[row][col] (INT32)
  → [optional bias fetch: bias_reg[col]]        ← Phase U4-c
  → [optional ReLU: sign? 0 : value]            ← Phase U4-b (first!)
  → [optional requant: INT32→INT8]               ← Phase U4-d
  → pack into 256-bit beat
  → write_beat_fifo → dma_axi_writer
```

### Phase U4-b: ReLU-only (INT32 output) — LOW RISK

**Change**: In GST_PUSH_BEAT, after reading `result_tile_bank[row][col]`, check sign bit. If `relu_en && value[31]`, output 0 instead.

```verilog
// Pseudocode for GST_PUSH_BEAT modification:
for (lane = 0; lane < this_beat_cols; lane = lane + 1) begin
    int32_val = store_desc_bank ? result_tile_bank1[row][base_col + lane]
                                 : result_tile_bank0[row][base_col + lane];
    beat[lane*32 +: 32] = (relu_en && int32_val[31]) ? 32'sd0 : int32_val;
end
```

**Impact**:
- Beat format unchanged: 8×INT32 = 256-bit
- `dma_wr_bytes` unchanged: `this_beat_cols * 4`
- `store_desc_row_stride` unchanged
- No new registers needed
- `relu_en` already available as wire
- No change to STORE/RUN overlap
- Pure combinational — minimal timing impact

**Gate change**: `fc_streaming_en` must allow `relu_en=1`:
```verilog
wire fc_streaming_en = is_fc_mode && conv_cfg[5] && !bias_enabled;
// Remove !relu_en — ReLU is now handled inline in GST
```

**Risk**: Low. The existing `!relu_en` gate prevents FC streaming from activating when `relu_en=1`. Removing it and adding GST ReLU is the only change.

### Phase U4-c: Bias Support (INT32 output) — MEDIUM RISK

**Additional hardware needed**:
- `bias_reg` already exists (64×INT32, line 1071)
- Need to load bias into `bias_reg` from memory (existing FSM_LOAD_BIAS path)
- GST_PUSH_BEAT: after reading INT32, add `bias_reg[store_desc_n_base + col]`
- Bias load must happen before STORE starts

**Gate change**: Remove `!bias_enabled` from `fc_streaming_en`. But bias load must complete before GST launches → need synchronization.

**Risk**: Medium. Bias values must be loaded into bias_reg before GST reads them. May require ensuring bias DMA completes before first GST_PUSH_BEAT.

### Phase U4-d: Requant INT8 Output — HIGHER RISK

**Additional hardware needed**:
- Instantiate `requant_i32_to_i8` per column (or time-multiplexed)
- Or use existing `bias_add_requant_i32_to_i8` module
- Change GST beat packing: **32×INT8 per 256-bit beat** instead of 8×INT32
- Change `dma_wr_bytes` per beat: `this_beat_cols` (1 byte/col) instead of `this_beat_cols * 4`
- Change `store_desc_row_stride`: `ceil(N/32)*32` instead of `ceil(N*4/32)*32`
- Last-beat WSTRB: handle partial beat differently
- Need `output_dtype` field in `store_desc_*`

**Risk**: Higher. Changes fundamental GST beat format assumptions. Must verify DMA writer handles 1-byte-per-column beats correctly (it does — `byte_count` and `WSTRB` are generic). But row stride and beat index calculations change.

**Alternative for U4-d**: Phase U4-d could instead introduce a `result_tile → acc_buffer` bridge (Option B variant): stream result_tile through existing requant path. This avoids modifying GST packing. But it loses STORE/RUN overlap benefit.

---

## 6. Option B: result_tile → acc_buffer Bridge — DEFERRED

**When to use**: Only if GST inline post-op for INT8 (U4-d) proves too complex.

**Mechanism**: After compute completes and result_tile is full, copy result_tile[row][col] → acc_buffer[addr] one word at a time. Then enter legacy FSM_REQUANT_COMPUTE and legacy store_pack.

**Pros**: Reuses 100% of existing post-op infrastructure.
**Cons**: Extra copy pass (~256 cycles for 64-entry tile), breaks STORE/RUN overlap for post-op cases, acc_buffer remains in critical path.

**Recommendation**: Keep as fallback. Try GST inline first.

---

## 7. Option C: Keep Post-Op Legacy — CURRENT BASELINE

Already implemented and verified. Pure FC/GEMM matmul goes through result_tile streaming; any post-op falls back to legacy acc_buffer path.

**When to stay on Option C**: If post-op latency is not critical and MatrixOp unification of pure matmul is sufficient.

---

## 8. Output Dtype Analysis

| Phase | Output | Beat format | dma_wr_bytes/col | row_stride(32B-aligned) |
|-------|--------|-------------|------------------|------------------------|
| U1-U3 (current) | INT32 | 8×INT32 → 256b | 4 | `ceil(N*4/32)*32` |
| U4-b (ReLU) | INT32 | 8×INT32 → 256b | 4 | Same |
| U4-c (bias) | INT32 | 8×INT32 → 256b | 4 | Same |
| U4-d (requant) | INT8 | 32×INT8 → 256b | 1 | `ceil(N/32)*32` |

**Key insight**: U4-b and U4-c keep INT32 output format, so no GST packing changes needed.
Only U4-d (INT8) requires format changes.

---

## 9. store_desc_* Extension Candidates (U4-d)

For INT8 output support, `store_desc_*` may need:

| Field | Width | Description |
|-------|-------|-------------|
| `output_dtype` | 1 bit | 0=INT32, 1=INT8 |
| `post_op_cfg` | 3 bit | none/ReLU/bias/bias+ReLU/bias+requant/... |
| `row_stride` | 32 bit | Already present — value changes per dtype |

For U4-b (ReLU-only): no new desc fields needed. `relu_en` already available as global wire.

---

## 10. Recommended Phased Plan

```
Phase U4-b (LOW risk, small RTL change):
  → ReLU-only on result_tile GST path
  → INT32 output format unchanged
  → Remove !relu_en from fc_streaming_en
  → Add sign-bit check in GST_PUSH_BEAT
  → 1 test: FC_STREAM_RELU

Phase U4-c (MEDIUM risk):
  → Bias support on result_tile GST path
  → INT32 output (bias is pre-requant)
  → Remove !bias_enabled from fc_streaming_en
  → Add bias_reg read in GST_PUSH_BEAT
  → Ensure bias DMA completes before first GST beat
  → 1-2 tests: FC_STREAM_BIAS, FC_STREAM_BIAS_RELU

Phase U4-d (HIGHER risk):
  → Requant INT8 output on result_tile path
  → Change GST beat format: 32×INT8/beat
  → Add output_dtype to store_desc (or use post_op_cfg to infer)
  → Change row_stride calculation
  → 2-3 tests: FC_STREAM_REQUANT_INT8, GEMM post-op (optional)
  → Fallback to Option B bridge if GST packing proves unstable
```

---

## 11. Test Plan (U4-b through U4-d)

| Phase | Test | Output | Verification |
|-------|------|--------|-------------|
| U4-b | FC_STREAM_RELU: M=4,K=64,N=64, A contains negatives | INT32, negatives zeroed | Compare vs software golden |
| U4-b | FC_STREAM_RELU negative: all-negative inputs | INT32 all zeros | Verify ReLU clamping |
| U4-c | FC_STREAM_BIAS: M=1,K=16,N=16, bias={1,2,3,...} | INT32 with bias offset | Per-column golden |
| U4-c | FC_STREAM_BIAS_RELU: bias+negatives | INT32, ReLU after bias | Combined golden |
| U4-d | FC_STREAM_REQUANT: M=1,K=16,N=16, mult=1,shift=0 | INT8 | Byte-level golden |
| U4-d | FC_STREAM_REQUANT_CLAMP: values >127 or <-128 | INT8 clamped [-128,127] | Clamp verification |
| U4-d | Legacy fallback comparison: legacy post-op vs streaming post-op matched | Same output | Cross-path verify |

---

## 12. Blockers and Preconditions

### No blockers for U4-b

- `relu_en` wire already available
- GST already has per-column access to result_tile values
- INT32 output unchanged → no packing/stride changes
- Existing `fc_streaming_en` gate only needs `!relu_en` removed

### Precondition for U4-c

- Bias load must complete before GST reads result_tile
- May need to add bias load FSM state in streaming pipeline (or reuse existing)
- `bias_reg` must be populated with correct per-column values

### Precondition for U4-d

- Requant multiplier/shift must be available as wires
- GST beat packing must be extended for INT8 format
- row_stride must be computed per dtype
- Need to verify WSTRB behavior for partial last beat (32 bytes vs 8 bytes boundary)

---

## 13. Decision Matrix

| Option | Risk | RTL Change | Benefit | Recommended |
|--------|:----:|:----------:|--------|:-----------:|
| A (GST inline, phased) | Low→High | Progressive | Unified path, keeps STORE/RUN overlap | **YES** — start with U4-b |
| B (acc_buffer bridge) | Low | Medium | Reuses legacy post-op | Fallback for U4-d |
| C (legacy fallback) | Zero | None | Zero risk | Current baseline |

**Final recommendation**: Start U4-b (ReLU-only on result_tile GST path). It is a small, low-risk change that validates the GST-inline-post-op approach. If U4-b passes, proceed to U4-c (bias). Reserve U4-d and Option B for after bias is stable.

---

## 14. Conclusion

```
Phase U4-b recommended as next coding phase:
  → Add ReLU to GST micro-FSM (combinational, INT32)
  → Remove !relu_en from fc_streaming_en gate
  → Add FC_STREAM_RELU test
  → No format/packing/stride changes
  → Risk: LOW
```
