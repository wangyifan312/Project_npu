# LeNet(MNIST) Network Specification For RTL

## Purpose

This document fixes the target `LeNet` variant, tensor shapes, data types, memory layout,
and dataset conversion rules for the current `CPU + NPU` RTL project.

It is the single source of truth for:

- Claude Code implementation work
- Codex review and acceptance
- Dataset conversion and testbench preload

## Fixed Target Network

The target network is the **Caffe-style MNIST LeNet**:

`Input(28x28x1) -> Conv1(20, 5x5, valid) -> Pool1(2x2 max, s=2) -> Conv2(50, 5x5, valid) -> Pool2(2x2 max, s=2) -> Flatten(800) -> FC1(500) -> ReLU -> FC2(10) -> Argmax`

### Layer Shapes

| Layer | Type | Input | Output | Notes |
|------|------|-------|--------|-------|
| Input | Image | `28x28x1` | `28x28x1` | MNIST grayscale |
| Conv1 | Conv | `28x28x1` | `24x24x20` | `5x5`, stride `1`, valid |
| Pool1 | MaxPool | `24x24x20` | `12x12x20` | `2x2`, stride `2` |
| Conv2 | Conv | `12x12x20` | `8x8x50` | `5x5`, stride `1`, valid |
| Pool2 | MaxPool | `8x8x50` | `4x4x50` | `2x2`, stride `2` |
| Flatten | Reshape | `4x4x50` | `800` | fixed order below |
| FC1 | Fully Connected | `800` | `500` | output in `INT32` |
| ReLU | Postproc | `500` | `500` | `INT32` domain |
| FC2 | Fully Connected | `500` | `10` | final logits |
| Argmax | Software/Testbench | `10` | `1` | not in RTL |

## Data Types

These types are fixed unless this document is explicitly revised:

- input image activations: `INT8`
- conv weights: `INT8`
- fc weights: `INT8`
- MAC accumulation: `INT32`
- intermediate feature maps written to memory: `INT32`
- FC outputs written to memory: `INT32`
- final logits: `INT32`

### FC Input Rule

The current architecture target is still `INT8 x INT8 -> INT32`.
Therefore the input to `FC1` and `FC2` must be explicitly converted from prior `INT32`
feature maps/vectors into `INT8` before entering the shared MAC array.

Default rule:

- use explicit saturating conversion from `INT32` to `INT8`
- clamp to `[-128, 127]`

## Operator Semantics

### Conv

- kernel size fixed to `5x5`
- stride fixed to `1`
- padding fixed to `valid`
- no bias

### Pool

- pool type fixed to `2x2 maxpool`
- stride fixed to `2`
- average pool not supported

### ReLU

- works in `INT32` domain
- negative values clamp to `0`

### FC

- uses the shared MAC array
- no dedicated FC array
- input ordering and weight layout are fixed below

## Tensor Layout

Unless explicitly overridden by a later architecture revision, the following memory layout is fixed:

- feature maps: `HWC`
- conv weights: `[in_c][k_h][k_w][out_c]` (contiguous per input channel for efficient DMA)
- each `in_c` weight chunk is padded to a 32-bit boundary in memory
  so the DMA base for the next `in_c` chunk remains word-aligned
- fc weights: `[out_neuron][in_neuron]`

### Flatten Rule

`Pool2` output `4x4x50` is flattened in `HWC` order:

`for h in 0..3, for w in 0..3, for c in 0..49`

This produces the `800`-element `FC1` input vector.

## Memory Map Convention

All base addresses must satisfy the current `task_checker` alignment rule:

- base address must be `64B` aligned

Recommended default memory regions:

| Region | Suggested Base |
|--------|-----------------|
| Input image | `0x0000_0100` |
| Conv1 weights | `0x0000_1000` |
| Conv1 output / Pool1 input | `0x0000_4000` |
| Pool1 output / Conv2 input | `0x0001_8000` |
| Conv2 weights | `0x0002_0000` |
| Conv2 output / Pool2 input | `0x0006_0000` |
| Pool2 output / FC1 input | `0x0008_0000` |
| FC1 weights | `0x0009_0000` |
| FC1 output / FC2 input | `0x000F_2000` |
| FC2 weights | `0x000F_3000` |
| Final logits | `0x000F_5000` |

These addresses are defaults for simulation planning and may be adjusted later,
but all tests and scripts must document any deviation.

Important scope note:

- the full LeNet regression currently runs at the `npu_top + axi4_ram` subsystem level
- `rtl/soc/top.v` still instantiates a default `64KB shared_ram` functional model
- therefore the address map above is validated against the larger subsystem test memory, not against the default `top` memory capacity

## Storage Size Rules

### Input Image

- logical shape: `28x28x1`
- storage format for dataset export: `INT8`
- raw byte count: `784`

### Conv Feature Maps

All conv/pool intermediate outputs are stored as `INT32`.

Examples:

- `Conv1`: `24 * 24 * 20 * 4 = 46080 bytes`
- `Pool1`: `12 * 12 * 20 * 4 = 11520 bytes`
- `Conv2`: `8 * 8 * 50 * 4 = 12800 bytes`
- `Pool2`: `4 * 4 * 50 * 4 = 3200 bytes`

### FC Weights

- `FC1`: `500 * 800 = 400000 INT8 weights`
- `FC2`: `10 * 500 = 5000 INT8 weights`

## Dataset Conversion Rules

### MNIST Source

Primary dataset source file in this repo:

- [datasets/mnist/mnist.npz](/root/Project_npu/datasets/mnist/mnist.npz)

The failed zero-byte IDX `.gz` artifact is not part of the active flow.

### Exported Sample Files

Each exported sample directory must contain:

- `image_u8.bin`
- `image_i8.bin`
- `packed_words.memh`
- `preload_map.txt`
- `label.txt`
- `meta.json`

### INT8 Conversion Rule

For the current RTL flow, image pixels are converted from MNIST `uint8` to signed `INT8` by:

- `int8_pixel = clamp(uint8_pixel - 128, -128, 127)`

This centers grayscale values around zero and matches the signed activation assumption already used in RTL tests.

### MEMH Packing Rule

`packed_words.memh` is the canonical testbench preload format.

Packing is little-endian by byte address:

- bytes `[b0, b1, b2, b3]`
- stored as one 32-bit word value `0x b3 b2 b1 b0`

This matches the existing RAM preload style used in current integration tests.

If the last word is incomplete, pad missing high-address bytes with `0x00`.

### preload_map.txt Format

`preload_map.txt` must contain one line per 32-bit word:

`<absolute_addr_hex> <word_hex>`

Example:

`00000100 04030201`

This format is intended for testbench preload tasks that write words into shared memory.

## Testbench Execution Model

The network is not hardcoded into RTL.
The execution model is:

1. testbench preloads image and weights into shared memory
2. testbench configures one NPU task at a time
3. NPU executes one operator/layer task
4. output memory region becomes the next task input
5. testbench sequences the full network layer-by-layer
6. final logits are read back and `argmax` is done in software/testbench

### Current Requantization Step

The current RTL supports:

- `Conv` input as `INT8`
- `Pool` input/output as `INT32`
- `FC` input as `INT32`, with internal saturating conversion to `INT8`

Therefore the current network-level testbench inserts one explicit software/testbench
requantization step between:

- `Pool1` output `12x12x20 INT32`
- `Conv2` input `12x12x20 INT8`

Rule:

- apply saturating clamp from `INT32` to `INT8`
- preserve `HWC` order
- repack the result into little-endian `32-bit` words for shared-memory preload

This is a network-driver responsibility in the current version.
It is not yet implemented as a dedicated RTL operator/task.

### Required Layer Sequence

For full LeNet execution, the testbench must schedule:

1. `Conv1`
2. `Pool1`
3. `Conv2`
4. `Pool2`
5. `FC1`
6. `FC2`

`ReLU` may be enabled inside the appropriate task if the RTL path supports it.

## Current RTL Gap Summary

This section is descriptive and should be kept aligned with implementation progress.

Current known gaps relative to this target:

- network-level LeNet regression is validated under `vcs`; `iverilog/vvp` remains much slower for full-sample runs
- the current LeNet flow uses explicit testbench-side requantization between `Pool1` and `Conv2`
- the current fixture flow has been validated on 8 MNIST samples with layer-by-layer golden comparison
- full-network validation currently targets the `npu_top` subsystem, while `top` remains a smaller-capacity SoC integration target
