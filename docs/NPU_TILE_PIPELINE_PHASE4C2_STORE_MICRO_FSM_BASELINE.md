# NPU Tile Pipeline — Phase 4c-2 GEMM Store Micro-FSM Baseline

## Metadata

- **Commit**: `8b33de1`
- **Base**: main `da48b42`
- **Branch**: `feature/npu-store-engine-per-beat`
- **Date**: 2026-07-02
- **Status**: **GEMM STORE MICRO-FSM INTEGRATED**

## Base Includes

| Phase | Commit | Description |
|-------|--------|-------------|
| Phase 4c-1 | `dfdf2a5` | c_tile double buffer |
| Phase 5-3 | `d5fc5be` | Output tile descriptor formalization |
| DMA audit | `bbc771a` | NPU store DMA protocol audit |
| Phase 4c-2a | `6c41470` | DMA writer per-beat protocol characterization |
| dma_producer_done | `dd0fe44` | Legacy OR GEMM producer_done structure |

## What Phase 4c-2 Implements

Phase 4c-2 replaces the inline FSM_GEMM_STREAM_STORE path with a per-beat
GEMM STORE micro-FSM integrated inside the main FSM always block.

The previous inline STORE (`FSM_GEMM_STREAM_STORE` → `6'd39` wait state) is
replaced by 5 micro-states multiplexed under `FSM_GEMM_STREAM_STORE` via
`gemm_store_eng_phase`.

## STORE Micro-States

```
localparam GST_PUSH_BEAT  = 3'd0;  // Pack beat, push FIFO, set addr/bytes
localparam GST_START      = 3'd1;  // dma_wr_start=1, producer_done valid
localparam GST_START_CLR  = 3'd2;  // dma_wr_start returns to 0 (default)
localparam GST_WAIT_DONE  = 3'd3;  // Wait dma_wr_done
localparam GST_ADVANCE    = 3'd4;  // Advance beat/row or finish tile
```

### State Semantics

```
GST_PUSH_BEAT:
    Pack c_tile_bank[store_desc_bank][row][col:col+7] → 256-bit beat.
    Push beat into write_beat_fifo (dma_wr_valid_r=1).
    Pre-compute dma_wr_addr and dma_wr_bytes.
    dma_wr_start stays 0 (default, not overridden).
    If !wf_wr_full → GST_START. Else stall.

GST_START:
    dma_wr_start <= 1'b1  (overrides default=0).
    dma_wr_started <= 1'b1.
    dma_wr_valid_r <= 1'b0.
    producer_done valid this cycle (gemm_store_eng_producer_done).
    → GST_START_CLR.

GST_START_CLR:
    dma_wr_start returns to 0 (no override — default assignment clears it).
    dma_wr_started stays 1.
    → GST_WAIT_DONE.

GST_WAIT_DONE:
    Wait for dma_wr_done from dma_axi_writer.
    On done: clear dma_wr_started, → GST_ADVANCE.
    On error: clear gemm_store_eng_active, → FSM_ERROR.

GST_ADVANCE:
    Advance beat within row, row within tile, or finish tile.
    More beats in row → GST_PUSH_BEAT.
    More rows in tile → GST_PUSH_BEAT.
    Tile complete: clear gemm_store_eng_active, tile advancement
    (N-tile → M-tile → DONE, same logic as Phase 5-2).
```

## Design Constraints

1. **No independent GST always block.** The micro-FSM runs inside the
   existing main FSM always block (`case (fsm_state) ... FSM_GEMM_STREAM_STORE: case (gemm_store_eng_phase) ...`).

2. **Zero multi-driver.** All `dma_wr_*` and `gemm_store_eng_*` signals
   are driven by a single always block. No separate GST always block.

3. **dma_axi_writer.v unchanged.** Writer protocol is per-beat Scheme B
   (1 transaction per beat) as characterized in Phase 4c-2a.

4. **write_beat_fifo unchanged.** Depth 64, no structural changes.

5. **STORE remains sequential.** No overlap between STORE and next tile
   compute. Phase 4c-3 will add STORE(previous) || RUN(current).

6. **c_tile and acc_buffer remain separated.** STORE reads from c_tile
   bank; compute writes to c_tile bank via collector.

## DMA Protocol: Per-Beat Transaction

Each 256-bit beat is an independent DMA transaction:

```
GST_PUSH_BEAT:    push beat into FIFO             (dma_wr_start=0)
GST_START:        dma_wr_start=1, producer_done=1 (1 cycle)
GST_START_CLR:    dma_wr_start=0, producer_done=0 (1 cycle)
GST_WAIT_DONE:    wait dma_wr_done                (variable)
GST_ADVANCE:      next beat / row / tile          (1 cycle)
```

### Critical Timing Rules

- `dma_wr_start` must be a 1→0 pulse. The default assignment
  `dma_wr_start <= 1'b0` at the top of the always block ensures
  automatic clearing. Only GST_START overrides to 1.
- `dma_axi_writer S_DONE → S_IDLE` requires `start == 0`.
- `producer_done` aligns with GST_START (1-cycle pulse).
- FIFO push happens 1 cycle before dma_wr_start, ensuring
  `eff_level >= 1` when writer enters S_WAIT_DATA.

## Descriptor Usage

STORE path uses locked store descriptor (Phase 5-3):

| Signal | Width | Description |
|--------|-------|-------------|
| `store_desc_m_base` | 16 | Tile global row start |
| `store_desc_n_base` | 16 | Tile global col start |
| `store_desc_M` | 16 | Tile rows |
| `store_desc_N` | 16 | Tile columns |
| `store_desc_base_addr` | 32 | Output block base address |
| `store_desc_row_stride` | 32 | Row stride = align32(N * 4) |
| `store_desc_bank` | 1 | c_tile bank to read |

Live tile descriptors (`gemm_tile_*`, `compute_c_bank`) are NOT used for
STORE pack. They are only used for tile advancement decisions.

## Producer Done Connection

```verilog
wire gemm_store_eng_producer_done;
assign gemm_store_eng_producer_done = (fsm_state == FSM_GEMM_STREAM_STORE) &&
                                       gemm_store_eng_active &&
                                       (gemm_store_eng_phase == GST_START);

assign dma_producer_done = gemm_store_eng_producer_done ||
                            dma_producer_done_legacy;
```

The legacy expression (`FSM_STORE`, `FSM_PIPE_RUN`, `FSM_VEC_RELU_PROC`)
is preserved unchanged.

## Signal Summary

| Signal | Width | Driven by | Description |
|--------|-------|-----------|-------------|
| `gemm_store_eng_active` | 1 | Main FSM always block | STORE engine active flag |
| `gemm_store_eng_phase` | 3 | Main FSM always block | Current micro-state |
| `gemm_store_row_idx` | 16 | Main FSM always block | Current STORE row (legacy, unused in micro-FSM) |
| `gemm_store_beat_idx` | 16 | Main FSM always block | Current STORE beat (legacy, unused in micro-FSM) |

Note: `gemm_store_row_idx` and `gemm_store_beat_idx` are retained from the
inline STORE baseline but are not actively used by the micro-FSM (which uses
`store_desc_*`). They are kept for compatibility and may be cleaned up later.

## What Phase 4c-2 Does NOT Implement

- STORE overlap (Phase 4c-3)
- Background STORE concurrent with compute
- DMA writer modifications
- write_beat_fifo modifications
- acc_buffer widening (separate project)

## Verification

| Test | Levels | Result | UVM_ERROR | UVM_FATAL |
|------|:------:|:------:|:---------:|:---------:|
| `tb_dma_writer_per_beat_protocol` | 5 | **PASS** | — | — |
| `npu_task_gemm_row_streaming_test` | 37 | **PASS** | 0 | 0 |
| `npu_task_gemm_func_test` | 6 | **PASS** | 0 | 0 |
| 7-key regression | 7 | **PASS** | 0 | 0 |

### STORE Engine Activity Confirmed

- `[GST]` messages: 2,678 (confirmed micro-FSM active in all tests)
- `[DIR_ST]` messages: 0 (confirmed old inline path NOT used)
- `gemm_store_eng_active` toggled correctly
- DMA write transactions: 1,339 completed, 0 errors

## Cycle Impact

| Metric | Baseline (inline) | Micro-FSM | Delta |
|--------|:--:|:--:|:--:|
| Total cycles | 293,688 | 296,314 | +2,626 |
| Relative | — | — | **+0.89%** |

The overhead comes from explicit GST_START and GST_START_CLR states
(~2 cycles/beat) that were previously collapsed into the inline
FSM_GEMM_STREAM_STORE state. At 1,339 beats, this accounts for the
2,678-cycle delta. This is acceptable for the structural clarity gained.

## Known Limitations

1. **Legacy counter signals** (`gemm_store_row_idx`, `gemm_store_beat_idx`)
   are retained but unused by the micro-FSM. They remain for compatibility
   and will be cleaned up in a future naming pass.

2. **No STORE overlap.** The main FSM blocks in FSM_GEMM_STREAM_STORE until
   all beats/rows of the current tile are stored. Phase 4c-3 will overlap
   STORE with next-tile compute.

3. **Cycles increase by ~0.9%.** The explicit START/START_CLR states add
   2 cycles per beat. For Phase 4c-3, the absolute STORE time becomes
   invisible when overlapped with compute.

## Next Step

**Phase 4c-3: STORE(previous output tile) || RUN(current output tile)**

Phase 4c-3 should build on:
- c_tile double buffer (Phase 4c-1)
- Locked store_desc_* (Phase 5-3)
- Per-beat STORE micro-FSM (Phase 4c-2)
- `gemm_store_eng_active` / `gemm_store_eng_phase` separation

The key challenge is: concurrent background STORE engine (accessing c_tile
bank N) + foreground compute pipeline (writing c_tile bank ~N) with proper
bank handoff at tile boundaries.
