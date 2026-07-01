# NPU Tile Pipeline — Phase 4b Weight Prefetch / Staging Plan

## 1. Audit Summary

### 1.1 Current B Weight Load Path

```
weight_addr (memory)
    └─ wgt_dma (DMA read, AXI4 256-bit)
         └─ wgt_buffer (1024×256-bit, 2 banks)
              └─ FSM_LOAD_ARRAY: unpack beats → wgt_load_reg
                   └─ FSM_WGT_LD: array_weight_ld=1 → PE.weight_reg
                        └─ mac_pe: product = act_reg × weight_reg
```

Key signals:
- `wgt_load_reg`: 64×64×8 bits = 32Kbit register array (one 8-bit weight per PE)
- `array_weight`: combinational bus driven by wgt_load_reg
- `array_weight_ld`: pulsed only in FSM_WGT_LD (1 cycle)
- `weight_ld` (in PE): latches `weight` into `weight_reg` when high

### 1.2 PE Weight Latch (mac_pe.v:26-35)

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        weight_reg <= 8'h0;
    end else begin
        if (weight_ld)           // ← ONLY update condition
            weight_reg <= weight;
    end
end
```

`weight_reg` is the ONLY weight storage in the PE. The product uses `weight_reg`:
```verilog
assign product = $signed(act_reg) * $signed(weight_reg);
```

**Key property**: `array_weight` bus may change at any time. The PE DOES NOT
latch it unless `weight_ld=1`. The MAC product uses the registered value,
not the input wire.

### 1.3 array_weight_ld Timing (npu_top.v:1232)

```verilog
assign array_weight_ld = (fsm_state == FSM_WGT_LD);
```

`array_weight_ld` is HIGH only during `FSM_WGT_LD` (1 cycle).
During `FSM_GEMM_STREAM_RUN`, `array_weight_ld = 0`.

**Conclusion**: Writing `wgt_load_reg` during RUN does NOT change PE.weight_reg.
The PEs are weight-stationary during RUN.

### 1.4 FSM_LOAD_ARRAY Behavior (npu_top.v:2555-2638)

For FC/GEMM path, `FSM_LOAD_ARRAY` unpacks bytes from `wgt_buffer` into
`wgt_load_reg` using a beat-level micro-sequencer:

```verilog
// For each byte in wgt_buffer (fc_tile_outputs × fc_chunk_inputs bytes):
fc_lane_out_idx = lane_idx / fc_chunk_inputs;      // output column
fc_lane_row_idx = lane_idx % fc_chunk_inputs;       // K row within chunk
fc_lane_byte_sel = wgt_dma_byte_idx + lane_offset;  // byte in beat
wgt_load_reg[(row * PE_COLS + out_col)*8 +: 8] <= hb_beat_byte(wgt_rd_data, byte_sel);
```

Address computation uses `fc_in_base` to select the K slice:
```
fc_load_buf_byte_idx = out_idx * input_c + fc_in_base + row_idx
fc_weight_beat_addr = (fc_load_buf_byte_idx + wgt_dma_byte_offset) >> 5
```

**Key property**: `FSM_LOAD_ARRAY` is NOT tied to any particular FSM state.
It just needs `wgt_load_phase`, `wgt_load_wait`, `fc_chunk_inputs`,
`fc_tile_outputs`, `fc_in_base`, and `input_c`. It reads from `wgt_rd_data`.

### 1.5 wgt_buffer Read Port Availability

During `FSM_GEMM_STREAM_RUN`:
```verilog
assign wgt_rd_addr = (fsm_state == FSM_BIAS_EXTRACT) ? ... :
                     (fsm_state == FSM_ADD_COMPUTE)   ? ... :
                     (is_fc_mode && LOAD_ARRAY)       ? fc_weight_beat_addr :
                     fc_shadow_active                 ? fc_shadow_beat_addr :
                     wgt_mac_addr;  // default
```

In RUN, none of the special conditions match. `wgt_rd_addr = wgt_mac_addr`
(Conv weight address, unused for GEMM streaming). The wgt_buffer IS being
read (to `wgt_rd_data`), but nobody consumes `wgt_rd_data` during RUN.

**Conclusion**: wgt_buffer read port CAN be used for background weight staging
during RUN by adding a prefetch condition to the `wgt_rd_addr` mux.

### 1.6 B Weight DMA Scope

```verilog
wgt_dma_bytes = (fc_tile_outputs * input_c) + offset;
```

For GEMM: `fc_tile_outputs = min(64, N)`, `input_c = K`.
This loads the **full** B[tile][0..K-1][0..N_tile-1] into wgt_buffer.

For K>64: all K rows are loaded in one DMA. FSM_LOAD_ARRAY for each chunk
reads a different K slice using `fc_in_base` (0, 64, 128, ...).

**Conclusion**: No additional weight DMA is needed for K-chunk streaming.
The full B matrix is already in wgt_buffer.

---

## 2. Key Decision: 方案 A vs 方案 B

### 方案 A: Reuse wgt_load_reg as next weight staging

**Feasibility assessment**:

| Condition | Status |
|-----------|:------:|
| PE.weight_reg holds B current during RUN | ✅ (latched in WGT_LD) |
| array_weight_ld = 0 during RUN | ✅ (only FSM_WGT_LD) |
| Writing wgt_load_reg during RUN safe | ✅ (PEs use weight_reg) |
| array_weight bus changes during RUN safe | ✅ (product uses weight_reg) |
| wgt_buffer read port free during RUN | ✅ (wgt_mac_addr unused) |
| Full B matrix in wgt_buffer | ✅ (single DMA loads all K) |
| fc_in_base selects correct K slice | ✅ (per-chunk value) |

**Verdict**: **方案 A IS VIABLE**. wgt_load_reg can be safely overwritten
during RUN to stage the next chunk's weights.

**Advantages**:
- Minimal RTL changes
- Reuses existing wgt_load_reg (no new storage)
- Background loader is similar to existing FSM_LOAD_ARRAY
- At chunk boundary: just WGT_LD (skip LOAD_ARRAY)

**Risks**:
- Must ensure background loader doesn't conflict with foreground LOAD_ARRAY
  (they run in different FSM states: background during RUN, foreground during
  LOAD_ARRAY state) → no conflict
- Background loader needs independent phase/row/col counters

### 方案 B: New weight staging bank

Only needed if 方案 A were infeasible. Not recommended given the analysis above.

---

## 3. Phase 4b Recommended Staged Implementation

### Phase 4b-1: Weight staging (sequential, no overlap)

Goal: Add a background `weight_stage_loader` micro-sequencer, verify it can
correctly unpack B weights from wgt_buffer into wgt_load_reg, but still run
it sequentially (after RUN, before WGT_LD). Essentially a drop-in replacement
for foreground LOAD_ARRAY.

- Add `weight_prefetch_*` registers (phase, row, col, active, done, k_base, k_tile, n_base, n_tile)
- Add `wgt_rd_addr` override for weight prefetch
- Replace foreground LOAD_ARRAY call with background loader (sequential)
- Same functionality, different implementation

**Verification**: RS0-RS16 PASS, GEMM_FUNC PASS. No cycle improvement expected.

### Phase 4b-2: RUN(current) || LOAD_B(next)

Goal: Run the weight background loader during FSM_GEMM_STREAM_RUN,
alongside the input tile prefetch.

- Trigger weight prefetch at start of RUN (same cycle as input prefetch)
- Weight prefetch reads from wgt_buffer, writes to wgt_load_reg
- Input prefetch reads from act_buffer, writes to input_tile_bank[~compute_bank]
- Both run concurrently with compute (act_rd and wgt_rd ports are independent)

**Key constraint**: both background micro-sequencers must complete before
the compute finishes (or stall ACCUM).

### Phase 4b-3: ACCUM hit skip LOAD_ARRAY

Goal: When both input AND weight are prefetched, skip both LOAD_A and LOAD_ARRAY.

```
ACCUM:
    if input_bank_valid && weight_stage_valid:
        // Both prefetched
        set compute_bank
        copy wgt_stage → wgt_load_reg? (no, wgt_load_reg already has it)
        skip LOAD_A
        skip LOAD_ARRAY  
        → WGT_LD → PREP → RUN
    elif input hit only:
        → LOAD_ARRAY → ... (existing path)
    else:
        → LOAD_A → LOAD_ARRAY → ... (fallback)
```

Actually, since the background loader writes DIRECTLY to wgt_load_reg,
there's no separate staging bank. The wgt_load_reg already contains the
next chunk's weights at the end of RUN. So we just skip LOAD_ARRAY:

```
ACCUM:
    if input_hit && weight_done:
        → WGT_LD → PREP → RUN  (skip both LOAD_A and LOAD_ARRAY!)
    elif input_hit:
        → LOAD_ARRAY → WGT_LD → ... (skip only LOAD_A)
    else:
        → LOAD_A → LOAD_ARRAY → ... (full fallback)
```

---

## 4. Test Plan

| Test | K | Chunks | Expected Behavior |
|------|---|:---:|------|
| RS9 | 128 | 2 | 1 input hit + 1 weight hit = skip both LOAD_A & LOAD_ARRAY |
| RS10 | 512 | 8 | 7 input hits + 7 weight hits, 0 stalls |
| RS11 | 128, N=16 | 2 | Weight staging covers N=16 tile |
| RS12 | 65 | 2 | Last chunk K_tile=1, weight staging correct |
| RS14 | 128 | 2 | Non-uniform A + weight prefetch |
| RS15 | 65 | 2 | K=65 boundary + weight prefetch |
| RS16 | 128 | 2 | Signed + weight prefetch |

Full regression: 7/7 UVM tests

---

## 5. Risk Assessment

| Risk | Severity | Mitigation |
|------|:--------:|------------|
| wgt_load_reg written during RUN affects PE | **LOW** | Verified: weight_ld=0, PE uses weight_reg |
| Background loader conflicts with foreground LOAD_ARRAY | **LOW** | Run in different FSM states |
| wgt_rd_addr mux selects wrong source | **LOW** | Priority: foreground LOAD_ARRAY > weight prefetch |
| wgt_load_phase reuse by background loader | **MED** | Use independent counters (wpref_phase, wpref_row, wpref_col) |
| GEMM_FUNC legacy path affected | **LOW** | Guard with gemm_row_streaming_en |
| Conv/FC path affected | **LOW** | Weight prefetch only active in GEMM streaming RUN |
| K=65 boundary weight staging | **LOW** | Same chunk-sizing logic as foreground LOAD_ARRAY |
| N=16/32/64 large tile staging | **MED** | wgt_load_reg is 64×64; verify all N tile outputs staged |
| Input + weight prefetch compete for cycles | **LOW** | Independent read ports (act_buffer vs wgt_buffer) |

---

## 6. Next Steps

1. **Phase 4b-0** (this document): audit complete → 方案 A recommended
2. **Phase 4b-1**: weight staging sequential (verify correctness)
3. **Phase 4b-2**: RUN || LOAD_B(next) overlap
4. **Phase 4b-3**: ACCUM hit skip LOAD_ARRAY
