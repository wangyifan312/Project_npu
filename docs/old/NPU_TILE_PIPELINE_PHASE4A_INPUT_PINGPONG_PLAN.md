# NPU Tile Pipeline — Phase 4a Input Ping-Pong Plan

## 1. Phase 3c Baseline (commit 4945d1d)

Phase 3c delivered general K>64 streaming GEMM with non-uniform A support via
a byte-by-byte input-tile-loader micro-sequencer within `FSM_GEMM_STREAM_LOAD_A`.

### Current data path

```
act_buffer (raw bytes, 1024×256-bit)
  └─ act_rd_addr (combinational mux override during LOAD_A)
       └─ act_rd_data (256-bit beat, 1-cycle latency)
            └─ a_tile[row][col] = act_rd_data[byte_sel*8 +: 8]
```

### Current micro-sequencer timing

```
Phase    | Action                          | Next Phase
---------|---------------------------------|-----------
IDLE     | init row=0, col=0              | REQ
REQ      | addr already set (combinational)| WAIT
WAIT     | data arrives next cycle         | CAPTURE
CAPTURE  | capture byte, advance col/row   | REQ (more) or IDLE (done)
```

Per-byte cost:
- First byte: 3 cycles (IDLE→REQ→WAIT→CAPTURE)
- Subsequent bytes: 2 cycles each (CAPTURE/REQ→WAIT→CAPTURE)
- **M=8, K_chunk=64 → 512 bytes → ~1027 cycles**

### Verified

```
RS0-RS16: 21/21 PASS  (includes RS14/RS15/RS16 non-uniform A)
GEMM_FUNC: 6/6 PASS
Full 7/7 regression PASS
UVM_ERROR=0, UVM_FATAL=0
```

---

## 2. Current Input Loader Data Path (detailed)

### 2.1 act_buffer read port

```
npu_buffer (act_buffer):
  - 1024 entries × 256-bit per bank, 2 banks (A/B)
  - Read: rd_data <= bank[rd_addr] at posedge (1-cycle synchronous latency)
  - Single read port: one read per cycle
  - During LOAD_A: rd_bank = act_comp_bank (set at task start, stable)
```

### 2.2 act_rd_addr mux (current)

```verilog
assign act_rd_addr =
    (fsm_state == FSM_GEMM_STREAM_LOAD_A) ? gemm_a_load_beat_addr :
    is_pool_mode    ? act_pool_beat_addr :
    fc_or_gemm      ? fc_act_beat_addr :
    ...
    act_feed_beat_addr;
```

Only FSM_GEMM_STREAM_LOAD_A has the override. Other states use the
legacy byte-by-byte feed paths or mode-specific address calculations.

### 2.3 act_buffer read port availability during RUN

During `FSM_GEMM_STREAM_RUN`, `stream_drive = 1`:

```verilog
// array_act_in[ai*8 +: 8] = stream_drive ? s_act : <legacy path>
// s_act = a_tile[s_m[2:0]][ai[5:0]]
```

The GEMM streaming compute path reads `a_tile` directly — **not** from `act_rd_data`.
Therefore, during `FSM_GEMM_STREAM_RUN`:
- act_rd_addr is driven to `fc_act_beat_addr` (a dummy/inactive value)
- act_rd_data is NOT consumed by the compute path
- **act_buffer read port IS FREE for background prefetch**

### 2.4 a_tile declaration

```verilog
reg [7:0] a_tile [0:7][0:63];    // 8 rows × 64 bytes, INT8
```

Used by compute:
```verilog
wire [7:0] s_act = ... ? a_tile[s_m[2:0]][ai[5:0]] : 8'd0;
```

`ai` = PE row index (0..63). `s_m` = streaming row index (0..gemm_M_val-1).
Only rows 0..active_k-1 are active; `s_m` indexes into row space.

---

## 3. Byte-by-Byte Loader Performance Issues

### 3.1 Cycle count

| Scenario | Bytes | Cycles (byte-by-byte) | Ideal (beat-level) | Waste |
|----------|-------|:---------------------:|:-------------------:|:-----:|
| M=8, K_chunk=64 | 512 | ~1027 | ~34 | **30×** |
| M=2, K_chunk=64 | 128 | ~259 | ~10 | **26×** |
| M=2, K_chunk=1 (K=65 boundary) | 2 | ~7 | ~6 | 1.2× |

The overhead dominates for typical K>64 streaming scenarios (~1000 cycles
just for loading, compared to ~200-300 cycles for compute).

### 3.2 Root cause

Each byte requires:
1. Setting act_rd_addr (combinational, "free")
2. Waiting 1 cycle for synchronous read
3. Capturing in the next cycle

But setting the address for the next byte ALSO takes a cycle.
Effective throughput: **1 byte per 2 cycles**.

### 3.3 Fix: beat-level bulk read

Each 256-bit beat contains 32 bytes (INT8). Reading a full beat takes:
1. Set beat address (1 cycle in REQ)
2. Wait (1 cycle in WAIT)
3. Capture and unpack 32 bytes (1 cycle in CAPTURE — for loop in Verilog)

Effective throughput: **32 bytes per 2 cycles → ~16 bytes/cycle**.
For 512 bytes: ~32 cycles (vs ~1027 byte-by-byte).

---

## 4. Beat-Level Bulk Read Design (Phase 4a-1)

### 4.1 Loader state machine

```
A_LOAD_IDLE → A_LOAD_REQ → A_LOAD_WAIT → A_LOAD_CAPTURE → REQ (next beat) or IDLE (done)
```

The difference from Phase 3c: in CAPTURE, instead of capturing ONE byte,
capture up to 32 bytes from the beat.

### 4.2 CAPTURE beat unpack logic

```verilog
A_LOAD_CAPTURE: begin
    // Determine bytes to capture from this beat
    // byte_lane_start = byte_idx & 0x1F
    // Valid bytes in this beat = min(fc_chunk_inputs - gemm_a_load_col, 32 - byte_lane_start)

    integer lane;
    for (lane = 0; lane < 32; lane = lane + 1) begin
        if (gemm_a_load_col + lane < fc_chunk_inputs)
            a_tile[gemm_a_load_row][gemm_a_load_col + lane] <=
                act_rd_data[(byte_lane_start + lane) * 8 +: 8];
    end

    // Advance: skip 32 bytes (or fewer on last partial beat)
    gemm_a_load_col <= gemm_a_load_col + bytes_this_beat;
    if (gemm_a_load_col + bytes_this_beat >= fc_chunk_inputs) begin
        // Row done; next row
        gemm_a_load_row <= gemm_a_load_row + 1;
        gemm_a_load_col <= 0;
    end
    if (last_row && last_beat) begin
        gemm_a_load_done <= 1;
        gemm_a_load_phase <= A_LOAD_IDLE;
    end else begin
        gemm_a_load_phase <= A_LOAD_REQ;
    end
end
```

### 4.3 Address calculation (unchanged)

```
byte_idx  = row * input_c + gemm_stream_k_base + gemm_a_load_col
beat_addr = byte_idx >> 5
byte_lane_start = byte_idx & 0x1F
```

Since `gemm_a_load_col` advances by beat-sized chunks (32), each subsequent beat
address increments by 1 (unless crossing a row boundary, where it's row*K + k_base>>5).

### 4.4 Key constraints

- First beat may be unaligned: `byte_lane_start ≠ 0` when `row*input_c` is not 32B-aligned
  - Example: K=65, row 1 starts at byte_idx=65, byte_lane_start=1
- Last beat may be partial: `bytes_this_beat < 32` when reaching chunk end
- Single buffer (a_tile only) — no ping-pong yet
- Same FSM state (FSM_GEMM_STREAM_LOAD_A)
- Same FSM routing (ACCUM→LOAD_A→LOAD_ARRAY→WGT_LD→PREP→RUN)

### 4.5 Verification

RS0-RS16 21/21 PASS. GEMM_FUNC 6/6 PASS.
No cycle-count regression expected (cycles should decrease, not increase).

---

## 5. Input Tile Bank [2] Design (Phase 4a-2)

### 5.1 Bank structure

```verilog
// Two banks, each 8×64 bytes (same as current a_tile)
reg [7:0] input_tile_bank0 [0:7][0:63];
reg [7:0] input_tile_bank1 [0:7][0:63];

// Bank metadata
reg       input_bank_valid   [0:1];  // bank has valid loaded data
reg [15:0] input_bank_k_base [0:1];  // K start for data in this bank
reg [15:0] input_bank_k_tile [0:1];  // K size for data in this bank

// Ownership — mutually exclusive during load/compute
reg       input_load_bank;           // which bank the loader writes (0 or 1)
reg       input_compute_bank;        // which bank the compute reads (0 or 1)
```

### 5.2 Loader writes to load_bank

```verilog
// During CAPTURE, write to the correct bank:
if (input_load_bank == 1'b0) begin
    input_tile_bank0[gemm_a_load_row][...] <= ...;
end else begin
    input_tile_bank1[gemm_a_load_row][...] <= ...;
end
```

### 5.3 Compute reads from compute_bank

```verilog
// stream_drive path:
wire [7:0] s_act_bank0 = input_tile_bank0[s_m[2:0]][ai[5:0]];
wire [7:0] s_act_bank1 = input_tile_bank1[s_m[2:0]][ai[5:0]];
wire [7:0] s_act = input_compute_bank ? s_act_bank1 : s_act_bank0;
```

### 5.4 Bank switching (sequential — no overlap yet)

```
chunk0:
    load_bank    = 0  →  LOAD_A loads bank0
    compute_bank = 0  →  RUN reads bank0
    bank0_valid  = 1  →  set after LOAD_A complete

chunk1:
    load_bank    = 1  →  LOAD_A loads bank1
    compute_bank = 1  →  RUN reads bank1
    bank1_valid  = 1  →  set after LOAD_A complete
```

Bank flip at each K-chunk boundary: `input_load_bank <= ~input_load_bank`.

### 5.5 Bank validity discipline

```
1. LOAD_A sets input_bank_valid[load_bank] when gemm_a_load_done
2. Before compute, check input_bank_valid[compute_bank]
3. PREP does NOT clear bank_valid — only clear on task reset
4. Last chunk may leave one bank partially written — OK (only valid rows used)
```

---

## 6. Overlap Scheduling (Phase 4a-3)

### 6.1 Target timeline

```
chunk0:
    LOAD_A bank0 (sequential)
    LOAD_ARRAY B0 → WGT_LD → PREP
    RUN using bank0
        ═══ while RUN: PREFETCH LOAD_A bank1 (next chunk A) ═══
    ACCUM

chunk1:
    (bank1 already loaded — skip LOAD_A!)
    LOAD_ARRAY B1 → WGT_LD
    PREP (skip LOAD_A, bank1 already valid)
    RUN using bank1
        ═══ while RUN: PREFETCH LOAD_A bank0 (if more chunks) ═══
    ACCUM
```

Key: chunk1+ skips LOAD_A because prefetch loaded it during previous compute.

### 6.2 Prefetch micro-sequencer

A second, independent micro-sequencer that runs during `FSM_GEMM_STREAM_RUN`:

```verilog
reg        input_prefetch_active;    // 1 during background prefetch
reg        input_prefetch_done;      // pulsed when prefetch completes
reg [1:0]  input_prefetch_phase;     // same 4-phase (IDLE/REQ/WAIT/CAPTURE)
reg [2:0]  input_prefetch_row;       // row iterator
reg [6:0]  input_prefetch_col;       // column iterator (beat-aligned)
reg        input_prefetch_bank;      // which bank to load (opposite of compute_bank)
reg [15:0] input_prefetch_k_base;    // k_base for the chunk being prefetched
reg [15:0] input_prefetch_k_tile;    // k_tile for the chunk being prefetched
```

### 6.3 act_rd_addr override during prefetch

```verilog
assign act_rd_addr =
    (fsm_state == FSM_GEMM_STREAM_LOAD_A) ? gemm_a_load_beat_addr :
    (input_prefetch_active)                ? input_prefetch_beat_addr :
    ...
```

Priority: explicit LOAD_A (for first chunk) > background prefetch > legacy paths.

### 6.4 Prefetch lifecycle

```
TRIGGER: Entering FSM_GEMM_STREAM_RUN, if there is a next K-chunk:
    input_prefetch_active <= 1;
    input_prefetch_bank   <= ~input_compute_bank;
    input_prefetch_k_base <= gemm_stream_k_base + fc_chunk_inputs;
    input_prefetch_phase  <= A_LOAD_REQ;

DURING RUN:
    Background micro-sequencer reads act_buffer, fills other bank.
    Compute is unaffected (a_tile reads from compute_bank, not load_bank).

COMPLETION:
    input_prefetch_done  <= 1;
    input_prefetch_active <= 0;
    input_bank_valid[input_prefetch_bank] <= 1;
    input_bank_k_base[input_prefetch_bank] <= input_prefetch_k_base;

STALL:
    If next chunk needs to start but prefetch is not yet done,
    stall in ACCUM wait state until prefetch completes.
```

### 6.5 Stall condition

In FSM_GEMM_STREAM_ACCUM (more chunks case):
```
if input_bank_valid[~input_compute_bank] is NOT set:
    stall — wait for prefetch completion
else:
    proceed normally (skip LOAD_A for chunk1+)
```

Stall counter:
```verilog
reg [31:0] prefetch_stall_count;  // increment when ACCUM stalls
```

### 6.6 Bank ownership rules

```
1. COMPUTE reads ONLY from compute_bank; loader NEVER writes compute_bank
2. LOADER writes ONLY to load_bank; compute NEVER reads load_bank
3. bank_valid[load_bank] cleared when load starts
4. bank_valid[load_bank] set when load/prefetch completes
5. compute_bank switches ONLY when bank_valid[new_compute_bank] is set
6. Last chunk does NOT trigger prefetch
```

### 6.7 What we DON'T overlap (still sequential)

```text
✗ B weight DMA — still sequential at chunk boundary
✗ STORE — still after all chunks
✗ WGT_LD — still after LOAD_A (or after prefetch complete)
```

---

## 7. GEMM First Landing Path

GEMM is the first (and only for Phase 4a) user of input ping-pong.
The path is:

```
For GEMM row-streaming (gemm_row_streaming_en = 1):
    1. chunk0: sequential LOAD_A bank0 → LOAD_ARRAY B0 → PREP → RUN + PREFETCH bank1
    2. chunk1+: skip LOAD_A → LOAD_ARRAY B1 → PREP → RUN + PREFETCH bank0
    3. last chunk: RUN (no prefetch), ACCUM → DONE → STORE
```

Implementation in existing FSM states:
- `FSM_GEMM_STREAM_LOAD_A` → writes to `input_load_bank`
- `FSM_GEMM_STREAM_RUN` → reads from `input_compute_bank`, triggers prefetch
- `FSM_GEMM_STREAM_ACCUM` → checks prefetch completion, stalls if needed
- `FSM_GEMM_STREAM_PREP` → flips banks (load_bank/compute_bank swap), skips LOAD_A for chunk1+

No new main FSM states.

---

## 8. FC/Conv/Vector Future Interface Reservation

### 8.1 FC

FC already shares the GEMM path through `Fc_or_gemm`. When FC multi-chunk
(input_c > 64) is fixed (shadow register bug), FC will naturally use the
same input ping-pong mechanism:

```
FC_input_tile[size] = input_tile_bank[load_bank]
FC uses fc_in_base instead of gemm_stream_k_base
```

No RTL changes needed now — the `input_tile_bank` naming is already generic.

### 8.2 Conv

Conv currently uses `conv_frontend` for activation feeding (byte-by-byte
via `cf_act_data`). A future `input_tile_loader` for Conv would load a
spatial window tile into `input_tile_bank`:

```
Conv: input_tile = conv_window_tile (KERNEL_SPATIAL × channels)
```

Phase 4a reserves the bank structure but does NOT migrate Conv.

### 8.3 Vector / Elementwise

Vector ops read act_buffer directly (no a_tile needed). The ping-pong
mechanism does not apply — Phase 4a reserves interface but does not change
vector path.

---

## 9. Items NOT Done in Phase 4a

| Item | Reason |
|------|--------|
| B weight prefetch | Separate DMA channel; needs independent scheduling |
| STORE overlap | Needs c_tile ping-pong (separate project) |
| result_tile_buffer unify | GEMM uses c_tile, FC/Conv use acc_buffer |
| STORE Scheme A burst | Independent optimization |
| M_tile > 8 | Needs larger a_tile array |
| PE array changes | No modification to mac_pe/mac_tile_4x4/array_top |
| FC/Conv functional path migration | Interface reservation only |
| New main FSM state | Reuse existing states |

---

## 10. Test Plan

### Phase 4a-1 tests

```
RS0-RS16: 21/21 must PASS (functional regression)
GEMM_FUNC: 6/6 must PASS
Check: loader reads beats, not individual bytes
```

### Phase 4a-2 tests

```
RS0-RS16: 21/21 must PASS
Check: bank switching is correct (no data corruption)
```

### Phase 4a-3 tests

```
RS0-RS16: 21/21 must PASS
GEMM_FUNC: 6/6 must PASS
Full 7/7 regression PASS

Performance metrics:
  - RS9 cycles before/after (K=128, 2 chunks)
  - RS10 cycles before/after (K=512, 8 chunks)
  - RS14 cycles before/after (non-uniform K=128)
  - input_prefetch_count: number of successful prefetches
  - prefetch_stall_count: times ACCUM stalled for prefetch
```

New tests for Phase 4a-3:
- **RS17**: K=128, verify total cycles decreased
- **RS18**: K=512, verify 8-chunk prefetch all completed
- **RS19**: K=65, verify boundary prefetch for 2 chunks

---

## 11. Risk Points

### 11.1 Beat-level alignment

- `row * input_c + gemm_stream_k_base` may not be 32B-aligned
- First beat may have `byte_lane_start ≠ 0`
- Last beat may have fewer than 32 valid bytes
- Mitigation: CAPTURE loop checks `lane < bytes_this_beat`

### 11.2 Bank conflict (Phase 4a-3)

- Prefetch writes to load_bank while compute reads compute_bank
- These are different banks — no structural conflict
- Risk: bank_valid not set before compute needs it → stall
- Mitigation: stall check in ACCUM

### 11.3 act_buffer read port conflict

- LOAD_A (explicit) and prefetch both use act_rd_addr
- These run at different times (LOAD_A during LOAD_A state, prefetch during RUN)
- No conflict — only one drives act_rd_addr at a time

### 11.4 K=65 boundary prefetch

- Last chunk has K_tile=1: prefetch only loads 1 column per row
- 2 rows × 1 beat = 2 beats, very fast prefetch
- No special handling needed

### 11.5 Legacy GEMM_FUNC tests

- GEMM_FUNC G0/G1/G2/G3 use non-streaming GEMM path (legacy FC path)
- These do NOT use input_tile_bank — they use the legacy act_feed/cf_act_data path
- Changes to input_tile_bank must NOT affect legacy path
- Mitigation: bank structures only active when gemm_row_streaming_en=1

---

## 12. Implementation Order

```
Phase 4a-1: beat-level bulk read (single buffer)
     ↓ RS0-RS16 PASS
Phase 4a-2: double-buffer input tile (sequential)
     ↓ RS0-RS16 PASS
Phase 4a-3: LOAD/COMPUTE overlap (prefetch during RUN)
     ↓ RS0-RS16 + 7/7 regression PASS
Phase 4a COMPLETE
```

Each phase is independently verifiable before proceeding to the next.
