# NPU STORE DMA Protocol Audit

## 1. Write Path Structure

```
FSM_GEMM_STREAM_STORE (npu_top.v)
  → pack c_tile_bank[store_desc_bank][row][col:col+7] → 256-bit beat
  → dma_wr_data_r / dma_wr_valid_r = 1 (1-cycle pulse)
  → write_beat_fifo (depth 64)
  → wf_rd_data / wf_rd_valid / wf_rd_en
  → dma_axi_writer
  → AXI4 W channel (256-bit INCR burst, up to 16 beats)
  → shared memory
```

## 2. dma_wr_start Semantics

**Per-beat transaction trigger.**

```
dma_wr_start = 1:
    writer enters S_IDLE → S_WAIT_DATA
    latches dma_wr_addr (beat address)
    latches dma_wr_bytes (beat byte count, e.g. 4×8=32 for N=8)

writer waits for FIFO to accumulate data (eff_level >= beats_in_burst)
    → S_AW → S_WDATA → S_WAIT_B → S_DONE (dma_wr_done=1)

dma_wr_start must be cleared (0) for writer to exit S_DONE → S_IDLE
    (line 372: `if (!start) state <= S_IDLE`)
```

RTL evidence:
- Line 228: `if (start)` in S_IDLE latches `byte_count`, `base_addr`, enters S_WAIT_DATA
- Line 372: `if (!start) state <= S_IDLE` exits S_DONE
- Line 429: `busy = (state != S_IDLE)`

**Conclusion: dma_wr_start is per-beat. Each beat needs its own start=1→start=0 pulse.**

## 3. dma_wr_bytes Semantics

**Beat-level byte count, NOT row-level or tile-level.**

Current usage: `dma_wr_bytes = this_beat_cols * 4` (e.g., 32 for N=8, 4 for N=1 last tile).

The writer uses this to:
- Compute burst_len = min(16, ceil(bytes/BEAT_BYTES))
- Track bytes_remaining across multi-beat bursts
- Compute wstrb for the last beat

## 4. dma_wr_addr Semantics

**Beat-aligned AXI address for the first beat of this transaction.**

32-byte aligned (BEAT_BYTES_LOG2 = 5 for 256-bit).

## 5. producer_done Semantics

**"Producer has finished pushing ALL data for this transaction."**

Used in S_WAIT_DATA:
```
if eff_level >= beats_in_burst → start write (FIFO has enough data)
elif producer_done && eff_level > 0 → start with partial data (tail)
elif producer_done && eff_level == 0 && bytes_remaining > 0 → ERROR (underflow)
```

For per-beat transactions: `producer_done` should pulse when the store engine has pushed the beat.

Currently: `producer_done` is driven by combinational condition in FSM_STORE/FSM_PIPE_RUN.
For GEMM streaming: `(fsm_state == FSM_GEMM_STREAM_STORE)` checks... actually stream store doesn't use producer_done in the inline path because each beat is a separate transaction with separate dma_wr_start.

## 6. write_beat_fifo

```
write_beat_fifo #(64) — depth 64 entries of 256-bit
wf_wr_full — backpressure signal
wf_rd_level — current fill level (for S_WAIT_DATA threshold)
```

FIFO depth 64 is more than adequate for 1 row (max 8 beats).
No near-full signal; only full. Must check `wf_wr_full` before push.

## 7. Current Inline STORE Pattern

**Per-beat DMA transaction (Scheme B: 1 txn per beat).**

```
FSM_GEMM_STREAM_STORE (current, per beat):
    GST_PACK_beat:
        pack c_tile[row][col:col+7] → beat
        if !wf_wr_full:
            dma_wr_data_r = beat
            dma_wr_valid_r = 1 (1 cycle)
            if !dma_wr_started:
                dma_wr_start = 1
                dma_wr_addr = row_addr + beat_offset
                dma_wr_bytes = this_beat_cols * 4
                dma_wr_started = 1
            → wait state (6'd39)
        else: stall

    Wait state (6'd39):
        dma_wr_valid_r = 0
        if dma_wr_done:
            dma_wr_started = 0
            dma_wr_start = 0  (CLEAR for next beat)
            next beat or next row or tile advancement
```

**Key: dma_wr_start MUST be cleared to 0 after each beat's done.**
The writer checks `if (!start)` to exit S_DONE.

## 8. Recommended Phase 4c-2 Implementation

### Per-beat Background STORE Engine

```
for each row in store_desc_M:
    for each beat in ceil(store_desc_N / 8):
        pack beat from c_tile_bank[store_desc_bank][row][col:col+7]
        if !wf_wr_full:
            push to FIFO
            if !dma_wr_started:
                dma_wr_start = 1
                dma_wr_addr = store_desc_base_addr + (store_desc_m_base + row) *
                              store_desc_row_stride + beat_offset
                dma_wr_bytes = min(store_desc_N - beat*8, 8) * 4
                dma_wr_started = 1
            wait dma_wr_done
            dma_wr_start = 0
            dma_wr_started = 0
        else: stall on FIFO full
    next beat
next row
store_done = 1
```

**Compared to Phase 4c-2 attempt: the missing piece was clearing `dma_wr_start=0` after each beat's done.** This was NOT done in the previous attempt (only `dma_wr_started` was cleared, not `dma_wr_start` itself).

### producer_done handling

For per-beat transactions, `producer_done = 1` after the beat is pushed to FIFO.
The writer uses this for tail detection (last partial beat of a burst).
For single-beat transactions (N≤8, one beat), the entire transaction is one beat → `producer_done` is not strictly needed when `dma_wr_bytes` already defines the exact byte count.

### writer busy guard

Before starting a new beat transaction, MUST check that the writer is not busy.
Current inline code uses `dma_wr_started` as a local guard, not `dma_wr_busy`.
For background engine, can use same `dma_wr_started` approach.

## 9. task_done Timing

Current: task_done after ALL rows of ALL tiles stored. This means the last beat's dma_wr_done must be received before task_done.

For background engine: `store_done` must NOT be set until ALL beats for ALL rows have been pushed AND the last dma_wr_done is received.

## 10. Risk Assessment

| Risk | Mitigation |
|------|-----------|
| dma_wr_start not cleared → writer stuck in S_DONE | Clear start after each beat done |
| FIFO full → beat dropped | Check wf_wr_full, stall |
| Last partial tile col count wrong | Use store_desc_N for beat count |
| writer busy when start asserted | dma_wr_started guard |
| task_done before last beat complete | Wait store_done + FIFO empty |
| N=65 last tile 1 col WSTRB wrong | dma_wr_bytes=4 → writer calc_wstrb handles it |

## 11. Test Plan

```
RS0-RS19: baseline
MT0-MT5: M-tiling
NT0-NT6: N-tiling
RS6: N=64, 8 beats/row
NT1: N=65, last tile 1 col
NT6: M=9, N=65 boundary
GEMM_FUNC, full 7/7 regression
```

## 12. Verdict

**Phase 4c-2 is feasible.** The key fix from the failed attempt:
1. **Clear `dma_wr_start=0` after each beat's done** (was missing)
2. Use store_desc_* for all STORE operations
3. Handle wf_wr_full backpressure

No dma_axi_writer modification needed.
