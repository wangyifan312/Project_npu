# GEMM Row-Streaming Global Review — Phase 0

**Date**: 2026-06-30  
**Scope**: System-level review of all data paths for continuous row-streaming GEMM on existing weight-stationary 64×64 PE array  
**Principle**: Do NOT modify PE/array interconnect. Optimize feeder/scheduler/collector.

---

## 1. Input Data Path Review

### 1.1 A[M,K] Memory → act_buffer

**Path**: `shared_ram → AXI read → act_read_path → act_buffer`

- `act_read_path.v`: Simple DMA wrapper. 256-bit AXI read beats streamed sequentially into act_buffer.
- `act_buffer` (`npu_buffer.v`): Double-buffer, 1024 entries × 256-bit per bank = 32KB per bank.
- A[M,K] is stored sequentially in byte order: A[0,0], A[0,1], ..., A[0,K-1], A[1,0], ...
- `act_feed_ptr` increments by 1 byte per cycle during Conv feed. For FC/GEMM, `cf_act_data` is a single byte extracted via `hb_beat_byte(act_rd_data, act_byte_sel)`.

### 1.2 Current act_buffer Read Capability

| Property | Value | Implication |
|----------|-------|-------------|
| Read ports | **1** (synchronous, 1-cycle latency) | Only one 256-bit beat per cycle |
| Bytes per beat | 32 (256-bit) | Can extract up to 32 bytes/cycle from one beat |
| Current extraction | **1 byte/cycle** (`hb_beat_byte`) | Wasteful — 31/32 bytes unused |
| Address granularity | Byte (`act_feed_ptr`) | Can address any byte within 32KB |
| Read latency | 1 cycle (`act_feed_wait`) | Pipelined read possible |

### 1.3 Feeder Architecture

**Current `act_held[0:63]` mechanism**:

```
CF_FEED_ACT: For comp_feed_cnt = 0..K-1:
    act_held[comp_feed_cnt] <= cf_act_data    // latch one byte per cycle
    array_act_in[comp_feed_cnt] = cf_act_data // drive current row directly

CP_DRAIN:
    array_act_in[ai] = act_held[ai]  // all rows static
```

**Key limitations for row-streaming**:

1. **Single-byte feed**: Only ONE `cf_act_data` value per cycle. For row-streaming with K_tile=64, we need up to 64 independent bytes per cycle (one per PE row).

2. **Static hold during DRAIN**: `act_held[]` freezes during DRAIN. Cannot feed new row's activations while previous row's partial sums are still propagating.

3. **Sequential feed only**: `comp_feed_cnt` increments 0,1,2,...,K-1. For continuous streaming, we need to feed new values periodically.

### 1.4 Answers to Input Path Questions

**Q1: A[M,K] 当前如何从 memory 读入？**
A: DMA → act_buffer, sequential byte order. One `act_dma_start` loads the entire `blk_in_bytes = M*K` bytes.

**Q2: A 是不是目前只支持一行 A[m,:] 进入 act_held？**
A: Yes. `act_held[0:K-1]` holds exactly one row `A[m,0:K-1]`. Updated during FEED_ACT, static during DRAIN.

**Q3: act_buffer 是否能支持按 A[m,k] 随机/斜向读取？**
A: Partially. `act_feed_ptr` can address any byte position. But only ONE read per cycle. To get A[t-k, k] for all k simultaneously would require up to K independent reads.

**Q4: 当前 act feeder 是否每拍只能提供一个 row_feed_val？**
A: **YES**. `cf_act_data = hb_beat_byte(act_rd_data, act_byte_sel)` — exactly one byte per cycle.

**Q5: 当前每拍最多能给多少个 PE row 提供新的 activation？**
A: **One**. Only the row matching `comp_feed_cnt` gets fresh data per cycle during FEED_ACT. During DRAIN, zero rows get new data.

**Q6: 若实现 row-streaming，是否需要多读口、banking、prefetch、line buffer 或 local A_tile？**
A: **Yes, need local A_tile buffer**. The choices are:
- **Option A (recommended)**: Local `A_tile[M_tile][K_tile]` register/SRAM. Preload from act_buffer once, then feed with parallel readout.
- Option B: Multi-bank act_buffer with parallel read ports — requires major buffer redesign.
- Option C: Pre-compute skewed pattern and interleave in act_buffer — complex, inflexible.

**Q7: B[K,N] 当前是否能一次预加载到 PE weight_reg？**
A: **YES**, when K_tile ≤ 64 and N_tile ≤ 64. Weight path: DMA → wgt_buffer → wgt_load_reg[64×64×8b] → WGT_LD pulse → PE[k,n].weight_reg.

**Q8: K>64 时 B chunk 如何切换？**
A: `fc_chunk_inputs = min(input_c, 64)`. Multiple K-chunks: load chunk 0 weights → compute → accumulate partial sums in acc_buffer → load chunk 1 weights → compute → accumulate → ...

**Q9: N>64 时 N tile 如何切换？**
A: Not currently supported for GEMM. `fc_tile_outputs` caps at `PE_COLS_16 = 64`. For N>64, the FC path iterates `fc_out_start` over N tiles. GEMM doesn't currently iterate N tiles, but the FC infrastructure could be reused.

---

## 2. Current GEMM Control Flow Review

### 2.1 GEMM Row Loop Trace

```
FSM_TASK_SETUP
  ↓
FSM_LOAD_ACT (DMA A[M,K] → act_buffer)
  ↓ act_dma_done
GEMM init: gemm_row_idx=0, fc_in_base=0
  ↓
FSM_FC_TILE_PREP (setup fc_tile_outputs, flush wgt_buf)
  ↓
FSM_FC_LOAD_WGT (DMA B[K,N] → wgt_buffer)
  ↓
FSM_FC_LOAD_WAIT (wait for DMA done)
  ↓
FSM_LOAD_ARRAY (wgt_buffer → wgt_load_reg, per-byte)
  ↓
FSM_WGT_LD (weight_ld=1 pulse → PE weight_reg)
  ↓
FSM_COMPUTE:
  CP_FEED_ACT (K cycles: feed A[m,0..K-1] skewed)
  CP_DRAIN    (~K+N+offset cycles: capture N columns)
  ↓
FSM_STORE (DMA write one row C[m,:] with 32B-aligned row stride)
  ↓ dma_wr_done
gemm_row_idx++ → FSM_FC_TILE_PREP (loop for next row)
  ...
  ↓ gemm_row_idx >= M
FSM_BLK_DONE → FSM_BLK_CHECK → FSM_DONE
```

### 2.2 Key Code Locations

| What | File:Line |
|------|-----------|
| GEMM init | `npu_top.v:1842-1849` |
| Row loop increment | `npu_top.v:3095-3100` |
| FEED_ACT (skewed feed) | `npu_top.v:2478-2501` |
| DRAIN termination | `npu_top.v:2574-2581` |
| GEMM store addr | `npu_top.v:2605-2608` |
| block_scheduler GEMM | `block_scheduler.v:114-117,242-250` |

### 2.3 Answers to Control Flow Questions

**Q1: 当前 GEMM row loop 在哪里实现？**
A: `npu_top.v:3093-3105`. After each row's STORE completes, `gemm_row_idx++` and loops to `FSM_FC_TILE_PREP`.

**Q2: 当前是否必须等 C[m,:] store 完才进入 C[m+1,:]？**
A: **YES**. Strictly sequential: FEED_ACT(m) → DRAIN(m) → STORE(m) → FEED_ACT(m+1). No overlap.

**Q3: 当前 act_held 是否只能表示单个 gemm_row_idx 的 A[m,:]？**
A: **YES**. `act_held[0:K-1]` holds exactly `A[m,0:K-1]` for the current `gemm_row_idx`.

**Q4: 当前 DRAIN 是否默认 array_sum_out[n] 属于当前 gemm_row_idx？**
A: **YES**. Each DRAIN cycle captures columns for the same output row m.

**Q5: 当前 STORE 是否只支持一行 C[m,:] 连续写回？**
A: **YES**. `fc_store_bytes = N*4` bytes per STORE. Address = `output_base + m * row_stride`.

**Q6: 当前 acc_buffer 是否支持 M×N tile 暂存？**
A: **Limited**. acc_buffer = 1024 int32 entries. M=8, N=64 → 512 entries (OK). M=64, N=64 → 4096 entries (DOES NOT FIT). For larger tiles, need row-by-row store or smaller tiles.

**Q7: 当前状态机中有哪些 bubble 是 row-by-row 造成的？**
A:
1. **Weight reload bubble**: Every row re-DMAs B[K,N] from shared RAM (~K*N/32 AXI beats)
2. **LOAD_ARRAY bubble**: Every row re-loads wgt_load_reg from wgt_buffer (~K*N cycles)
3. **Store bubble**: DMA writer startup and FIFO drain between rows
4. **Compute restart bubble**: FSM transitions through FSM_FC_TILE_PREP → LOAD_WGT → LOAD_WAIT → LOAD_ARRAY → WGT_LD between rows

---

## 3. Output Path Review

### 3.1 DRAIN → COLLECT → acc_buffer → STORE Flow

```
DRAIN:
  Each cycle after drain_offset:
    col_results[global_col] <= array_sum_out[global_col]

COLLECT (merged into CP_DRAIN):
  Each cycle:
    acc_wr_data = first_accum ? col_results[idx] : (acc_rd_data + col_results[idx])
    acc_wr_en, acc_partial_addr++

STORE (separate FSM_STORE state):
  SP_FIRST → SP_STREAM → SP_PUSH loop:
    Read acc_buffer[store_rd_prefetch]
    Pack 8 × int32 → 256-bit beat (store_pack)
    Push to write_beat_fifo[64]
    DMA writer consumes and writes to AXI
```

### 3.2 Answers to Output Path Questions

**Q1: 当前 bottom output 是如何变成 col_results[n] 的？**
A: `array_sum_out[n*32 +: 32]` → `col_results[n]` during CP_DRAIN, one column per cycle. `array_sum_out` comes from bottom tile row: `array_top.v:113-115`.

**Q2: 当前 col_results[n] 是否默认只属于一个 output row m？**
A: **YES**. After DRAIN+COLLECT completes for one GEMM row, all col_results are consumed and acc_partial_addr resets.

**Q3: 如果 row-streaming 后输出 wavefront 交错，当前 collector 能否区分 m,n？**
A: **NO**. Current collector assumes all outputs belong to the same row m. It does not track which row a column value belongs to. For wavefront output:
```
C[0,0] → C[1,0], C[0,1] → C[2,0], C[1,1], C[0,2] → ...
```
We need to map each captured value to the correct `(m,n)`.

**Q4: acc_buffer 是否能按 acc_addr = m*N+n 写入？**
A: **YES** — if M×N ≤ 1024 entries. For RS0-RS3 (M≤8, N≤64): 512 entries max → fits.

**Q5: STORE path 是否支持先收集完整 C tile，再按 row-major 写回？**
A: **YES** — if C tile fits in acc_buffer. Then one STORE pass writes all rows sequentially, each row at its 32B-aligned address.

**Q6: DMA write 是否要求 32B aligned row stride？**
A: **YES** — AXI 256-bit alignment. Current code: `row_stride = ceil(N*4/32)*32`.

**Q7: 对 N=4 时，row_stride_bytes 是否仍然需要 32B？**
A: **YES**. N=4 → C row = 16 bytes, but AXI requires 32B-aligned burst start. Row stride = 32 bytes (next 32B boundary).

---

## 4. Critical Bottleneck Analysis

### 4.1 Weight Reload Per Row

**Current**: Each GEMM row re-DMAs B[K,N] from shared RAM.

| GEMM size | B bytes | AXI beats (256b) | Cost per row |
|-----------|---------|------------------|--------------|
| G1: K=64, N=8 | 512B | 16 | ~16+ cycles |
| G2: K=128, N=16 | 2048B | 64 | ~64+ cycles |
| G3: K=512, N=32 | 16KB | 512 | ~512+ cycles |

**Fix**: After first row, B weights stay in `wgt_load_reg` AND in PE `weight_reg`. Skip FSM_FC_LOAD_WGT, FSM_LOAD_ARRAY, FSM_WGT_LD for subsequent rows. Just clear `act_held[]` and restart FEED_ACT.

**Savings**: For G3 with M=32: saves 31 × 512 = ~15872 cycles just in DMA.

### 4.2 Sequential Row Processing

**Current**: FEED_ACT → DRAIN → STORE, strictly sequential per row.

**Row-streaming fix**: Overlap FEED_ACT(m+1) with DRAIN+COLLECT(m). But this requires:
- `act_held[k]` to be updated with A[m+1,k] while A[m,k] is still propagating through later columns
- Since activation flows RIGHT through N columns (N cycles), and partial sum flows DOWN through K rows (K cycles), we need to ensure act_held[k] is updated only after row k has finished with A[m,k]

**Timing analysis for weight-stationary streaming**:

For weight-stationary array (PE row=k, PE col=n):
- A[m,k] enters PE(k,0) at cycle t_k = k (skewed feed)
- A[m,k] reaches PE(k,n) at cycle t_k + n
- Partial sum from row k reaches row k+1 at cycle t_k + n + 1
- Total pipeline: K + N + const cycles for one output row

For continuous streaming:
- Feed A[0,:] starting at cycle 0 (K cycles skewed)
- Feed A[1,:] starting at cycle K (next K cycles)
- DRAIN starts capturing at cycle `drain_offset`
- Wavefront: C[0,0] at cycle ~K, C[1,0] at cycle ~2K, etc.

**Key insight**: Row k of PE array can accept A[m+1,k] as soon as it has finished generating contributions for A[m,k] to all columns. This happens roughly K cycles after feeding A[m,k].

### 4.3 Feeder Parallelism

**Current bottleneck**: 1 byte/cycle from act_buffer.

**For row-streaming**: Need to feed K_tile bytes per cycle across K_tile PE rows.
- With 256-bit act_buffer: can extract up to 32 bytes from one beat
- With K_tile=64: need 2 beats → 2 read ports or 2 cycles

**Recommended solution**: Local A_tile[M_tile][K_tile] register file.
- Preload from act_buffer (sequential DMA read, one 256-bit beat = 32 bytes per cycle)
- During compute: parallel readout of K_tile bytes per cycle from A_tile
- For M_tile=8, K_tile=64: 512 bytes → 16× 256-bit registers (very small)

---

## 5. Row-Streaming GEMM: Recommended Architecture

### 5.1 Data Organization

```
A_tile[M_tile][K_tile] : 8-bit register array (local, inside npu_top)
B_tile[K_tile][N_tile] : via existing wgt_load_reg → PE weight_reg
C_tile[M_tile][N_tile] : in acc_buffer, addr = m*N_tile + n
```

### 5.2 Feeder Design (Phase 1: simple prototype)

For the weight-stationary array, row-streaming means:

```
stream_cycle t (t = 0, 1, 2, ..., K_tile + M_tile - 2 + flush):
  
  // Feed activation to each PE row k
  for k = 0..K_tile-1:
      m = t - k
      if (0 <= m < M_tile):
          array_act_in[k] = A_tile[m][k]
      else:
          array_act_in[k] = 0
  
  // During streaming, act_held is updated every cycle
  // (not just during FEED_ACT)
```

**Implementation**: Replace the CP_FEED_ACT/CP_DRAIN split with a single continuous feed state:
- New sub-state: `CP_STREAM` (replaces CP_FEED_ACT + CP_DRAIN)
- `act_held[k]` is updated EVERY cycle with `A_tile[t-k][k]`
- Output capture runs continuously in parallel

### 5.3 Wavefront Output Capture

```
For each drain cycle (after initial pipeline fill):
    
    // drain_global_col = current output column n being captured
    n = drain_global_col
    stream_t = current stream cycle number
    
    // Calculate which output row this value belongs to
    // PIPE_OFFSET measured from RTL trace
    m = stream_t - K_tile - n - PIPE_OFFSET
    
    if (0 <= m < M_tile && 0 <= n < N_tile):
        C_captured[m][n] = array_sum_out[n]
```

`PIPE_OFFSET` accounts for:
- Pipeline registers inside each PE (act_reg, sum_out_reg)
- Tile boundary pipeline effects
- Output arbiter latency

### 5.4 Sequence

```
Phase 1: Load B[K,N] → wgt_load_reg → PE weight_reg (once)
Phase 2: Load A[M,K] → local A_tile register array
Phase 3: Continuous stream:
           - Feed skewed A[t-k,k] to array_act_in[k]
           - Capture wavefront outputs to acc_buffer[m*N+n]
Phase 4: After stream completes, STORE C[M,N] row-by-row
```

### 5.5 FSM Changes (minimal set)

| Change | Description |
|--------|-------------|
| New state | `FSM_GEMM_STREAM` — continuous streaming compute |
| New sub-state | `CP_STREAM` — replaces CP_FEED_ACT + CP_DRAIN for GEMM |
| Modified | `FSM_FC_TILE_PREP` — detect gemm_row_idx>0 and skip weight reload |
| Modified | DRAIN termination — continue until M×N outputs captured, not just N |
| New register | `stream_cycle` — global stream cycle counter |
| New register | `A_tile[0:M_tile-1][0:K_tile-1]` — local activation buffer |
| New register | `stream_captured_count` — how many C[m,n] captured so far |

---

## 6. Answers to Key Engineering Questions

### Q1: 每拍需要给多少个 PE row 提供 activation？
**A**: K_tile rows, up to 64. Each needs a different byte per cycle during streaming.

### Q2: 当前 act_buffer 是否支持这个并行度？
**A**: **NO**. Single read port, single byte extraction per cycle. Need local A_tile.

### Q3: 如果不支持，用 local A_tile 还是改 act_buffer banking？
**A**: **Local A_tile** (recommended). Simple register file. 64×8×8b = 512B for M=8, K=64. Easily fits in FPGA registers.

### Q4: B 是否可以跨所有 M 行保持驻留？
**A**: **YES**. PE weight_reg retains value until next `weight_ld` pulse. Just don't re-enter WGT_LD state.

### Q5: K>64 时 row-streaming 如何和 K chunk accumulation 结合？
**A**: Each K-chunk produces partial C[m,n] contributions. Accumulate across chunks in acc_buffer:
```
For K_chunk = 0, 64, 128, ...:
    Load B[K_chunk : K_chunk+63, :] into PE weight_reg
    Stream A[:, K_chunk : K_chunk+63]
    Capture partial contributions → acc_buffer[m*N+n] += new_value
Final C[m,n] ready after all K_chunks streamed.
```

### Q6: wavefront 输出如何映射到 C[m,n]？
**A**: `m = stream_cycle - K_tile - n - PIPE_OFFSET`. Need RTL trace to determine PIPE_OFFSET exactly.

### Q7: PIPE_OFFSET 如何测量？
**A**: Run M=4, K=4, N=4 with known data pattern. Trace `stream_cycle`, `array_sum_out[n]`, calculate when C[0,0] first appears. PIPE_OFFSET = stream_cycle - K - 0 - 0 at first valid C[0,0].

### Q8: acc_buffer 是否足够存 M×N 个 int32？
**A**: For RS0-RS3 (M≤8, N≤64): YES (≤512 entries). For larger tiles: use multiple smaller tiles or per-row store.

### Q9: STORE 是否按行统一写回？
**A**: **YES**. After all M rows collected in acc_buffer, one STORE pass writes each row sequentially at `output_base + m * row_stride_bytes`.

### Q10: 对 AXI 32B alignment 有什么影响？
**A**: None. Each C row starts at a 32B-aligned address (`row_stride = ceil(N*4/32)*32`). Same as current.

### Q11: 哪些现有 regression 可能受影响？
**A**:
- `npu_fc_smoke_test`: NOT affected (FC uses different path)
- `npu_conv_smoke_test`: NOT affected (Conv uses different path)
- `npu_fc_128x128_peak_test`: NOT affected
- `npu_conv_multiblock_test`: NOT affected
- `npu_bandwidth_60pct_stress_test`: NOT affected (VecReLU path)
- `npu_task_gemm_func_test`: **WILL BE MODIFIED** — new row-streaming path should produce identical results

---

## 7. Risk Register

| Risk | Severity | Mitigation |
|------|:--:|------|
| PIPE_OFFSET miscalculation | HIGH | Measure from RTL trace with known data |
| act_held update timing corrupts in-flight computation | HIGH | Conservative: clear act_held between rows, verify with small tests first |
| Wavefront collector index off-by-one | MEDIUM | Print per-cycle trace for all candidate (m,n) |
| Weight corruption during streaming | LOW | Disable weight_ld after first load |
| acc_buffer overflow for large tiles | MEDIUM | Limit initial tests to M≤8, N≤64 |
| Store address calculation wrong | LOW | Reuse existing 32B-aligned row stride logic |

---

## 8. Modified Module List (Planned)

| Module | Change Level | Description |
|--------|:--:|------|
| `npu_top.v` | **MAJOR** | New GEMM streaming FSM, A_tile buffer, wavefront collector, modified FEED/DRAIN |
| `block_scheduler.v` | MINOR | May need GEMM block awareness for M tiling |
| `task_checker.v` | NONE | No change needed |
| `mac_pe.v` | **NONE** | Preserve weight-stationary PE |
| `mac_tile_4x4.v` | **NONE** | Preserve interconnect |
| `array_top.v` | **NONE** | Preserve interconnect |
| `dma_axi_reader.v` | NONE | No change |
| `dma_axi_writer.v` | NONE | No change |
| `npu_task_gemm_func_test.sv` | MINOR | Keep legacy test, add comparison |
| `npu_task_gemm_row_streaming_test.sv` | **NEW** | Row-streaming test cases |

---

## 9. Phase 1 Implementation Plan

### Phase 1a: B weight retention (simplest optimization)
- Skip weight reload for gemm_row_idx > 0
- Direct path from STORE done → CP_FEED_ACT (skip LOAD_ARRAY→WGT_LD)
- **Expected savings**: ~K*N + DMA cycles per additional row

### Phase 1b: Local A_tile buffer
- Add `A_tile[M_tile][K_tile]` register array (M_tile parameter, default 8)
- Preload from act_buffer after DMA
- Feed from A_tile during compute

### Phase 1c: Continuous streaming
- New CP_STREAM sub-state
- act_held updated every cycle from A_tile
- Wavefront output capture

### Phase 1d: Batch STORE
- Collect all M×N outputs in acc_buffer
- Single STORE pass writes all rows

---

## 10. Conclusion

The existing weight-stationary 64×64 PE array can support continuous row-streaming GEMM with:
1. **NO PE or array interconnect changes** — mac_pe.v, mac_tile_4x4.v, array_top.v unchanged
2. **B weight retention** — load once, keep in PE weight registers across all M rows
3. **Local A_tile buffer** — overcome single-port act_buffer limitation
4. **Continuous feed** — update act_held[k] each cycle with skewed A[t-k,k]
5. **Wavefront collector** — map output timing to correct C[m,n]
6. **Batch store** — collect full C tile in acc_buffer, then write row-major

The primary limitation is acc_buffer capacity (1024 int32 entries), which caps single-tile size to M×N ≤ 1024 (e.g., M=16, N=64 = 1024 exactly).
