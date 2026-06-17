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

### R1: Register and Task-Type Foundation

目标：

```text
1. task_type 全链路扩到至少 3 bit。
2. 添加 VERSION/CAPABILITY 和新 config registers。
3. 新寄存器 reset/default 保持 LeNet-compatible。
4. ADD/GAP 在 datapath 未实现前必须被 task_checker 受控拒绝，或 CAPABILITY 明确标为 unsupported。
```

验收：

```text
1. 旧 LeNet testbench 不写新寄存器仍通过。
2. 新寄存器 read/write/reset 测试通过。
3. 旧 task_type 0/1/2/3 readback 和行为不变。
4. invalid unsupported task 能给出确定 error code。
```

### R2: Generalized Conv Valid Path

目标：

```text
1. 保留当前 legacy 5x5 valid Conv path。
2. 新增 generalized Conv path。
3. 支持 1x1 valid stride1。
4. 支持 3x3 valid stride1。
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
