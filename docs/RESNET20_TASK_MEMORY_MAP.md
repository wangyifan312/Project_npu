# ResNet-20 Task Sequence and Memory Map

This document records R0.5 F6d/F6e: final ResNet-20 logical task sequence
skeleton and `1 MB` shared-memory reuse map generation/validation.  It does not
modify RTL/testbench and does not start RTL R1.

## 1. Inputs

- Export package:
  `datasets/cifar10/resnet20_export_package/`
- Export package validation:
  `datasets/cifar10/resnet20_export_package/validation_report.json`
- Required package status:
  `validation_status = pass`

## 2. Generation

Command:

```bash
python3 datasets/scripts/generate_resnet20_task_memory_map.py \
  --package-dir datasets/cifar10/resnet20_export_package \
  --output-task datasets/cifar10/resnet20_export_package/task_sequence.json \
  --output-memory datasets/cifar10/resnet20_export_package/memory_map.json
```

Generated files:

```text
datasets/cifar10/resnet20_export_package/task_sequence.json
datasets/cifar10/resnet20_export_package/memory_map.json
```

The generator also updates:

```text
datasets/cifar10/resnet20_export_package/manifest.json
datasets/cifar10/resnet20_export_package/summary.json
```

## 3. Task Sequence

Current task sequence:

```text
task_count: 32
CONV3x3: 19
CONV1x1_PROJECTION: 2
RESIDUAL_ADD: 9
GAP8x8: 1
FC10: 1
```

Logical coverage:

- 21 Conv tasks total:
  - `conv1`
  - 18 residual block `conv1/conv2` tasks
  - 2 projection shortcut `1x1 stride2` tasks
- 9 residual ADD tasks
- 1 GAP task
- 1 FC10 task

Each task records:

- `task_id`
- `name`
- `op_type`
- input/output tensors and shapes
- kernel/stride where applicable
- weight/bias/requant references where applicable
- memory input/output addresses
- `contract_status = handoff_skeleton`

## 4. Memory Map

Current memory map policy:

```text
total memory: 1 MB = 32768 x 256-bit beat
addressing: byte-addressed
alignment: 64B
reserved_null_bytes: 64
null_address_policy: address 0 is reserved to preserve task_checker null-address reject
activation dtype: INT8
allocation strategy: conservative unique tensor allocation, no reuse
```

Current memory result:

```text
memory_total_bytes: 1048576
memory_peak_live_bytes: 49152
memory_max_end_address: 289984
```

The map records every live tensor:

- input image tensor
- Conv intermediate feature maps
- projection branch outputs
- residual ADD outputs
- GAP output vector
- FC logits

For each tensor it records shape, dtype, element count, byte size, aligned byte
size, base/end address, producer task, consumer tasks, and lifetime interval.

The current allocation is intentionally conservative.  It is not an optimized
reuse map, but it is under 1 MB and avoids any address overlap.

## 5. Validation

Command:

```bash
python3 datasets/scripts/validate_resnet20_task_memory_map.py \
  --package-dir datasets/cifar10/resnet20_export_package \
  --task-sequence datasets/cifar10/resnet20_export_package/task_sequence.json \
  --memory-map datasets/cifar10/resnet20_export_package/memory_map.json \
  --output datasets/cifar10/resnet20_export_package/task_memory_validation.json
```

Validation result:

```text
validation_status: pass
error_count: 0
task_count: 32
conv_task_count: 21
residual_add_task_count: 9
gap_task_count: 1
fc_task_count: 1
alignment_status: pass
null_address_status: pass
live_range_overlap_status: pass
```

The validator checks task counts, referenced files, tensor presence, nonzero
task tensor addresses, 64B alignment, 1 MB bounds, live-range/address overlap,
residual ADD input liveness, GAP input, and FC input.

After task/memory generation, the export package validator also passes with
`task_sequence_generated = true` and `one_mb_memory_reuse_map_generated = true`.

## 6. Decision

The ResNet-20 handoff package is ready for RTL R1 review.

This does not mean RTL R1 is implemented.  It only means the software golden,
export package, final logical task sequence, and memory map inputs required for
RTL R1 review are present and validated.
