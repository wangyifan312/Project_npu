# LeNet(MNIST) Implementation Tasks

> Historical planning note:
> 本文档是早期 LeNet bring-up 的任务拆解记录，保留用于追溯实现过程。
> 它**不是**当前正式规格或当前交付状态说明。
> 当前正式基线请以以下文档为准：
> - [README.md](/root/Project_npu/README.md)
> - [ARCHITECTURE_SPEC.md](/root/Project_npu/ARCHITECTURE_SPEC.md)
> - [docs/LENET_MNIST_SPEC.md](/root/Project_npu/docs/LENET_MNIST_SPEC.md)
> - [docs/REQUANTIZATION_PLAN.md](/root/Project_npu/docs/REQUANTIZATION_PLAN.md)

## Goal

Implement full support for a `Caffe-style LeNet` on top of the current `CPU + NPU` RTL,
using `MNIST` as the standard dataset.

Target network:

`Input(28x28x1) -> Conv1(20, 5x5, valid) -> Pool1(2x2 max, s=2) -> Conv2(50, 5x5, valid) -> Pool2(2x2 max, s=2) -> Flatten(800) -> FC1(500) -> ReLU -> FC2(10) -> Argmax`

Detailed network and data-layout rules are fixed in:

- [docs/LENET_MNIST_SPEC.md](/root/Project_npu/docs/LENET_MNIST_SPEC.md)

## Task Order

Tasks must be executed in this exact order:

1. Network spec and dataset flow
2. Multi-channel Conv support
3. Pool/ReLU network integration
4. FC path enablement
5. Network-level LeNet testbench
6. Golden-model tooling

Do not skip forward.

## Task 1 — Network Spec And Dataset Flow

### Required work

- Treat [docs/LENET_MNIST_SPEC.md](/root/Project_npu/docs/LENET_MNIST_SPEC.md) as authoritative
- Keep `MNIST` source format fixed to:
  - [datasets/mnist/mnist.npz](/root/Project_npu/datasets/mnist/mnist.npz)
- Keep exported sample format fixed to:
  - `image_u8.bin`
  - `image_i8.bin`
  - `packed_words.memh`
  - `preload_map.txt`
  - `label.txt`
  - `meta.json`
- Preserve little-endian byte packing rule for `packed_words.memh`

### Acceptance

- Export script can generate at least 8 MNIST test samples
- `packed_words.memh` and `preload_map.txt` are reproducible
- Spec, scripts, and generated files use the same layout and signed-int8 rule

## Task 2 — Multi-Channel Conv Support

### Required work

Current Conv path is not sufficient for LeNet.
It must be extended from `C_in=1, C_out=1` to support at least:

- `Conv1: 1 -> 20`
- `Conv2: 20 -> 50`

### Required RTL behavior

- weight loading must scale with `25 * input_c * output_c`
- feature-map reads/writes must scale with channel count
- output writeback must cover all output channels
- block scheduling must account for channelized byte counts
- output collection must no longer assume a single output stream

### Acceptance

- New tests cover:
  - `1 -> 20`
  - `20 -> 50`
  - multi-block
  - multiple input channels
  - multiple output channels
- Results match software golden convolution

## Task 3 — Pool/ReLU Network Integration

### Required work

- Keep `Pool` as an independent task
- Allow `Conv` task to use `relu_en`
- Validate multi-channel pool behavior for:
  - `24x24x20 -> 12x12x20`
  - `8x8x50 -> 4x4x50`

### Acceptance

- Pool output matches software golden results
- ReLU behavior matches software golden results
- Pool test is system-level, not checker-only

## Task 4 — FC Path Enablement

### Required work

- Remove current FC rejection behavior
- Enable `task_checker` acceptance for legal FC tasks
- Connect `fc_frontend`
- Support:
  - `FC1: 800 -> 500`
  - `FC2: 500 -> 10`

### Fixed rule

> Historical note:
> 下述 `saturating clamp` 规则属于旧 direct-saturate bring-up 基线；
> 当前正式层间语义已经升级到 requant，请以
> [docs/LENET_MNIST_SPEC.md](/root/Project_npu/docs/LENET_MNIST_SPEC.md)
> 和
> [docs/REQUANTIZATION_PLAN.md](/root/Project_npu/docs/REQUANTIZATION_PLAN.md)
> 为准。

- FC inputs come from `INT32` intermediate data
- Convert to `INT8` with saturating clamp before entering the shared MAC path

### Acceptance

- `800 -> 500` works
- `500 -> 10` works
- FC outputs match software golden values
- Illegal FC parameters are still rejected

## Task 5 — Network-Level LeNet Testbench

### Required work

Add a network-level integration testbench that executes:

1. `Conv1`
2. `Pool1`
3. `Conv2`
4. `Pool2`
5. `FC1`
6. `FC2`

Then read back `10 logits` and perform `argmax` in testbench/software.

### Execution scope

- First milestone: single MNIST sample
- Second milestone: 8 MNIST samples
- Do not attempt full 10k-set regression in the first implementation

### Acceptance

- Single-sample full LeNet path completes
- 8-sample regression completes
- Layer shapes and final logits match the golden model

## Task 6 — Golden Model And Comparison Tooling

### Required work

Add a software golden flow that can generate:

- Conv1 output
- Pool1 output
- Conv2 output
- Pool2 output
- FC1 output
- FC2 logits
- final predicted class

### Acceptance

- Golden outputs can be compared layer-by-layer with RTL
- Tensor shapes, layout, and quantization match the spec

## Non-Negotiable Defaults

These defaults are fixed and must not be silently changed:

- network variant: `Caffe-style MNIST LeNet`
- feature map layout: `HWC`
- conv weight layout: `[in_c][k_h][k_w][out_c]` with each `in_c` chunk padded to a 32-bit boundary
- fc weight layout: `[out_neuron][in_neuron]`
- `softmax` stays outside RTL
- final classification uses `argmax` on `10 logits`
- dataset source stays `mnist.npz`
- initial network driver is `testbench`, not PicoRV32 software

## Required Output Per Task

For each task, output:

1. task summary
2. modified files
3. testbench/test changes
4. simulation commands
5. results
6. whether acceptance criteria are satisfied
7. residual risks
