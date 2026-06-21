# ResNet-20 Fixed-Point Golden Plan

This document defines the R0.5 fixed-point golden design for CIFAR-10
ResNet-20. It is a software planning and skeleton contract only; it does not
start RTL implementation.

## 1. Current Float Candidate

Input checkpoint:

```text
datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt
```

Linux CPU full-test float recheck:

```text
8648/10000 = 86.48%
```

This is float accuracy only. It is not the fixed-point accuracy gate.

Fixed-point gate before RTL numerical implementation:

```text
CIFAR-10 software fixed-point accuracy >= 80%
```

## 2. Fixed-Point Numerical Contract

Planned v1 numerical semantics:

- Input activation: `INT8`
- Input layout: `HWC`
- Input quantization: `uint8_minus_128` or a later explicitly selected final input quantization
- Conv/FC weight: `INT8`
- Conv/FC accumulate: `INT32`
- Folded bias: `INT32`, in accumulator domain
- ReLU: `INT32` domain before requant
- Requant: existing project round-half-away-from-zero semantics
- Residual ADD: `INT32 + INT32 -> INT32`, same-scale
- GAP: fixed-point reciprocal/shift, no hardware divider
- FC head: `FC10`

Planned v1 explicitly does not implement:

- Per-channel quantization, unless separately approved later
- Dual-branch ADD rescale
- Asymmetric zero-point quantization
- RTL changes

## 3. Planned Stages

### F0: Inspect Checkpoint / Layer Graph

Inputs:

- Float candidate checkpoint
- Float full-test evaluation JSON

Outputs:

- Checkpoint tensor inventory
- ResNet-20 layer/block graph summary
- Pending fixed-point field status

### F1: BN Folding Metadata Extraction

Goal:

- Identify every Conv/BN pair.
- Compute the future folded Conv weight and INT32 bias formulas.
- Record source tensor names for each fold.
- Check folded-float equivalence against the original checkpoint model.

No memh is generated in this stage.

Current F1 entry:

```text
datasets/scripts/export_resnet20_bn_folded.py
```

Current F1 outputs:

```text
datasets/cifar10/resnet20_bn_folded/summary.json
datasets/cifar10/resnet20_bn_folded/folded_layers.json
datasets/cifar10/resnet20_bn_folded/equivalence_check.json
```

F1 scope:

- Fold metadata for initial `conv1 + bn1`.
- Fold metadata for each block `conv1 + bn1`.
- Fold metadata for each block `conv2 + bn2`.
- Fold metadata for projection shortcut `shortcut.0 + shortcut.1`.
- FC source weight/bias metadata only.
- Folded-float equivalence check over a selectable CIFAR-10 subset.

F1 remains float-domain metadata/equivalence work. It does not implement
actual fixed-point inference, does not generate memh files, and does not pass
the fixed-point accuracy gate.

Current F1 reference result on 256 CIFAR-10 test samples:

```text
Conv+BN pairs: 21
Projection shortcut folds: 2
max_abs_logit_diff: 7.62939453125e-06
mean_abs_logit_diff: 1.2664153473451733e-06
original_accuracy: 0.859375
folded_accuracy: 0.859375
accuracy_match: true
```

### F2: Activation Calibration / Quantization Scale Skeleton

Goal:

- Run folded-float activation probes over a CIFAR-10 calibration subset.
- Record activation ranges for input, Conv/ReLU, residual ADD, GAP, and FC logits.
- Generate initial per-tensor symmetric signed INT8 activation scales.
- Generate initial per-tensor symmetric signed INT8 folded weight scales.
- Generate conv/fc accumulator-scale and residual ADD same-scale planning metadata.
- Keep requant multiplier/shift search explicit as `not_implemented` until verified.

Current F2 entry:

```text
datasets/scripts/calibrate_resnet20_quantization.py
```

Current F2 outputs:

```text
datasets/cifar10/resnet20_quant_calibration/summary.json
datasets/cifar10/resnet20_quant_calibration/activation_stats.json
datasets/cifar10/resnet20_quant_calibration/quant_params.json
datasets/cifar10/resnet20_quant_calibration/requant_plan.json
```

F2 scope:

- Activation scale formula: `scale = max_abs / 127`.
- Weight scale formula: folded per-tensor `scale = max_abs / 127`.
- Zero-range protection: `scale = 1.0`.
- Per-channel quantization remains `not_implemented`.
- Residual ADD scale mismatches are recorded as `pending_same_scale_alignment`.

F2 remains calibration/requant planning metadata. It does not implement actual
fixed-point inference, does not generate memh files, and does not pass the
fixed-point accuracy gate.

### F3: Verified Requant Search / Fixed-Point Parameter Selection

Goal:

- Convert F2 scale metadata into verified multiplier/shift pairs.
- Resolve or explicitly handle residual ADD same-scale alignment.
- Produce parameters usable by the software fixed-point operator golden.

Current F3 entry:

```text
datasets/scripts/search_resnet20_requant_plan.py
```

Current F3 outputs:

```text
datasets/cifar10/resnet20_requant_plan/summary.json
datasets/cifar10/resnet20_requant_plan/conv_fc_requant.json
datasets/cifar10/resnet20_requant_plan/residual_add_alignment.json
datasets/cifar10/resnet20_requant_plan/multiplier_shift_check.json
```

F3 scope:

- Conv/FC real multiplier: `accumulator_scale / output_scale`.
- Integer approximation: `multiplier_int = round(real_multiplier * 2^shift)`.
- Search range: `shift = 0..31`.
- Multiplier bound: signed int32 positive range.
- Residual ADD policy: align both branches to `target_add_scale`.

F3 residual ADD alignment status is:

```text
planned_alignment_not_end_to_end_verified
```

F3 does not implement end-to-end fixed-point inference, does not prove full
fixed-point ADD behavior, does not run full CIFAR-10 fixed-point eval, and does
not pass the fixed-point accuracy gate.

Current F3 reference result:

```text
Conv/FC requant count: 22
Residual ADD alignment count: 9
Invalid scale count: 0
max_relative_error: 1.0778770604353305e-07
mean_relative_error: 2.8291384236134632e-08
residual_same_scale_status: planned_alignment_not_end_to_end_verified
```

### F4: Fixed-Point Operator Golden

Goal:

- Implement software INT8/INT32 Conv/ADD/GAP/FC semantics.
- Use the same requant rounding as the current project.
- Emit per-layer tensor checksums for fixture debug.

Current F4 entry:

```text
datasets/scripts/run_resnet20_fixed_point_smoke.py
```

Current F4 outputs:

```text
datasets/cifar10/resnet20_fixed_point_smoke/summary.json
datasets/cifar10/resnet20_fixed_point_smoke/predictions.json
datasets/cifar10/resnet20_fixed_point_smoke/layer_checksums.json
datasets/cifar10/resnet20_fixed_point_smoke/fixed_point_config.json
```

F4 current scope:

- Uses F1 folded Conv+BN parameters.
- Uses F2 per-tensor symmetric INT8 activation and weight scales.
- Uses F3 Conv/FC multiplier/shift and residual ADD branch alignment.
- Runs actual software INT8/INT32 operator smoke over a selectable subset.
- Records per-layer checksums for `conv1`, residual ADD ReLU outputs, GAP, and FC logits.

Current F4 reference result on 64 CIFAR-10 test samples:

```text
fixed_point_correct: 53/64
fixed_point_accuracy: 82.8125%
float_reference_correct: 54/64
float_reference_accuracy: 84.375%
```

F4 is not the full CIFAR-10 fixed-point evaluation gate.  The current smoke uses
software reference rounding and records it as
`software_reference_round_half_away_from_zero_not_rtl_locked`.  It does not
generate RTL memh files, task sequences, or the `1 MB` memory reuse map.

### F5: Full CIFAR-10 Fixed-Point Eval

Goal:

- Run full CIFAR-10 test set through fixed-point software golden.
- Gate: `accuracy >= 80%`.

Passing this gate is required before ResNet RTL numerical implementation starts.

Current F5 staged hardening uses the F4 backend through:

```text
datasets/scripts/run_resnet20_fixed_point_smoke.py
```

Current staged outputs:

```text
datasets/cifar10/resnet20_fixed_point_eval_256/
datasets/cifar10/resnet20_fixed_point_eval_1000/
```

Each staged output directory contains:

```text
summary.json
predictions.json
mismatch_summary.json
saturation_summary.json
layer_checksums.json
fixed_point_config.json
```

Current staged reference results:

```text
256 samples:
  fixed_point_correct: 218/256 = 85.15625%
  float_reference_correct: 220/256 = 85.9375%
  fixed_float_prediction_mismatch: 4/256

1000 samples:
  fixed_point_correct: 870/1000 = 87.0%
  float_reference_correct: 871/1000 = 87.1%
  fixed_float_prediction_mismatch: 21/1000
```

These staged results are not the full CIFAR-10 fixed-point gate.  The gate can
only be marked passed after `count=10000` full test evaluation reaches
`accuracy >= 80%`.  F5 staged hardening still does not generate RTL memh files,
task sequences, or the `1 MB` memory reuse map.

Current full F5 gate output:

```text
datasets/cifar10/resnet20_fixed_point_eval_10000/summary.json
datasets/cifar10/resnet20_fixed_point_eval_10000/predictions.json
datasets/cifar10/resnet20_fixed_point_eval_10000/mismatch_summary.json
datasets/cifar10/resnet20_fixed_point_eval_10000/saturation_summary.json
datasets/cifar10/resnet20_fixed_point_eval_10000/layer_checksums.json
datasets/cifar10/resnet20_fixed_point_eval_10000/fixed_point_config.json
```

Current full F5 reference result:

```text
fixed_point_correct: 8639/10000
fixed_point_accuracy: 86.39%
float_reference_correct: 8648/10000
float_reference_accuracy: 86.48%
fixed_float_prediction_mismatch: 213/10000
runtime_sec: 62.92080072220415
samples_per_sec: 158.92995456542394
max_saturation_risk_layer: fc.logits
max_saturation_total_clamp_ratio: 0.00017
fixed_point_accuracy_gate.status: passed
```

This passes the R0.5 software fixed-point accuracy gate.  It still does not
start RTL R1 and does not generate RTL handoff assets.  Before RTL numerical
implementation, the F6b handoff contract closure must be used to generate F6
handoff assets.

### F6a: RTL-Lock Rounding / Saturation / Requant Review

Goal:

- Discover the existing LeNet/NPU requant rounding, shift, and saturation
  contract.
- Compare it against the ResNet-20 software fixed-point helper.
- Generate deterministic contract vectors for handoff review.
- Decide whether INT8/INT32 export can proceed.

Current F6a entry:

```text
datasets/scripts/verify_resnet20_rtl_quant_contract.py
```

Current F6a outputs:

```text
docs/RESNET20_RTL_LOCK_REVIEW.md
datasets/cifar10/resnet20_rtl_lock_review/summary.json
datasets/cifar10/resnet20_rtl_lock_review/rounding_vectors.json
datasets/cifar10/resnet20_rtl_lock_review/requant_vectors.json
```

Current F6a reference result:

```text
rtl_lock_status: reviewed_with_open_items
rounding_contract: match existing requant_i32_to_i8 primitive
saturation_contract: match signed INT8 clamp [-128,127]
requant_contract: match existing multiplier/shift primitive
conv_fc_requant_count: 22
residual_add_alignment_count: 9
max_relative_error: 1.0778770604353305e-07
mean_relative_error: 2.8291384236134632e-08
```

F6a found no mismatch in the existing LeNet/NPU requant primitive.  It is still
not marked `reviewed_match` because these ResNet-specific items remain open:

- Folded bias INT32 export rounding must be RTL-owner locked.
- GAP reciprocal/shift semantics must be RTL-owner locked.
- Residual ADD datapath handoff must explicitly adopt the planned same-scale
  alignment and requant contract.

F6a does not generate RTL memh files, task sequences, or the `1 MB` memory
reuse map.  RTL R1 remains not started.

### F6b: RTL Handoff Contract Closure

Goal:

- Close or explicitly dispose of F6a open items.
- Freeze the ResNet-20 numerical handoff contract for export.
- Define the expected F6c export package schema.

Current F6b entry:

```text
datasets/scripts/export_resnet20_handoff_contract.py
```

Current F6b outputs:

```text
docs/RESNET20_RTL_HANDOFF_CONTRACT.md
datasets/cifar10/resnet20_handoff_contract/summary.json
datasets/cifar10/resnet20_handoff_contract/numerical_contract.json
datasets/cifar10/resnet20_handoff_contract/op_contract.json
datasets/cifar10/resnet20_handoff_contract/export_manifest_schema.json
```

Current F6b reference result:

```text
handoff_contract_status: reviewed_contract_closed_for_export
closed_items: 3
waiver_items: 0
unresolved_items: 0
next_allowed_stage: export_int8_int32_assets
```

Closed F6a items:

- Folded bias INT32 rounding: `closed_for_export`; R1 must consume signed
  INT32 folded bias in accumulator domain.
- GAP reciprocal/shift: `closed_for_export`; R1 must implement GAP datapath or
  an explicit task-sequence macro without hardware divider.
- Residual ADD datapath: `closed_for_export`; R1 must implement ADD or
  postprocess op using planned same-scale branch alignment.

F6b still does not generate INT8 weight memh, INT32 folded bias memh, final task
sequence, or the `1 MB` memory reuse map.  RTL R1 remains not started.

### F6c/F6g: INT8/INT32/Requant Export Package and Validation

Goal:

- Export INT8 weights from folded Conv/FC tensors.
- Export INT32 folded bias vectors.
- Export Conv/FC, residual ADD, and GAP requant metadata.
- Validate package consistency before task sequence / memory map work.

Current F6c/F6g entries:

```text
datasets/scripts/export_resnet20_int8_package.py
datasets/scripts/validate_resnet20_export_package.py
```

Current F6c/F6g outputs:

```text
docs/RESNET20_EXPORT_PACKAGE.md
datasets/cifar10/resnet20_export_package/summary.json
datasets/cifar10/resnet20_export_package/manifest.json
datasets/cifar10/resnet20_export_package/weights/summary.json
datasets/cifar10/resnet20_export_package/weights/*.memh
datasets/cifar10/resnet20_export_package/bias/summary.json
datasets/cifar10/resnet20_export_package/bias/*.memh
datasets/cifar10/resnet20_export_package/requant/summary.json
datasets/cifar10/resnet20_export_package/requant/conv_fc_requant.json
datasets/cifar10/resnet20_export_package/requant/residual_add_alignment.json
datasets/cifar10/resnet20_export_package/requant/gap_requant.json
datasets/cifar10/resnet20_export_package/validation_report.json
```

Current F6c/F6g reference result:

```text
weight_file_count: 22
bias_file_count: 22
conv_fc_requant_count: 22
residual_add_alignment_count: 9
gap_requant_status: searched
validation_status: pass
validation_error_count: 0
task_sequence_generated: false
one_mb_memory_reuse_map_generated: false
rtl_r1_started: false
```

F6c/F6g itself does not generate final `task_sequence.json` or final
`memory_map.json`.  Those handoff files are generated by F6d/F6e.  RTL R1
remains not started.

### F6d/F6e: Task Sequence and 1 MB Memory Map

Goal:

- Generate final logical `task_sequence.json`.
- Generate `1 MB` shared-memory `memory_map.json`.
- Validate task references, tensor liveness, `64B` alignment, and 1 MB bounds.
- Update the export package manifest/summary for RTL R1 review.

Current F6d/F6e entries:

```text
datasets/scripts/generate_resnet20_task_memory_map.py
datasets/scripts/validate_resnet20_task_memory_map.py
```

Current F6d/F6e outputs:

```text
docs/RESNET20_TASK_MEMORY_MAP.md
datasets/cifar10/resnet20_export_package/task_sequence.json
datasets/cifar10/resnet20_export_package/memory_map.json
datasets/cifar10/resnet20_export_package/task_memory_validation.json
datasets/cifar10/resnet20_export_package/manifest.json
datasets/cifar10/resnet20_export_package/summary.json
datasets/cifar10/resnet20_export_package/validation_report.json
```

Current F6d/F6e reference result:

```text
task_count: 32
conv_task_count: 21
residual_add_task_count: 9
gap_task_count: 1
fc_task_count: 1
memory_total_bytes: 1048576
memory_peak_live_bytes: 49152
memory_max_end_address: 289920
alignment_status: pass
live_range_overlap_status: pass
task_memory_validation_status: pass
export_package_validation_status: pass
```

F6d/F6e makes the handoff package ready for RTL R1 review.  It does not start
or implement RTL R1.

## 4. Skeleton Assets

Current skeleton scripts:

```text
datasets/scripts/inspect_resnet20_checkpoint.py
datasets/scripts/export_resnet20_fixed_point_skeleton.py
datasets/scripts/export_resnet20_bn_folded.py
datasets/scripts/calibrate_resnet20_quantization.py
datasets/scripts/search_resnet20_requant_plan.py
datasets/scripts/verify_resnet20_rtl_quant_contract.py
datasets/scripts/export_resnet20_handoff_contract.py
datasets/scripts/export_resnet20_int8_package.py
datasets/scripts/validate_resnet20_export_package.py
datasets/scripts/generate_resnet20_task_memory_map.py
datasets/scripts/validate_resnet20_task_memory_map.py
```

They must not generate fake memh, fake task sequences, or fake memory maps.

Skeleton-only status labels used by early F0/F1/F2 assets:

```text
fixed_point_status = skeleton_only
fixed_point_accuracy_gate.status = not_evaluated
fold_bn_status = not_implemented
int8_weight_export_status = not_implemented
int32_bias_export_status = not_implemented
requant_search_status = not_implemented
```

These labels do not override the later F5 full evaluation result.  The current
full fixed-point evaluation output reports
`fixed_point_accuracy_gate.status = passed`.

## 5. RTL Boundary

No RTL R1/R2/R3 work may start from this document alone. ResNet RTL work still
requires a completed software fixed-point golden with `>=80%` CIFAR-10
fixed-point accuracy, closed F6b handoff contract, validated F6c/F6g export
package, and a validated task/memory-map handoff.  The current package satisfies
those handoff inputs and is ready for RTL R1 review; RTL R1 itself remains not
started.
