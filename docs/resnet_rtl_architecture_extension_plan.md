# ResNet-Oriented RTL Architecture Extension Plan

> Project: Project_npu  
> Scope: Extend the existing LeNet/MNIST-oriented NPU RTL into a backward-compatible task-based NPU that can support ResNet-style inference.  
> Primary constraint: the current LeNet/MNIST flow must remain bit-exact and must continue to pass existing regression tests.

---

## 1. Executive Summary

The current NPU architecture is not hardwired to LeNet only, but its completed RTL and verification closure are centered on a LeNet/MNIST workload. Its supported operator set is currently close to:

```text
Conv:
  5x5
  stride = 1
  valid padding
  no bias
  INT8 activation
  INT8 weight
  INT32 accumulate/output

Pool:
  2x2 MaxPool
  stride = 2

FC:
  INT8 input
  INT8 weight
  INT32 output
  6-cluster compute path

ReLU:
  INT32 domain

Requant:
  INT32 -> INT8
  multiplier + shift + round-half-away-from-zero + clamp
```

To support ResNet-style inference, the architecture needs to evolve from a LeNet-style fixed operator pipeline into a more general task-based CNN accelerator.

The main architectural gap is not the PE array. The existing 6-cluster MAC hierarchy can still be reused for convolution and FC. The main missing capabilities are:

```text
1. Parameterized convolution:
   kernel_size = 1 / 3 / 5
   stride = 1 / 2
   padding = valid / same

2. Bias support:
   Conv/FC bias, preferably injected through sum_in.

3. Residual add:
   Elementwise ADD task with two input tensors.

4. ADD post-processing:
   ADD + ReLU
   ADD + Requant
   ADD + ReLU + Requant

5. Global average pooling:
   Required for standard CIFAR-style ResNet classification heads.

6. Expanded task/config interface:
   Additional registers, capability reporting, and stricter task checks.

7. Compatibility guardrails:
   All new functionality must be opt-in.
   Reset/default behavior must exactly match the current LeNet path.
```

This document defines a systematic RTL extension plan that preserves the current LeNet/MNIST implementation while enabling a ResNet-oriented roadmap.

---

## 2. Non-Negotiable Compatibility Contract

The first requirement is not ResNet support. The first requirement is to preserve the existing LeNet/MNIST flow.

### 2.1 Hard Compatibility Rules

The following rules are mandatory:

```text
MUST-1:
  Existing LeNet/MNIST task sequence must not need changes.

MUST-2:
  Existing register addresses must not be moved or reinterpreted.

MUST-3:
  Existing task_type encodings must not change.

MUST-4:
  Existing Conv default behavior must remain:
    5x5 / stride1 / valid / no bias.

MUST-5:
  Existing Pool default behavior must remain:
    2x2 MaxPool / stride2.

MUST-6:
  Existing FC path must remain on the official 6-cluster compute path.
  It must not fall back to any legacy scalar FC path.

MUST-7:
  Existing Requant arithmetic must not change.

MUST-8:
  Existing HWC layout must not change.

MUST-9:
  Existing convolution weight layout must not change for 5x5 Conv.

MUST-10:
  Existing FC weight layout must not change.

MUST-11:
  Existing 64B task base-address alignment contract must not change.

MUST-12:
  Existing 32-bit acc_buffer to 256-bit AXI write packing must not change.

MUST-13:
  Existing last-beat WSTRB behavior must not change.

MUST-14:
  All newly added registers must reset to values that reproduce current LeNet behavior.

MUST-15:
  Every extension milestone must run the LeNet regression before being accepted.
```

### 2.2 Existing Task Encoding Preservation

Existing task encodings must remain:

```text
task_type = 0: Conv
task_type = 1: FC
task_type = 2: Pool
task_type = 3: Requant
```

New task types must only be appended:

```text
task_type = 4: ADD
task_type = 5: GAP
task_type = 6: ShortcutDownsamplePad, optional
```

If the current `task_type` signal is 2-bit, it must be widened to at least 3 bits. That widening must be applied consistently across:

```text
npu_ctrl
task_checker
npu_top
testbenches
documentation
any task register pack/unpack logic
```

Old values `0/1/2/3` must preserve their exact old meaning.

### 2.3 New Features Must Be Opt-In

Every ResNet-oriented feature must be disabled by default.

Required defaults:

```text
kernel_size       = 5
stride            = 1
padding_mode      = valid
bias_en           = 0
conv_relu_en      = legacy/default behavior
conv_requant_en   = legacy/default behavior
src1_addr         = 0
src1_bytes        = 0
add_relu_en       = 0
add_requant_en    = 0
gap_en            = 0
postproc_mode     = legacy
```

This means an old LeNet testbench that never writes the new registers must still execute the same RTL behavior as before.

---

## 3. Current Architecture Baseline

The current system can be summarized as:

```text
CPU / AXI-Lite test driver
  -> npu_ctrl
  -> task_checker
  -> npu_top main FSM
  -> AXI read/write DMA
  -> local act/weight/acc buffers
  -> cluster_scheduler
  -> compute_core_6cluster
  -> output_arbiter
  -> store packing
  -> shared memory
```

Current multi-cluster compute behavior:

```text
activation:
  broadcast to enabled clusters

weight:
  split by output column/output channel group

sum_in:
  currently zero for the main Conv/FC paths

output:
  routed back to global output columns
  then merged through output_arbiter
```

This is compatible with expanding Conv and FC because ResNet still relies heavily on MAC operations. The PE cluster array should be treated as reusable infrastructure.

The architectural areas that must be generalized are:

```text
1. Conv frontend/window generation.
2. Task configuration and validation.
3. Bias and initial sum injection.
4. Elementwise residual data path.
5. Global pooling.
6. DMA/buffer read scheduling for two-input tasks.
7. Verification strategy.
```

---

## 4. Target ResNet Hardware Capability

For CIFAR-style ResNet, the minimum useful target is ResNet-20 or a similar basic-block network.

A basic ResNet block has this shape:

```text
x
 |
 +---------------- shortcut ----------------+
 |                                          |
 v                                          |
Conv3x3 -> Bias/BN-fold -> ReLU -> Conv3x3 |
 |                                          |
 +------------------- ADD <----------------+
                     |
                    ReLU
                     |
                  Requant
```

A downsample block commonly has:

```text
main path:
  Conv3x3 stride2

shortcut path:
  either 1x1 stride2 projection Conv
  or spatial downsample + channel zero padding

merge:
  ADD -> ReLU -> Requant
```

Therefore, the minimum RTL feature set for ResNet is:

```text
Required:
  Conv3x3 same stride1
  Conv3x3 same stride2
  Bias add
  ReLU
  Requant
  Elementwise ADD
  ADD + ReLU
  ADD + Requant
  GAP
  FC10

Strongly recommended:
  Conv1x1 stride2 projection shortcut

Optional first-generation shortcut alternative:
  ShortcutDownsamplePad task
```

Features that are useful but not first priority:

```text
per-channel quantization
independent BatchNorm operator
softmax
depthwise convolution
group convolution
descriptor queue
dual AXI read master
```

---

## 5. Register Architecture

### 5.1 Register Map Policy

The existing register map must be append-only.

Rules:

```text
1. Do not move existing register addresses.
2. Do not reinterpret existing fields for old task types.
3. Add new registers only in unused high address ranges.
4. New registers must be readable for debug.
5. New registers must have safe reset defaults.
6. Add VERSION and CAPABILITY registers before adding complex optional features.
```

### 5.2 Proposed New Registers

Suggested new registers:

```text
VERSION_REG
CAPABILITY_REG

CONV_CFG
  kernel_size
  stride
  padding_mode
  bias_en
  conv_relu_en
  conv_requant_en

BIAS_ADDR
BIAS_BYTES

SRC1_ADDR
SRC1_BYTES

ADD_CFG
  add_dtype
  add_relu_en
  add_requant_en
  add_saturate_en, optional

GAP_CFG
  gap_input_dtype
  gap_output_dtype
  reciprocal
  shift

POSTPROC_CFG
  relu_en
  requant_en
  postproc_mode
```

### 5.3 Suggested Field Definitions

`CONV_CFG`:

```text
bits [1:0] kernel_size_sel
  0: legacy/default 5x5
  1: 1x1
  2: 3x3
  3: reserved or 5x5

bit [2] stride_sel
  0: stride1
  1: stride2

bit [3] padding_mode
  0: valid
  1: same

bit [4] bias_en
  0: no bias
  1: add INT32 bias through sum_in

bit [5] conv_relu_en
  0: legacy/no explicit fused ReLU
  1: enable Conv post-ReLU if supported

bit [6] conv_requant_en
  0: legacy/no explicit fused requant
  1: enable Conv post-requant if supported
```

`ADD_CFG`:

```text
bits [1:0] add_dtype
  0: INT32 + INT32 -> INT32
  1: reserved for INT8 + INT8
  2: reserved for mixed mode

bit [2] add_relu_en
bit [3] add_requant_en
bit [4] add_saturate_en, optional
```

`GAP_CFG`:

```text
bits [1:0] gap_input_dtype
  0: INT32
  1: INT8, future

bits [3:2] gap_output_dtype
  0: INT32
  1: INT8 through requant, future

bits [19:4] reciprocal
bits [25:20] shift
```

### 5.4 Capability Register

Suggested `CAPABILITY_REG`:

```text
bit0: conv_5x5_supported
bit1: conv_3x3_supported
bit2: conv_1x1_supported
bit3: same_padding_supported
bit4: stride2_supported
bit5: bias_supported
bit6: add_supported
bit7: gap_supported
bit8: add_relu_supported
bit9: add_requant_supported
bit10: conv_fused_relu_supported
bit11: conv_fused_requant_supported
bit12: projection_shortcut_supported
bit13: shortcut_downsample_pad_supported
```

This lets software and testbenches detect the active RTL capability instead of relying on out-of-band assumptions.

---

## 6. Parameterized Convolution Architecture

### 6.1 Design Goal

The current fixed Conv should be generalized without breaking the old 5x5 valid path.

Target:

```text
kernel_size = 1 / 3 / 5
stride = 1 / 2
padding = valid / same
```

The compute core can still consume:

```text
array_act_in
array_weight
array_sum_in
```

The main change is how `array_act_in` and weight indexing are generated.

### 6.2 Active Row Mapping

Use:

```text
kernel_elems = kernel_size * kernel_size
active_rows = kernel_elems
```

Mapping:

```text
1x1:
  active_rows = 1
  PE row 0 active
  rows 1..N zero

3x3:
  active_rows = 9
  PE rows 0..8 active
  remaining rows zero

5x5:
  active_rows = 25
  PE rows 0..24 active
  remaining rows zero
```

The old LeNet path corresponds to:

```text
kernel_size = 5
stride = 1
padding = valid
active_rows = 25
```

### 6.3 Output Shape Rules

For `valid`:

```text
out_h = floor((input_h - kernel_size) / stride) + 1
out_w = floor((input_w - kernel_size) / stride) + 1
```

For `same`:

```text
out_h = ceil(input_h / stride)
out_w = ceil(input_w / stride)
```

For hardware checks:

```text
ceil(input_h / stride) = (input_h + stride - 1) / stride
ceil(input_w / stride) = (input_w + stride - 1) / stride
```

### 6.4 Padding Rules

For same padding:

```text
pad = kernel_size / 2
```

Window coordinate:

```text
in_y = out_y * stride + ky - pad
in_x = out_x * stride + kx - pad
```

Boundary behavior:

```text
if in_y < 0 or in_y >= input_h:
  act = 0
else if in_x < 0 or in_x >= input_w:
  act = 0
else:
  act = input[in_y][in_x][cin]
```

The output element still corresponds to:

```text
output[out_y][out_x][out_c]
```

### 6.5 Weight Layout

Maintain the existing conceptual layout:

```text
weight[in_c][kernel_y][kernel_x][out_c]
```

For 1x1:

```text
weight[in_c][0][0][out_c]
```

For 3x3:

```text
weight[in_c][0..2][0..2][out_c]
```

For 5x5:

```text
weight[in_c][0..4][0..4][out_c]
```

Important compatibility rule:

```text
For kernel_size=5, stride=1, padding=valid, no bias,
the weight fetch order and window order must match the old LeNet implementation exactly.
```

### 6.6 Conv Frontend Implementation Options

There are two viable implementation approaches:

#### Option A: Extend Existing `conv_frontend`

Modify the existing window generator to support:

```text
kernel_size
stride
padding
```

Pros:

```text
less module churn
fewer integration points
easier to reuse current line buffers
```

Cons:

```text
risk of breaking old 5x5 valid behavior
more conditional logic in an existing module
```

#### Option B: Add a Generalized Conv Frontend and Keep Legacy Mode

Create:

```text
conv_frontend_legacy_5x5
conv_frontend_param
```

Then select:

```text
if kernel=5 && stride=1 && padding=valid:
  use legacy-equivalent path
else:
  use param path
```

Pros:

```text
lower LeNet regression risk
easier bit-exact comparison
clearer bring-up
```

Cons:

```text
more RTL area
duplicated logic during transition
```

Architectural recommendation:

```text
Use Option A only if the existing conv_frontend is clean enough to extend safely.
Otherwise use Option B for the first ResNet-capable milestone, then merge later if needed.
```

---

## 7. Bias Architecture

### 7.1 Why Bias Is Required

ResNet inference usually folds BatchNorm into Conv:

```text
Conv + BatchNorm -> Conv(weight') + bias'
```

If the hardware cannot add bias, it cannot faithfully execute a normal folded ResNet without accuracy loss.

### 7.2 Recommended Bias Injection Point

Use the existing sum input concept:

```text
sum_out[col] = sum_in[col] + Σ act[row] * weight[row][col]
```

Current behavior:

```text
sum_in[col] = 0
```

New behavior:

```text
if bias_en == 0:
  sum_in[col] = 0
else:
  sum_in[col] = bias[global_output_channel]
```

This keeps the PE array unchanged.

### 7.3 Bias Data Type

Recommended:

```text
INT32 bias
```

Reasons:

```text
1. Conv accumulation is INT32.
2. Folded BN bias is naturally an accumulated-domain value.
3. Avoids early saturation.
4. Easy to verify.
```

### 7.4 Multi-Cluster Bias Mapping

The existing 6-cluster path splits output columns/channels across enabled clusters.

Bias must follow the same global output-channel mapping:

```text
cluster local column -> global output column -> bias[global output column]
```

Required checks:

```text
1. Enabled clusters get the correct bias slice.
2. Disabled clusters receive zero.
3. Unused local columns receive zero.
4. output_c not divisible by cluster_count is handled.
5. mask cluster mode does not duplicate bias assignment.
```

### 7.5 LeNet Compatibility

Bias reset/default:

```text
bias_en = 0
bias_addr = 0
bias_bytes = 0
```

When `bias_en=0`, the old LeNet Conv and FC behavior must be bit-exact.

---

## 8. Residual ADD Architecture

### 8.1 Why ADD Is a First-Class Task

Residual add is the defining operator of ResNet:

```text
output = main_path + shortcut_path
```

It cannot be expressed by the current Conv/Pool/FC/Requant set without adding a two-input elementwise datapath.

### 8.2 ADD Task Semantics

First-generation ADD:

```text
task_type = ADD

for i in 0..N-1:
  output[i] = src0[i] + src1[i]
```

Recommended first-generation data type:

```text
src0: INT32
src1: INT32
dst : INT32
```

Reasoning:

```text
1. Current Conv/FC outputs are INT32.
2. No immediate scale-alignment logic is required.
3. It is easy to compare with a golden model.
4. It avoids INT8 saturation ambiguity in the first implementation.
```

### 8.3 ADD Register Inputs

Recommended registers:

```text
SRC0_ADDR:
  can reuse existing input_addr semantics

SRC1_ADDR:
  new register

OUTPUT_ADDR:
  existing output_addr

SRC0_BYTES:
  can reuse existing input_bytes

SRC1_BYTES:
  new register

OUTPUT_BYTES:
  existing output_bytes

ADD_CFG:
  dtype
  relu_en
  requant_en
```

Short-term compatibility option:

```text
For ADD task only:
  weight_addr can be interpreted as src1_addr.
```

Architectural recommendation:

```text
Add SRC1_ADDR and SRC1_BYTES explicitly.
Do not overload weight_addr long-term.
```

### 8.4 ADD Post-Processing Modes

ADD should support:

```text
ADD only:
  output = src0 + src1

ADD + ReLU:
  output = max(src0 + src1, 0)

ADD + Requant:
  output = requant(src0 + src1)

ADD + ReLU + Requant:
  output = requant(max(src0 + src1, 0))
```

The recommended ResNet block output is:

```text
ADD + ReLU + Requant
```

so that the next Conv can consume INT8 activation.

### 8.5 Scale Alignment Policy

Residual add requires compatible numeric scales.

First-generation policy:

```text
ADD operates in INT32 domain.
Software/test flow must ensure both branches are in compatible INT32 scale.
ADD output may then be ReLU/requantized.
```

Future enhanced policy:

```text
src0_rescale:
  multiplier + shift

src1_rescale:
  multiplier + shift

add:
  rescaled_src0 + rescaled_src1

output_requant:
  multiplier + shift + clamp
```

Do not implement full dual-branch rescale in the first RTL milestone unless it is explicitly required. It increases control register complexity, datapath complexity, and verification scope.

### 8.6 ADD DMA and Buffering

ADD requires two source tensors.

Minimum implementation:

```text
1. Read src0 into a local buffer.
2. Read src1 into a second local buffer.
3. Perform elementwise add.
4. Store output.
```

Potential buffer reuse:

```text
act_buffer -> src0
wgt_buffer -> src1
```

This is acceptable for first bring-up, but the documentation should clearly state that `wgt_buffer` is acting as a generic second-source buffer for ADD.

Long-term cleaner naming:

```text
src_a_buffer
src_b_buffer
```

### 8.7 ADD Validation

Task checker must verify:

```text
src0_addr aligned
src1_addr aligned
output_addr aligned
src0_bytes != 0
src1_bytes != 0
src0_bytes == src1_bytes
output_bytes matches dtype and postproc mode
address ranges do not overflow shared memory
shape metadata is consistent
dtype is supported
requant params are valid if add_requant_en=1
```

---

## 9. Shortcut Path Architecture

### 9.1 ResNet Shortcut Variants

ResNet downsample blocks need to handle shape changes:

```text
spatial:
  32x32 -> 16x16
  16x16 -> 8x8

channels:
  16 -> 32
  32 -> 64
```

Two common shortcut strategies:

```text
Option A:
  spatial downsample + channel zero padding

Option B:
  1x1 stride2 projection Conv
```

### 9.2 Recommended Strategy

Prefer Option B:

```text
1x1 Conv stride2 projection shortcut
```

Reasons:

```text
1. It is a general operator.
2. It is useful beyond ResNet shortcut.
3. It reuses the Conv engine.
4. It avoids adding a highly specialized shortcut-only task.
```

### 9.3 Optional ShortcutDownsamplePad Task

If projection Conv is not implemented in the first version, an optional task can be added:

```text
task_type = ShortcutDownsamplePad

for output_y, output_x:
  for c < input_c:
    output[output_y][output_x][c] = input[output_y*2][output_x*2][c]

  for c >= input_c:
    output[output_y][output_x][c] = 0
```

This is less general and should be treated as a temporary or specialized feature.

---

## 10. Global Average Pooling Architecture

### 10.1 Why GAP Is Needed

CIFAR-style ResNet typically ends with:

```text
8x8xC
  -> Global Average Pooling
  -> 1x1xC
  -> FC10
```

The current hardware supports 2x2 MaxPool, not GAP.

Without GAP, the network can flatten:

```text
8*8*C -> FC10
```

but this increases FC parameters and deviates from standard ResNet structure.

### 10.2 GAP Task Semantics

```text
task_type = GAP

for c in 0..C-1:
  sum = 0
  for y in 0..H-1:
    for x in 0..W-1:
      sum += input[y][x][c]

  output[c] = sum / (H * W)
```

### 10.3 Data Type

Recommended first version:

```text
input: INT32
accumulate: INT48 or INT64
output: INT32
```

Future option:

```text
output: INT8 through requant
```

### 10.4 Avoid Hardware Divider

Do not add a general divider.

Use fixed-point reciprocal:

```text
avg = (sum * reciprocal_hw) >> shift
```

`reciprocal_hw` and `shift` can be configured through `GAP_CFG`.

### 10.5 GAP Validation

Task checker must verify:

```text
input_h >= 1
input_w >= 1
input_c >= 1
output_c == input_c
output_bytes matches output_c and output dtype
input_bytes matches input_h * input_w * input_c * input dtype bytes
reciprocal and shift are valid
addresses are aligned and within shared memory range
```

---

## 11. Post-Processing Architecture

### 11.1 Existing Post-Processing

Current post-processing includes:

```text
ReLU in INT32 domain
Pool path
Requant INT32 -> INT8
```

### 11.2 Required Extension

Post-processing should become reusable across:

```text
Conv output
FC output
ADD output
GAP output, optional
```

At minimum:

```text
ADD -> ReLU
ADD -> Requant
ADD -> ReLU -> Requant
```

### 11.3 Postproc Mode

Suggested mode:

```text
postproc_mode = 0:
  legacy/default

postproc_mode = 1:
  none

postproc_mode = 2:
  ReLU

postproc_mode = 3:
  Requant

postproc_mode = 4:
  ReLU + Requant
```

Compatibility:

```text
legacy/default must reproduce the current LeNet behavior.
```

---

## 12. `npu_top` Architecture Refactoring

### 12.1 Problem

`npu_top` currently coordinates many responsibilities:

```text
task dispatch
DMA read
DMA write
buffer control
Conv frontend feeding
FC feeding
Pool
Requant
cluster feeding
output routing
store packing
performance counting
```

Adding ResNet support directly into one monolithic FSM will increase risk.

### 12.2 Recommended Internal Partition

Even if files are not physically split immediately, the logic should be organized around engines:

```text
conv_engine:
  window generation
  weight fetch
  bias fetch
  active_rows
  cluster feeding

fc_engine:
  existing arrayized FC path

eltwise_engine:
  ADD
  ADD + ReLU
  ADD + Requant

pool_engine:
  MaxPool
  GAP

store_engine:
  INT32/INT8 to AXI write packing

dma_read_scheduler:
  act/src0 reads
  weight/src1 reads
  bias reads
```

### 12.3 FSM Policy

Recommended high-level FSM model:

```text
FSM_IDLE
FSM_CHECK_TASK
FSM_DISPATCH

FSM_CONV_LOAD
FSM_CONV_COMPUTE
FSM_CONV_COLLECT
FSM_CONV_STORE

FSM_FC_LOAD
FSM_FC_COMPUTE
FSM_FC_COLLECT
FSM_FC_STORE

FSM_POOL_RUN
FSM_POOL_STORE

FSM_REQUANT_RUN
FSM_REQUANT_STORE

FSM_ADD_LOAD_SRC0
FSM_ADD_LOAD_SRC1
FSM_ADD_RUN
FSM_ADD_POSTPROC
FSM_ADD_STORE

FSM_GAP_LOAD
FSM_GAP_ACCUM
FSM_GAP_DIV
FSM_GAP_STORE

FSM_DONE
FSM_ERROR
```

This can be implemented incrementally, but ADD/GAP should not be mixed into Conv-specific state naming or assumptions.

---

## 13. DMA and Buffer Architecture

### 13.1 Current Constraint

The architecture has one external AXI read channel for NPU DMA. Activation and weight reads are arbitrated internally; they are not truly parallel at the shared-memory read interface.

This is acceptable for first-generation ResNet support but must be documented.

### 13.2 Read Classes

After extension, the NPU may need to read:

```text
Conv:
  activation
  weight
  bias, optional

FC:
  input
  weight
  bias, optional

ADD:
  src0
  src1

GAP:
  input
```

### 13.3 Read Scheduler Policy

Minimum policy:

```text
1. Only one read client owns the AXI read channel at a time.
2. Read ownership is explicit per FSM phase.
3. No implicit overlap is assumed unless verified.
4. Performance counters must record read activity per class where possible.
```

### 13.4 Buffer Reuse Policy

Short-term:

```text
act_buffer:
  Conv activation
  FC input
  ADD src0
  GAP input

wgt_buffer:
  Conv/FC weight
  ADD src1
```

Long-term cleaner architecture:

```text
src_a_buffer
src_b_buffer
weight_buffer
bias_buffer or bias register cache
```

For the first implementation, buffer reuse is acceptable if documented and verified.

---

## 14. Task Checker Expansion

### 14.1 Goal

The task checker should evolve from LeNet-oriented checks into a general CNN task validator.

### 14.2 Existing Checks to Preserve

Preserve:

```text
valid task_type checks for old tasks
nonzero byte checks
null address checks
64B base alignment checks
shared memory bounds checks
Conv minimum dimension checks
Pool even dimension checks
Requant byte/multiplier/shift checks
input_c/output_c checks for non-Requant tasks
```

### 14.3 New Checks

Add:

```text
kernel_size in {1, 3, 5}
stride in {1, 2}
padding_mode in {valid, same}
bias_en implies bias_addr/bias_bytes valid
src1_addr valid for ADD
src1_bytes valid for ADD
ADD src0/src1 bytes equal
ADD output bytes match dtype/postproc
GAP dimensions valid
GAP output_c == input_c
output shape matches kernel/stride/padding
output_bytes matches output shape and dtype
```

### 14.4 Suggested Error Codes

Add or reserve:

```text
ERR_INVALID_KERNEL
ERR_INVALID_STRIDE
ERR_INVALID_PADDING
ERR_BIAS_PARAM
ERR_ADD_PARAM
ERR_SRC1_PARAM
ERR_GAP_PARAM
ERR_SHAPE_MISMATCH
ERR_OUTPUT_BYTES
ERR_UNSUPPORTED_FEATURE
```

Error priority should be deterministic and documented.

---

## 15. Multi-Cluster Correctness Requirements

The current multi-cluster design relies on:

```text
activation broadcast
weight split by output column/channel
global-column output routing
aggregate OR merge
```

This must be revalidated for the new Conv modes.

### 15.1 Required Cases

Verify:

```text
kernel_size = 1
kernel_size = 3
kernel_size = 5 legacy
stride = 1
stride = 2
padding = valid
padding = same
output_c divisible by cluster_count
output_c not divisible by cluster_count
single cluster
dual cluster
full cluster
mask mode
```

### 15.2 Output Merge Safety

The OR aggregate merge is safe only if:

```text
1. Different clusters write mutually exclusive global output columns.
2. Invalid columns are zero.
3. Disabled clusters output zero or are masked out.
4. Routed columns are correct for every cluster mode.
```

This proof must be repeated for:

```text
Conv1x1
Conv3x3
Conv5x5 legacy
FC
```

ADD/GAP should not use the cluster output arbiter unless explicitly implemented through the compute core. They should have their own store path or a clearly documented reuse path.

---

## 16. Data Type and Quantization Policy

### 16.1 First-Generation Policy

Use the current datatype model:

```text
Conv/FC input activation:
  INT8

Conv/FC weight:
  INT8

Conv/FC accumulate:
  INT32

ADD:
  INT32 + INT32 -> INT32

GAP:
  INT32 input -> INT32 output

Requant:
  INT32 -> INT8
```

### 16.2 What Not To Add Initially

Do not add in the first ResNet RTL milestone unless explicitly required:

```text
per-channel quantization
zero-point asymmetric quantization
dual-branch ADD rescale
INT8 ADD saturation
independent BatchNorm operator
softmax
```

### 16.3 Future Scale-Aligned ADD

Future ADD may support:

```text
src0_scaled = requant_like(src0, src0_multiplier, src0_shift)
src1_scaled = requant_like(src1, src1_multiplier, src1_shift)
sum = src0_scaled + src1_scaled
output = requant_like(sum, out_multiplier, out_shift)
```

This is useful for more accurate quantized residual networks but should be treated as a second-generation feature.

---

## 17. Memory Capacity Considerations

Although software assigns addresses, memory capacity is a hardware contract.

Current shared memory is sized for the existing project baseline. ResNet adds pressure because:

```text
1. There are more layers.
2. Residual paths require preserving shortcut tensors.
3. ADD may require two source tensors at the same time.
4. INT32 intermediate tensors are 4x larger than INT8.
```

Example feature sizes for CIFAR ResNet:

```text
32x32x16 INT32 = 65,536 bytes
16x16x32 INT32 = 32,768 bytes
8x8x64 INT32   = 16,384 bytes
```

Single tensors are manageable, but multiple live tensors plus weights can become tight.

Architectural recommendation:

```text
1. Keep shared memory size unchanged for the first compatibility-preserving milestone.
2. Require Requant after major Conv/ADD outputs when possible.
3. Avoid long-lived INT32 feature maps unless necessary.
4. If full ResNet end-to-end memory pressure is too high, consider increasing shared memory as a separate explicit architecture change.
```

Do not silently change memory size or address contract as part of Conv/ADD/GAP implementation.

---

## 18. File-Level Implementation Plan

### 18.1 `rtl/npu/npu_ctrl.v`

Required changes:

```text
1. Add new registers using append-only address policy.
2. Add VERSION_REG and CAPABILITY_REG.
3. Add CONV_CFG.
4. Add BIAS_ADDR/BIAS_BYTES.
5. Add SRC1_ADDR/SRC1_BYTES.
6. Add ADD_CFG.
7. Add GAP_CFG.
8. Export config wires to npu_top.
9. Reset all new registers to LeNet-compatible defaults.
```

Do not:

```text
1. Move existing registers.
2. Change existing register reset values.
3. Change old start/busy/done/error semantics.
```

### 18.2 `rtl/npu/task_checker.v`

Required changes:

```text
1. Widen task_type if needed.
2. Preserve old task encodings.
3. Add ADD and GAP checks.
4. Add kernel/stride/padding checks.
5. Add bias checks.
6. Add src1 checks.
7. Add shape/output_bytes consistency checks.
8. Add new error codes.
```

Compatibility requirement:

```text
Old LeNet tasks that passed before must still pass with default new config.
```

### 18.3 `rtl/npu/conv_frontend.v`

Required changes:

```text
1. Support kernel_size 1/3/5.
2. Support stride1/stride2.
3. Support valid/same padding.
4. Generate zero values for padding boundary.
5. Preserve legacy 5x5 valid window order.
```

Implementation recommendation:

```text
Either extend the existing module with strict legacy tests,
or add a generalized frontend and keep a legacy-equivalent path during bring-up.
```

### 18.4 `rtl/npu/npu_top.v`

Required changes:

```text
1. Receive new config wires.
2. Dispatch new ADD/GAP tasks.
3. Parameterize Conv active_rows.
4. Add bias load and bias-to-sum_in mapping.
5. Add ADD load/compute/store path.
6. Add ADD postproc path.
7. Add GAP accumulate/divide/store path.
8. Preserve Conv/FC cluster feed and output routing for old tasks.
9. Preserve store packing behavior.
10. Preserve performance counter behavior and extend counters where useful.
```

High-risk areas:

```text
1. act_rd_addr / wgt_rd_addr mux changes.
2. wgt_load_reg indexing for kernel_size != 5.
3. cluster_weight_all_flat slicing.
4. array_sum_in bias injection.
5. output_arbiter aggregate safety.
6. store_pack_lane and partial-beat WSTRB.
```

### 18.5 `rtl/npu/postproc.v`

Required changes:

```text
1. Make ReLU reusable for ADD output.
2. Make Requant reusable for ADD output.
3. Optionally support GAP output postproc.
4. Preserve old Pool/ReLU behavior.
```

### 18.6 `rtl/npu/requant_i32_to_i8.v`

First milestone:

```text
No arithmetic change.
Reuse existing module.
```

Future:

```text
Optional per-source or per-channel quantization support.
```

### 18.7 `rtl/npu/compute_core_6cluster.v`

Expected changes:

```text
None or minimal.
```

Rationale:

```text
The compute core can remain a generic MAC array.
Conv1x1/3x3/5x5 differences are expressed through active_rows and input/weight feeding.
```

### 18.8 `rtl/soc/top.v`

Required changes:

```text
1. Wire new npu_ctrl outputs to npu_top.
2. Preserve old top-level ports and behavior.
3. Expose new register behavior only through AXI-Lite map.
```

---

## 19. Verification Strategy

Verification must be staged. Do not attempt ResNet end-to-end before unit and block-level closure.

### 19.1 Stage 0: Lock Current LeNet Baseline

Before making functional RTL changes:

```text
1. Run existing top-level LeNet sample.
2. Run top8/top16/top32 if available.
3. Run subsystem LeNet fixture.
4. Run Conv/Pool/FC/Requant unit tests.
5. Save memory dumps or checksums as baseline.
6. Save performance counter snapshots.
```

Acceptance:

```text
All current LeNet/MNIST tests pass.
Baseline outputs are available for comparison.
```

### 19.2 Stage 1: Register Extension

Tests:

```text
1. Read VERSION_REG.
2. Read CAPABILITY_REG.
3. Write/read CONV_CFG.
4. Write/read BIAS_ADDR/BIAS_BYTES.
5. Write/read SRC1_ADDR/SRC1_BYTES.
6. Write/read ADD_CFG.
7. Write/read GAP_CFG.
8. Reset and check defaults.
9. Run LeNet regression.
```

Acceptance:

```text
New registers work.
Reset defaults are LeNet-compatible.
LeNet output is unchanged.
```

### 19.3 Stage 2: Conv Parameterization

Tests:

```text
1. 5x5 valid stride1 legacy bit-exact.
2. 3x3 valid stride1 unit test.
3. 1x1 valid stride1 unit test.
4. Multiple input channels.
5. Multiple output channels.
6. output_c not divisible by cluster count.
7. single/dual/full/mask cluster modes.
```

Acceptance:

```text
Legacy Conv remains bit-exact.
New Conv kernels match golden.
```

### 19.4 Stage 3: Same Padding and Stride2

Tests:

```text
1. 3x3 same stride1 at corners/edges/center.
2. 3x3 same stride2.
3. 1x1 stride2.
4. odd/even input dimensions.
5. output shape checks.
6. invalid shape rejection.
```

Acceptance:

```text
Padding zero-fill is correct.
Stride output coordinate mapping is correct.
Output bytes and store layout match golden.
```

### 19.5 Stage 4: Bias

Tests:

```text
1. bias_en=0 legacy bit-exact.
2. bias_en=1 single cluster.
3. bias_en=1 full cluster.
4. output_c not divisible by enabled cluster count.
5. disabled clusters.
6. negative bias.
7. large positive/negative bias.
```

Acceptance:

```text
Bias maps to global output channel correctly.
No invalid column contamination.
```

### 19.6 Stage 5: ADD

Tests:

```text
1. INT32 + INT32 -> INT32.
2. positive + positive.
3. positive + negative.
4. negative + negative.
5. ADD + ReLU.
6. ADD + Requant.
7. ADD + ReLU + Requant.
8. partial final AXI beat.
9. misaligned address rejection.
10. src0/src1 byte mismatch rejection.
```

Acceptance:

```text
ADD output matches golden.
Task checker catches invalid ADD tasks.
LeNet regression still passes.
```

### 19.7 Stage 6: GAP

Tests:

```text
1. 8x8xC INT32 input.
2. 4x4xC INT32 input.
3. C = 1.
4. C not multiple of AXI word group.
5. reciprocal/shift rounding behavior.
6. output byte count correctness.
7. invalid parameter rejection.
```

Acceptance:

```text
GAP output matches golden within the defined fixed-point rule.
```

### 19.8 Stage 7: ResNet Block Tests

BasicBlock:

```text
Conv3x3 same
Bias
ReLU
Requant
Conv3x3 same
Bias
ADD
ReLU
Requant
```

DownsampleBlock:

```text
main path:
  Conv3x3 same stride2

shortcut path:
  Conv1x1 stride2 projection

merge:
  ADD
  ReLU
  Requant
```

Acceptance:

```text
Block-level memory output matches Python/C golden.
```

### 19.9 Stage 8: ResNet End-to-End

Only after previous stages pass:

```text
1. Single sample.
2. Small batch.
3. Performance counters.
4. Regression against LeNet.
```

Acceptance:

```text
ResNet sample path matches golden.
LeNet/MNIST remains passing.
```

---

## 20. Performance Counter Extension

Existing counters should be preserved.

Recommended new counters:

```text
conv_cycles
add_cycles
gap_cycles
bias_read_beats
src1_read_beats
eltwise_active_cycles
eltwise_stall_cycles
gap_active_cycles
gap_stall_cycles
shortcut_cycles
```

Purpose:

```text
1. Separate compute time from elementwise time.
2. Identify memory bottlenecks for ADD two-source reads.
3. Measure GAP cost.
4. Preserve visibility into cluster utilization.
```

Do not remove or rename old counters. If register space is tight, add a counter-select register rather than breaking existing counter addresses.

---

## 21. Implementation Milestones

### M0: Baseline Freeze

Deliverables:

```text
LeNet regression script/checklist
baseline output checksum or memory dump
baseline performance counter snapshot
```

Exit criteria:

```text
Current LeNet/MNIST flow passes before any behavior change.
```

### M1: Register and Capability Extension

Deliverables:

```text
VERSION_REG
CAPABILITY_REG
CONV_CFG
BIAS_ADDR/BIAS_BYTES
SRC1_ADDR/SRC1_BYTES
ADD_CFG
GAP_CFG
```

Exit criteria:

```text
New registers read/write correctly.
Reset defaults preserve LeNet.
```

### M2: Conv Kernel Parameterization

Deliverables:

```text
kernel_size = 1/3/5
active_rows = 1/9/25
legacy 5x5 bit-exact
```

Exit criteria:

```text
1x1/3x3 valid Conv tests pass.
5x5 LeNet Conv remains bit-exact.
```

### M3: Padding and Stride

Deliverables:

```text
same padding
stride2
shape checks
```

Exit criteria:

```text
3x3 same stride1/stride2 tests pass.
LeNet regression passes.
```

### M4: Bias

Deliverables:

```text
INT32 bias read
bias-to-sum_in mapping
multi-cluster bias routing tests
```

Exit criteria:

```text
bias_en=0 legacy bit-exact.
bias_en=1 golden tests pass.
```

### M5: ADD

Deliverables:

```text
ADD task
SRC1 read
INT32 add datapath
ADD store path
ADD task_checker checks
```

Exit criteria:

```text
ADD unit tests pass.
Invalid ADD tasks fail cleanly.
LeNet regression passes.
```

### M6: ADD Postproc

Deliverables:

```text
ADD + ReLU
ADD + Requant
ADD + ReLU + Requant
```

Exit criteria:

```text
All ADD postproc modes match golden.
```

### M7: GAP

Deliverables:

```text
GAP task
fixed-point reciprocal average
GAP store path
GAP checks
```

Exit criteria:

```text
GAP tests pass.
LeNet regression passes.
```

### M8: ResNet Block

Deliverables:

```text
BasicBlock test
DownsampleBlock test
projection shortcut test
```

Exit criteria:

```text
Block-level outputs match golden.
```

### M9: ResNet End-to-End Bring-Up

Deliverables:

```text
single sample ResNet run
small batch ResNet run
performance summary
LeNet regression report
```

Exit criteria:

```text
ResNet path matches golden within defined quantization rules.
LeNet/MNIST remains passing.
```

---

## 22. Architectural Risks and Mitigations

### Risk 1: Legacy Conv Behavior Changes

Cause:

```text
Conv frontend parameterization changes old 5x5 valid window order or timing.
```

Mitigation:

```text
1. Add 5x5 legacy bit-exact unit test.
2. Keep legacy mode path if needed.
3. Run LeNet regression after every Conv change.
```

### Risk 2: Padding Window Order Mismatch

Cause:

```text
same padding creates window values in an order that does not match weight layout.
```

Mitigation:

```text
1. Corner/edge/center directed tests.
2. Use small hand-checkable tensors.
3. Compare every window position against golden.
```

### Risk 3: Stride2 Store Shape Mismatch

Cause:

```text
Compute output dimensions and DMA output_bytes disagree.
```

Mitigation:

```text
1. task_checker shape checks.
2. output_h/output_w golden tests.
3. store address trace tests.
```

### Risk 4: Bias Mapped to Wrong Output Channel

Cause:

```text
Cluster local columns are not correctly mapped to global output channels.
```

Mitigation:

```text
1. Unique bias pattern per channel.
2. Test output_c not divisible by cluster_count.
3. Test single/dual/full/mask cluster modes.
```

### Risk 5: ADD Scale Mismatch

Cause:

```text
Two residual branches are not in compatible numeric scale.
```

Mitigation:

```text
1. First version defines ADD as INT32 same-scale.
2. Document the numeric contract.
3. Add future rescale only as separate milestone.
```

### Risk 6: Buffer Reuse Confusion

Cause:

```text
wgt_buffer reused as src1 buffer for ADD, causing confusing control or stale data.
```

Mitigation:

```text
1. Explicit read ownership per task.
2. Clear buffer valid/state before ADD.
3. Add directed stale-buffer tests.
4. Consider renaming abstraction later.
```

### Risk 7: Task Type Width Inconsistency

Cause:

```text
Some modules still use 2-bit task_type after adding ADD/GAP.
```

Mitigation:

```text
1. Search all task_type declarations.
2. Add compile-time width checks where possible.
3. Add ADD/GAP smoke tests through top-level register path.
```

### Risk 8: Output Arbiter OR Merge Unsafe for New Conv Modes

Cause:

```text
Invalid columns not zeroed or cluster column routing overlaps.
```

Mitigation:

```text
1. Re-run route/aggregate tests for 1x1/3x3/5x5.
2. Add assertions for mutually exclusive valid columns.
3. Test cluster masks.
```

### Risk 9: Store Packing Breaks Partial Beats

Cause:

```text
ADD/GAP output sizes may create new partial-beat cases.
```

Mitigation:

```text
1. Directed tests for 1, 2, 7, 8, 9 output words.
2. Check WSTRB on final beat.
3. Compare memory byte lanes against golden.
```

### Risk 10: New Defaults Break LeNet

Cause:

```text
New control registers reset to non-legacy values.
```

Mitigation:

```text
1. Reset-default register test.
2. LeNet no-new-register-write regression.
3. Explicit default constants in RTL and docs.
```

---

## 23. Acceptance Criteria

No ResNet extension is considered complete unless all of the following are true:

```text
1. LeNet/MNIST regression passes.
2. Existing old task encodings still work.
3. Existing register map remains backward-compatible.
4. New registers reset to LeNet-compatible defaults.
5. Each new operator has unit tests.
6. Each new operator has golden output comparison.
7. ADD and GAP invalid parameter cases are rejected by task_checker.
8. Conv1x1/3x3/5x5 all pass directed tests.
9. same padding edge/corner behavior is verified.
10. stride2 shape/store behavior is verified.
11. bias mapping is verified under multi-cluster modes.
12. output_arbiter route/merge safety is reverified for new Conv modes.
13. store packing and WSTRB are verified for new output sizes.
14. ResNet BasicBlock and DownsampleBlock pass block-level golden checks.
```

End-to-end ResNet is not allowed to replace LeNet regression. It is an additional capability, not a new baseline that invalidates the old one.

---

## 24. Recommended Codex Work Order

Codex should implement in this order:

```text
1. Add VERSION/CAPABILITY registers.
2. Add CONV_CFG/BIAS/SRC1/ADD/GAP registers with safe defaults.
3. Run LeNet regression.
4. Widen task_type consistently if needed.
5. Add task_checker support for widened old task_type only.
6. Run LeNet regression.
7. Parameterize Conv active_rows while preserving 5x5 legacy behavior.
8. Add 1x1 and 3x3 valid tests.
9. Add same padding.
10. Add stride2.
11. Add bias through sum_in.
12. Add ADD task.
13. Add ADD postproc.
14. Add GAP task.
15. Add BasicBlock test.
16. Add DownsampleBlock test.
17. Add ResNet end-to-end smoke.
18. Run full LeNet regression again.
```

At every step:

```text
If LeNet regression fails, stop and fix compatibility before continuing.
```

---

## 25. Final Architectural Position

The correct long-term framing is:

```text
The current design is a LeNet-validated task-based NPU.
The proposed work extends it into a residual-CNN-capable task-based NPU.
The PE array remains reusable.
The major changes are in task configuration, convolution frontend generality,
elementwise data paths, post-processing, and validation.
```

The most important design principle is:

```text
Do not replace the LeNet path.
Extend around it with opt-in capabilities.
```

The second most important principle is:

```text
Do not treat ResNet as only "more layers".
ResNet requires new hardware-visible semantics:
same-padding Conv, stride2 shape changes, residual ADD, bias/BN-fold support,
and global average pooling.
```

If these principles are followed, the RTL can evolve toward ResNet support while preserving the current MNIST/LeNet implementation as a stable regression baseline.

