# NPU Phase U6-a: PE Array Dynamic Clock Gating

**Date:** 2026-07-02  
**Branch:** `feature/npu-pe-array-clock-gating-u6a`  
**Phase:** U6-a (Low-Power Clock Gating Enhancement)

---

## 1. U6-a Objective

Enable dynamic PE array clock gating: when NPU is idle (not computing), disable the systolic array clock to reduce dynamic power consumption. Satisfies the competition low-power metric:

> 当 NPU 未使用时关闭 systolic array / PE array 时钟。

---

## 2. U6-a Audit Conclusion

Clock gating infrastructure already exists in the RTL:

- `array_top.v:62` — per-tile AND-gate clock gating: `gated_clk[ti] = clk && tile_clk_en_flat[ti]`
- `npu_top.v:874` — `array_clk_en` was hardcoded to `{256{1'b1}}` (permanently enabled)
- All 256 `mac_tile_4x4` instances already use `gated_clk[ti]` as their clock

The hardware was present but the dynamic enable control was missing.

---

## 3. Implementation

### 3.1 npu_top.v — Dynamic Enable

**Before (line 874):**
```verilog
assign array_clk_en = {N_TILES{1'b1}};
```

**After:**
```verilog
// Phase U6-a: dynamic PE array clock gating
wire pe_array_clk_en_comb;
assign pe_array_clk_en_comb = (fsm_state != FSM_IDLE) &&
                              (fsm_state != FSM_DONE)  &&
                              (fsm_state != FSM_ERROR);
assign array_clk_en = {N_TILES{pe_array_clk_en_comb}};
```

Strategy: conservative exclusion. PE clock is ON during all states except IDLE, DONE, and ERROR. Primary power saving comes from the long idle periods between tasks.

### 3.2 array_top.v — Low-Phase Latch

**Before (line 62):**
```verilog
assign gated_clk[ti] = clk && tile_clk_en_flat[ti];
```

**After:**
```verilog
// Phase U6-a: low-phase latch for clean clock gating (models standard ICG)
reg [N_TILES-1:0] tile_clk_en_latched;
always @(*) begin
    if (!clk) begin
        tile_clk_en_latched = tile_clk_en_flat;
    end
end
// ...
assign gated_clk[ti] = clk & tile_clk_en_latched[ti];
```

This models standard integrated clock gating (ICG) cell behavior where the enable signal is stable during the clock high phase, preventing glitches.

### 3.3 ASIC / FPGA Mapping

| Target | Implementation |
|--------|---------------|
| RTL simulation | Low-phase latch (as implemented) |
| ASIC synthesis | Replace with library ICG cell (e.g., `CKLNQD12`) |
| FPGA | Replace with `BUFGCE` (Xilinx) or clock-enable primitive |

---

## 4. UVM Verification

**Test:** `npu_pe_array_clock_gating_test.sv`  
**Probe:** `soc_probe_if.npu_cluster_tile_clk_en_flat` (existing, 1536-bit)

### Results

| Condition | Expected | Actual |
|-----------|----------|--------|
| IDLE (100us wait) | tile_clk_en = 0 | ✅ 0 |
| GEMM active (busy=1) | tile_clk_en != 0 | ✅ 1 |
| GEMM done (post-settle) | tile_clk_en = 0 | ✅ 0 |
| B2B T1 active | tile_clk_en != 0 | ✅ 1 |
| B2B T2 active | tile_clk_en != 0 | ✅ 1 |
| Output correctness (GEMM) | PASS | ✅ PASS |
| Output correctness (B2B T1) | PASS | ✅ PASS |
| Output correctness (B2B T2) | PASS | ✅ PASS |

**Final: `saw_idle_zero=1 saw_active_one=1 saw_done_zero=1 func_fails=0` — PASS**

---

## 5. Regression Results

| Test | Status | UVM_ERROR |
|------|--------|-----------|
| `npu_pe_array_clock_gating_test` | PASS | 0 |
| `npu_task_gemm_func_test` | PASS | 0 |
| `npu_int8_extreme_value_stress_test` | PASS (192/192) | 0 |
| `npu_gemm_kchunk_stress_test` | PASS (36/36) | 0 |
| `npu_back_to_back_task_stress_test` | PASS (16/16) | 0 |
| `npu_fc_streaming_smoke_test` | PASS | 0 |
| `npu_fc_streaming_relu_test` | PASS | 0 |
| `npu_fc_streaming_fallback_test` | PASS | 0 |
| `npu_fc_smoke_test` | PASS | 0 |
| `npu_conv_smoke_test` | PASS | 0 |

**UVM_FATAL = 0, UVM_ERROR = 0 across all tests.**

---

## 6. Design Decisions

### Why not per-tile utilization gating?
Per-tile dynamic gating (enabling only active tiles based on M/N/K) adds complexity with marginal additional power savings. The global enable/disable based on FSM state captures the dominant idle power savings with minimal risk.

### Why not gate CSR / DMA / status?
These modules must respond to AXI-Lite transactions and maintain state even when the NPU is idle. Gating their clocks would break register access.

### Why conservative exclusion?
Excluding only IDLE/DONE/ERROR ensures the PE clock is never accidentally disabled during computation or transitional states (weight load, activation feed, drain, collect).

---

## 7. Files Modified

| File | Change |
|------|--------|
| `rtl/npu/npu_top.v` | +5 lines (pe_array_clk_en_comb derivation) |
| `rtl/npu/array_top.v` | +7 lines (low-phase latch) |
| `verif/uvm_top/tests/npu_pe_array_clock_gating_test.sv` | New (180 lines) |
| `verif/uvm_top/pkg/soc_top_uvm_pkg.sv` | +3 lines (test include) |

**No changes to:** dma_axi_writer, write_beat_fifo, mac_pe, npu_ctrl, CSR map.

---

## 8. Competition Metric Satisfaction

✅ **"当 NPU 未使用时关闭 systolic array / PE array 时钟"** — satisfied.

- Hardware: per-tile AND-gate clock gating in array_top.v
- Dynamic control: `pe_array_clk_en_comb` driven by FSM state
- Idle detection: FSM_IDLE forces tile_clk_en = 0
- Verification: UVM probe confirms idle=0, active=1, done=0
