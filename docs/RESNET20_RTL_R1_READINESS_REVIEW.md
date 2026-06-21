# ResNet-20 RTL R1 Readiness Review

This document records R1-0: ResNet-20 RTL R1 readiness review and
implementation scope.  It does not modify RTL/testbench and does not start RTL
R1 implementation.

## 1. Source Evidence

R0.5 handoff package status:

```text
software fixed-point full eval:
  datasets/cifar10/resnet20_fixed_point_eval_10000/summary.json
  8639/10000 = 86.39%

handoff contract:
  datasets/cifar10/resnet20_handoff_contract/summary.json
  handoff_contract_status = reviewed_contract_closed_for_export

export package validation:
  datasets/cifar10/resnet20_export_package/validation_report.json
  validation_status = pass

task/memory validation:
  datasets/cifar10/resnet20_export_package/task_memory_validation.json
  validation_status = pass
```

Generated R1-0 machine-readable review:

```text
datasets/cifar10/resnet20_export_package/rtl_r1_readiness.json
```

## 2. Inspected RTL Files

Primary inspected files:

```text
rtl/npu/npu_top.v
rtl/npu/npu_ctrl.v
rtl/npu/task_checker.v
rtl/npu/block_scheduler.v
rtl/npu/conv_frontend.v
rtl/npu/requant_i32_to_i8.v
rtl/npu/compute_core_6cluster.v
rtl/npu/output_arbiter.v
rtl/npu/dma_axi_reader.v
rtl/npu/dma_axi_writer.v
rtl/npu/npu_buffer.v
rtl/npu/postproc.v
rtl/npu/fc_frontend.v
rtl/npu/act_read_path.v
rtl/npu/weight_read_path.v
rtl/npu/perf_counter.v
```

The review also checked the R0.5 scripts/docs with:

```text
rg "task_type|kernel|stride|requant|bias|add|gap|fc|5x5|3x3|output_c|input_h" rtl/npu datasets/scripts docs
```

## 3. Current RTL Capability Inventory

Current supported capability:

- `npu_ctrl.v`: AXI-Lite register file with legacy 2-bit `task_type`, base
  addresses, byte counts, dimensions, postproc bits, four requant slots, and
  runtime `CLUSTER_MODE / CLUSTER_MASK` at `0x88/0x8C`.
- `task_checker.v`: validates legacy task types `0=Conv`, `1=FC`, `2=Pool`,
  `3=Requant`, 64B alignment, 1 MB bounds, non-zero bytes, Conv input
  dimensions `>=5x5`, Pool even dimensions, and requant multiplier/shift.
- `block_scheduler.v`: splits legacy Conv/FC/Pool/Requant tasks. Conv is
  fixed to 5x5 valid stride1 shape math:
  `out_h=input_h-5+1`, `out_w=input_w-5+1`, `wgt_bytes_per_cin=25*output_c`.
- `conv_frontend.v`: 5x5 HWC INT8 window generator, stride1, valid padding.
- `npu_top.v`: formal 6-cluster path, legacy Conv/Pool/Requant and arrayized
  FC orchestration, fixed `KERNEL_SPATIAL=25`, existing read/write DMA, store
  packing, and arrayized FC path.
- `requant_i32_to_i8.v`: signed INT32 to INT8 requant primitive using
  round-half-away-from-zero, positive multiplier, shift `0..31`, and signed
  INT8 clamp `[-128,127]`.
- `compute_core_6cluster.v` / `output_arbiter.v`: 6-cluster compute and routed
  global-column OR merge semantics used by the current formal path.
- `dma_axi_reader.v` / `dma_axi_writer.v` / `npu_buffer.v`: 256-bit AXI4 INCR
  data movement, local buffering, and write path. `dma_axi_writer.v` keeps the
  last-beat `WSTRB` byte-count contract.
- `postproc.v`: existing ReLU / Pool style post-processing for the LeNet path.

Current unsupported ResNet capabilities:

- `task_type` values `ADD` and `GAP`.
- Direct consumption of `task_sequence.json`.
- Direct consumption of `memory_map.json`.
- Append-only ResNet config registers `VERSION`, `CAPABILITY`, `CONV_CFG`,
  `BIAS_ADDR`, `BIAS_BYTES`, `SRC1_ADDR`, `SRC1_BYTES`, `ADD_CFG`, `GAP_CFG`,
  and `POSTPROC_CFG`.
- Generalized Conv kernel sizes `1x1` and `3x3`.
- `stride2` Conv.
- same padding output shape and boundary handling.
- 1x1 stride2 projection Conv.
- INT32 folded bias add in the Conv/FC accumulator domain.
- Residual ADD datapath or postprocess op.
- GAP8x8 datapath or macro task.
- ResNet export package weight/bias/requant preload interpretation.

## 4. R1 Required Changes

### R1a: Descriptor / Task Decode Extension Skeleton

- Expand `task_type` end-to-end from 2 bit to at least 3 bit while preserving
  legacy encodings `0..3`.
- Add append-only AXI-Lite registers after `0x8C`:
  `VERSION`, `CAPABILITY`, `CONV_CFG`, `BIAS_ADDR`, `BIAS_BYTES`, `SRC1_ADDR`,
  `SRC1_BYTES`, `ADD_CFG`, `GAP_CFG`, and `POSTPROC_CFG`.
- Keep reset defaults LeNet-compatible.
- Add readback coverage for all new registers.
- While ADD/GAP datapaths are not implemented, either make `task_checker` reject
  them deterministically or keep capability bits marked unsupported.

### R1b: Generalized Conv 3x3/1x1 Stride Support

- Generalize `conv_frontend` beyond 5x5 valid stride1.
- Generalize `block_scheduler` output shape, input row overlap, row stride, and
  weight bytes per input channel.
- Generalize `npu_top` `KERNEL_SPATIAL`, `array_active_rows`,
  `conv_wgt_valid_bytes`, and weight extraction.
- Preserve legacy 5x5 valid behavior bit-exact.

### R1c: Folded Bias + Requant Integration

- Add INT32 folded bias input path from `BIAS_ADDR/BIAS_BYTES`.
- Add bias in accumulator domain before final requant/postprocess.
- Preserve existing `requant_i32_to_i8` arithmetic exactly.
- Consume F6c/F6g bias and requant metadata without changing export semantics.

### R1d: Residual ADD Op

- Add `task_type=ADD` or an equivalent postprocess op under the approved
  append-only control model.
- Read main and shortcut tensors from shared memory using `SRC0/SRC1`.
- Apply F3 branch alignment to target ADD scale.
- Perform INT32 aligned add, optional ReLU, requant to post-ReLU scale, and
  signed INT8 clamp.

### R1e: GAP Op

- Add `task_type=GAP` or an explicit macro-task path.
- Sum 8x8 spatial region per channel in INT32.
- Use fixed reciprocal/shift; do not add hardware divider.
- Requant to GAP output scale and emit INT8 vector length 64.

### R1f: ResNet Task-Sequence Testbench Smoke

- Add a ResNet-specific driver/testbench path that reads the generated
  `task_sequence.json` and `memory_map.json`, or translates them to AXI-Lite
  writes in a deterministic fixture runner.
- Do not change existing LeNet testbench semantics.

### R1g: Small Fixture Fixed-Point Comparison

- Run a small ResNet fixed-point fixture against software golden predictions.
- Compare layer/tensor checksums where available.
- Keep LeNet/HB/AXI smoke regressions as guardrails.

## 5. Immutable Contracts

R1 implementation must not change:

- Existing LeNet behavior and task encodings `0..3`.
- Existing AXI-Lite register meanings and addresses through `0x8C`.
- Existing `requant_i32_to_i8` round-half-away-from-zero / clamp semantics.
- Shared memory organization: `1 MB = 32768 x 256-bit beat`.
- NPU task base address alignment: `64B`.
- AXI/HB completed project subset.
- `acc_buffer -> DMA writer` packing and last-beat `WSTRB` behavior.
- Single-task register-triggered control model, unless separately approved.
- R0.5 fixed-point export package numerical semantics.

## 6. Blockers and Non-Blockers

Blocking items before R1a coding:

```text
none
```

No package blocker remains: software fixed-point gate passed, handoff contract
closed, export package validation passed, and task/memory validation passed.

Non-blockers to solve during R1 coding:

- Existing RTL lacks 3-bit task type and append-only ResNet registers.
- Existing Conv path is fixed 5x5 valid stride1.
- Existing datapath lacks folded bias input/accumulate support.
- Existing datapath lacks residual ADD.
- Existing datapath lacks GAP.
- Existing testbench/scripts do not consume `task_sequence.json` and
  `memory_map.json` directly.

These are the expected R1 implementation scope, not blockers to starting R1a.

## 7. Readiness Decision

```text
rtl_r1_ready_for_review: true
rtl_r1_ready_for_implementation: true for R1a/R1 foundation coding
rtl_modified: false
testbench_modified: false
rtl_r1_started: false
```

Recommended next coding slice:

```text
R1a: task_type/register/capability foundation
```

R1a should only add the append-only control foundation and deterministic
unsupported-task handling.  It should not attempt generalized Conv, ADD, GAP, or
full ResNet execution in the same coding step.

