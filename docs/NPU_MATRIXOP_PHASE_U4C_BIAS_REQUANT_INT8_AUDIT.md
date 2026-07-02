# NPU MatrixOp Phase U4-c — Bias + Requant + INT8 Output Migration Audit

**Phase**: U4-c — audit only, no RTL changes
**Date**: 2026-07-02
**Base**: `main` `a86c424` (Phase U4-b merge)
**Branch**: `feature/npu-result-tile-bias-postop-audit`

---

## 1. Executive Summary

**Bias 和 requant 强绑定**：`bias_enabled=1` 必然进入 `FSM_REQUANT_COMPUTE`，输出 INT8。不存在 "bias-only INT32 output" 的硬件路径。

**GST inline full post-op 可行但需要 U4-d（INT8 GST packing）+ U4-e（bias/requant tile buffer）两个子阶段**。先在 audit 中完整评估风险，再决定是否进入 coding。

**推荐分阶段**：U4-d 先做 INT8 output descriptor + GST_INT8 packing（无 post-op），验证 INT8 beat 格式和 row_stride；U4-e 再加 bias/requant。

**近期不建议删除 FC legacy path** — 需要 U4-d/U4-e coding 稳定 + 全量 regression 后才能 cleanup audit。

---

## 2. Current Legacy Bias/Requant Semantics

### 2.1 Control Signals

```verilog
// npu_top.v:235 — bias only for Conv(3'd0) and FC(3'd1), not GEMM(3'd7)
wire bias_enabled = conv_cfg[4] && ((task_type == 3'd0) || (task_type == 3'd1));

// npu_ctrl.v:638 — ReLU from NPU_REG_POSTPROC[0]
relu_en_r <= cfg_postproc[0];

// npu_ctrl.v — requant multiplier/shift from NPU registers
// addr 0x60-0x7C: requant_slot_sel, requant_multiplier, requant_shift
// These are per-layer parameters (not per-channel)
```

### 2.2 Bias + Requant Are Strongly Coupled

| Condition | FSM State | Output Format |
|-----------|-----------|:---:|
| `bias_enabled=1` | `FSM_REQUANT_COMPUTE` | INT8 |
| `bias_enabled=0` | `FSM_STORE` (direct) | INT32 |

**No path exists for "bias-only INT32 output" in current RTL.** `bias_enabled=1` always routes through `bias_add_requant_i32_to_i8` → `FSM_REQUANT_COMPUTE` → INT8 packing → INT8 output.

### 2.3 Bias Data

- **Type**: Per-output-channel INT32 (not per-element)
- **Count**: `output_c` elements (N)
- **Storage**: `bias_reg[0:PE_COLS-1]` — 64×INT32 global register file
- **Index**: `rq_bias_idx = fc_or_gemm ? rq_src_idx[5:0] : (rq_src_idx % output_c)` (line 1312-1313)
- **Load**: From memory via `bias_addr` → `FSM_LOAD_BIAS` → `FSM_BIAS_WAIT` → `FSM_BIAS_EXTRACT`
- **Layout**: INT32 array, offset by `fc_out_start * 4` for FC (line 1401)

### 2.4 Requant Parameters

- **multiplier**: `requant_multiplier` — 32-bit unsigned, per-layer
- **shift**: `requant_shift` — 6-bit, per-layer
- **Formula**: `q = clamp(round_half_away_from_zero(acc * multiplier / 2^shift), -128, 127)`
- **Module**: `requant_i32_to_i8` — 1 lane, combinational
- **Combined module**: `bias_add_requant_i32_to_i8` — bias add + ReLU + requant, 1 lane, combinational

---

## 3. Current Legacy Bias/Requant Data Path

```
1. FSM_COMPUTE (CP_COLLECT/CP_DRAIN):
   PE array_sum_out → acc_buffer write (INT32, per output column)

2. FSM_REQUANT_COMPUTE:
   For each output column (0..fc_tile_outputs-1):
     acc_rd_data = acc_buffer[addr]          (INT32)
     → bias_add_requant_i32_to_i8:
         acc_i    = acc_rd_data              (INT32)
         bias_i   = bias_reg[rq_bias_idx]     (INT32)
         bias_en  = bias_enabled && rq_mode_internal
         relu_en  = relu_en && rq_mode_internal
         multiplier = requant_multiplier
         shift      = requant_shift
       → biased_acc = acc_i + bias_i         (INT32, optional)
       → post_relu  = relu ? max(0, biased_acc) : biased_acc (INT32)
       → requant: rounded → clamp [-128,127] → INT8
     → Pack 4 INT8 per 32-bit word (rq_pack_idx 0→3)
     → Write word back to acc_buffer

3. FSM_STORE:
   store_pack: read 32-bit words from acc_buffer
   → Pack 8 words → 256-bit beat → write_beat_fifo → dma_axi_writer
   → store_bytes_active = rq_store_bytes (= fc_tile_outputs, INT8 bytes)
   → store_words_active = (fc_tile_outputs + 3) >> 2 (INT8 packed 4:1)
   → dma_wr_bytes = fc_tile_outputs (INT8 — not *4!)
```

Key observations:
- **Bias/ReLU/requant is applied AFTER accumulator read from acc_buffer** — not inline with PE output
- **INT8 packing is done in 4:1 ratio** within FSM_REQUANT_COMPUTE, before store_pack
- **store_pack always reads 32-bit words** — the INT8 data is already packed into 32-bit containers
- **dma_wr_bytes differs**: INT32 = N*4 bytes, INT8 = N bytes

---

## 4. result_tile_bank GST Feasibility for Full Post-Op

### 4.1 Target Data Path

```
result_tile_bank[row][col] (INT32)
  → [optional: bias_reg[n_base + col]]      ← bias add (INT32)
  → [optional: ReLU — sign bit check]        ← ReLU (INT32)
  → [optional: requant_i32_to_i8]            ← requant (INT32→INT8)
  → pack into 256-bit beat                   ← different: 32×INT8 vs 8×INT32
  → write_beat_fifo → dma_axi_writer
```

### 4.2 GST_PUSH_BEAT Feasibility for INT8 Packing

| Aspect | Current (INT32) | Target (INT8) |
|--------|:---:|:---:|
| Values per beat | 8 | 32 |
| this_beat_cols max | 8 (cols per beat) | 32 (cols per beat) |
| dma_wr_bytes | this_beat_cols * 4 | this_beat_cols * 1 |
| row_stride | ceil(N*4/32)*32 | ceil(N/32)*32 |
| Beat address offset | beat_idx << 5 (= *32) | beat_idx << 5 (= *32, same!) |
| n_base offset in address | {n_base, 2'b0} (= n_base*4) | n_base (= n_base*1) |
| Last beat partial | cols%8 partial INT32 | cols%32 partial INT8 |

**The GST state machine structure (push → start → wait → advance) is compatible with INT8 packing.** The per-beat DMA protocol is format-agnostic — only the column count per beat and byte calculations differ.

### 4.3 Required Descriptor Fields

```verilog
// Existing (unchanged):
reg [15:0] store_desc_M;          // rows in tile (max 8)
reg [15:0] store_desc_N;          // columns in tile (max 64)
reg [31:0] store_desc_base_addr;  // output base address
reg [31:0] store_desc_row_stride; // bytes between rows (dtype-dependent)
reg        store_desc_bank;       // which result_tile bank
reg        store_desc_relu_en;    // U4-b: per-tile ReLU

// New (Phase U4-d for INT8, U4-e for bias/requant):
reg        store_desc_output_dtype; // 0=INT32, 1=INT8
reg        store_desc_bias_en;      // enable per-column bias add
reg        store_desc_requant_en;   // enable INT32→INT8 requant
reg [31:0] store_desc_requant_mult; // per-tile requant multiplier
reg [5:0]  store_desc_requant_shift;// per-tile requant shift
reg [15:0] store_desc_n_base;       // already exists — OK for bias indexing

// Bias buffer (per-tile, double-buffered for STORE/RUN overlap):
reg signed [31:0] bias_tile_bank0 [0:63]; // 64 × INT32 = 256 bytes
reg signed [31:0] bias_tile_bank1 [0:63];
reg               bias_tile_bank;         // which bank to use
```

**Why all post-op config must be in store_desc (not live global signals):**
GST is a background STORE engine. `STORE(previous)` can overlap `RUN(current)`. The `bias_reg`, `requant_multiplier`, and `requant_shift` are live global signals that can change between tiles. Locking them into `store_desc_*` at STORE launch time ensures tile-consistent post-op — the same pattern already proven by `store_desc_relu_en` in Phase U4-b.

---

## 5. Bias Data Lifecycle — Critical Risk

### 5.1 Current bias_reg is a Global Singleton

```verilog
reg signed [31:0] bias_reg [0:PE_COLS-1];  // 64 elements, global
```

- **Loaded**: In `FSM_LOAD_BIAS` → `FSM_BIAS_EXTRACT`, before compute starts
- **Overwritten**: Only when loading bias for a NEW task or a new Conv channel
- **Read**: During `FSM_REQUANT_COMPUTE`, indexed by `rq_bias_idx`

### 5.2 STORE/RUN Overlap Risk

If FC streaming with bias uses `store_desc_bias_en`:
- **STORE launches** with `store_desc_n_base=0` → bias indices [0,63]
- **RUN(next) starts** with `gemm_tile_n_base=64` → may need bias indices [64,127]
- **But bias_reg only holds 64 elements!**

For FC with N>64 (N-tiling):
- Tile 0 (n_base=0): bias[0..63] needed → already in `bias_reg` from initial load
- Tile 1 (n_base=64): bias[64..127] needed → NOT in `bias_reg`

**Problem**: The GST for Tile 0 may still be running when Tile 1 compute starts. If Tile 1 loads new bias[64..127] into `bias_reg`, Tile 0's GST would read wrong bias values.

### 5.3 Mitigation: bias_tile_bank Double Buffer

**Recommended solution**: Add `bias_tile_bank0/1` — 2 banks × 64 × INT32.

```
bias_tile_bank0[0:63]  — for tile at n_base=0
bias_tile_bank1[0:63]  — for tile at n_base=64 (or next N-tile)
```

**Flow**:
1. Before first STORE launch: load bias[0..63] into `bias_tile_bank0`
2. If N>64: load bias[64..127] into `bias_tile_bank1` (can be background DMA while Tile 0 runs)
3. GST reads: `bias_tile_bank{store_desc_bias_bank}[store_desc_n_base + local_col]`
4. Toggle `bias_tile_bank` at N-tile boundaries (same as `compute_result_bank`)

**Size cost**: 2 × 64 × 32-bit = 512 bytes of flip-flops. Acceptable.

**Alternative**: Single bias_tile (no overlap). Simpler but loses STORE/RUN overlap for N>64 bias workloads. Risk: GST stalls while waiting for bias reload.

---

## 6. Requant Parameter Lifecycle

### 6.1 Current Params are Global

```verilog
wire [31:0] requant_multiplier;  // from NPU registers, per-layer
wire [5:0]  requant_shift;       // from NPU registers, per-layer
```

### 6.2 STORE/RUN Overlap Risk

Same as bias: if RUN(current) changes `requant_multiplier` or `requant_shift` mid-task, STORE(previous) would use wrong parameters.

**Mitigation**: Lock `requant_multiplier` and `requant_shift` into `store_desc_*` at STORE launch, same pattern as `store_desc_relu_en`.

### 6.3 Per-Channel Requant

Current RTL uses **per-layer** requant (single multiplier/shift for all output channels). If per-channel requant is needed, a 64-element parameter tile (similar to bias_tile) would be required. This is **NOT in scope** for Phase U4.

---

## 7. INT8 GST Packing Feasibility

### 7.1 Current Beat Assembly (INT32)

```verilog
// 8 INT32 per beat
base_col = gemm_store_beat_idx << 3;    // beat_idx * 8
this_beat_cols = min(8, store_desc_N - base_col);
for (lane = 0; lane < this_beat_cols; lane++)
    beat[lane*32 +: 32] = result_tile_bank[row][base_col + lane];
dma_wr_bytes = this_beat_cols * 4;
```

### 7.2 Proposed Beat Assembly (INT8)

```verilog
// 32 INT8 per beat
base_col = gemm_store_beat_idx << 5;    // beat_idx * 32
this_beat_cols = min(32, store_desc_N - base_col);
for (lane = 0; lane < this_beat_cols; lane++) begin
    int32_val = result_tile_bank[row][base_col + lane];
    // optional bias add
    // optional ReLU
    // requant: int32_val → int8_val
    beat[lane*8 +: 8] = int8_val;
end
dma_wr_bytes = this_beat_cols;  // 1 byte per column
```

### 7.3 Address Calculation Changes (INT8)

| Component | INT32 | INT8 |
|-----------|-------|------|
| n_base in address | `{n_base, 2'b0}` (= n_base*4) | `n_base` (= n_base*1) |
| Beat offset | `beat_idx << 5` (= beat_idx*32) | `beat_idx << 5` (= beat_idx*32, same) |
| row_stride | `ceil(N*4/32)*32` | `ceil(N/32)*32` |
| Last beat partial | `min(8, N - base)` | `min(32, N - base)` |

### 7.4 Requant Parallelism

Current `requant_i32_to_i8` is 1-lane combinational (synthesizes to ~4 DSP + mux). For GST_INT8, we need 32 lanes in parallel. This is feasible:
- 32 × requant_i32_to_i8 instances → ~128 DSPs
- Or time-multiplexed: 4 cycles × 8 lanes → ~32 DSPs
- Or use existing `bias_add_requant_i32_to_i8` (1 lane) iteratively — breaks GST per-beat timing

**Recommendation**: Static 32-lane instantiation for simplicity. Area ~128 DSPs is acceptable for a single compute unit.

---

## 8. dma_axi_writer and write_beat_fifo Compatibility

### 8.1 write_beat_fifo

- Currently: depth 64, 256-bit data, `wr_strb = {32{1'b1}}` (all bytes valid)
- For INT8: same 256-bit data width. FIFO doesn't care about element dtype — it stores bits.
- **Compatible as-is.** ✅

### 8.2 dma_axi_writer

- `byte_count` parameter: already accepts arbitrary 32-bit count
- `calc_wstrb`: generates correct WSTRB for any `valid_bytes` from 1 to 32
- Short beats: `valid_bytes_this_beat = min(bytes_left, 32)` — handles partial last beat
- **Compatible as-is.** ✅

**No changes needed to dma_axi_writer or write_beat_fifo for INT8 support.**

---

## 9. Option Assessment

### Option A: GST Inline Full Post-Op (RECOMMENDED, Phased)

| Sub-phase | Scope | Risk | Dependencies |
|-----------|-------|:----:|-------------|
| U4-d | INT8 output_dtype + GST_INT8 packing (no post-op) | Medium | store_desc_output_dtype |
| U4-e | bias_tile_bank + store_desc_bias_en + store_desc_requant_en | Medium-High | U4-d + bias_tile double buffer |
| U4-f | Full FC bias+ReLU+requant INT8 end-to-end | Medium | U4-d + U4-e |

**Pros**: Cleanest architecture, keeps STORE/RUN overlap, eliminates acc_buffer from FC path.
**Cons**: Moderate RTL changes, needs careful bias lifecycle management.

### Option B: result_tile → acc_buffer Bridge

**Pros**: Reuses 100% of legacy post-op.
**Cons**: Extra copy cycle (~256 per tile), breaks STORE/RUN overlap, doesn't simplify architecture.

**Recommendation**: Keep as fallback if U4-d/U4-e proves too complex.

### Option C: Keep Bias/Requant Legacy (CURRENT)

**Pros**: Zero risk.
**Cons**: FC post-op unification incomplete, legacy FC path cannot be removed.

---

## 10. Blockers

| Blocker | Severity | Mitigation |
|---------|:--------:|-----------|
| bias_reg is global singleton, can be overwritten during STORE/RUN overlap | **HIGH** | bias_tile_bank double buffer |
| INT8 GST packing changes this_beat_cols, dma_wr_bytes, row_stride | **MEDIUM** | store_desc_output_dtype |
| requant 32-lane parallelism | **MEDIUM** | Static 32-lane instantiation |
| N-tiling bias index (n_base > 63) | **MEDIUM** | bias_tile_bank[0:63], bank toggle at N-tile boundary |
| Per-channel requant not supported | LOW | Out of scope; use per-layer params |

**No blockers for dma_axi_writer or write_beat_fifo** — both already handle arbitrary byte counts and partial beats.

---

## 11. Recommended Phased Plan

```
Phase U4-d (MEDIUM risk):
  → Add store_desc_output_dtype
  → Add GST_INT8 packing mode (32×INT8 per 256-bit beat)
  → No bias, no requant — pure INT32→INT8 truncation or simple clamp
  → Change dma_wr_bytes and address per output_dtype
  → 3-4 tests: INT8 basic, NTILE, KCHUNK, last partial beat
  Goal: Validate INT8 GST packing before adding arithmetic post-op.

Phase U4-e (MEDIUM-HIGH risk):
  → Add bias_tile_bank0/1 double buffer
  → Add store_desc_bias_en, store_desc_requant_en
  → Lock requant_multiplier, requant_shift into store_desc
  → Load bias tile before STORE launch (or background DMA)
  → Add bias + requant in GST_INT8 packing loop
  → 3-4 tests: bias+INT8, bias+ReLU+INT8, NTILE bias, KCHUNK bias

Phase U4-f (LOW risk, integration):
  → End-to-end FC bias+ReLU+requant INT8 verification
  → Matched comparison: legacy FC post-op vs streaming post-op
  → Full regression
```

---

## 12. Test Plan (Future)

| Phase | Test | Verification |
|-------|------|-------------|
| U4-d | FC_STREAM_INT8_BASIC: M=1,K=16,N=16 | INT8 bytes correct, row_stride correct |
| U4-d | FC_STREAM_INT8_NTILE: N=65 | Last partial beat WSTRB correct |
| U4-d | FC_STREAM_INT8_KCHUNK: K=128 | Cross-chunk INT8 output |
| U4-e | FC_STREAM_BIAS_INT8: M=1,K=16,N=16, bias={1,2,...} | Per-column bias offset correct |
| U4-e | FC_STREAM_BIAS_RELU_INT8: bias + ReLU | Negative post-bias values zeroed |
| U4-e | FC_STREAM_REQUANT_SAT: values >127 | Clamp to 127 verified |
| U4-f | FC_STREAM_FULL_POSTOP: bias+ReLU+requant | End-to-end vs software golden |
| U4-f | Legacy vs streaming matched comparison | Cross-path output equivalence |

---

## 13. Should FC Legacy Path Be Removed?

**NOT YET.** Removal requires:

1. ✅ FC pure matmul on MatrixOp path (Phase U1-U3)
2. ✅ FC ReLU-only on MatrixOp path (Phase U4-b)
3. ❌ FC bias+requant INT8 on MatrixOp path (not yet implemented)
4. ❌ FC matched comparison: all modes (not yet)
5. ❌ Cleanup audit: confirmed no FC dependency on acc_buffer (not yet)
6. ❌ Full regression (not yet)

**Earliest possible**: After Phase U4-f completion + cleanup audit (Phase U5).

---

## 14. Conclusion

```
Phase U4-d recommended as next phase:
  → INT8 output_dtype + GST_INT8 packing (no post-op)
  → Validates INT8 beat format and address computation
  → Keeps bias/requant on legacy path during this phase
  → Risk: MEDIUM — GST loop and descriptor changes, but no arithmetic complexity

Phase U4-e follows:
  → bias_tile_bank + bias/requant in GST_INT8 loop
  → Risk: MEDIUM-HIGH — bias lifecycle management critical

dma_axi_writer and write_beat_fifo: NO CHANGES NEEDED.
```
