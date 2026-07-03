# NPU Tile Pipeline — Phase 4c STORE Overlap Plan

## 1. Current Output Path Audit

### 1.1 Streaming GEMM Output Path

```
RUN (wavefront collector)
  └─ c_tile[m][n] += array_sum_out[n*32 +: 32]   (K-chunk accumulation)
       └─ FSM_GEMM_STREAM_DONE (after all K-chunks)
            └─ FSM_GEMM_STREAM_STORE
                 └─ Pack c_tile[row][base_col:N×8] → 256-bit beat
                      └─ write_beat_fifo (depth 64)
                           └─ dma_axi_writer (AXI4 256-bit write)
                                └─ Memory
```

### 1.2 c_tile Structure

```verilog
// Single buffer — no double-buffering
reg signed [31:0] c_tile [0:7][0:63];       // 8 rows × 64 columns, INT32
reg               c_tile_valid [0:7][0:63];  // write-once tracking (chunk0)
```

Writes: FSM_GEMM_STREAM_RUN, wavefront collector (lines 3817-3824)
- First chunk: write-once (`if (!c_tile_valid[m][n])`)
- Subsequent chunks: signed accumulate (`c_tile += array_sum_out`)
Clears: FSM_GEMM_STREAM_PREP, first_chunk only
Reads: FSM_GEMM_STREAM_STORE (line 3986: `c_tile[gemm_store_row_idx][base_col+lane]`)

### 1.3 acc_buffer Status

```verilog
// Still present — 1024 entries × 32-bit, dual bank
u_acc_buffer (...)
```

Services legacy paths:
- FC (non-streaming): acc_buffer → store_pack → DMA writer
- Conv: acc_buffer → store_pack → DMA writer
- Requant: rq_acc_wr_* → acc_buffer
- Add/GAP: add_acc_wr_* / gap_acc_wr_* → acc_buffer

NOT used by streaming GEMM (c_tile direct store bypasses acc_buffer).

### 1.4 Why NOT Merge c_tile and acc_buffer Now

| Reason | Detail |
|--------|--------|
| c_tile supports wavefront multi-point writes | Collector writes [m][n] at arbitrary cycle offsets |
| c_tile supports K>64 accumulation | Read-modify-write with signed accumulation |
| acc_buffer services 5+ legacy paths | FC, Conv, Requant, Add, GAP, Pool |
| Merging would touch both streaming and legacy | High regression risk |
| Phase 4c goal is STORE overlap | Not global result buffer refactor |

**Recommendation**: Keep separate. Long-term plan:
```
Short-term:  c_tile_bank[2] for streaming GEMM STORE overlap
Mid-term:    Abstract c_tile_bank as result_tile_bank
Long-term:   Unified result_tile_buffer framework (c_tile + acc_buffer + col_results)
```

### 1.5 DMA Writer Parallelism Capability

`dma_axi_writer` is an independent module with its own FSM:
```
- Reads from write_beat_fifo (wf_rd_en, wf_rd_data, wf_rd_valid)
- Writes to AXI4 bus (m_axi_aw/w/b, m_axi_w)
- producer_done input: indicates producer finished; writer drains remaining beats
- Can run in background — not tied to main FSM state
- write_beat_fifo depth=64: provides buffering decoupling
```

**Key insight**: Once beats are pushed into `write_beat_fifo`, the DMA writer
runs autonomously. The main FSM doesn't need to wait for each beat's DMA
transaction to complete — it only needs to know when the FIFO has room.

### 1.6 STORE Critical Path Analysis

Current STORE implementation:
1. FSM_GEMM_STREAM_DONE → FSM_GEMM_STREAM_STORE (1 cycle)
2. STORE: pack 1 beat from c_tile, push to FIFO, start DMA (1 cycle)
3. Wait state (6'd39): wait for dma_wr_done (N cycles, DMA latency)
4. Next beat or next row or DONE
5. After all rows: task_done_r=1, → FSM_DONE

For N=4 (1 beat per row): ~M × (1+1+~10 DMA cycles) per row.
For N=64 (8 beats per row): ~M × 8 × ~12 cycles.

Total STORE time: typically 10-20% of total task time for small N,
but could be significant for larger N.

### 1.7 Key Finding: STORE vs RUN Overlap Scope

**Critical insight**: For a SINGLE streaming GEMM task, STORE happens AFTER
all K-chunks complete. There is no more compute to overlap with.

The STORE overlap is only meaningful for:
1. **Multi-tile GEMM** (N > 64, or M > 8): COMPUTE tile i+1 while STORE tile i
2. **Multi-block workloads** (P3 FSM_PIPE_RUN): COMPUTE next block while STORE current
3. **Back-to-back tasks**: STORE task i while NPU starts task i+1

None of these are currently supported in streaming GEMM (gemm_row_streaming_en
path). P3 FSM_PIPE_RUN is Conv-only.

**Consequence**: Phase 4c STORE overlap CANNOT provide cycle benefit for the
current single-tile streaming GEMM regression tests (RS0-RS19).

**BUT**: The c_tile double-buffer structure and background store
micro-sequencer are essential prerequisites for multi-tile and multi-block
support. They should be built now as infrastructure.

---

## 2. Phase 4c Design

### 2.1 c_tile Double Buffer

```verilog
reg signed [31:0] c_tile_bank0 [0:7][0:63];
reg signed [31:0] c_tile_bank1 [0:7][0:63];
reg               c_tile_valid_bank0 [0:7][0:63];
reg               c_tile_valid_bank1 [0:7][0:63];

reg        c_tile_compute_bank;   // collector writes this bank
reg        c_tile_store_bank;     // store reads this bank
reg        c_tile_bank_valid;     // compute bank has valid data
```

### 2.2 Bank Ownership

```
RUN:
    collector writes c_tile_bank[compute_bank]
    clear c_tile_valid on first chunk only

STORE:
    pack from c_tile_bank[store_bank]
    push beats to write_beat_fifo
    after all rows: store_done

Ownership rules:
    1. compute_bank ≠ store_bank during overlap
    2. compute_bank written only by collector
    3. store_bank read only by store engine
    4. bank_valid set after all K-chunks accumulated into compute_bank
```

### 2.3 Store Descriptor (metadata needed for background STORE)

Current inline metadata (computed in FSM_GEMM_STREAM_STORE):
- `gemm_store_row_idx`: current row being stored
- `gemm_store_beat_idx`: current beat within row
- `blk_out_addr`: output base address
- `gemm_M_val`: number of output rows
- `gemm_N_val`: number of output columns
- `row_stride_bytes = (N*4 + 31) & ~31`: row stride (32B aligned)

For background store, these need to be latched into a descriptor:

```verilog
reg [31:0] store_out_base_addr;
reg [15:0] store_M;
reg [15:0] store_N;
reg [31:0] store_row_stride;
reg [15:0] store_row_idx;
reg [15:0] store_beat_idx;
reg        store_bank;
reg        store_active;
reg        store_done;
```

### 2.4 Background Store Micro-sequencer

```verilog
localparam ST_IDLE  = 2'd0;
localparam ST_PACK  = 2'd1;  // pack beat, push to FIFO
localparam ST_WAIT  = 2'd2;  // wait for DMA done (if needed)

reg [1:0]  store_phase;
```

Behavior:
1. IDLE → PACK: pack `c_tile_bank[store_bank][row][col:col+7]` → beat → FIFO
2. PACK → WAIT if DMA per-beat ack needed, else → PACK for next beat
3. WAIT → PACK (next beat) or IDLE (done)
4. When all rows stored: store_done=1

### 2.5 write_beat_fifo Backpressure

If `wf_wr_full` during PACK: stall. Don't push. Wait for DMA writer to drain.

```verilog
if (wf_wr_full) begin
    // stall in PACK, don't advance
    store_phase <= ST_PACK;
end
```

---

## 3. Recommended Staged Implementation

### Phase 4c-1: c_tile double buffer (sequential, no overlap)

**Goal**: Add c_tile_bank[2], still store sequentially after all chunks.

- Replace `c_tile[0:7][0:63]` with `c_tile_bank0` + `c_tile_bank1`
- Collector writes to `c_tile_compute_bank`
- STORE reads from `c_tile_store_bank` (= compute_bank)
- No overlap: compute_bank = store_bank
- Store still inline in FSM_GEMM_STREAM_STORE

**Verification**: RS0-RS19 PASS, GEMM_FUNC PASS. No cycle change expected.

### Phase 4c-2: Background store micro-sequencer (still sequential)

**Goal**: Extract STORE into independent engine, but still trigger sequentially.

- Add store descriptor registers
- Add store micro-sequencer (IDLE/PACK/WAIT)
- FSM_GEMM_STREAM_DONE launches store_microsequencer (store_active=1)
- Store engine reads c_tile_bank[store_bank], packs, pushes to FIFO
- Main FSM waits for store_done before task_done

**Verification**: Functional equivalence. All beat/row/stride correct for N=4/8/16/32/64.

### Phase 4c-3: STORE(previous) || RUN(current) — requires multi-tile

**Goal**: True overlap, but ONLY meaningful with multi-tile support.

- Requires c_tile_bank[2] + store descriptor + background engine (from 4c-1, 4c-2)
- COMPUTE tile i into bank0, STORE bank1
- COMPUTE tile i+1 into bank1, STORE bank0
- **Dependency**: Needs multi-tile (N>64 or M>8) or P3 FSM_PIPE_RUN for streaming GEMM

**Verification**: Would need multi-tile streaming GEMM tests (not in current regression).

**NOTE**: For current single-tile streaming GEMM (all RS tests), Phase 4c-3 provides
ZERO cycle benefit because STORE happens after all chunks when no compute remains.

---

## 4. Test Plan

### Phase 4c-1
```
RS0-RS19: 24/24 PASS — c_tile double buffer correctness
RS4/RS5/RS6: N=16/32/64 multi-beat STORE
RS10: K=512 c_tile accumulation across 8 chunks
RS17/RS18/RS19: non-uniform B + signed + K boundary
GEMM_FUNC 6/6 PASS
```

### Phase 4c-2
```
Same as 4c-1 plus:
- Verify store beats match expected per-row beat count
- Verify output bytes match golden per-row/col
- Verify store_done timing
```

### Phase 4c-3 (multi-tile only)
```
New multi-tile streaming GEMM tests:
- N=128 (2 tiles, overlap STORE tile0 || COMPUTE tile1)
- Guard region check around tile boundaries
```

---

## 5. Risk Assessment

| Risk | Severity | Mitigation |
|------|:--------:|------------|
| STORE reads wrong bank | **MED** | Bank ownership check before STORE |
| c_tile_valid tracking across banks | **MED** | Clear valid on first chunk for correct bank only |
| DMA writer backpressure stalls store engine | **LOW** | FIFO depth 64 provides buffering |
| write_beat_fifo full drops beat | **LOW** | Stall in PACK phase |
| N=64 multi-beat STORE with double buffer | **MED** | Beat-level row/col indexing verified |
| STORE incomplete when task_done asserted | **HIGH** | store_done must gate task_done |
| Legacy FC/Conv path affected | **LOW** | Guard with gemm_row_streaming_en |
| Phase 4c-3 no benefit for current tests | **INFO** | Infrastructure for future multi-tile |
| DUAL_HIT input/weight prefetch signals conflict | **LOW** | Prefetch uses different read ports |

---

## 6. Decision: Scope of Phase 4c

Given that:
1. STORE overlap provides zero benefit for current single-tile streaming GEMM
2. Multi-tile support is a prerequisite for STORE overlap to matter
3. c_tile double-buffer + background store engine are useful infrastructure

**Recommendation**: Phase 4c-1 (c_tile double buffer) should proceed as
infrastructure. Phase 4c-2 (background store engine) is also useful.
Phase 4c-3 (STORE overlap) should be deferred until multi-tile support exists.

Alternatively, the entire Phase 4c could be deferred in favor of:
- Phase 5: Multi-tile streaming GEMM (N>64, M>8)
- Then Phase 4c-3: STORE overlap with multi-tile

---

## 7. Next Steps

1. Phase 4c-1: c_tile double buffer (infrastructure, no benefit yet)
2. Phase 5: Multi-tile streaming GEMM (N>64, M>8)
3. Phase 4c-3: STORE overlap with multi-tile
