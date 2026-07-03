# NPU Test Case Inventory

## 1. Baseline Information

| Item | Value |
|------|-------|
| Final delivery tag | `npu-final-delivery-v1.0` |
| Main HEAD | `fbfb3f2` — Merge Phase U6-a |
| Date | 2026-07-02 |
| Scope | All UVM tests, sequences, checkers, probes, scripts |

---

## 2. Test Directory Overview

| Directory | Contents | Count |
|-----------|----------|-------|
| `verif/uvm_top/tests/` | UVM test classes (active) | 51 registered tests |
| `verif/uvm_top/tests/archive/` | Archived legacy tests (U7-a) | 5 files (not in regression) |
| `verif/uvm_top/sequences/` | Reusable test sequences | 13 files |
| `verif/uvm_top/pkg/` | UVM package (includes all) | 1 file |
| `verif/uvm_top/checkers/` | Pipeline checker (stub) | 1 file |
| `verif/uvm_top/interfaces/` | AXI-Lite, probe, backdoor | 3 files |
| `verif/uvm_top/tb/` | Top-level testbench + defines | 2 files |
| `verif/uvm_top/scripts/` | VCS compile-and-run | 1 script |
| `docs/` | Phase & test documentation | ~20 files |

---

## 3. Test Category Summary

| Category | Count | Main Coverage |
|----------|-------|---------------|
| A. Smoke / basic | 5 | CSR, DMA, task start/poll, basic operators |
| B. GEMM / MatrixOp fast path | 7 | GEMM streaming, K>64, N-tile, extreme values, B1 |
| C. FC streaming | 5 | FC streaming, ReLU, INT8 pack, robustness, fallback |
| D. Legacy / auxiliary operators | 14 | Conv, Add, Pool, GAP, Requant, bias, VecReLU |
| E. Back-to-back / pipeline | 2 | Sequential tasks, store/compute overlap |
| F. Low-power / clock gating | 1 | PE array idle clock disable (U6-a) |
| G. Performance / bandwidth | 7 | Counters, throughput, bandwidth, TOPS |
| H. Error path | 3 | Invalid task, misaligned addr, start-while-busy |
| I. Cluster / array structural | 6 | Cluster mode, mask, full array, probe verification |
| J. Diagnostic / debug | 5 | Conv multi-cluster, frontend hang diag |
| **Total active** | **50 registered** | — |
| Archived (U7-a) | 5 | Legacy multi-cluster / diagnostic tests |

---

## 4. Consistency Check

| Check | Result |
|-------|--------|
| Tests in package also on disk | ✅ All 55 included tests exist |
| Tests on disk also in package | ✅ All active tests registered; 5 archived separately |
| Orphan tests | 0 |
| Archived tests (Phase U7-a) | 5: `npu_cluster_mode_test`, `npu_cluster_mask_sweep_test`, `npu_perf_counter_scaling_test`, `npu_conv_1x1_dual_32oc_diag_test`, `npu_fc_b1_diag` |
| Base test registered | ✅ `soc_base_test.sv` |
| Shared RAM test registered | ✅ `soc_shared_ram_rw_test.sv` |

---

## 5. Complete Test List

### 5.1 Smoke / Basic Tests

| # | Test Name | Purpose | Task | Config | Status |
|---|-----------|---------|------|--------|--------|
| 1 | `soc_shared_ram_rw_test` | AXI-Lite path sanity: write/read shared RAM | — | — | PASS |
| 2 | `npu_fc_smoke_test` | Legacy FC: 4×1 INT8 input, DPI golden | FC=1 | default | PASS |
| 3 | `npu_conv_smoke_test` | Legacy Conv 5×5 valid: DPI golden | Conv=0 | default | PASS |
| 4 | `npu_add_smoke_test` | INT8 element-wise ADD | ADD=5 | default | PASS |
| 5 | `npu_gap_smoke_test` | 8×8 GAP | GAP=4 | default | PASS |

### 5.2 GEMM / MatrixOp Fast Path Tests

| # | Test Name | Purpose | Task | Config | Related Phase/Bug | Status |
|---|-----------|---------|------|--------|-------------------|--------|
| 6 | `npu_task_gemm_func_test` | TASK_GEMM functional: G0-G6 levels | GEMM=7 | default | U0 | PASS |
| 7 | `npu_task_gemm_row_streaming_test` | GEMM row-streaming: RS0-RS19 + MT0-MT5 + NT0-NT6 (largest test, 112KB) | GEMM=7 | streaming=0x20 | U1-U3 | PASS |
| 8 | `npu_gemm_kchunk_stress_test` | K>64 accumulation: K=65,127,128,129,192,255 × M=1,4,8 × N=1,8,63,64,65 (36 cases) | GEMM=7 | streaming=0x20 | U5-a Task A | **PASS** |
| 9 | `npu_matrixop_partial_beat_stress_test` | INT32/INT8 partial beat: N=1-65 × M=1,2,4 byte-accurate (60 cases) | GEMM=7, FC=1 | streaming=0x20, INT8=0x60 | U5-a Task B | **PASS** |
| 10 | `npu_int8_extreme_value_stress_test` | Signed INT8 extremes: 8 patterns × 4 K × 6 M/N (192 cases) | GEMM=7 | streaming=0x20 | U5-a Task C, **B1** | **PASS** |
| 11 | `npu_gemm_ntile_nonuniform_diag_test` | N>64 non-uniform weight diag: checkerboard, col-coded, k-col-coded | GEMM=7 | streaming=0x20 | U5-b **B1 fix** | **PASS** |
| 12 | `npu_axi_gemm_peak_test` | AXI-fed GEMM peak microbenchmark (supplemental) | GEMM=7 | — | Historical | PASS |

### 5.3 FC Streaming Tests

| # | Test Name | Purpose | Task | Config | Related Phase/Bug | Status |
|---|-----------|---------|------|--------|-------------------|--------|
| 13 | `npu_fc_streaming_smoke_test` | FC routed through streaming GEMM pipeline | FC=1 | streaming=0x20 | U1 | PASS |
| 14 | `npu_fc_streaming_relu_test` | FC streaming + ReLU via GST | FC=1 | streaming=0x20, relu=1 | U4-b | PASS |
| 15 | `npu_fc_streaming_robustness_test` | Boundary, signed, legacy-vs-streaming, post-op fallback | FC=1 | streaming=0x20 | U2 | PASS |
| 16 | `npu_fc_streaming_int8_pack_test` | FC INT8 packing via conv_cfg[6] test hook | FC=1 | streaming=0x20, INT8=0x60 | U4-d | PASS |
| 17 | `npu_fc_streaming_fallback_test` | FC with bias falls back to legacy path | FC=1 | bias=0x10, streaming=0x20 | U1, **K1/K1-b fix** | **PASS** |

### 5.4 Legacy / Auxiliary Operator Tests

| # | Test Name | Purpose | Task | Status |
|---|-----------|---------|------|--------|
| 18 | `npu_conv_1x1_smoke_test` | Conv 1×1 kernel, 3×3 input | Conv=0 | PASS |
| 19 | `npu_conv_3x3_same_test` | Conv 3×3 kernel, same padding | Conv=0 | PASS |
| 20 | `npu_conv_stride2_test` | Conv 3×3 kernel, stride=2 | Conv=0 | PASS |
| 21 | `npu_conv_bias_requant_test` | Conv 5×5, bias + requant, 2 output channels | Conv=0 | PASS |
| 22 | `npu_conv_multichannel_test` | Conv 3×3, Cin=2, Cout=2 multi-channel | Conv=0 | PASS |
| 23 | `npu_pool_smoke_test` | 2×2 MaxPool, 1 channel | Pool=2 | PASS |
| 24 | `npu_pool_multichannel_test` | 2×2 MaxPool, 4 channels | Pool=2 | PASS |
| 25 | `npu_requant_smoke_test` | INT32→INT8 requant, multiplier/shift | Requant=3 | PASS |
| 26 | `npu_requant_extreme_test` | Requant clamping at [-128,127] boundary | Requant=3 | PASS |
| 27 | `npu_requant_partial_beat_test` | Requant 9 INT32→9 INT8, non-beat-aligned | Requant=3 | PASS |
| 28 | `npu_add_requant_test` | INT8 ADD with pre/post-requant | ADD=5 | PASS |
| 29 | `npu_bandwidth_test` | Conv bandwidth: DMA read/write traffic | Conv=0 | PASS |
| 30 | `npu_bandwidth_60pct_stress_test` | VecReLU 256-bit streaming: 60% bus target | VecReLU=6 | PASS |
| 31 | `npu_conv_bandwidth_test` | Conv bandwidth: 1×1, 128 output channels | Conv=0 | PASS |

### 5.5 Back-to-Back / Pipeline Tests

| # | Test Name | Purpose | Related Phase | Status |
|---|-----------|---------|---------------|--------|
| 32 | `npu_back_to_back_task_test` | Two sequential FC tasks without reset | Structural UVM | PASS |
| 33 | `npu_back_to_back_task_stress_test` | 8 streaming transitions: GEMM↔FC↔ReLU↔K-chunk | U5-a Task D | **PASS** |

### 5.6 Low-Power / Clock Gating Tests

| # | Test Name | Purpose | Related Phase | Status |
|---|-----------|---------|---------------|--------|
| 34 | `npu_pe_array_clock_gating_test` | PE array clock enable: idle=0, active=1, done=0 via UVM probe | **U6-a** | **PASS** |

### 5.7 Performance / Bandwidth Tests

| # | Test Name | Purpose | Status |
|---|-----------|---------|--------|
| 35 | `npu_peak_throughput_test` | FC 64→64: full 4096 PE throughput | PASS |
| 36 | `npu_fc_128x128_peak_test` | FC 128×128 peak TOPS measurement | PASS |
| 37 | `npu_gemm_pipeline_bw_tops_test` | GEMM pipeline BW+TOPS (EXPERIMENTAL) | Historical FAIL |
| 38 | `npu_conv_multiblock_test` | Conv multi-block: 3 blocks pipeline | PASS |
| 39 | `npu_lenet_1_test` | Full LeNet-5 9-layer pipeline | PASS |
| 40 | `npu_conv_1x1_full_96oc_diag_test` | 1×1 Conv 96 output channels | PASS |

### 5.8 Error Path Tests

| # | Test Name | Purpose | Expected Error | Status |
|---|-----------|---------|----------------|--------|
| 42 | `npu_error_invalid_task_test` | Invalid task_type triggers error | ERR_INVALID_TASK_TYPE (0x01) | PASS |
| 43 | `npu_error_misaligned_addr_test` | Non-64B-aligned address triggers error | ERR_ADDR_ALIGN (0x04) | PASS |
| 44 | `npu_start_while_busy_test` | CTRL.start while busy → error | ERR_START_WHILE_BUSY | PASS |

### 5.9 Cluster / Array Structural Tests

| # | Test Name | Purpose | Status |
|---|-----------|---------|--------|
| 41 | `npu_fc_16x16_full_array_test` | Full 16×16 tile array activation, sticky probe | PASS |
| 42 | `npu_fc_full_array_activation_test` | Full 64×64 PE array activation (renamed U7-a) | PASS |

### 5.10 Diagnostic / Debug Tests

| # | Test Name | Purpose | Status |
|---|-----------|---------|--------|
| 43 | `npu_conv_1x1_single_16oc_diag_test` | Single-cluster Conv 16oc baseline | PASS |
| 44 | `npu_conv_1x1_multiwindow_diag_test` | 1×1 Conv multi-window hang test | PASS |
| 45 | `npu_conv_3x3_multiwindow_diag_test` | 3×3 Conv multi-window hang test | PASS |
| 46 | `npu_conv_5x5_singlewindow_diag_test` | 5×5 Conv single-window baseline | PASS |
| 47 | `npu_conv_1x1_full_array_multiwindow_diag_test` | Full-array multi-window hang test (renamed U7-a) | PASS |

### 5.11 Base Test (not a standalone test)

| # | Test Name | Purpose |
|---|-----------|---------|
| 55 | `soc_base_test` | Base class for all tests; creates env, enables monitors |

### 5.12 NPU IRQ / Interrupt Reporting Tests (Phase U8-a)

| # | Test Name | Purpose | Task | Config | Related Phase | Status |
|---|-----------|---------|------|--------|---------------|--------|
| 48 | `npu_irq_reporting_test` | BFM-level IRQ: done/error pending, enable gating, W1C clear, B2B (7 sub-tests) | GEMM=7, error test | streaming=0x20 | **U8-a** | **PASS** |

**Note:** U8-a is BFM-level verification only. No CPU-running interrupt firmware is implemented. IRQ CSRs at 0x100/0x104/0x108 in extended NPU CSR space (512B window).

### 5.13 Archived Tests (Phase U7-a, not in active regression)

| # | Test Name | Archive Reason |
|---|-----------|----------------|
| A1 | `npu_cluster_mode_test` | Multi-cluster modes; CLUSTER_COUNT=1 renders mode>0 as NO-OP |
| A2 | `npu_cluster_mask_sweep_test` | Multi-cluster mask sweep; only mask[0] valid for CLUSTER_COUNT=1 |
| A3 | `npu_perf_counter_scaling_test` | 1/2/6 cluster scaling; meaningless for CLUSTER_COUNT=1 |
| A4 | `npu_conv_1x1_dual_32oc_diag_test` | Dual-cluster Conv diagnostic; CLUSTER_COUNT=1 |
| A5 | `npu_fc_b1_diag` | Historical FC B1 multi-tile mismatch diagnostic; pre-fix fingerprint |

All archived files preserved in `verif/uvm_top/tests/archive/`.

---

## 6. Regression Suites

### 6.1 Core Regression (7 tests)

```
npu_fc_smoke_test, npu_conv_smoke_test, npu_add_smoke_test,
npu_gap_smoke_test, npu_pool_smoke_test, npu_requant_smoke_test,
soc_shared_ram_rw_test
```

### 6.2 MatrixOp Fast Path Regression (10 tests)

```
npu_task_gemm_func_test, npu_task_gemm_row_streaming_test,
npu_gemm_kchunk_stress_test, npu_matrixop_partial_beat_stress_test,
npu_int8_extreme_value_stress_test, npu_gemm_ntile_nonuniform_diag_test,
npu_fc_streaming_smoke_test, npu_fc_streaming_relu_test,
npu_fc_streaming_robustness_test, npu_back_to_back_task_stress_test
```

### 6.3 Legacy / Fallback Regression (6 tests)

```
npu_fc_streaming_fallback_test, npu_conv_smoke_test,
npu_conv_1x1_smoke_test, npu_pool_smoke_test,
npu_requant_smoke_test, npu_bandwidth_60pct_stress_test
```

### 6.4 Low-Power Regression (1 test)

```
npu_pe_array_clock_gating_test
```

### 6.5 NPU IRQ Regression (1 test)

```
npu_irq_reporting_test
```

### 6.6 Full Stress Regression (all 51 registered tests)

Run time: ~2-3 hours at 200MHz simulation.

---

## 7. Run Commands

### Standard UVM test run

```bash
./verif/uvm_top/scripts/run_uvm.sh <test_name> [verbosity]

# Examples:
./verif/uvm_top/scripts/run_uvm.sh npu_fc_smoke_test UVM_NONE
./verif/uvm_top/scripts/run_uvm.sh npu_gemm_kchunk_stress_test UVM_MEDIUM
```

### Reuse compiled simv

```bash
./sim/simv_uvm_top +UVM_TESTNAME=<test_name> +UVM_VERBOSITY=UVM_NONE
```

### Compilation command (from run_uvm.sh)

```bash
vcs -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm-1.2 \
    +incdir+rtl/npu +incdir+rtl/soc +incdir+rtl/bus +incdir+rtl/cpu/picorv32 \
    +incdir+verif/uvm_top/tb +incdir+verif/uvm_top/interfaces +incdir+verif/uvm_top/pkg \
    +incdir+verif/uvm_top/tests +incdir+verif/uvm_top/ref_model +incdir+verif/uvm_top/checkers \
    -top tb_soc_top_uvm -o sim/simv_uvm_top -f verif/uvm_top/filelist.f
```

---

## 8. Checkers / SVA / Probe Infrastructure

| File | Type | Status |
|------|------|--------|
| `verif/uvm_top/checkers/npu_matrixop_pipeline_checker.sv` | Documented assertion plan (stub) | Inactive: 10 check categories defined, SVA commented out. Functional coverage from stress tests. |
| `verif/uvm_top/interfaces/soc_probe_if.sv` | UVM probe interface | Active: npu_status, npu_cluster_tile_clk_en_flat, DMA signals |
| `verif/uvm_top/interfaces/axil_if.sv` | AXI-Lite interface | Active: CSR register programming |
| `verif/uvm_top/interfaces/backdoor_if.sv` | Backdoor memory access | Active: fast RAM preload |
| `verif/uvm_top/env/soc_scoreboard.sv` | Output compare | Active: byte-level golden comparison |
| `verif/uvm_top/env/soc_perf_checker.sv` | DMA performance checker | Active: read/write beat counting |

**K4 (SVA/checker activation): Future work.** Functional coverage is sufficient from stress tests.

---

## 9. Coverage Gaps and Future Work

| Gap | Priority | Notes |
|-----|----------|-------|
| SVA/checker activation (K4) | Low | Stub exists; functional stress tests cover most checks |
| Legacy Conv/FC B2B coverage (K5) | Low | Only streaming transitions covered; legacy deferred |
| Per-tile utilization clock gating test | Future | Current U6-a uses global FSM-based gating |
| Multi-cluster regression (CLUSTER_MODE>0) | Future | Current baseline is CLUSTER_COUNT=1 |
| ASIC/FPGA synthesis regression | Future | RTL simulation only; no gate-level verification |
| Formal property verification | Future | No SVA assertions active |
| `npu_fc_b1_diag.sv` orphan registration | Low | Either register in package or archive |

---

## 10. Final Summary

| Metric | Value |
|--------|-------|
| Total test files | 55 (50 active + 5 archived) |
| Active registered tests | 50 |
| Archived tests (U7-a, not in regression) | 5 |
| Orphan tests (not in package) | 0 |
| Base test class | 1 (`soc_base_test`) |
| Concrete test classes (active) | 49 |
| Tests with PASS status (active) | 48 |
| Tests with FAIL status (pre-existing, known) | 0 in baseline, 1 historical (`gemm_pipeline_bw_tops_test`) |
| UVM sequences | 13 |
| Checker files | 1 (stub) |
| Run scripts | 1 (`run_uvm.sh`) |
| Interfaces | 3 |
| **UVM_ERROR** | 0 (for all baseline regression) |
| **UVM_FATAL** | 0 (for all baseline regression) |
| **Baseline** | Single-cluster 64×64 PE NPU, CLUSTER_COUNT=1 |
