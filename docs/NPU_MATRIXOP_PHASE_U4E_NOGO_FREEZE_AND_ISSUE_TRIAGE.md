# NPU MatrixOp Phase U4-e — No-Go Freeze & Legacy Issue Triage

**Phase**: U4-e — bias/requant migration no-go freeze + legacy issue triage
**Date**: 2026-07-02
**Base**: `main` `adf4270` (Phase U4-d merge)
**Branch**: `feature/npu-result-tile-bias-requant-design` (audit only, no coding)

---

## 1. Executive Summary

**Formal decision: Do not continue FC bias/requant full migration in the current baseline.**

Phase U0 through U4-d achieved substantial MatrixOp unification (FC pure matmul, FC+ReLU streaming path, result_tile_bank abstraction, INT8 packing infrastructure). Further bias/requant migration on result_tile GST would add significant complexity (bias_tile_bank double buffer, requant 32-lane parallelism, GST multi-format post-op descriptor) with marginal benefit for the primary deliverable (GEMM/FC compute pipeline correctness and performance).

**No rollback is needed.** U4-b (ReLU on GST) and U4-d (INT8 packing infrastructure) are retained. Both default to zero behavioral change and have passed full regression.

**Current progress estimate:**
| Area | Confidence |
|------|:---------:|
| Streaming GEMM correctness | 95% |
| Streaming GEMM pipeline | 93% |
| General NPU tile pipeline | 78% |
| MatrixOp unification | 56% |

---

## 2. Current Baseline

| Tag | Phase | Deliverable |
|-----|-------|-------------|
| `npu-matrixop-unification-audit-u0` | U0 | GEMM/FC/MatrixOp audit |
| `npu-matrixop-phase-u1-fc-streaming` | U1 | FC MatrixOp streaming gate |
| `npu-matrixop-phase-u2-fc-streaming-robustness` | U2 | Robustness + boundary tests |
| `npu-matrixop-phase-u3-result-tile-bank-abstraction` | U3 | c_tile → result_tile_bank |
| `npu-matrixop-phase-u4a-result-tile-postop-audit` | U4-a | Post-op Option A/B/C audit |
| `npu-matrixop-phase-u4b-result-tile-relu-postop` | U4-b | ReLU on result_tile GST |
| `npu-matrixop-phase-u4c-bias-requant-int8-audit` | U4-c | Bias+requant+INT8 audit |
| `npu-matrixop-phase-u4d-result-tile-int8-pack` | U4-d | INT8 GST packing infrastructure |

---

## 3. Current MatrixOp Fast Path (Frozen)

```
LOAD:
    input_tile_bank0/1  ← act_buffer ← DMA from shared_ram
    wgt_load_reg        ← wgt_buffer ← DMA from shared_ram

RUN:
    systolic PE array (64×64, INT8×INT8→INT32)
    continuous streaming mode (FSM_GEMM_STREAM_RUN)
    K-chunk cross-accumulation in result_tile_bank0/1

STORE:
    GST micro-FSM (background, overlaps with next tile compute)
    reads result_tile_bank[row][col] (INT32)
    applies store_desc_relu_en (U4-b) → INT32 ReLU
    packs output per store_desc_output_dtype:
      INT32: 8 values × 32-bit/beat (U1-U3, default)
      INT8:  32 values × 8-bit/beat  (U4-d, infrastructure only)
    → write_beat_fifo → dma_axi_writer → shared_ram
```

**Supported operations on fast path:**
| Operation | Status | Output Format |
|-----------|:------:|:---:|
| GEMM (M,N,K) | ✅ Frozen | INT32 |
| FC pure matmul | ✅ U1 | INT32 |
| FC + ReLU-only | ✅ U4-b | INT32 |

**Three-stage pipeline**: LOAD(next) || RUN(current) || STORE(previous) — all three stages can overlap for multi-tile workloads.

---

## 4. Current Legacy Fallback Path (Preserved)

```
PE array_sum_out
  → acc_buffer (COLLECT/DRAIN, INT32 per column)
  → [FSM_REQUANT_COMPUTE: bias_add_requant_i32_to_i8 → INT8 pack]
  → legacy store_pack (SP_FIRST → SP_STREAM → SP_PUSH)
  → write_beat_fifo → dma_axi_writer → shared_ram
```

**Operations on legacy path:**
| Operation | Reason for Legacy |
|-----------|-------------------|
| FC + bias | bias_reg global singleton, no bias_tile_bank |
| FC + requant | coupled with bias, INT8 output format |
| FC + bias + ReLU | post-op parameter lifecycle risk |
| FC + bias + ReLU + requant | full post-op in legacy only |
| Conv (all variants) | window generator frontend |
| Add / Pool / GAP | aux path, not MatrixOp |
| Standalone requant | task_type=3, acc_buffer required |
| VecReLU | streaming bypass, task_type=6 |

---

## 5. Why No Bias/Requant Migration Now

1. **Marginal benefit for primary deliverable**: Bias/requant migration improves architecture cleanliness, not GEMM/FC compute performance. The primary performance path (GEMM) already uses result_tile fast path.

2. **Small FC scenarios**: Legacy FC is cycle-competitive or faster for M=1 single-row workloads (MATCH0: 158 legacy vs 174 streaming cycles).

3. **bias_tile_bank0/1 required**: bias_reg is a global 64-element singleton. STORE(previous) may overlap RUN(current). A double-buffered bias_tile_bank (2×64×INT32 = 512 bytes of flip-flops) is needed for safe per-tile bias access.

4. **requant parameter lifecycle**: requant_multiplier and requant_shift are live global wires. They must be latched into store_desc_* at STORE launch (same pattern as store_desc_relu_en), adding descriptor complexity.

5. **32-lane requant parallelism**: Current requant_i32_to_i8 is 1-lane combinational. GST_INT8 needs 32 parallel lanes (~128 DSPs) or time-multiplexed staging. Adds area and potentially affects critical path.

6. **GST descriptor bloat**: store_desc_bias_en, store_desc_requant_en, store_desc_requant_mult, store_desc_requant_shift, store_desc_output_dtype — the descriptor is becoming a post-op configuration register file.

7. **result_tile → acc_buffer bridge would not simplify architecture**: It adds a copy pass without removing the dependency on acc_buffer. STORE/RUN overlap is lost for post-op cases.

8. **Regression cost**: Every new post-op path requires matched-comparison tests against legacy behavior, expanding test matrix combinatorially.

9. **Project priority**: Current baseline needs stabilization, performance characterization, and delivery hardening — not further control-plane expansion.

---

## 6. Why No Rollback Is Needed

**U4-b (FC + ReLU on GST) and U4-d (INT8 packing infrastructure) are retained.**

| Component | Reason to Keep |
|-----------|---------------|
| `store_desc_relu_en` | Gate defaults 0; ReLU only activates when `relu_en=1`. No post-op parameter leakage because there are no parameters — just a sign-bit check. |
| `fc_streaming_en` (no `!relu_en` gate) | FC + ReLU correctly routes through streaming with STORE/RUN overlap. Three-stage pipeline confirmed. |
| `store_desc_output_dtype` | Defaults 0 (INT32). No behavior change for existing paths. |
| `conv_cfg[6]` | Defaults 0, masked at 0x7F in npu_ctrl. No production software writes bit[6]. |
| GST INT8 packing | 32×INT8/beat infrastructure is correct for future INT8 output (requant or otherwise). Uses store_desc_relu_en, not raw relu_en. |
| acc_buffer | Untouched. All legacy paths intact. |
| dma_axi_writer | Untouched. No format-dependent changes. |
| write_beat_fifo | Untouched. Depth 64, 256-bit width. |

**Full regression PASS**: GEMM 37/37, GEMM_FUNC 6/6, FC smoke/robustness/fallback/ReLU/INT8-pack, legacy FC, 7-key regression. UVM_ERROR=0, UVM_FATAL=0. Zero cycle delta for INT32 paths.

---

## 7. FC + ReLU Three-Stage Pipeline Confirmation

```
LOAD_A(next tile) ───────┐
                          ├─ overlap confirmed (Phase 3c, 4a-3)
RUN(current tile) ────────┤
                          ├─ overlap confirmed (Phase 4c-3)
STORE(previous tile) ─────┘
  GST_PUSH_BEAT:
    reads result_tile_bank[row][col]
    applies store_desc_relu_en → ReLU(INT32)
    packs 8×INT32 or 32×INT8 per beat
    launches per-beat DMA
```

- **LOAD/RUN overlap**: input_tile_bank double buffer + background prefetch (Phase 4a-3)
- **STORE/RUN overlap**: GST background micro-FSM + gemm_store_pending queue (Phase 4c-3)
- **ReLU in GST**: Pure combinational sign-bit check, zero cycle overhead
- **Post-op safety**: store_desc_relu_en locked at STORE launch, not live relu_en

---

## 8. U4-d INT8 Packing Infrastructure Status

- ✅ store_desc_output_dtype: 0=INT32(default), 1=INT8
- ✅ GST dual-format: INT32 (8×32b/beat), INT8 (32×8b/beat)
- ✅ dma_wr_bytes per dtype: cols×4 (INT32), cols (INT8)
- ✅ row_stride per dtype: ceil(N×4/32)×32 (INT32), ceil(N/32)×32 (INT8)
- ✅ n_base addressing per dtype: `{n_base,2'b0}` (INT32), `n_base` (INT8)
- ✅ N-tiling last partial beat: INT8_NTILE N=65, last beat bytes=1
- ✅ conv_cfg[6] defaults 0, reserved internal test bit
- ✅ Uses store_desc_relu_en, not raw relu_en
- ✅ INT8 pack tests 4/4 PASS
- ❌ INT8 byte = INT32[7:0] only — no requant, no bias, no saturation

---

## 9. Legacy Issue Triage Table

### 9.1 Must Fix Before Final Baseline (Category A)

| # | Issue | Module | Status | Risk | Fix |
|---|-------|--------|:------:|:----:|-----|
| A1 | FC multi-chunk (K>64) shadow register bug | npu_top.v, FC path | Known since P2 | Low | Already worked around by GEMM K-chunking; legacy FC K>64 untested |
| A2 | Conv multi-c_in weight preload bug | conv_frontend | Pre-existing since 9586d9e | Low | 4/8 byte mismatch for cin=2; conv still uses legacy path |
| A3 | Perf counter documentation completeness | perf_counter | Partial | Low | All counters work but 0xE8-0xFC not fully documented |
| A4 | GEMM/FC last-beat partial byte regression gap | GST micro-FSM | Not covered | Low | INT8 has coverage; INT32 partial-beat needs test |
| A5 | Signed INT8 extreme value tests (-128, 127, cross-chunk signed accum) | GEMM/FC | Not covered | Low | Smoke tests use modest values; extreme boundary needs coverage |

### 9.2 Should Fix If Low Risk (Category B)

| # | Issue | Module | Status | Fix |
|---|-------|--------|:------:|-----|
| B1 | Performance characterization table (cycles/TOPS/bus%/array%) | All | Not done | Run systematic benchmarks, document in perf summary |
| B2 | Back-to-back GEMM→GEMM, GEMM→FC, FC→GEMM stress | npu_ctrl | Covered for FC | Extend to GEMM streaming |
| B3 | conv_cfg[6] production hardening | npu_ctrl, npu_top | Documented as reserved | Optional: add `ifdef SYNTHESIS force 0` guard |
| B4 | result_tile_bank valid-mask assertion for first-chunk write-once | npu_top | Not asserted | Add SVA assertion |
| B5 | K>64 cross-chunk accumulation overflow assertion | npu_top | Not asserted | Add SVA: INT32 overflow detection |

### 9.3 Keep As Future Work (Category C)

| # | Issue | Module | Notes |
|---|-------|--------|-------|
| C1 | N-tiling B/weight background prefetch enable | npu_top | Currently gated `1'b0`; Phase 4b-2 code exists |
| C2 | Conv1x1 as MatrixOp | conv_frontend | Map to MatrixOp M=H*W, K=Cin, N=Cout |
| C3 | Formal descriptor cleanup (gemm_tile_* → matrixop_tile_*) | npu_top | Rename-only, zero behavior change |
| C4 | Performance characterization (roofline, DMA vs compute) | All | System-level analysis |
| C5 | 512-bit AXI migration (feature/512bit branch) | dma_axi_writer | DMA bandwidth doubling |
| C6 | acc_buffer 128-bit widening | npu_buffer, store_pack | Store throughput improvement |
| C7 | Coverage flow / UVM full regression | verif/ | Automation infrastructure |

### 9.4 No Longer Pursue in Current Baseline (Category D)

| # | Issue | Reason |
|---|-------|--------|
| D1 | FC bias/requant full migration on result_tile GST | Post-op complexity vs marginal benefit |
| D2 | bias_tile_bank0/1 implementation | Blocked by D1 no-go |
| D3 | store_desc_bias_en / store_desc_requant_en | Blocked by D1 no-go |
| D4 | 32-lane requant in GST | Blocked by D1 no-go |
| D5 | FC legacy path deletion | acc_buffer still required for Conv/Add/Pool/GAP |
| D6 | acc_buffer removal | Required by legacy post-op and auxiliary paths |
| D7 | general Conv MatrixOp migration | Window generator complexity; defer to future project |
| D8 | descriptor queue / multiple outstanding STORE | Complexity vs pipeline depth benefit |
| D9 | MatrixOp CSR introduction | Redundant with existing task_type + conv_cfg; no clear benefit |

---

## 10. Final Architecture Boundary

```
┌─────────────────────────────────────────────────────────┐
│                    MatrixOp Fast Path                    │
│  ┌──────┐  ┌──────┐  ┌──────────┐  ┌────┐  ┌────────┐ │
│  │ LOAD │→│  RUN │→│result_tile│→│GST │→│ DMA wr │ │
│  │(A/B) │  │(PE64)│  │  bank0/1 │  │FSM │  │ (256b) │ │
│  └──────┘  └──────┘  └──────────┘  └────┘  └────────┘ │
│  input_tile             ↑ReLU        ↑INT32/INT8        │
│  double buf         store_desc    store_desc_output     │
│  ─────────────────────────────────────────────────────  │
│  GEMM ✓  FC ✓  FC+ReLU ✓                               │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                   Legacy Fallback Path                   │
│  ┌──────┐  ┌──────────┐  ┌────────────┐  ┌──────────┐ │
│  │  RUN │→│acc_buffer│→│bias+ReLU    │→│store_pack│ │
│  │(PE64)│  │ (32b×1K) │  │+requant     │  │→DMA wr   │ │
│  └──────┘  └──────────┘  └────────────┘  └──────────┘ │
│  ─────────────────────────────────────────────────────  │
│  FC+bias ✓  Conv ✓  Add ✓  Pool ✓  GAP ✓  Requant ✓   │
└─────────────────────────────────────────────────────────┘
```

---

## 11. U4-d conv_cfg[6] Reserved Hook — Handling Recommendation

**Current state**: conv_cfg[6] is AXI-Lite R/W via register 0x98. Default 0. Mask extended from 0x3F to 0x7F.

**Recommendation**: Category B (Should Fix If Low Risk).

**Optional hardening** (not required for current baseline):
1. Document in production hardening guide that bit[6] is reserved
2. If synthesis requires: add `ifdef SYNTHESIS` wrapper to force `conv_cfg[6] = 0`
3. Or leave as-is: default 0 + regression pass is sufficient evidence

**Do NOT rollback**: The mask extension from 0x3F to 0x7F enables future conv_cfg expansion without further npu_ctrl changes. Bit[6] functionality is gated by `fc_streaming_en` and has zero impact on production paths.

---

## 12. Recommended Next Phase

```
Phase U5 — System Baseline Stabilization and Performance Characterization

Scope:
  1. Add low-risk GEMM/FC stress tests (Category A items)
  2. Compile GEMM/FC/FC+ReLU cycle performance table
  3. Compile DMA bus active ratio analysis
  4. Compile array active ratio analysis
  5. Finalize architecture documentation
  6. Freeze RTL for delivery

NOT in scope:
  - bias/requant migration
  - Conv migration
  - acc_buffer removal
  - legacy path deletion
  - new descriptor fields
  - major RTL rewrite
```

---

## 13. Conclusion

Phase U4-e formally freezes MatrixOp post-op scope at U4-d. The FC bias/requant migration on result_tile GST is classified as "No Longer Pursue in current baseline." The existing MatrixOp fast path (GEMM, FC pure matmul, FC+ReLU) is confirmed stable with full regression. No rollback is needed. The project should proceed to Phase U5: system baseline stabilization and performance characterization.
