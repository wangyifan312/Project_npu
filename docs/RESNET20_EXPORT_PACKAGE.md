# ResNet-20 INT8/INT32 Export Package

This document records R0.5 F6c/F6g and F6d/F6e package state: ResNet-20 INT8
weights, INT32 folded bias, requant metadata, final logical task sequence, and
`1 MB` memory map generation/validation.  It does not start RTL R1.

## 1. Inputs

- Checkpoint:
  `datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt`
- Folded metadata:
  `datasets/cifar10/resnet20_bn_folded/folded_layers.json`
- Quant params:
  `datasets/cifar10/resnet20_quant_calibration/quant_params.json`
- Conv/FC requant:
  `datasets/cifar10/resnet20_requant_plan/conv_fc_requant.json`
- Residual ADD alignment:
  `datasets/cifar10/resnet20_requant_plan/residual_add_alignment.json`
- Full fixed-point eval:
  `datasets/cifar10/resnet20_fixed_point_eval_10000/summary.json`
- F6b handoff contract:
  `datasets/cifar10/resnet20_handoff_contract/summary.json`

Precheck requirements:

```text
fixed_point_accuracy_gate.status = passed
fixed_point_accuracy >= 0.80
handoff_contract_status = reviewed_contract_closed_for_export
next_allowed_stage = export_int8_int32_assets
```

## 2. Export Command

```bash
python3 datasets/scripts/export_resnet20_int8_package.py \
  --checkpoint datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt \
  --folded-layers datasets/cifar10/resnet20_bn_folded/folded_layers.json \
  --quant-params datasets/cifar10/resnet20_quant_calibration/quant_params.json \
  --conv-fc-requant datasets/cifar10/resnet20_requant_plan/conv_fc_requant.json \
  --residual-add-alignment datasets/cifar10/resnet20_requant_plan/residual_add_alignment.json \
  --fixed-eval datasets/cifar10/resnet20_fixed_point_eval_10000/summary.json \
  --handoff-contract datasets/cifar10/resnet20_handoff_contract/summary.json \
  --output-dir datasets/cifar10/resnet20_export_package
```

## 3. Package Contents

Output directory:

```text
datasets/cifar10/resnet20_export_package/
```

Generated package files:

```text
summary.json
manifest.json
weights/summary.json
weights/*.memh
bias/summary.json
bias/*.memh
requant/summary.json
requant/conv_fc_requant.json
requant/residual_add_alignment.json
requant/gap_requant.json
validation_report.json
task_sequence.json
memory_map.json
task_memory_validation.json
```

Package summary:

```text
weight_file_count: 22
bias_file_count: 22
conv_fc_requant_count: 22
residual_add_alignment_count: 9
gap_requant_status: searched
fixed_point_accuracy: 0.8639
gate_status: passed
task_sequence_generated: true
one_mb_memory_reuse_map_generated: true
```

Weight export:

- dtype: signed INT8
- quantization: per-tensor symmetric signed INT8
- Conv layout target: `IHWO` converted from PyTorch `OIHW`
- FC layout target: `OI`
- memh encoding: one two's-complement hex value per line

Bias export:

- dtype: signed INT32
- formula:
  `round_half_away_from_zero(folded_bias / accumulator_scale)`
- ordering: output channel / output neuron order
- memh encoding: one 32-bit two's-complement hex value per line

Requant export:

- Conv/FC requant copied from F3.
- Residual ADD alignment copied from F3.
- GAP requant generated from `gap.input` and `gap.output` scales with
  `kernel_area = 64`.

## 4. Validation

Validation command:

```bash
python3 datasets/scripts/validate_resnet20_export_package.py \
  --package-dir datasets/cifar10/resnet20_export_package \
  --output datasets/cifar10/resnet20_export_package/validation_report.json
```

Validation result:

```text
validation_status: pass
error_count: 0
weight_file_count: 22
bias_file_count: 22
conv_fc_requant_count: 22
residual_add_alignment_count: 9
gap_requant_status: searched
```

The validator checks manifest references, memh counts, INT8/INT32 ranges,
metadata shape products, requant multiplier/shift bounds, and whether generated
task sequence / memory map files referenced by the manifest exist.

## 5. Task Sequence and Memory Map

Task/memory generation command:

```bash
python3 datasets/scripts/generate_resnet20_task_memory_map.py \
  --package-dir datasets/cifar10/resnet20_export_package \
  --output-task datasets/cifar10/resnet20_export_package/task_sequence.json \
  --output-memory datasets/cifar10/resnet20_export_package/memory_map.json
```

Task/memory validation command:

```bash
python3 datasets/scripts/validate_resnet20_task_memory_map.py \
  --package-dir datasets/cifar10/resnet20_export_package \
  --task-sequence datasets/cifar10/resnet20_export_package/task_sequence.json \
  --memory-map datasets/cifar10/resnet20_export_package/memory_map.json \
  --output datasets/cifar10/resnet20_export_package/task_memory_validation.json
```

Task/memory result:

```text
task_count: 32
conv_task_count: 21
residual_add_task_count: 9
gap_task_count: 1
fc_task_count: 1
memory_total_bytes: 1048576
memory_peak_live_bytes: 49152
memory_max_end_address: 289984
null_address_policy: address 0 reserved; input.image starts at 64
alignment_status: pass
null_address_status: pass
live_range_overlap_status: pass
task_memory_validation_status: pass
```

The memory map uses conservative unique tensor allocation under the fixed
`1 MB`, byte-addressed, `64B`-aligned shared-memory contract.

## 6. Boundary

The package now includes generated:

- final `task_sequence.json`
- final `memory_map.json`
- `1 MB` shared-memory map

It still does not include:

- RTL implementation or testbench changes

Next recommended stage:

```text
RTL R1 review
```

RTL R1 remains not started.  The current package is ready for RTL R1 review,
not an RTL implementation.
