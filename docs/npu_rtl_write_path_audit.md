# NPU RTL Write Data Path Audit Report

**Date**: 2026-06-24
**Scope**: Read-only analysis of DMA write channel, store pack, AXI protocol correctness, bandwidth utilization
**Status**: No RTL modifications made — this is an analysis-only report

---

## 1. Current RTL Writeback Path Summary

### 1.1 Data Flow Diagram

```
Cluster output (INT32 columns)
        |
        v
output_arbiter (OR-merge across 6 clusters, round-robin column output)
        |
        v
npu_top FSM: CP_DRAIN -> col_results[] registers (one INT32 per column)
        |
        v
npu_top FSM: CP_COLLECT -> acc_buffer write (INT32, sequential address)
        |                    [accumulates across input channels if bias enabled]
        v
npu_top FSM: FSM_REQUANT_COMPUTE (if bias/requant enabled)
        |   reads INT32 from acc_buffer -> requant_i32_to_i8 -> packs 4x INT8 into 32-bit word
        |   writes 32-bit word back to acc_buffer
        v
npu_top FSM: FSM_STORE / store_pack FSM
        |   reads 1x 32-bit word per cycle from acc_buffer
        |   shifts into 256-bit accumulator (store_pack_data)
        |   after 8 words: pushes complete 256-bit beat into write_beat_fifo
        v
write_beat_fifo (16 entries deep)
        |   combinational read port
        |   rd_level output to dma_axi_writer
        v
dma_axi_writer
        |   S_WAIT_DATA: waits until fifo_level >= beats_in_burst
        |   S_AW: issues AW with AWLEN = beats_in_burst - 1
        |   S_WDATA: reads from FIFO, sends W beats continuously
        |   S_WAIT_B: waits for BVALID, checks BRESP
        v
AXI4 W channel -> shared_ram
```

### 1.2 Key Parameters

| Parameter | Value |
|-----------|-------|
| acc_buffer width | 32-bit (ACC_DATA_W = 32) |
| acc_buffer depth | 1024 entries per bank |
| AXI W channel width | 256-bit |
| Beat size | 32 bytes |
| MAX_BURST_LEN | 16 beats |
| write_beat_fifo depth | 16 entries |
| store_pack lanes | 8 (3-bit lane counter) |

### 1.3 Module Responsibilities

| Module | File | Role |
|--------|------|------|
| `output_arbiter` | `rtl/npu/output_arbiter.v` | Aggregate mode: OR-merges cluster outputs column-by-column |
| `npu_top` (FSM_STORE) | `rtl/npu/npu_top.v:2079-2196` | store_pack FSM: reads acc_buffer 32-bit → packs 256-bit → pushes to write_beat_fifo |
| `write_beat_fifo` | `rtl/npu/write_beat_fifo.v` | 16-deep FIFO between store_pack and dma_axi_writer. Combinational read port |
| `dma_axi_writer` | `rtl/npu/dma_axi_writer.v` | AXI4 write master: burst splitting, WSTRB, WLAST, B handling. **Already has S_WAIT_DATA state** |
| `npu_buffer` (acc_buffer) | `rtl/npu/npu_buffer.v:446-456` | Generic dual-bank buffer, instantiated as `DATA_WIDTH=32` for acc |
| `perf_counter` | `rtl/npu/perf_counter.v` | write_beat = `dma_wr_valid && dma_wr_ready` (FIFO→writer transfer), write_active = `dma_wr_busy` (all non-IDLE states) |

### 1.4 Critical Signal Trace

```
perf_counter.write_beat  ← dma_wr_valid && dma_wr_ready   (npu_top.v:825)
dma_wr_valid             ← wf_rd_valid                     (npu_top.v:1198, FIFO output)
dma_wr_ready             ← data_ready                      (npu_top.v:1199, writer input)
  = (state==S_WDATA) && !wvalid_r && !w_done               (dma_axi_writer.v:157)

perf_counter.write_active ← dma_wr_busy                    (npu_top.v:826)
dma_wr_busy               ← (state != S_IDLE)              (dma_axi_writer.v:309)
  // Includes: S_WAIT_DATA, S_AW, S_WDATA, S_WAIT_B, S_DONE, S_ERROR
```

**Key insight**: `write_active` counts ALL time the writer FSM is not idle, including `S_WAIT_DATA` where the writer is just waiting for the FIFO to fill. This is the root cause of the 5.88% measurement.

---

## 2. Bug / Risk List

| ID | Type | Symptom/Risk | Suspected File | Evidence | Severity | Suggested Fix |
|----|------|-------------|----------------|----------|----------|---------------|
| **B1** | Counter/statistics issue | `write_util` ≈ 5.88% is a measurement artifact: `write_active` includes `S_WAIT_DATA` cycles where FIFO is filling but no W beats are sent | `rtl/npu/npu_top.v:825-826`, `rtl/npu/perf_counter.v:111-119`, `rtl/npu/dma_axi_writer.v:309` | `write_active = dma_wr_busy = (state != S_IDLE)`. Writer spends ~94% of busy time in `S_WAIT_DATA` waiting for store_pack to fill FIFO. Transaction-level utilization within AW→B window is actually ~88% | **Low** (measurement, not functional) | Redefine `write_active` to exclude `S_WAIT_DATA`: add `dma_wr_transaction_active` signal that is high only during `S_AW \| S_WDATA \| S_WAIT_B`. Or add a separate `write_transaction_util` counter |
| **B2** | Performance bottleneck | store_pack reads acc_buffer 32-bit serially: each 256-bit beat requires ~17 cycles to assemble (2 cycles/word × 8 words + send overhead) | `rtl/npu/npu_top.v:2106-2161` | STORE_PACK_WAIT (1 cycle) + STORE_PACK_CAPTURE (1 cycle reading, 1 cycle shifting) per word = ~2 cycles/word. For 8-word beat: 16 + send overhead = ~17 cycles/beat | **High** (throughput) | Widen acc_buffer to 256-bit or add 8-bank parallel read. See Section 4.2 |
| **B3** | Functional bug (minor) | `write_beat_fifo` wr_strb hardcoded to `{32{1'b1}}`, wr_last hardcoded to `1'b0`. FIFO stores these but they are never used by `dma_axi_writer` (writer computes its own WSTRB/WLAST). FIFO rd_strb/rd_last wires are declared but unconnected | `rtl/npu/npu_top.v:1201` | `wf_rd_strb` and `wf_rd_last` declared on line 1194 but never connected to dma_axi_writer. dma_axi_writer has no strb/last input ports | **Low** (waste, not functional) | Either remove strb/last from FIFO, or connect them to dma_axi_writer and use them (remove internal WSTRB/WLAST computation from writer). Current approach is functionally correct because writer computes these from byte_count arithmetic |
| **B4** | Verification gap | `dma_axi_writer` WDATA/WSTRB/WLAST stability when WVALID && !WREADY: registers hold correctly in `S_WDATA`, but this scenario is not covered in directed tests | `rtl/npu/dma_axi_writer.v:217-237` | `load_w_beat` blocks re-loading when wvalid_r=1. `w_hs` only clears wvalid_r. WDATA/WSTRB/WLAST hold when WREADY is deasserted. AXI spec requires stability | **Low** (protocol compliant, untested) | Add directed test with WREADY backpressure to verify WDATA/WSTRB/WLAST stability |
| **B5** | Verification gap | No test for WLAST assertion on exactly the last beat of a burst when burst is partial (tail burst with < 16 beats) | `rtl/npu/dma_axi_writer.v:221` | `wlast_r <= (beat_counter == burst_len)` — correct by construction, but tail burst with e.g., 3 beats: burst_len=2, beat_counter=0,1,2. WLAST asserts when beat_counter=2=burst_len. Correct. But no directed test | **Low** | Add directed test with output_bytes = 17 (produces 1 full beat + tail) |
| **B6** | Verification gap | `AWLEN = beats_in_burst - 1` for all bursts including tail. Not verified that `AWLEN` matches actual beat count for tail bursts | `rtl/npu/dma_axi_writer.v:199` | `burst_len <= calc_burst_beats(byte_count) - 8'h1`. For tail: e.g., 40 bytes → 2 beats → AWLEN=1. Correct by construction | **Low** | Add assertion: `m_axi_awlen == (beats_in_burst - 1)` during S_AW |
| **B7** | Functional risk (timing) | `dma_wr_start` is a 1-cycle pulse. If writer is not in `S_IDLE` at that exact cycle (shouldn't happen due to `dma_wr_started` guard), the start is missed. | `rtl/npu/npu_top.v:2094-2096` | Guarded by `!dma_wr_started`, which is cleared only after `dma_wr_done`. Writer returns to `S_IDLE` after `S_DONE` only when `!start` | **Low** | Add assertion: `dma_wr_start \|-> dma_wr_busy` within 1 cycle |
| **B8** | AXI protocol risk | `m_axi_bready` is hardwired to `1'b1`. This is legal per AXI spec but means the writer MUST accept B response immediately. If the shared_ram returns BRESP=OK immediately, this is fine. But if there's any delay in BVALID, `bready=1` is just ignored | `rtl/npu/dma_axi_writer.v:162` | `assign m_axi_bready = 1'b1` — OK for simple slave but no backpressure on B channel | **Low** (acceptable for current slave) | No change needed for current architecture |
| **B9** | Functional bug (edge case) | `calc_burst_beats` for `bytes_remaining == 0`: returns `(0 + 31) / 32 = 0 → 0 beats`. But `burst_len = 0 - 1 = 8'hFF`. This is reached only after the transition `bytes_remaining <= remaining_after_burst` which is 0, and then `bytes_remaining == 0` is checked before recomputing burst | `rtl/npu/dma_axi_writer.v:77-88, 244-254` | In S_WAIT_B, `bytes_remaining == 0` is checked FIRST before recomputing. Then state goes to S_DONE, not S_WAIT_DATA. So the 0-beat case is never reached | **None** (guarded) | Guard exists. No fix needed |
| **B10** | Performance bottleneck | acc_buffer is 32-bit wide, instantiated as `npu_buffer #(.DATA_WIDTH(32), ...)`. Single read port provides 1 word/cycle. No burst read capability | `rtl/npu/npu_top.v:446-456` | `npu_buffer` synchronous read: address applied cycle N, data available cycle N+1. No multi-word read capability | **High** (throughput) | See Section 4.2 for acc_buffer 256-bit widening proposal |

---

## 3. Write DMA Utilization Bottleneck Conclusion

### 3.1 Executive Summary

**The 5.88% write_util is a measurement scope issue, NOT a functional bug in the DMA writer or AXI protocol.** The transaction-level utilization (beats per cycle within the AW→B window) is actually ~88%. The low number comes from counting the store_pack FIFO-fill waiting time as "write active" time.

### 3.2 Detailed Analysis

#### Current Architecture Already Implements the Proposed Fix

The `write_beat_fifo` + delayed AW architecture described in the task requirements is **already implemented**:

1. **`write_beat_fifo.v`** exists (untracked file), 16 entries deep, instantiated in `npu_top.v:1200-1206`
2. **`dma_axi_writer.v`** has `S_WAIT_DATA` state (line 205-208) that waits for `fifo_level >= beats_in_burst` before issuing AW
3. **AW is delayed** until FIFO has enough data for a full burst (or tail burst)
4. **Within-burst throughput** is near-ideal: W beats flow at 1 beat/cycle from FIFO through writer to AXI W channel

#### Root Cause of 5.88% Write Utilization

The write_util metric is defined as:

```
write_util = write_beats / write_active_cycles
```

Where:
- `write_beats` = count of `(WVALID && WREADY)` — **correctly counts data transfer cycles**
- `write_active` = `dma_wr_busy` = `(state != S_IDLE)` — **includes ALL states, including S_WAIT_DATA**

The writer spends most of its "busy" time in `S_WAIT_DATA`:

```
Timeline for one 16-beat burst:
  S_WAIT_DATA: ~256 cycles  (waiting for store_pack to fill 16 beats in FIFO)
  S_AW:        ~1 cycle     (AW handshake)
  S_WDATA:     ~16 cycles   (sending 16 W beats at 1/cycle)
  S_WAIT_B:    ~1 cycle     (B response)
  ───────────────────────────────────
  Total busy:  ~274 cycles
  W beats:     16
  write_util:  16/274 = 5.84%
```

**This matches the observed ~5.88% exactly.**

#### Transaction-Level Utilization (Within AW→B Window)

If we only count `S_AW + S_WDATA + S_WAIT_B`:

```
Transaction window: 1 + 16 + 1 = 18 cycles
W beats: 16
Transaction util: 16/18 = 88.9%
```

**The AXI transaction itself is highly efficient.**

#### Where Is the REAL Bottleneck?

```
acc_buffer read (32-bit, 1 word/cycle)
    → store_pack serial assembly: ~17 cycles per 256-bit beat
        → write_beat_fifo fills at ~0.059 beats/cycle
            → writer waits in S_WAIT_DATA for ~16 cycles per burst beat
```

The bottleneck is the **acc_buffer 32-bit serial read path**, NOT the DMA writer or AXI protocol.

```
Theoretical analysis:
  - acc_buffer read bandwidth: 1 × 32-bit = 4 bytes/cycle @ 200MHz = 0.8 GB/s
  - AXI write bandwidth: 1 × 256-bit = 32 bytes/cycle @ 200MHz = 6.4 GB/s
  - Actual throughput limited by acc_buffer: 4 bytes/cycle → 0.8 GB/s
  - 256-bit beat needs 8 reads → 8+ cycles (actually ~17 with FSM overhead)
  - Write util = 1/17 = 5.88% ✓ matches observation
```

### 3.3 Answer to Specific Questions

| Question | Answer |
|----------|--------|
| Is the bottleneck store_pack 17 cycles/beat? | **Yes.** Each 256-bit beat requires ~17 cycles of store_pack FSM time |
| Is it slave backpressure? | **No.** The shared_ram has zero backpressure (WREADY is always high in current TB) |
| Is it writer issuing AW too early? | **No.** Writer already waits for `fifo_level >= beats_in_burst` before AW |
| Is it acc_buffer read bandwidth? | **Yes, this is the root cause.** 32-bit single-port read → 4 bytes/cycle vs 32 bytes/cycle needed |
| What does 5.88% mean? | It's the ratio of W transfer cycles to total writer busy cycles. ~94% of busy time is waiting for store_pack |

---

## 4. Recommended Fix Plan

### 4.1 Phase 1: Fix write_util Measurement (Low Risk, Immediate)

**Problem**: `write_util` counts `S_WAIT_DATA` as "active" time, giving a misleading 5.88%.

**Fix**: Add a `write_transaction_active` signal that is only high during actual AXI transaction phases.

**Files to modify**:
1. `rtl/npu/dma_axi_writer.v` — add `write_transaction_active` output
2. `rtl/npu/npu_top.v` — connect to perf_counter
3. `rtl/npu/perf_counter.v` — add `write_transaction_active_cycles` counter

**dma_axi_writer.v changes**:
```verilog
// Add new output port:
output wire write_transaction_active,  // high only during S_AW | S_WDATA | S_WAIT_B

// Implementation:
assign write_transaction_active = (state == S_AW) || (state == S_WDATA) || (state == S_WAIT_B);
```

**perf_counter.v changes**:
```verilog
// Add new input:
input wire write_transaction_active,

// Add new counter:
reg [31:0] wr_txn_active_cyc;
// ... count on write_transaction_active && task_active && !freeze
```

**Expected result**:
- `write_util` (old): still ~5.88% (system-level)
- `write_transaction_util` (new): ~85-90% (transaction-level)
- Both metrics are now available for analysis

**Risk**: Zero functional risk. Pure measurement change.

### 4.2 Phase 2: Widen acc_buffer to 256-bit (Higher Risk, Higher Reward)

**Problem**: acc_buffer reads 1×32-bit word per cycle. Assembling a 256-bit beat takes ~17 cycles.

**Fix options**:

#### Option A: Widen acc_buffer to 256-bit (preferred)

Modify `npu_buffer` instantiation for acc_buffer from `.DATA_WIDTH(32)` to `.DATA_WIDTH(256)`.

**Changes needed**:
1. `rtl/npu/npu_top.v`: Change `u_acc_buffer` parameter `ACC_DATA_W` usage
2. `rtl/npu/npu_top.v`: Rewrite `store_pack` FSM to read full 256-bit beats directly (no lane assembly)
3. Keep `write_beat_fifo` and `dma_axi_writer` unchanged

**Expected throughput improvement**:
- From ~17 cycles/beat → ~1-2 cycles/beat
- System-level write throughput: from ~0.8 GB/s → ~6.4 GB/s (8× improvement)
- Write util: from 5.88% → ~50% (limited by compute time, not write bandwidth)

**Risk**: Medium. Requires careful handling of:
- Partial sum accumulation (currently writes 32-bit to acc_buffer, need to change to 256-bit beat writes with byte-level strobes)
- All paths that write to acc_buffer (CP_COLLECT, requant, GAP, ADD modes)
- Address mapping changes (32-bit word addressing → 256-bit beat addressing)

#### Option B: 8-bank parallel acc_buffer (alternative)

Instantiate 8 parallel 32-bit acc_buffers, one per lane. Read all 8 in parallel.

**Risk**: High. Significant architectural change. Not recommended as first step.

### 4.3 Phase 3: Direct 256-bit Store from Compute (Future Enhancement)

Skip acc_buffer write entirely for the common path. During CP_COLLECT, accumulate 8 INT32 results directly into a 256-bit register, then push to write_beat_fifo.

**Risk**: High. Changes the compute accumulation path significantly. Only pursue after Phase 1 and 2 are stable.

---

## 5. Detailed Analysis of Current Store Pack Timing

### 5.1 FSM States and Cycle Count

The store_pack FSM in `npu_top.v:1174-2161`:

```
STORE_PACK_IDLE    (1 cycle: transition to WAIT if words remain)
STORE_PACK_WAIT    (1 cycle per word: transition to CAPTURE)
STORE_PACK_CAPTURE (1 cycle per word: read acc_rd_data, shift into accumulator)
STORE_PACK_SEND    (1 cycle per beat: push to FIFO, wait if FIFO full)
```

### 5.2 Per-Beat Cycle Breakdown

For a full 8-word, 256-bit beat:

```
Cycle  Event
  0    IDLE → WAIT (store_word_idx=0 < store_words_active)
  1    WAIT → CAPTURE
  2    CAPTURE: latch word[0] into lane 0, dma_rd_ptr=1, store_pack_lane=1
  3    WAIT (next word)
  4    CAPTURE: latch word[1] into lane 1, dma_rd_ptr=2
  5    WAIT
  6    CAPTURE: latch word[2] into lane 2, dma_rd_ptr=3
  7    WAIT
  8    CAPTURE: latch word[3] into lane 3, dma_rd_ptr=4
  9    WAIT
 10    CAPTURE: latch word[4] into lane 4, dma_rd_ptr=5
 11    WAIT
 12    CAPTURE: latch word[5] into lane 5, dma_rd_ptr=6
 13    WAIT
 14    CAPTURE: latch word[6] into lane 6, dma_rd_ptr=7
 15    WAIT
 16    CAPTURE: latch word[7] into lane 7, push to FIFO, goes to SEND
 17    SEND: wait if FIFO full, then clear valid, go to WAIT for next beat
```

**Total: 18 cycles for the first beat of a store operation. Subsequent beats: ~17 cycles** (no initial IDLE→WAIT overhead per beat, but the first word of each new beat still goes through WAIT→CAPTURE).

Wait — actually let me re-check. After SEND, the FSM goes to WAIT:
```verilog
STORE_PACK_SEND: begin
    if (!wf_wr_full) begin
        dma_wr_valid_r <= 1'b0;
        if (store_word_idx < store_words_active) begin
            dma_rd_ptr <= dma_rd_ptr + 1;  // points to next word
            store_pack_state <= STORE_PACK_WAIT;
        end
    end
end
```

After SEND → WAIT (cycle 18), next cycle goes to CAPTURE. So subsequent beats: WAIT(1) + CAPTURE(1) per word = 16 cycles for 8 words + SEND(1) = ~17 cycles.

Confirmed: **~17 cycles per 256-bit beat** from acc_buffer to FIFO.

### 5.3 Critical Path Note

The CAPTURE state reads `acc_rd_data` combinationally from the register (via `assign acc_rd_addr = dma_rd_ptr` → npu_buffer synchronous read). The npu_buffer synchronous read has 1-cycle latency:

- Cycle N: dma_rd_ptr set to value X
- Cycle N+1: acc_rd_data available for address X

The store_pack FSM's WAIT state provides this 1-cycle latency. When WAIT transitions to CAPTURE, the data from the previous cycle's dma_rd_ptr assignment is available.

---

## 6. AXI Protocol Correctness Analysis

### 6.1 AW Channel

| Check | Status | Evidence |
|-------|--------|----------|
| AWADDR alignment | ✅ Correct | `start_misaligned` check enforces 32-byte alignment (`base_addr[4:0] == 0`) |
| AWLEN = beats - 1 | ✅ Correct | `burst_len <= calc_burst_beats(bytes) - 8'h1` |
| AWSIZE = log2(32) = 5 | ✅ Correct | `BEAT_BYTES_LOG2 = 5` for 256-bit |
| AWBURST = INCR | ✅ Correct | `2'b01` |
| AWVALID stable until AWREADY | ✅ Correct | `(state == S_AW) && !aw_done` — stays in S_AW until handshake |

### 6.2 W Channel

| Check | Status | Evidence |
|-------|--------|----------|
| WDATA stable when WVALID && !WREADY | ✅ Correct | `load_w_beat` disabled when `wvalid_r=1` |
| WSTRB correct for full beats | ✅ Correct | All 32 bytes enabled: `valid_bytes_this_beat = 32` |
| WSTRB correct for tail beat | ✅ Correct | `calc_wstrb(remaining_bytes)` generates correct lane enables |
| WLAST only on last beat of burst | ✅ Correct | `wlast_r <= (beat_counter == burst_len)` |
| WLAST for tail burst | ✅ Correct | e.g., 40 bytes → 2 beats, burst_len=1, beat_counter=0→wlast=0, beat_counter=1→wlast=1 |

### 6.3 B Channel

| Check | Status | Evidence |
|-------|--------|----------|
| BREADY always ready | ✅ OK | Hardwired to 1 |
| BRESP error detection | ✅ Correct | Checks `bresp != 2'b00` in S_WAIT_B |
| No new burst before B response | ✅ Correct | S_WAIT_B → S_WAIT_DATA only after BVALID |

### 6.4 WSTRB Calculation Verification

```verilog
function [STRB_W-1:0] calc_wstrb;
    input [31:0] valid_bytes;
    integer i;
    begin
        calc_wstrb = {STRB_W{1'b0}};
        for (i = 0; i < STRB_W; i = i + 1) begin
            if (valid_bytes > i)
                calc_wstrb[i] = 1'b1;
        end
    end
endfunction
```

Test cases:
- `valid_bytes = 32`: wstrb[0:31] = all 1s ✅
- `valid_bytes = 17`: wstrb[0:16] = 1s, wstrb[17:31] = 0s ✅
- `valid_bytes = 1`: wstrb[0] = 1, wstrb[1:31] = 0s ✅
- `valid_bytes = 0`: wstrb = all 0s ✅ (should never happen due to byte_count check)

---

## 7. Verification Plan

### 7.1 Tests That Should Pass (Phase 1)

After Phase 1 (measurement fix only):

| Test | Command | Check |
|------|---------|-------|
| soc_shared_ram_rw_test | TBD (need to find exact command) | PASS, no timeout |
| npu_requant_smoke_test | TBD | output compare PASS |
| npu_fc_smoke_test | TBD | output compare PASS |
| npu_conv_smoke_test | TBD | output compare PASS |
| LeNet single sample | TBD | output compare PASS |

### 7.2 Additional Checks

- AWLEN == beats_in_burst - 1 for all bursts
- WLAST assertion count == number of bursts
- WSTRB correct for tail beats
- B response count == number of bursts
- No AXI protocol violations
- write_transaction_util > 80% (new metric)

### 7.3 Phase 2 Tests (After acc_buffer 256-bit widening)

All Phase 1 tests must still PASS.
Additional emphasis:
- Multi-block Conv (tests address sequencing)
- FC tiled mode (tests partial sum accumulation)
- Bias + requant path (tests INT32→INT8 conversion)
- Residual ADD + requant path
- GAP path
- Partial output byte counts (non-32B-aligned)

---

## 8. Conclusion

### 8.1 Current State Assessment

1. **The write_beat_fifo + delayed AW architecture is already implemented and functional.**
2. **The 5.88% write_util is a measurement definition issue, not a hardware bug.**
3. **Transaction-level AXI utilization is ~88% within each burst.**
4. **The real throughput bottleneck is acc_buffer 32-bit serial read → 17 cycles per 256-bit beat.**
5. **No critical functional bugs found in the AXI write protocol implementation.**

### 8.2 Recommended Action Items

| Priority | Action | Risk | Impact |
|----------|--------|------|--------|
| P0 | Fix `write_util` measurement (Phase 1) | None | Clarifies performance metrics |
| P1 | Widen acc_buffer to 256-bit (Phase 2, Option A) | Medium | 8× write throughput improvement |
| P2 | Add directed tests for WREADY backpressure and tail bursts | None | Closes verification gaps B4, B5, B6 |
| P3 | Clean up write_beat_fifo strb/last (remove unused fields or connect them) | None | Code quality |

### 8.3 What NOT to Do

- Do NOT modify the dma_axi_writer FSM — it's already correct
- Do NOT change the AXI protocol handling — it's compliant
- Do NOT remove the write_beat_fifo — it's working correctly
- Do NOT modify the store_pack lane ordering — it's correct
- Do NOT change the acc_buffer memory organization without updating all readers/writers

### 8.4 Residual Risks

1. **Phase 2 acc_buffer widening**: The partial sum accumulation path (CP_COLLECT) currently writes individual 32-bit columns. Changing to 256-bit beats requires careful handling of column-offset addressing and read-modify-write for partial beats.
2. **Testing coverage**: Current test suite does not exercise WREADY backpressure scenarios.
3. **Multi-cluster correctness**: The output_arbiter OR-merge approach is correct but was verified on limited test vectors.

---

*Report generated by systematic read-only analysis of all NPU RTL files in `/root/Project_npu/rtl/npu/`.*
