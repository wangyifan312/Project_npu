# AGENTS.md - Project_npu Agent Baseline

This file is the entry point for Codex/coding agents working in this repository.
It does not replace `CLAUDE.md`; it points agents to the current project status
and fixes the boundaries that must not drift during implementation.

## Required Reading Order

Before making any code, testbench, script, or document change, read:

1. `docs/CURRENT_PROJECT_STATUS.md`
2. `CLAUDE.md`
3. The topic-specific plan/status document for the requested task

For ResNet-20 work, also read:

1. `docs/RESNET20_CURRENT_STATUS.md`
2. `docs/RESNET20_SOFTWARE_GOLDEN_PLAN.md`
3. `docs/RESNET20_FIXED_POINT_GOLDEN_PLAN.md`
4. `docs/RESNET20_RTL_EXTENSION_PLAN.md`

Do not use README, `CLAUDE.md`, or any historical plan as the sole source of
current status. `docs/CURRENT_PROJECT_STATUS.md` is the status entry point.

## Current Baseline

The current formal hardware baseline is:

- SoC: `PicoRV32 + AXI interconnect + shared_ram + NPU`
- NPU: `6 x 16x16 PE cluster`
- Total PE count: `1536`
- Peak target: `0.6144 TOPS @ 200MHz`
- Shared memory: `1 MB = 32768 x 256-bit beat`
- CPU control plane: `32-bit AXI-Lite`
- NPU DMA data plane: `256-bit AXI4 INCR burst`
- Formal compute path: `cluster_scheduler -> compute_core_6cluster -> output_arbiter`
- FC formal path: arrayized FC, not legacy scalar FC

Current closure status:

- `HB1/HB2` are complete within current boundaries.
- `AXI-1/2/3/4` are complete within the project-supported AXI subset.
- `W1/W2/W3` are complete and may be closed.
- `W4/W5/W6` are follow-up enhancements, not active default work.
- NPU RTL `Workstream A/B/C` is complete.
- First-pass full-cluster optimization is stable at `top32 + subsystem64`.

## Immutable Contracts

Do not change these in ordinary fixes, cleanups, or ResNet planning work:

- LeNet address map.
- Requant arithmetic semantics.
- Shared memory organization: `32768 x 256-bit beat`.
- NPU task base address alignment: `64B`.
- `acc_buffer -> DMA writer` packing: `32-bit word -> 256-bit AXI beat`.
- Last-beat `WSTRB` generated from actual byte count.
- Output layout and layer memory map.
- Single-task register-triggered control model.
- Runtime `CLUSTER_MODE / CLUSTER_MASK` is AXI-Lite config only; it is not a
  task queue, descriptor FIFO, or shadow config architecture.

The AXI implementation is a standardized project subset:

- Control: AXI-Lite project subset.
- Data: `256-bit AXI4 INCR burst` project subset.

Do not describe it as a complete general-purpose AXI4/AXI-Lite IP.

## ResNet-20 Status

ResNet-20 is a new migration line and does not change the current LeNet/MNIST
formal baseline.

Current ResNet-20 state:

- R0.5 software golden / fixture flow is complete.
- Float candidate checkpoint is available.
- Software fixed-point full-test eval is complete.
- `>=80%` fixed-point accuracy gate is passed.
- F6b RTL handoff contract is closed.
- F6c/F6g INT8/INT32/requant export package is generated and validated.
- F6d/F6e final task sequence and `1 MB` memory map are generated and validated.
- R1a-R1e RTL foundations are implemented.
- R1g compact residual-slice exact match is complete.
- R1h package-faithful full-shape `input.image -> conv1` exact match is complete.
- R1i package-faithful early residual multi-task exact match is complete.
- Full 32-task / full ResNet-20 RTL closure is not complete.

Current implemented ResNet RTL feature scope:

- `task_type` control path is 3-bit end-to-end.
- Generalized Conv control exists for `1x1 / 3x3 / 5x5`, `stride1/2`, `valid/same`.
- Folded INT32 bias + requant is connected for Conv/FC.
- Residual ADD task/datapath foundation is implemented.
- GAP8x8 task/datapath foundation is implemented.
- Package-faithful exact-match evidence currently covers:
  - full-shape `input.image -> conv1`
  - early residual multi-task slice
- Full 32-task exact match is still open.

Current float candidate:

- Checkpoint: `datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt`
- Float full-test accuracy: `8648/10000 = 86.48%`
- Linux CPU recheck matched `86.48%`

This is float software evidence only. It is not fixed-point evidence and it is
not an RTL start condition by itself.

Current fixed-point evidence:

- Fixed-point full-test eval: `datasets/cifar10/resnet20_fixed_point_eval_10000/summary.json`
- Fixed-point full-test accuracy: `8639/10000 = 86.39%`
- Export package: `datasets/cifar10/resnet20_export_package/`

Do not describe full 32-task / end-to-end ResNet RTL closure as implemented
until explicit package-faithful multi-task evidence covers the whole sequence
and preserves the existing LeNet/HB/AXI baseline.
The current ResNet state is beyond handoff-only review: R1a-R1i partial RTL
evidence exists, but full-sequence closure is still open.

## Work Rules

- One task at a time.
- Do not enter the next milestone until the current milestone is reviewed.
- Prefer narrow changes that preserve existing LeNet/HB/AXI evidence.
- Do not use legacy/debug/micro tests as formal functionality or performance
  evidence.
- Do not package small-batch replay as full-set evidence.
- Do not package RTL representative chunks as complete RTL full-set results.
- Do not package float ResNet accuracy as fixed-point accuracy.

Generated assets such as CIFAR tarballs, checkpoints, fixtures, and `results/`
outputs are normally ignored and should not be committed unless explicitly
requested.

## Required Completion Report

Every implementation turn must report:

- Current task / milestone
- Modified files
- What changed
- Tests or commands run
- Results
- Whether RTL/testbench changed
- Whether any formal contract changed
- Whether the task satisfies its acceptance criteria
- Remaining unfinished items
- Residual risk
