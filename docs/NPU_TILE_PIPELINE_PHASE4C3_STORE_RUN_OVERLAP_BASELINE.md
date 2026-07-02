# NPU Tile Pipeline — Phase 4c-3 STORE/RUN Overlap Baseline

## Metadata

- **Commit**: `33ed9e6`
- **Base**: main `5404afa` (Phase 4c-2 GEMM store micro-FSM)
- **Branch**: `feature/npu-store-overlap-run-current`
- **Date**: 2026-07-02
- **Status**: **STORE/RUN OVERLAP IMPLEMENTED**

## Base Includes

| Phase | Commit | Description |
|-------|--------|-------------|
| Phase 4c-1 | `dfdf2a5` | c_tile double buffer |
| Phase 5-3 | `d5fc5be` | Output tile descriptor formalization |
| Phase 4c-2 | `8b33de1` | Per-beat GEMM STORE micro-FSM |
## What Phase 4c-3 Implements

Phase 4c-3 implements **STORE(previous output tile) || RUN(current output tile)**.

Before Phase 4c-3, the tile pipeline was strictly sequential:
```
RUN tile_i → STORE tile_i → RUN tile_i+1
```

After Phase 4c-3, STORE runs concurrently with the next tile's compute:
```
RUN tile_i
  → launch STORE tile_i (background)
  → immediately advance to tile_i+1
  → RUN tile_i+1 while STORE tile_i is active
```

The STORE engine continues ticking regardless of the main FSM state
(PREP / LOAD_A / LOAD_ARRAY / RUN / ACCUM), enabling the overlap.

## Architecture

### Background GST Tick

The GST micro-FSM is moved from inside `FSM_GEMM_STREAM_STORE` to an
after-case position in the main FSM always block:

```verilog
always @(posedge clk or negedge rst_n) begin
    // reset / default assignments ...

    case (fsm_state)
        // main FSM states
    endcase

    // After-case: legacy store_pack (FSM_STORE / pipe_mode)
    if (fsm_state == FSM_STORE || pipe_mode) begin ... end

    // After-case: GST background tick (Phase 4c-3)
    if (gemm_store_eng_active) begin
        case (gemm_store_eng_phase)
            GST_PUSH_BEAT / GST_START / GST_START_CLR / GST_WAIT_DONE / GST_ADVANCE
        endcase
    end
end
```

Key design properties:
1. GST remains inside the main FSM always block (no multi-driver)
2. GST ticks whenever `gemm_store_eng_active == 1`, regardless of `fsm_state`
3. Default `dma_wr_start <= 1'b0` provides automatic 1→0 pulse
4. Tile advancement is separated from GST_ADVANCE — handled in the main FSM

### Producer Done Update

Before Phase 4c-3:
```verilog
gemm_store_eng_producer_done = (fsm_state == FSM_GEMM_STREAM_STORE) &&
                                gemm_store_eng_active &&
                                (gemm_store_eng_phase == GST_START);
```

After Phase 4c-3 (fsm_state guard removed):
```verilog
gemm_store_eng_producer_done = gemm_store_eng_active &&
                                (gemm_store_eng_phase == GST_START);
```

`fsm_state == FSM_GEMM_STREAM_STORE` is removed because the STORE engine
must drive `dma_wr_start` and `producer_done` while the main FSM is in
RUN/PREP/LOAD_A/LOAD_ARRAY/ACCUM states during overlap.

Legacy `dma_producer_done_legacy` expression is preserved unchanged.

### Tile Launch Logic

**FSM_GEMM_STREAM_DONE** (tile compute complete):

```
if (!gemm_store_eng_active) {
    lock store_desc_* from current tile
    launch GST (gemm_store_eng_active = 1)

    if (has next N-tile or M-tile) {
        advance to next tile
        toggle compute_c_bank
        fsm_state = PREP  // Phase 4c-3 overlap: GST runs in background
    } else {
        fsm_state = FSM_GEMM_STREAM_STORE  // final tile: wait for STORE
    }
} else {
    gemm_store_pending = 1   // previous STORE still running
    fsm_state = FSM_GEMM_STREAM_STORE
}
```

**FSM_GEMM_STREAM_STORE** (wait state):

```
if (!gemm_store_eng_active) {
    if (gemm_store_pending) {
        lock store_desc_* for pending tile
        launch GST
        // same overlap/advance logic as above
    } else {
        task_done  // final tile STORE complete
    }
}
```

## Bank Ownership

| Signal | Driven by | Description |
|--------|-----------|-------------|
| `store_desc_bank` | STORE launch | Bank currently read by background STORE |
| `compute_c_bank` | Tile advance | Bank currently written by compute/collector |

Rules:
- `store_desc_*` locked only when `gemm_store_eng_active == 0`
- After STORE launch: `compute_c_bank <= ~compute_c_bank`
- Next tile PREP clears only new `compute_c_bank`
- Active STORE bank is never cleared while GST is running
- Active STORE descriptor is never overwritten while GST is running

## Backpressure / Pending

Phase 4c-3 supports **one outstanding STORE** (single dma_axi_writer).

If tile_i+1 compute completes while tile_i STORE is still running:
- `gemm_store_pending` is set to 1
- tile_i+1 STORE is not launched immediately
- `store_desc_*` is not overwritten (protects active GST)
- Main FSM waits in `FSM_GEMM_STREAM_STORE`
- When tile_i STORE completes (`gemm_store_eng_active == 0`):
  - Pending STORE is launched with current `store_desc_*` values
  - If next tile exists: overlap launch with PREP transition

### Test Evidence (37-test streaming suite)

| Metric | Count | Description |
|--------|:-----:|-------------|
| `GST_LAUNCH` | 56 | Total STORE launches |
| `N_TILE_OV` / `M_TILE_OV` | 16 | Overlap launches (advance to next tile while STORE runs) |
| `GST_PEND` | 7 | Backpressure events (previous STORE still active) |
| `GST_LAUNCH_PEND` | 7 | Pending STORE launches (after previous STORE completes) |
| `GST_DONE` | 56 | STORE engine completions |

## DMA Protocol

Per-beat DMA transaction sequence is unchanged from Phase 4c-2:

```
GST_PUSH_BEAT:    push beat into FIFO             (dma_wr_start=0)
GST_START:        dma_wr_start=1, producer_done=1 (1 cycle)
GST_START_CLR:    dma_wr_start=0, producer_done=0 (1 cycle)
GST_WAIT_DONE:    wait dma_wr_done                (variable)
GST_ADVANCE:      next beat / row / tile          (1 cycle)
```

- `dma_wr_start` is a 1→0 pulse (default=0, GST_START overrides to 1)
- `producer_done` aligns with GST_START (no fsm_state guard)
- `store_desc_*` used for STORE pack (not live tile descriptors)

## What Phase 4c-3 Does NOT Implement

1. No multiple outstanding STOREs (only one active)
2. No descriptor queue
3. No more than two c_tile banks
4. No dma_axi_writer modification
5. No write_beat_fifo modification
6. No N-tiling background weight prefetch restoration
7. No c_tile/acc_buffer unification
8. No STORE/STORE overlap

## Verification

| Test | Levels | Result | UVM_ERROR | UVM_FATAL |
|------|:------:|:------:|:---------:|:---------:|
| `tb_dma_writer_per_beat_protocol` | 5 | **PASS** | — | — |
| `npu_task_gemm_row_streaming_test` | 37 | **PASS** | 0 | 0 |
| `npu_task_gemm_func_test` | 6 | **PASS** | 0 | 0 |
| 7-key regression | 7 | **PASS** | 0 | 0 |

## Performance

| Metric | Phase 4c-2 | Phase 4c-3 | Delta |
|--------|:--:|:--:|:--:|
| **Overall** | 296,314 | **289,424** | **-6,890 (-2.3%)** |
| NT0 (N=128) | 2,887 | 2,299 | -588 (-20.4%) |
| NT1 (N=65) | 1,703 | 1,556 | -147 (-8.6%) |
| NT2 (N+K tiling) | 4,252 | 3,549 | -703 (-16.5%) |
| NT3 (B-by-col) | 2,887 | 2,299 | -588 (-20.4%) |
| NT4 (M+N tiling) | 5,492 | 3,726 | -1,766 (-32.2%) |
| NT5 (M+N+K) | 7,950 | 5,839 | -2,111 (-26.6%) |
| NT6 (signed boundary) | 3,877 | 3,457 | -420 (-10.8%) |

N-tiling tests benefit significantly because previous-tile STORE time is
hidden under next-tile compute. Tests with more tiles (NT4: 4 tiles,
NT5: 8 tiles) show larger improvements since more STORE time is overlapped.

MT0-MT5 and RS0-RS19 tests are single-tile or compute-bound, so they
show little to no improvement. The 2.3% overall reduction is driven
by the 7 N-tiling tests in the 37-test suite.

## Known Limitations

1. **Single outstanding STORE.** If STORE takes longer than next-tile
   compute, the pipeline stalls. A descriptor queue could mitigate this
   but is out of scope for Phase 4c-3.

2. **Background weight prefetch under N-tiling is deferred.** Foreground
   LOAD_ARRAY fallback provides correct but suboptimal weight loading
   for N>64.

3. **c_tile bank count limits overlap depth.** With only two banks,
   bank0 must be freed (STORE complete) before bank0 can be reused for
   compute on a third tile. This limits the overlap to one level.

## Next Recommended Step

**Phase 6-0: Full tile pipeline audit.**

Audit the current overlap coverage:
- LOAD_A(next) || RUN(current) — Phase 4a-3 ✅
- STORE(previous) || RUN(current) — Phase 4c-3 ✅
- B/weight prefetch under N-tiling — deferred

Then decide whether to:
- A. Polish and freeze the current streaming GEMM pipeline
- B. Resume N-tiling weight background prefetch (Phase 5-2b)
- C. Generalize tile descriptors for broader NPU operators
