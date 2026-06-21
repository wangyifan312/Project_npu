# ResNet-20 RTL Extension Plan

本文档定义 `Project_npu` 从当前 LeNet/MNIST validated NPU 扩展到 CIFAR ResNet-20 的 RTL 修改计划。

本计划依赖：

```text
docs/RESNET20_SOFTWARE_GOLDEN_PLAN.md
```

ResNet RTL 数值实现不得在 `R0.5 ResNet-20 Software Golden and Fixture Flow` 关闭前启动。

---

## 1. Summary

目标是在不破坏当前 LeNet/MNIST、HB、AXI、store packing、64B alignment contract 的前提下，把现有 task-based NPU 扩展为支持 CIFAR ResNet-20 小批量 `8/16` golden 对拍。

首版硬件能力固定为：

```text
Conv1x1 / Conv3x3 / Conv5x5
stride1 / stride2
valid / same padding
INT32 folded bias
INT32 same-scale ADD
ADD only
ADD + ReLU
ADD + Requant
ADD + ReLU + Requant
GAP
FC10
```

downsample shortcut 固定采用：

```text
1x1 stride2 projection Conv
```

---

## 2. Immutable Guardrails

以下 contract 不允许在 ResNet RTL 扩展中顺手改变：

```text
1. LeNet/MNIST 当前 task sequence 必须保持可运行。
2. 旧 task_type 编码含义不变。
3. 现有 AXI-Lite register 地址不移动、不重解释。
4. LeNet Conv default 仍是 5x5 / stride1 / valid / no bias。
5. FC 正式路径继续使用 arrayized 6-cluster compute path。
6. Requant 算法语义不变。
7. HWC feature layout 不变。
8. 现有 5x5 Conv weight layout 不变。
9. FC weight layout 不变。
10. shared memory 固定为 1 MB = 32768 x 256-bit beat。
11. NPU task base address 继续要求 64B 对齐。
12. acc_buffer -> DMA writer packing 保持 32-bit word -> 256-bit AXI beat。
13. last-beat WSTRB 继续由实际 byte count 决定。
14. 不新增 task queue / descriptor FIFO / shadow config。
15. 不改变单任务寄存器触发模型。
```

每个 RTL milestone 必须复跑当前 LeNet regression。若 LeNet regression 失败，停止推进 ResNet 功能。

---

## 3. Interface Changes

### 3.1 Task Type

`task_type` 全链路从 2 bit 扩到至少 3 bit。

旧编码保持不变：

```text
0: Conv
1: FC
2: Pool
3: Requant
```

新增编码：

```text
4: ADD
5: GAP
6: reserved, optional ShortcutDownsamplePad if explicitly approved later
7: reserved
```

涉及范围至少包括：

```text
npu_ctrl
task_checker
block_scheduler
npu_top
testbenches
documentation
task register readback
```

### 3.2 Append-Only Register Map

当前 register map 已使用到：

```text
0x88 CLUSTER_MODE
0x8C CLUSTER_MASK
```

ResNet 扩展只允许 append-only 追加：

```text
0x90 VERSION       RO
0x94 CAPABILITY    RO
0x98 CONV_CFG      RW
0x9C BIAS_ADDR     RW
0xA0 BIAS_BYTES    RW
0xA4 SRC1_ADDR     RW
0xA8 SRC1_BYTES    RW
0xAC ADD_CFG       RW
0xB0 GAP_CFG       RW
0xB4 POSTPROC_CFG  RW
```

所有新增寄存器必须 readable for debug，并在 reset 后复现当前 LeNet 行为。

### 3.3 CONV_CFG

建议字段：

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

bit [5] projection_hint
  0: normal Conv
  1: projection Conv hint for 1x1 shortcut path
```

Conv fused ReLU/Requant 可由 `POSTPROC_CFG` 表达，不应在首版同时引入两套 postproc 控制语义。

### 3.4 ADD_CFG

首版固定支持：

```text
INT32 + INT32 -> INT32
```

建议字段：

```text
bits [1:0] add_dtype
  0: INT32 + INT32 -> INT32
  others: reserved

bit [2] add_relu_en
bit [3] add_requant_en
```

ADD same-scale 由 software golden 保证，RTL v1 不支持 dual-branch rescale。

### 3.5 GAP_CFG

首版固定支持：

```text
INT32 HWC input -> INT32 output[C]
```

建议字段：

```text
bits [1:0] gap_input_dtype
  0: INT32
  others: reserved

bits [3:2] gap_output_dtype
  0: INT32
  others: reserved

bits [19:4] reciprocal
bits [25:20] shift
```

不新增硬件 divider。

### 3.6 CAPABILITY

建议 capability bits：

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
bit10: projection_shortcut_supported
```

CAPABILITY 只能反映当前 RTL 已实现并验证的功能，不能提前声明未来功能。

---

## 4. Implementation Milestones

### R1-0: Readiness Review and Implementation Scope

状态：完成。

输出：

```text
docs/RESNET20_RTL_R1_READINESS_REVIEW.md
datasets/cifar10/resnet20_export_package/rtl_r1_readiness.json
```

结论：

```text
rtl_r1_ready_for_review = true
rtl_r1_ready_for_implementation = true for R1a/R1 foundation coding
blockers = none
rtl_modified = false
testbench_modified = false
rtl_r1_started = false
```

R1-0 只完成 review/scope，不实现 RTL。下一步推荐进入 R1a。

### R1a: Register and Task-Type Foundation

状态：完成。

目标：

```text
1. task_type 全链路扩到至少 3 bit。
2. 添加 VERSION/CAPABILITY 和新 config registers。
3. 新寄存器 reset/default 保持 LeNet-compatible。
4. ADD/GAP 在 datapath 未实现前必须被 task_checker 受控拒绝，或 CAPABILITY 明确标为 unsupported。
```

当前实现：

```text
task_type width:
  npu_ctrl -> task_checker -> npu_top -> block_scheduler = 3 bit

legacy encodings preserved:
  0 = Conv legacy
  1 = FC
  2 = Pool
  3 = Requant

reserved encodings:
  4 = ADD, unsupported in R1a
  5 = GAP, unsupported in R1a
  6/7 = invalid/reserved
```

R1a append-only register map:

```text
0x90 VERSION       RO  0x0001_000A
0x94 CAPABILITY    RO  0x0000_7801
0x98 CONV_CFG      RW  reset 0, bits [5:0] retained
0x9C BIAS_ADDR     RW  reset 0
0xA0 BIAS_BYTES    RW  reset 0
0xA4 SRC1_ADDR     RW  reset 0
0xA8 SRC1_BYTES    RW  reset 0
0xAC ADD_CFG       RW  reset 0, bits [3:0] retained
0xB0 GAP_CFG       RW  reset 0, bits [25:0] retained
0xB4 POSTPROC_CFG  RW  reset 0
```

R1a CAPABILITY bit definition:

```text
bit0  conv_5x5_supported = 1
bit1  conv_3x3_supported = 0
bit2  conv_1x1_supported = 0
bit3  same_padding_supported = 0
bit4  stride2_supported = 0
bit5  bias_supported = 0
bit6  add_supported = 0
bit7  gap_supported = 0
bit8  add_relu_supported = 0
bit9  add_requant_supported = 0
bit10 projection_shortcut_supported = 0
bit11 fc_supported = 1
bit12 pool_supported = 1
bit13 requant_supported = 1
bit14 runtime_cluster_config_supported = 1
```

ADD/GAP behavior in R1a:

```text
task_type=4 ADD -> task_checker reject, error_code=0x0A
task_type=5 GAP -> task_checker reject, error_code=0x0A
```

The new config registers are storage/readback only in R1a. They are not consumed by
the legacy datapath and do not enable generalized Conv, residual ADD, GAP, task
queues, descriptor FIFO, or shadow config.

验收：

```text
1. 旧 LeNet testbench 不写新寄存器仍通过。
2. 新寄存器 read/write/reset 测试通过。
3. 旧 task_type 0/1/2/3 readback 和行为不变。
4. invalid unsupported task 能给出确定 error code。
```

R1a validation entry:

```text
tb/unit/tb_resnet20_r1a_ctrl_regs.v
```

### R1b: Generalized Conv Foundation

状态：完成。

目标：

```text
1. 让 R1a CONV_CFG 被 Conv checker / scheduler / frontend 消费。
2. 保持 legacy 5x5 valid stride1 默认行为不变。
3. 为 ResNet 1x1 / 3x3 / stride2 / same padding 建立 control 和 output-shape foundation。
4. 在 folded bias / ADD / GAP datapath 未实现前，不声明 ResNet 数值通路完成。
```

R1b CONV_CFG bit definition:

```text
bits [1:0] kernel_size_sel
  0: 5x5
  1: 1x1
  2: 3x3
  3: reserved/invalid in R1b

bit [2] stride_sel
  0: stride1
  1: stride2

bit [3] padding_mode
  0: valid
  1: same

bit [4] bias_en
  0: no folded bias
  1: rejected in R1b, reserved for R1c folded bias

bit [5] projection_hint
  retained/readable in R1b; semantic hint for future 1x1 projection path
```

Accepted Conv configs in R1b:

```text
CONV_CFG=0x00: 5x5 valid stride1, legacy/default
CONV_CFG=0x0A: 3x3 same stride1
CONV_CFG=0x0E: 3x3 same stride2
CONV_CFG=0x01: 1x1 valid stride1
CONV_CFG=0x05: 1x1 valid stride2
```

Rejected in R1b:

```text
kernel_size_sel=3
3x3 valid
1x1 same
bias_en=1
ADD/GAP task_type
```

Reject behavior:

```text
illegal Conv config -> task_checker error_code=0x07
task_type=4 ADD    -> task_checker error_code=0x0A
task_type=5 GAP    -> task_checker error_code=0x0A
```

Output-shape rules used by block_scheduler and npu_top:

```text
valid:        floor((input - kernel) / stride) + 1
same stride1: output = input
same stride2: output = ceil(input / 2)
```

Implementation scope:

```text
control/checker:
  R1b Conv modes above are accepted or rejected deterministically.

scheduler:
  derives generalized output_h/output_w, block input rows, and weight bytes per input channel.

frontend:
  recognizes 5x5/3x3/1x1, stride1/2, valid/same and emits compact window lanes.

datapath:
  legacy 5x5 valid stride1 remains the only formally proven numerical Conv datapath.
  1x1/3x3/stride2/same are foundation paths and require later directed numerical closure.
```

CAPABILITY remains conservative after R1b:

```text
bit0  conv_5x5_supported = 1
bit1  conv_3x3_supported = 0
bit2  conv_1x1_supported = 0
bit3  same_padding_supported = 0
bit4  stride2_supported = 0
bit5  bias_supported = 0
bit10 projection_shortcut_supported = 0
```

This means R1b accepts selected generalized Conv task configs at the control and
scheduler/frontend level, but it does not claim full ResNet generalized Conv
datapath support.

Validation entry:

```text
tb/unit/tb_task_checker.v
tb/unit/tb_resnet20_r1b_conv_shape.v
tb/unit/tb_conv_frontend.v
tb/unit/tb_resnet20_r1a_ctrl_regs.v
```

### R1c: Folded Bias + Requant Integration

目标：

```text
1. 复用 R1a BIAS_ADDR / BIAS_BYTES 寄存器，把 folded INT32 bias 接入 Conv/FC task control path。
2. 让 CONV_CFG[4] 从 reserved/reject 变为 Conv/FC folded-bias enable。
3. 固定数值顺序：accumulator INT32 -> optional + folded bias INT32 -> requant_i32_to_i8 -> INT8。
4. 保持 bias_en=0 时 legacy Conv/FC/Pool/Requant 行为不变。
5. 不实现 residual ADD、GAP 或 ResNet end-to-end。
```

R1c control semantics:

```text
CONV_CFG[4] = 0
  no folded bias; legacy no-bias behavior remains the reset default.

CONV_CFG[4] = 1
  enables folded INT32 bias for task_type=Conv and task_type=FC.
  BIAS_ADDR / BIAS_BYTES must describe a valid signed INT32 bias vector.
```

R1c bias payload validation:

```text
BIAS_ADDR != 0
BIAS_ADDR is 64B aligned
BIAS_ADDR + BIAS_BYTES stays within shared memory
BIAS_BYTES != 0
BIAS_BYTES is 32-bit word aligned
BIAS_BYTES >= output_c * 4
```

Invalid or missing bias payload is rejected deterministically:

```text
task_checker error_code=0x0C
```

Numeric contract:

```text
bias dtype: signed INT32
Conv bias ordering: output channel order
FC bias ordering: output neuron order
bias add domain: accumulator INT32 domain
requant primitive: existing requant_i32_to_i8, unchanged
```

Datapath status after R1c:

```text
Conv legacy 5x5 no-bias path: preserved
FC legacy no-bias path: preserved
Conv optional bias + requant postprocess: connected foundation path
FC optional bias + requant postprocess: connected foundation path
Residual ADD: not implemented
GAP: not implemented
ResNet end-to-end: not implemented
```

CAPABILITY after R1c:

```text
bit0  conv_5x5_supported = 1
bit5  bias_supported = 1

bit1  conv_3x3_supported = 0
bit2  conv_1x1_supported = 0
bit3  same_padding_supported = 0
bit4  stride2_supported = 0
bit10 projection_shortcut_supported = 0
ADD/GAP remain unsupported
```

This means R1c reports folded-bias postprocess support only. It still does not
claim generalized Conv numerical closure or ResNet block/end-to-end support.

Validation entry:

```text
tb/unit/tb_bias_add_requant_i32_to_i8.v
tb/unit/tb_task_checker.v
tb/unit/tb_resnet20_r1a_ctrl_regs.v
tb/unit/tb_resnet20_r1b_conv_shape.v
tb/unit/tb_conv_frontend.v
tb/unit/tb_npu_top_route_observe.v
```

### R1d: Residual ADD Task/Datapath Foundation

状态：完成。

目标：

```text
1. 将 task_type=4 从 unsupported/reject 升级为 ADD task。
2. 消费 R1a SRC1 / ADD / POSTPROC 寄存器。
3. 增加 branch pre-align / post-requant 参数寄存器。
4. 实现 directed unit-level ADD datapath foundation。
5. 保持 GAP unsupported，且不跑 ResNet end-to-end。
```

R1d append-only register map:

```text
0xB8 ADD_SRC0_MULT   RW reset 0, src0 pre-align multiplier
0xBC ADD_SRC0_SHIFT  RW reset 0, src0 pre-align shift
0xC0 ADD_SRC1_MULT   RW reset 0, src1 pre-align multiplier
0xC4 ADD_SRC1_SHIFT  RW reset 0, src1 pre-align shift
0xC8 ADD_OUT_MULT    RW reset 0, post-ADD output requant multiplier
0xCC ADD_OUT_SHIFT   RW reset 0, post-ADD output requant shift
```

ADD control semantics:

```text
task_type=4 ADD
input_addr/input_bytes   -> src0
SRC1_ADDR/SRC1_BYTES     -> src1
output_addr/output_bytes -> dst

ADD_CFG[1:0] reserved, must be 0
ADD_CFG[2] or POSTPROC_CFG[0] = ReLU enable
ADD_CFG[3] or POSTPROC_CFG[1] = post-requant enable
```

ADD validation:

```text
src0/src1/output addr must be non-zero, 64B aligned, and in 1MB shared memory
src1_bytes != 0
input_bytes == src1_bytes
output_bytes == input_bytes
if post-requant enabled:
  ADD_SRC0_MULT / ADD_SRC1_MULT / ADD_OUT_MULT must be non-zero
  ADD_SRC0_SHIFT / ADD_SRC1_SHIFT / ADD_OUT_SHIFT must be <= 31
invalid ADD payload -> task_checker error_code=0x0B
```

`0x0B` is the shared numeric/scale parameter validation error for legacy Requant
and R1d ADD requant/alignment parameters. Because ADD multiplier registers reset
to `0`, an ADD task with post-requant enabled is rejected until software writes
non-zero `ADD_SRC0_MULT`, `ADD_SRC1_MULT`, and `ADD_OUT_MULT`.

Datapath foundation:

```text
act_buffer: ADD src0
wgt_buffer: ADD src1
acc_buffer: ADD output staging

src0 INT8 -> pre-align through requant_i32_to_i8
src1 INT8 -> pre-align through requant_i32_to_i8
aligned INT8 values sign-extend to INT32
INT32 add
optional ReLU
optional post-requant through requant_i32_to_i8
INT8 output packed through existing store path
```

The `wgt_buffer` reuse is an internal buffer policy for ADD src1 and does not
change weight semantics. `requant_i32_to_i8` is reused unchanged.

CAPABILITY after R1d:

```text
bit0  conv_5x5_supported = 1
bit5  bias_supported = 1
bit6  add_supported = 1
bit8  add_relu_supported = 1
bit9  add_requant_supported = 1
bit11 fc_supported = 1
bit12 pool_supported = 1
bit13 requant_supported = 1
bit14 runtime_cluster_config_supported = 1

CAPABILITY readback = 0x0000_7B61

bit7  gap_supported = 0
bit10 projection_shortcut_supported = 0
bit1/2/3/4 generalized Conv full numerical support = 0
```

R1d boundary:

```text
Residual ADD directed foundation: connected
Residual block / ResNet end-to-end: not implemented
GAP datapath: not implemented
Generalized Conv numerical closure: not completed
LeNet legacy contract: unchanged
```

Validation entry:

```text
tb/unit/tb_residual_add_requant_i8.v
tb/unit/tb_task_checker.v
tb/unit/tb_resnet20_r1a_ctrl_regs.v
tb/unit/tb_bias_add_requant_i32_to_i8.v
tb/unit/tb_resnet20_r1b_conv_shape.v
```

### R1e: GAP8x8 Task/Datapath Foundation

R1e upgrades `task_type=5` from deterministic reject to a directed GAP8x8
foundation. This is not ResNet task-sequence or end-to-end execution.

GAP control semantics:

```text
task_type=5 GAP
input_addr/input_bytes   -> INT8 8x8 feature-map source
output_addr/output_bytes -> INT8 per-channel vector destination
weight_addr/weight_bytes -> unused / zero

GAP_CFG[1:0]   = 0: INT8 input
GAP_CFG[3:2]   = 0: INT8 output
GAP_CFG[19:4]  = 0: reserved
GAP_CFG[25:20] = 6: divide-by-64 shift for 8x8 GAP
GAP_CFG[31:26] = 0: reserved

POSTPROC_CFG[1] = optional post-requant enable
POSTPROC_CFG other bits must be 0 for R1e GAP
```

GAP validation:

```text
input/output addr must be non-zero, 64B aligned, and in 1MB shared memory
input_h = 8
input_w = 8
input_c >= 1
output_c = input_c
input_bytes = 64 * input_c
output_bytes = input_c
weight_bytes = 0
if POSTPROC_CFG[1] is set:
  requant_multiplier must be non-zero
  requant_shift must be <= 31
invalid GAP payload -> task_checker error_code=0x0B
```

Datapath foundation:

```text
act_buffer: GAP input staging
acc_buffer: GAP output staging

INT8 feature-map values
per-channel INT32 spatial sum over 8x8
signed round-half-away divide-by-64 fixed shift
optional post-requant through requant_i32_to_i8
INT8 output packed through existing store path
```

`requant_i32_to_i8` is reused unchanged. The existing store path and DMA writer
keep the byte-count / last-beat WSTRB contract.

CAPABILITY after R1e:

```text
bit0  conv_5x5_supported = 1
bit5  bias_supported = 1
bit6  add_supported = 1
bit7  gap_supported = 1
bit8  add_relu_supported = 1
bit9  add_requant_supported = 1
bit11 fc_supported = 1
bit12 pool_supported = 1
bit13 requant_supported = 1
bit14 runtime_cluster_config_supported = 1

CAPABILITY readback = 0x0000_7BE1

bit10 projection_shortcut_supported = 0
bit1/2/3/4 generalized Conv full numerical support = 0
```

R1e boundary:

```text
GAP8x8 directed foundation: connected
ResNet task sequence / end-to-end: not implemented
Generalized Conv numerical closure: not completed
LeNet legacy contract: unchanged
```

Validation entry:

```text
tb/unit/tb_gap8x8_requant_i8.v
tb/unit/tb_task_checker.v
tb/unit/tb_resnet20_r1a_ctrl_regs.v
tb/unit/tb_npu_top_route_observe.v
```

### R1f: Task-Sequence RTL Smoke Foundation

R1f first added a package-derived control/checker smoke, then was upgraded to a
minimal `npu_top` datapath-carrying smoke. It is intentionally not a full
ResNet-20 run and does not close numerical end-to-end correctness.

Current `npu_top` smoke slice:

```text
layer1.0.conv1
layer1.0.conv2
layer1.0.add
```

This is a contiguous early residual slice. It replaces the earlier review
prototype that mixed `layer1.0.add` with the non-contiguous tail
`layer3.2.add.relu -> gap -> fc`.

R1f originally skipped package task0 because the handoff memory map placed
`input.image` at byte address `0`, while the existing `task_checker` treats
address `0` as a null-address reject. R1h closes that contract gap in the
package layer: `memory_map.json` now reserves address `0`, and `input.image`
starts at byte address `64`. The `task_checker` null-address rule is preserved;
no RTL special-case is added for ResNet task0. R1f/R1g compact aliases remain
test-only speed fixtures for the contiguous residual slice.

R1f generated stimulus:

```text
datasets/scripts/extract_resnet20_r1f_smoke.py
tb/generated/resnet20_r1f_smoke_tasks.vh
tb/generated/resnet20_r1f_smoke_summary.json
tb/generated/resnet20_r1f_npu_top_residual_tasks.vh
tb/generated/resnet20_r1f_npu_top_residual_summary.json
```

R1f validation entries:

```text
tb/integration/tb_resnet20_r1f_smoke.v
tb/integration/tb_resnet20_r1f_npu_top_smoke.v
```

The smoke consumes the validated export package:

```text
datasets/cifar10/resnet20_export_package/task_sequence.json
datasets/cifar10/resnet20_export_package/memory_map.json
datasets/cifar10/resnet20_export_package/weights/*.memh
datasets/cifar10/resnet20_export_package/bias/*.memh
datasets/cifar10/resnet20_export_package/requant/*.json
```

Covered behavior:

```text
task_type 0 Conv register programming and npu_top execution
task_type 4 ADD register programming and npu_top execution
busy/done/error control flow through npu_top
memory_map-derived src0/src1/dst address consumption
package-derived weight/bias/requant metadata consumption
AXI read/write beat observation
X-aware masked checksum and unknown-byte count observation
```

R1f boundary:

```text
Full 32-task ResNet-20 sequence: not executed
GAP/FC tail in npu_top smoke: not executed
Small fixture fixed-point compare: not completed
Generalized Conv numerical datapath closure: not completed
ResNet end-to-end RTL closure: not completed
Requant primitive semantics: unchanged
LeNet legacy contract: unchanged
```

### R1g: Small Fixture Fixed-Point Compare

R1g adds a value-aware compare on the same package-derived contiguous residual
slice used by the R1f `npu_top` smoke:

```text
layer1.0.conv1
layer1.0.conv2
layer1.0.add
```

The compare still uses the R1f compact alias/remap fixture:

```text
conv1.relu                  -> 0x00001000, 36 bytes
layer1.0.conv1.relu         -> 0x00002000, 36 bytes
layer1.0.conv2.pre_add_main -> 0x00003000, 36 bytes
layer1.0.add.relu           -> 0x00004000, 36 bytes
```

This remap is test-only. R1h updates the formal package `memory_map.json` so
address `0` is reserved/null and `input.image` uses a nonzero 64B-aligned base
address. The compact R1g compare remains useful directed evidence, but it is no
longer the only path around the `input.image` null-address conflict.

R1g generated artifacts:

```text
datasets/scripts/extract_resnet20_r1g_compare_fixture.py
tb/generated/resnet20_r1g_compare_expected.vh
tb/generated/resnet20_r1g_compare_summary.json
tb/generated/resnet20_r1g_compare_rtl_result.json
tb/integration/tb_resnet20_r1g_compare.v
```

R1g reference source:

```text
datasets/cifar10/resnet20_export_package/weights/*.memh
datasets/cifar10/resnet20_export_package/bias/*.memh
datasets/cifar10/resnet20_export_package/requant/conv_fc_requant.json
datasets/cifar10/resnet20_export_package/requant/residual_add_alignment.json
```

R1g compact layout contract:

```text
Conv input: dense HWC INT8 byte stream at task input address
Conv output: current RTL physical store, one INT8 output in byte lane 0 of each 32-bit word
ADD input: physical byte stream exactly as stored in memory
ADD output: dense INT8 byte stream packed four values per 32-bit word by ADD datapath
```

Current R1g result:

```text
compared_bytes: 108
mismatch_count: 0
total_unknown_bytes: 0
stage logical_output_elements: 9 / 9 / 9
stage stored_bytes: 36 / 36 / 36
stage mismatch_count: 0 / 0 / 0
stage unknown_bytes: 0 / 0 / 0
first_unknown_stage: none
final_checksum_masked: 0x00001bb0
final_unknown_bytes: 0
first mismatch: none
status: match
```

Conv1 byte0 trace after layout alignment:

```text
RTL/reference window bytes: 00 00 00 00 00 00 00 71 6c
selected weights: ff 07 03 02 f5 01 f7 fd 03
bias_i32: 2334
mac_before_bias: -15
post-bias accumulator: 2319
requant multiplier/shift: 11913625 / 31
reference output byte: 0x0d
RTL output byte: 0x0d
```

Current root-cause assessment:

```text
Unknown propagation no longer appears in the compact slice after the Conv bias/requant/store
element-count fix.
The R1g TB now loads package-derived Conv weight/bias bytes instead of checksum-derived seed data.
The compact reference now uses the same dense HWC Conv input byte stream consumed by
conv_frontend. That prior layout fix reduced total mismatch from 27 to 5; the
Conv tail writeback fix further reduced total mismatch from 5 to 1. The current
ADD final packed-word writeback fix reduces total mismatch from 1 to 0.
The Conv tail mismatch was traced to the internal Conv bias/requant path: the final
registered `rq_acc_wr_en_r` pulse occurred after leaving `FSM_REQUANT_COMPUTE`, but
the acc_buffer write mux only accepted internal requant writes while still in that
state. As a result, the last logical Conv output element was not committed before
STORE read the buffer.
R1g now inserts an internal `FSM_REQUANT_DRAIN` phase and treats that phase as an
internal requant write phase, so the final element commits before STORE starts.
After the fix:
  layer1.0.conv1 last expected/actual word: 09 00 00 00 / 09 00 00 00
  layer1.0.conv2 last expected/actual word: 0d 00 00 00 / 0d 00 00 00
Conv1 and conv2 now exact-match the compact reference with unknown=0.
The final ADD mismatch was traced to the same registered writeback class:
`add_acc_wr_en_r` committed one cycle after the final ADD pack decision, but the
acc_buffer write mux only accepted ADD writes in `FSM_ADD_COMPUTE`. R1g now
inserts `FSM_ADD_DRAIN` and treats that state as an ADD write phase, so the final
packed word commits before STORE reads acc_buffer.
ADD byte32 trace after the fix:
  src0_i8: 13
  src1_i8: -111
  src0_aligned: 13
  src1_aligned: -80
  add_raw: -67
  add_after_relu: 0
  post_requant_output_i8: 0
  stored word bytes: 00 00 00 00
The compact 3-task residual slice now exact-matches with unknown=0.
```

R1g conclusion:

```text
Value-aware compact compare is now available.
Exact fixed-point match is achieved for the current compact 3-task residual slice.
Compact Conv layout and Conv tail writeback are closed for the current 3-task
compact residual slice.
Residual ADD compact physical-byte compare is closed for the same slice.
Full 32-task ResNet-20 sequence remains unexecuted.
ResNet end-to-end RTL closure remains incomplete.
Requant primitive semantics are unchanged.
LeNet legacy contract is unchanged.
```

### R1h: Package-Faithful Small Fixture Compare

R1h adds the first package-faithful small fixture compare. The selected scope is
the minimal formal task0 path:

```text
input.image -> conv1 -> conv1.relu
```

Address-contract closure:

```text
address 0: reserved/null
input.image base_addr: 64
conv1.relu base_addr: 3136
task_checker null-address reject: unchanged
LeNet legacy contract: unchanged
```

Generated/updated R1h artifacts:

```text
datasets/scripts/extract_resnet20_r1h_package_fixture.py
tb/generated/resnet20_r1h_package_compare.vh
tb/generated/resnet20_r1h_package_compare_summary.json
tb/generated/resnet20_r1h_conv1_reference_trace.json
tb/generated/resnet20_r1h_conv1_trace.json
tb/generated/resnet20_r1h_conv1_window_weight_isolation.json
tb/generated/resnet20_r1h_conv1_acc_source_trace.json
tb/generated/resnet20_r1h_conv1_window_truth.json
tb/generated/resnet20_r1h_conv1_acc_ownership_truth.json
tb/generated/resnet20_r1h_conv1_byte3_trace.json
tb/generated/resnet20_r1h_package_compare_debug_summary.json
tb/generated/resnet20_r1h_package_compare_rtl_result.json
tb/integration/tb_resnet20_r1h_package_compare.v
datasets/cifar10/resnet20_export_package/memory_map.json
datasets/cifar10/resnet20_export_package/task_sequence.json
datasets/cifar10/resnet20_export_package/task_memory_validation.json
datasets/cifar10/resnet20_export_package/validation_report.json
```

R1h uses the formal package tensor addresses and byte sizes:

```text
input.image bytes: 3072
conv1.relu output/compare bytes: 16384
weights/bias/requant source: validated export package
```

R1h VCS result before this window/ownership fix:

```text
compared_bytes: 16384
mismatch_count: 12252
unknown_bytes: 1
first_mismatch: byte0 expected 0x00 actual 0x0b
first_unknown: byte64, dense HWC position (oh=0, ow=4, oc=0)
final_checksum: 0xdb490b10
expected_checksum: 0x482186f6
numeric_match: false
```

R1h intermediate result after byte0 window/readback fix only:

```text
compared_bytes: 16384
mismatch_count: 11049
unknown_bytes: 1
first_mismatch: byte3 expected 0x18 actual 0x00
first_unknown: byte64, dense HWC position (oh=0, ow=4, oc=0)
final_checksum: 0x137820e4
expected_checksum: 0x482186f6
numeric_match: false
```

R1h final VCS result after global collect-owner and byte-lane ownership fix:

```text
compared_bytes: 16384
mismatch_count: 0
unknown_bytes: 0
first_mismatch: none
final_checksum: 0x482186f6
expected_checksum: 0x482186f6
numeric_match: true
```

R1h focused conv1 trace after fix:

```text
trace position: output(oh=0, ow=0, oc=0)
artifact: tb/generated/resnet20_r1h_conv1_trace.json
reference MAC before bias: -963
RTL MAC before bias: -963
reference bias / RTL bias: -1323 / -1323
reference post-bias / RTL post-bias: -2286 / -2286
reference output byte / RTL output byte: 0x00 / 0x00
first divergence stage for output(0,0,0): none
```

R1h window placement truth after fix:

```text
artifact: tb/generated/resnet20_r1h_conv1_window_truth.json
3x3 same stride1 output(0,0,0): top row and left column are zero padding
input[0..5]: taps 12..17
input[96..101]: taps 21..26
reference MAC before bias: -963
RTL captured tap-product sum: -963
mapping_match_for_output_0_0_0: true
```

R1h acc ownership truth after fix:

```text
artifact: tb/generated/resnet20_r1h_conv1_acc_ownership_truth.json
expected owner: output(oh=0, ow=0, oc=0) -> acc_buffer_addr 0
reference MAC before bias: -963
RTL requant read0 acc_data: -963
ownership_match_for_output_0_0_0: true
acc0 final collect source: cin=2, comp_win=0, acc_col=0, wr_addr=0, wr_data=-963
collect_bad_owner_count: 0
logical16 requant acc/q unknown: 0 / 0
```

The apparent late `fsm=21, wr_addr=0` event is not a collect overwrite:
`FSM_REQUANT_COMPUTE` is state 21, and the write is the legal internal requant
replacement for dense output byte0. The actual collect ownership defect was the
CP_DRAIN reassignment of `acc_partial_addr` from the drifting sequential
`acc_wr_ptr`, despite CP_FEED already deriving the authoritative
`window_index * output_channels` base. Conv collect now preserves that logical
base and blocks writes beyond `comp_total_wins`.

R1h byte3 ownership trace:

```text
artifact: tb/generated/resnet20_r1h_conv1_byte3_trace.json
logical output: index3 / (oh=0, ow=0, oc=3)
expected acc owner: acc_buffer[3]
requant input / q: 5434 / 0x18
pre-fix physical store: lane0-word byte12
post-fix physical store: dense packed lane3 / byte3
```

R1h conclusion:

```text
Package-faithful formal-address conv1 smoke runs through npu_top.
The address-0 contract gap is closed in the handoff package.
Full-size conv1 numerical compare exact-matches for all 16384 output bytes.
The output(0,0,0) byte0 path is now aligned through window placement,
acc ownership, bias add, post-bias ReLU, requant, and store.
Progression: mismatch/unknown 12252/1 -> 11049/1 -> 0/0.
The byte3 failure was a physical byte-lane ownership error: full-shape dense
INT8 output was incorrectly forced through the compact/legacy lane0-word mode.
Task output byte count now selects dense packing versus explicit word layout.
The former unknown byte64 was logical q16; it disappeared after logical collect
ownership was restored and dense packing placed q16 at byte16.
R1g compact lane0-word exact-match remains unchanged.
Full ResNet-20 RTL execution remains incomplete.
```

### R2: Generalized Conv Valid Path

目标：

```text
1. 保留当前 legacy 5x5 valid Conv path。
2. 在 R1b foundation 上完成 generalized Conv 数值 datapath 验证。
3. 支持 1x1 valid stride1 的 directed golden。
4. 支持 3x3 valid/same stride1 的 directed golden。
5. 参数化 active_rows = 1 / 9 / 25。
```

必须同步修改：

```text
block_scheduler output shape
block_scheduler input rows
block_scheduler weight bytes per input channel
block input/output addr and byte count
wgt_load_reg indexing for kernel_size != 5
array_active_rows
```

验收：

```text
1. legacy 5x5 valid bit-exact。
2. 1x1 valid directed golden 通过。
3. 3x3 valid directed golden 通过。
4. output_c divisible / non-divisible by enabled cluster count 均通过。
5. single/dual/full/mask mode route/aggregate guard 通过。
```

### R3: Same Padding, Stride2, Projection Conv

目标：

```text
1. generalized Conv path 支持 same padding。
2. 支持 stride2。
3. 支持 1x1 stride2 projection Conv。
4. 支持 3x3 same stride1/stride2。
```

shape 规则：

```text
valid:
  out_h = floor((input_h - kernel_size) / stride) + 1
  out_w = floor((input_w - kernel_size) / stride) + 1

same:
  out_h = ceil(input_h / stride)
  out_w = ceil(input_w / stride)
```

same padding boundary：

```text
out-of-range input coordinate -> activation 0
```

验收：

```text
1. corner / edge / center directed tests 通过。
2. odd/even input dimensions 通过。
3. output addr / output bytes / store layout 对齐 golden。
4. 1x1 stride2 projection Conv 通过。
5. LeNet regression 通过。
```

### R4: INT32 Folded Bias

目标：

```text
1. 通过 array_sum_in 注入 INT32 bias。
2. bias index 按 global output channel 映射。
3. bias_en=0 时旧 Conv/FC bit-exact。
4. bias_en=1 时支持 Conv/FC。
```

multi-cluster 要求：

```text
1. enabled clusters 得到正确 bias slice。
2. disabled clusters 接收 0。
3. unused local columns 接收 0。
4. output_c 非整除 enabled cluster count 时映射正确。
5. mask mode 不重复或遗漏 bias。
```

验收：

```text
1. unique per-channel bias pattern 测试通过。
2. positive / negative / large bias 测试通过。
3. single/dual/full/mask 全通过。
4. LeNet regression 通过。
```

### R5: ADD and ADD Postproc

目标：

```text
1. 实现 task_type=ADD。
2. input_addr/input_bytes 作为 src0。
3. SRC1_ADDR/SRC1_BYTES 作为 src1。
4. output_addr/output_bytes 作为 dst。
5. 支持 INT32 same-scale ADD。
6. 支持 ADD only / ADD+ReLU / ADD+Requant / ADD+ReLU+Requant。
```

buffer policy：

```text
act_buffer: ADD src0
wgt_buffer: ADD src1
```

该复用必须在文档和测试中明确，不允许把 wgt_buffer reuse 解释为 weight semantics。

task_checker 必须检查：

```text
src0 addr aligned and in bounds
src1 addr aligned and in bounds
output addr aligned and in bounds
src0_bytes != 0
src1_bytes != 0
src0_bytes == src1_bytes
output_bytes matches postproc dtype
requant params valid if add_requant_en=1
```

验收：

```text
1. positive + positive。
2. positive + negative。
3. negative + negative。
4. ADD + ReLU。
5. ADD + Requant。
6. ADD + ReLU + Requant。
7. src byte mismatch rejection。
8. misaligned address rejection。
9. partial final AXI beat WSTRB 正确。
10. LeNet regression 通过。
```

### R6: GAP

目标：

```text
1. 实现 task_type=GAP。
2. 支持 INT32 HWC input -> INT32 output[C]。
3. 使用 reciprocal/shift 做 fixed-point average。
4. 不添加 general divider。
```

task_checker 必须检查：

```text
input_h >= 1
input_w >= 1
input_c >= 1
output_c == input_c
input_bytes matches H * W * C * 4
output_bytes matches C * 4
reciprocal/shift valid
addresses aligned and in bounds
```

验收：

```text
1. hand-check small tensors 通过。
2. C=1 通过。
3. C not multiple of 8 通过。
4. 8x8xC ResNet head case 通过。
5. reciprocal/shift rounding 与 software golden 一致。
6. partial final AXI beat WSTRB 正确。
7. LeNet regression 通过。
```

### R7: ResNet Block Tests

BasicBlock sequence：

```text
Conv3x3 same stride1
Bias
ReLU
Requant
Conv3x3 same stride1
Bias
ADD
ReLU
Requant
```

DownsampleBlock sequence：

```text
main path:
  Conv3x3 same stride2
  Bias

shortcut path:
  Conv1x1 stride2 projection
  Bias

merge:
  ADD
  ReLU
  Requant
```

验收：

```text
1. BasicBlock output tensor/checksum matches software golden。
2. DownsampleBlock output tensor/checksum matches software golden。
3. 1 MB shared memory reuse map followed exactly。
4. LeNet regression 通过。
```

### R8: ResNet-20 Small Batch

目标：

```text
1. 执行 CIFAR ResNet-20 task sequence。
2. 小批量 count = 8 or 16。
3. 逐样本输出 predicted / expected / status。
4. 保存 logits/checksum evidence。
```

验收：

```text
1. RTL small batch matches software predicted_class。
2. 关键 tensor checksum 与 software golden 对齐，或失败时能定位 first mismatch layer。
3. summary.json / per_sample.csv 生成。
4. current LeNet/MNIST official baseline 仍通过。
```

---

## 5. Test Plan

每个 RTL milestone 必跑：

```text
1. 新增功能的 directed unit/golden tests。
2. 相关 task_checker invalid-case tests。
3. LeNet top/subsystem regression。
4. store packing / WSTRB guard when output path is touched。
5. route/aggregate guard when Conv/bias/cluster path is touched。
```

Conv 必测：

```text
1x1 / 3x3 / 5x5
valid / same
stride1 / stride2
output_c divisible by enabled cluster count
output_c not divisible by enabled cluster count
single / dual / full / mask
```

ADD 必测：

```text
positive / negative mixed values
ADD postproc combinations
src byte mismatch rejection
misalignment rejection
partial final AXI beat
```

GAP 必测：

```text
small hand-check tensors
8x8xC ResNet head case
C not multiple of AXI word group
reciprocal/shift golden consistency
```

Final acceptance：

```text
1. R0.5 software golden accuracy >= 80%。
2. ResNet-20 RTL small batch 8/16 matches golden。
3. Existing LeNet/MNIST baseline remains passing。
4. AXI-Lite/AXI4 project subset behavior not regressed。
5. shared memory / 64B alignment / store packing contracts unchanged。
```

---

## 6. Implementation Rules for Coding Agents

Coding agents must follow these rules:

```text
1. 一次只执行一个 milestone。
2. 当前 milestone 未 review 关闭前，不进入下一个 milestone。
3. 不允许把 legacy/debug tests 当作正式 ResNet evidence。
4. 不允许在 R0.5 未完成时实现 ResNet numerical datapath。
5. 不允许顺手重写 npu_top 主 FSM，除非该 milestone 明确要求并重新评审。
6. 不允许引入 dual AXI read master。
7. 不允许引入 inter-cluster reduce。
8. 不允许改变 LeNet address map 或 requant semantics。
```

每轮结果必须报告：

```text
current milestone
modified files
interface changes
tests added/changed
commands run
results
LeNet regression status
contract impact
residual risk
```

---

## 7. Assumptions

本 RTL 计划基于以下前提：

```text
1. RESNET20_SOFTWARE_GOLDEN_PLAN.md 已完成 R0.5。
2. ResNet-20 task sequence、weights/bias memh、fixture 和 memory reuse map 已冻结。
3. ADD same-scale 由 software golden 保证。
4. Shared memory 不扩容。
5. 所有 base address 继续 64B 对齐。
6. RTL v1 不做 dual-branch ADD rescale。
7. RTL v1 不做 per-channel quantization。
8. Full CIFAR-10 RTL full-set 不作为首轮 RTL acceptance。
```

如果以上前提变化，必须先更新本计划和 software golden 计划，再启动对应 RTL 修改。
