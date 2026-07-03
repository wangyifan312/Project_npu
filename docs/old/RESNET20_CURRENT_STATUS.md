# ResNet-20 Current Status

本文档记录 CIFAR-10 ResNet-20 迁移线的当前状态。它只描述 ResNet-20 新工作，不改变当前 LeNet/MNIST、HB、AXI、NPU RTL Workstream A/B/C 的既有基线。

## 1. 当前阶段

当前状态：

- planning complete
- `R0.5 Software Golden and Fixture Flow` implementation started
- synthetic smoke skeleton complete
- real CIFAR-10 float train/eval/fixture sanity complete
- float candidate short pilot complete
- float candidate checkpoint available
- fixed-point golden design/skeleton started
- F1 BN folding metadata implemented
- F2 activation calibration / quantization scale skeleton implemented
- F3 verified requant search skeleton / residual ADD alignment plan implemented
- F4 actual fixed-point operator smoke implemented
- F5 staged fixed-point eval hardening implemented for 256/1000 sample subsets
- F5 full CIFAR-10 fixed-point eval complete
- software fixed-point accuracy gate passed
- F6a RTL-lock rounding / saturation / requant review complete with open items
- F6b RTL handoff contract closure complete
- F6c/F6g INT8/INT32/requant export package generated and validated
- F6d/F6e task sequence + `1 MB` memory map generated and validated
- R1-0 RTL R1 readiness review complete
- R1a task/register/capability foundation complete
- R1b generalized Conv foundation complete
- R1c folded bias + requant integration complete
- generalized Conv numerical datapath verification not complete
- R1d ADD directed foundation complete
- R1e GAP8x8 directed foundation complete
- R1f task-sequence RTL smoke foundation complete
- R1g compact residual-slice fixed-point compare exact-match complete
- R1h package-faithful `input.image -> conv1` full-shape compare exact-match complete
- ResNet end-to-end RTL not started

当前新增的是 software golden / fixture flow 的工程骨架、float baseline flow、fixed-point golden 设计、F4 小样本 operator smoke、F5 staged eval hardening、full `10000` fixed-point eval、F6a RTL-lock 数值契约 review、F6b handoff contract closure、F6c/F6g INT8/INT32/requant export package、F6d/F6e task sequence + `1 MB` memory map、R1-0 RTL R1 readiness review、R1a task/register/capability foundation、R1b generalized Conv foundation、R1c folded bias + requant integration、R1d residual ADD directed foundation、R1e GAP8x8 directed foundation、R1f task-sequence RTL smoke foundation、R1g compact fixed-point compare，以及 R1h package-faithful small fixture compare。当前 `>=80%` software fixed-point accuracy gate 已通过；现有 LeNet/NPU requant 原语与 ResNet software helper 在 round/shift/clamp 上匹配。F6a 的 folded bias / GAP / residual ADD open items 已在 F6b 中关闭为 `closed_for_export` handoff contract。R1d/R1e 已接入 directed ADD/GAP task/datapath foundation；R1f/R1g 覆盖 `layer1.0.conv1 -> layer1.0.conv2 -> layer1.0.add` compact residual slice的 exact value compare。R1h 已关闭 package `input.image` 非零地址契约，并使 full-shape `input.image -> conv1` package-faithful compare 达到 `16384` bytes exact match；这仍不是 full ResNet-20 task sequence closure。ResNet end-to-end RTL 仍未实现。

## 2. 固定架构决策

- 目标网络：CIFAR-10 ResNet v1 / ResNet-20
- downsample shortcut：`1x1 stride2 projection Conv`
- bias：INT32 folded bias
- residual ADD：INT32 same-scale ADD
- ADD postproc：ADD / ADD+ReLU / ADD+Requant / ADD+ReLU+Requant
- GAP：INT8 8x8 input feature map -> INT32 per-channel sum -> divide-by-64 -> optional requant -> INT8 output vector
- FC head：FC10
- software fixed-point accuracy gate：`>=80%`
- shared memory contract：`1 MB = 32768 x 256-bit beat`
- base address alignment：`64B`

## 3. 当前已新增入口

训练 smoke：

```bash
python3 datasets/scripts/train_resnet20_cifar10.py \
  --output datasets/cifar10/models/resnet20_smoke.pt \
  --smoke \
  --synthetic-count 8 \
  --epochs 1
```

eval smoke：

```bash
python3 datasets/scripts/eval_resnet20_checkpoint.py \
  --checkpoint datasets/cifar10/models/resnet20_smoke.pt \
  --smoke \
  --synthetic-count 8 \
  --output results/resnet20_smoke_eval.json
```

fixture smoke：

```bash
python3 datasets/scripts/generate_resnet20_fixture.py \
  --checkpoint datasets/cifar10/models/resnet20_smoke.pt \
  --output-dir datasets/cifar10/resnet20_smoke_fixture \
  --smoke \
  --synthetic-count 4
```

这些 smoke 入口使用 deterministic synthetic CIFAR-like data，不下载 CIFAR-10，不代表真实 accuracy。

真实 CIFAR-10 float training sanity：

```bash
python3 datasets/scripts/train_resnet20_cifar10.py \
  --output datasets/cifar10/models/resnet20_cifar10_sanity.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --count 32 \
  --epochs 1 \
  --batch-size 8 \
  --device cpu
```

真实 CIFAR-10 float eval sanity：

```bash
python3 datasets/scripts/eval_resnet20_checkpoint.py \
  --checkpoint datasets/cifar10/models/resnet20_cifar10_sanity.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --split test \
  --count 32 \
  --output results/resnet20_cifar10_sanity_eval.json \
  --device cpu
```

真实 CIFAR-10 float fixture sanity：

```bash
python3 datasets/scripts/generate_resnet20_fixture.py \
  --checkpoint datasets/cifar10/models/resnet20_cifar10_sanity.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --split test \
  --count 4 \
  --output-dir datasets/cifar10/resnet20_cifar10_sanity_fixture \
  --device cpu
```

这些真实 CIFAR-10 命令仍然只是 float software flow sanity，不是 fixed-point golden，不代表 `>=80%` fixed-point gate 已完成。

float baseline candidate training 示例：

```bash
python3 datasets/scripts/train_resnet20_cifar10.py \
  --output datasets/cifar10/models/resnet20_float_candidate.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --epochs 20 \
  --batch-size 128 \
  --lr 0.1 \
  --momentum 0.9 \
  --weight-decay 0.0001 \
  --augment \
  --eval-count 10000 \
  --save-best \
  --metrics-output results/resnet20_float_candidate_train.json \
  --device cpu
```

说明：

- 该命令是较长 float baseline training 入口，本轮不要求跑完。
- 输出 accuracy 仍是 float accuracy，不能写成 fixed-point accuracy。
- 只有后续 fixed-point golden 完成并达到 `>=80%`，才允许进入 ResNet RTL numerical implementation。

float candidate short pilot 结果：

```text
checkpoint: datasets/cifar10/models/resnet20_float_pilot_short.pt
train subset: 5000 samples
eval subset: 1000 test samples
epochs: 3
train accuracy: 1454/5000 = 29.08%
eval accuracy: 293/1000 = 29.3%
```

该结果只证明当前 float training/eval/checkpoint/fixture flow 能支撑 candidate 训练实验；它不是 fixed-point accuracy gate。

staged float candidate training runner：

```bash
python3 datasets/scripts/run_resnet20_float_training_stages.py \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --out-dir results/resnet20_float_staged_smoke \
  --stages 2 \
  --epochs-per-stage 1 \
  --train-count 256 \
  --eval-count 128 \
  --batch-size 32 \
  --device cpu
```

默认 staged runner 适合 CPU-only 环境做可恢复训练探针：

- 每个 stage 输出独立 checkpoint、train metrics JSON、eval JSON。
- 后续 stage 使用前一 stage checkpoint `--resume` 继续加载模型权重。
- optimizer state 当前不 resume，checkpoint metadata 明确记录 `optimizer_state_resume=false`。
- 总 summary 写入 `out-dir/summary.json`，包含 best checkpoint、best eval accuracy、所有 stage metrics 路径。
- staged runner 仍是 float software flow；不实现 fixed-point golden，不启动 RTL R1。

当前 float candidate checkpoint：

```text
datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt
```

Linux CPU full-test float recheck：

```text
results/resnet20_float_candidate_mps_continue_stage2_eval.json
8648/10000 = 86.48%
```

该结果是 float accuracy，不是 fixed-point accuracy gate。

fixed-point golden design / skeleton 入口：

```bash
python3 datasets/scripts/inspect_resnet20_checkpoint.py \
  --checkpoint datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt \
  --output results/resnet20_float_candidate_checkpoint_inspect.json

python3 datasets/scripts/export_resnet20_fixed_point_skeleton.py \
  --checkpoint datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt \
  --float-eval results/resnet20_float_candidate_mps_continue_stage2_eval.json \
  --output-dir datasets/cifar10/resnet20_fixed_point_skeleton
```

配套设计文档：

```text
docs/RESNET20_FIXED_POINT_GOLDEN_PLAN.md
```

当前 fixed-point skeleton 只冻结接口、层级结构、planned numerical contract 和 TODO 状态：

- 不执行 actual fixed-point inference。
- 不生成 INT8 weights memh。
- 不生成 INT32 folded bias memh。
- 不生成 final task sequence。
- 不生成 `1 MB` memory reuse map。
- 不启动 RTL R1。

F1 BN folding metadata / folded-float equivalence check：

```bash
python3 datasets/scripts/export_resnet20_bn_folded.py \
  --checkpoint datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --split test \
  --count 256 \
  --batch-size 128 \
  --device cpu \
  --output-dir datasets/cifar10/resnet20_bn_folded
```

该入口：

- 识别并记录所有 Conv+BN pair 的 source tensor、shape、min/max/mean。
- 对 initial conv、每个 block conv1/conv2、projection shortcut 执行 folded-float 参数计算。
- 记录 FC source weight/bias，但不做 BN folding。
- 构建 folded-float inference path，并与原 checkpoint float model 做 logits/accuracy 等价检查。
- 只输出 JSON metadata，不生成 memh、task sequence 或 memory reuse map。

F1 完成不等同于 fixed-point golden 完成；F1 本身不执行 actual fixed-point inference，full fixed-point golden 和 `>=80%` fixed-point accuracy gate 仍未完成。

当前 F1 运行结果：

```text
Conv+BN pairs: 21
Projection shortcut folds: 2
Checked samples: 256
max_abs_logit_diff: 7.62939453125e-06
mean_abs_logit_diff: 1.2664153473451733e-06
original_accuracy: 0.859375
folded_accuracy: 0.859375
accuracy_match: true
```

该结果证明 BN folding 公式和 checkpoint tensor 映射在 folded-float 路径下成立；它仍不是 fixed-point inference。

F2 activation calibration / quantization scale skeleton：

```bash
python3 datasets/scripts/calibrate_resnet20_quantization.py \
  --checkpoint datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --split train \
  --count 512 \
  --batch-size 128 \
  --device cpu \
  --output-dir datasets/cifar10/resnet20_quant_calibration
```

该入口：

- 复用 F1 folded-float path。
- 收集 input、Conv/ReLU、residual ADD、GAP、FC logits 等关键 tensor 的 activation range。
- 生成 per-tensor symmetric signed INT8 activation scale skeleton，公式为 `scale=max_abs/127`。
- 生成 folded weight 的 per-tensor symmetric INT8 scale skeleton。
- 生成 conv/fc accumulator scale 和 residual ADD same-scale alignment plan。
- 对 scale 不一致的 residual ADD 明确标记 `pending_same_scale_alignment`，不强行声称已解决。
- 只输出 JSON metadata，不生成 memh、task sequence 或 memory reuse map。

F2 完成仍不等同于 fixed-point golden 完成；F2 本身不执行 actual fixed-point inference，full fixed-point golden 和 `>=80%` fixed-point accuracy gate 仍未完成。

F3 verified requant search / residual ADD same-scale alignment plan：

```bash
python3 datasets/scripts/search_resnet20_requant_plan.py \
  --quant-params datasets/cifar10/resnet20_quant_calibration/quant_params.json \
  --requant-plan datasets/cifar10/resnet20_quant_calibration/requant_plan.json \
  --folded-layers datasets/cifar10/resnet20_bn_folded/folded_layers.json \
  --output-dir datasets/cifar10/resnet20_requant_plan
```

该入口：

- 读取 F2 activation/weight scale 和 requant plan。
- 校验 conv/fc 项数量为 `22`，residual ADD 项数量为 `9`。
- 为每个 Conv/FC 计算 `real_multiplier = accumulator_scale / output_scale`。
- 在有限 shift 范围 `0..31` 内搜索 int32 `multiplier_int` / `shift` 近似。
- 对 9 个 residual ADD 生成 planned same-scale alignment：
  - main branch -> `target_add_scale`
  - shortcut branch -> `target_add_scale`
- 输出数学误差统计。

F3 的 residual ADD same-scale 只是 `planned_alignment_not_end_to_end_verified`。它不是完整 fixed-point ADD，不是 full fixed-point inference，也不是 fixed-point accuracy gate。

当前 F3 运行结果：

```text
Conv/FC requant count: 22
Residual ADD alignment count: 9
F2 same-scale pending count: 9
Invalid scale count: 0
max_relative_error: 1.0778770604353305e-07
mean_relative_error: 2.8291384236134632e-08
residual_same_scale_status: planned_alignment_not_end_to_end_verified
```

F4 actual fixed-point operator smoke：

```bash
python3 datasets/scripts/run_resnet20_fixed_point_smoke.py \
  --checkpoint datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --split test \
  --count 64 \
  --batch-size 16 \
  --device cpu \
  --output-dir datasets/cifar10/resnet20_fixed_point_smoke
```

该入口：

- 使用 F1 folded Conv+BN 参数。
- 使用 F2 per-tensor INT8 activation / weight scale。
- 使用 F3 Conv/FC multiplier/shift 和 residual ADD branch same-scale alignment。
- 执行 software INT8/INT32 Conv、residual ADD、GAP、FC operator smoke。
- 输出 `summary.json`、`predictions.json`、`layer_checksums.json`、`fixed_point_config.json`。
- 只生成 software debug JSON，不生成 memh、task sequence 或 memory reuse map。

当前 F4 运行结果：

```text
Checked samples: 64
fixed_point_correct: 53/64
fixed_point_accuracy: 82.8125%
float_reference_correct: 54/64
float_reference_accuracy: 84.375%
rounding_status: software_reference_round_half_away_from_zero_not_rtl_locked
residual_add_planned_alignment_executed: true
```

该结果只是 small-subset operator smoke。它不是 full CIFAR-10 fixed-point eval，也不能作为 `>=80%` fixed-point accuracy gate 通过证据。

F5 staged fixed-point eval hardening：

```bash
python3 datasets/scripts/run_resnet20_fixed_point_smoke.py \
  --checkpoint datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --split test \
  --count 256 \
  --batch-size 16 \
  --device cpu \
  --output-dir datasets/cifar10/resnet20_fixed_point_eval_256

python3 datasets/scripts/run_resnet20_fixed_point_smoke.py \
  --checkpoint datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --split test \
  --count 1000 \
  --batch-size 16 \
  --device cpu \
  --output-dir datasets/cifar10/resnet20_fixed_point_eval_1000
```

该入口在 F4 backend 基础上新增：

- `mismatch_summary.json`
- `saturation_summary.json`
- runtime / samples-per-second 统计
- `fixed_float_prediction_match/mismatch` 统计
- fixed-only / float-only / both-wrong 统计

当前 F5 staged 运行结果：

```text
256 samples:
  fixed_point_correct: 218/256 = 85.15625%
  float_reference_correct: 220/256 = 85.9375%
  fixed_float_prediction_mismatch: 4/256
  runtime: 1.662568996893242 sec
  samples_per_sec: 153.9785720041539
  max_saturation_risk_layer: layer2.0.add.relu

1000 samples:
  fixed_point_correct: 870/1000 = 87.0%
  float_reference_correct: 871/1000 = 87.1%
  fixed_float_prediction_mismatch: 21/1000
  runtime: 6.101249165134504 sec
  samples_per_sec: 163.90086241920503
  max_saturation_risk_layer: gap.output
```

这两个 staged eval 结果说明当前 fixed-point software path 在 256/1000 样本上健康，适合后续考虑后台 full `10000` eval。但它们仍不是 full CIFAR-10 fixed-point gate；只有 `count=10000` 的 full test eval 达到 `>=80%` 才能声明 gate 通过。

F5 full CIFAR-10 fixed-point eval gate run：

```bash
python3 datasets/scripts/run_resnet20_fixed_point_smoke.py \
  --checkpoint datasets/cifar10/models/resnet20_float_candidate_mps_continue_stage2.pt \
  --cifar10-tar datasets/cifar10/cifar-10-python.tar.gz \
  --split test \
  --count 10000 \
  --batch-size 16 \
  --device cpu \
  --output-dir datasets/cifar10/resnet20_fixed_point_eval_10000
```

当前 full `10000` 运行结果：

```text
fixed_point_correct: 8639/10000 = 86.39%
float_reference_correct: 8648/10000 = 86.48%
fixed_float_prediction_mismatch: 213/10000
fixed_only_correct_count: 85
float_only_correct_count: 94
both_wrong_count: 1267
runtime: 62.92080072220415 sec
samples_per_sec: 158.92995456542394
max_saturation_risk_layer: fc.logits
max_saturation_total_clamp_ratio: 0.00017
fixed_point_accuracy_gate.status: passed
```

该结果是当前 ResNet-20 software fixed-point full-test accuracy gate 证据。它仍不表示 RTL R1 已启动，也不表示已经生成 RTL handoff 资产。

F6a RTL-lock rounding / saturation / requant review：

```bash
python3 datasets/scripts/verify_resnet20_rtl_quant_contract.py \
  --fixed-eval datasets/cifar10/resnet20_fixed_point_eval_10000/summary.json \
  --conv-fc-requant datasets/cifar10/resnet20_requant_plan/conv_fc_requant.json \
  --residual-add-alignment datasets/cifar10/resnet20_requant_plan/residual_add_alignment.json \
  --output-dir datasets/cifar10/resnet20_rtl_lock_review
```

当前 F6a 输出：

```text
docs/RESNET20_RTL_LOCK_REVIEW.md
datasets/cifar10/resnet20_rtl_lock_review/summary.json
datasets/cifar10/resnet20_rtl_lock_review/rounding_vectors.json
datasets/cifar10/resnet20_rtl_lock_review/requant_vectors.json
```

当前 F6a 结论：

```text
rtl_lock_status: reviewed_with_open_items
rounding_contract: match existing requant_i32_to_i8 primitive
saturation_contract: match signed INT8 clamp [-128,127]
requant_contract: match existing multiplier/shift primitive for positive multipliers and shift 0..31
```

未发现现有 LeNet/NPU requant 原语 mismatch；但 folded bias INT32 export rounding、GAP reciprocal/shift、residual ADD datapath handoff 仍需要 RTL owner 决策。因此当前不应把 F6a 写成 `reviewed_match`，也不应直接进入 RTL R1。

F6b RTL handoff contract closure：

```bash
python3 datasets/scripts/export_resnet20_handoff_contract.py \
  --fixed-eval datasets/cifar10/resnet20_fixed_point_eval_10000/summary.json \
  --rtl-lock-review datasets/cifar10/resnet20_rtl_lock_review/summary.json \
  --conv-fc-requant datasets/cifar10/resnet20_requant_plan/conv_fc_requant.json \
  --residual-add-alignment datasets/cifar10/resnet20_requant_plan/residual_add_alignment.json \
  --quant-params datasets/cifar10/resnet20_quant_calibration/quant_params.json \
  --output-dir datasets/cifar10/resnet20_handoff_contract
```

当前 F6b 输出：

```text
docs/RESNET20_RTL_HANDOFF_CONTRACT.md
datasets/cifar10/resnet20_handoff_contract/summary.json
datasets/cifar10/resnet20_handoff_contract/numerical_contract.json
datasets/cifar10/resnet20_handoff_contract/op_contract.json
datasets/cifar10/resnet20_handoff_contract/export_manifest_schema.json
```

当前 F6b 结论：

```text
handoff_contract_status: reviewed_contract_closed_for_export
closed_items: 3
waiver_items: 0
unresolved_items: 0
next_allowed_stage: export_int8_int32_assets
```

F6c/F6g INT8/INT32/requant export package：

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

python3 datasets/scripts/validate_resnet20_export_package.py \
  --package-dir datasets/cifar10/resnet20_export_package \
  --output datasets/cifar10/resnet20_export_package/validation_report.json
```

当前 F6c/F6g 输出：

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

当前 F6c/F6g 结论：

```text
weight_file_count: 22
bias_file_count: 22
conv_fc_requant_count: 22
residual_add_alignment_count: 9
gap_requant_status: searched
validation_status: pass
validation_error_count: 0
task_sequence_generated: false at F6c/F6g boundary
one_mb_memory_reuse_map_generated: false at F6c/F6g boundary
rtl_r1_started: false
```

F6c/F6g 生成的是 weights/bias/requant export package 输入资产；final task sequence 和 `1 MB` memory map 在后续 F6d/F6e 中生成。

F6d/F6e task sequence + `1 MB` memory map：

```bash
python3 datasets/scripts/generate_resnet20_task_memory_map.py \
  --package-dir datasets/cifar10/resnet20_export_package \
  --output-task datasets/cifar10/resnet20_export_package/task_sequence.json \
  --output-memory datasets/cifar10/resnet20_export_package/memory_map.json

python3 datasets/scripts/validate_resnet20_task_memory_map.py \
  --package-dir datasets/cifar10/resnet20_export_package \
  --task-sequence datasets/cifar10/resnet20_export_package/task_sequence.json \
  --memory-map datasets/cifar10/resnet20_export_package/memory_map.json \
  --output datasets/cifar10/resnet20_export_package/task_memory_validation.json
```

当前 F6d/F6e 输出：

```text
docs/RESNET20_TASK_MEMORY_MAP.md
datasets/cifar10/resnet20_export_package/task_sequence.json
datasets/cifar10/resnet20_export_package/memory_map.json
datasets/cifar10/resnet20_export_package/task_memory_validation.json
datasets/cifar10/resnet20_export_package/manifest.json
datasets/cifar10/resnet20_export_package/summary.json
datasets/cifar10/resnet20_export_package/validation_report.json
```

当前 F6d/F6e 结论：

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
task_sequence_generated: true
one_mb_memory_reuse_map_generated: true
rtl_r1_started: false
```

F6d/F6e 使 ResNet-20 handoff package 达到 RTL R1 review 输入完整状态。它不表示 RTL R1 已实现。

R1-0 RTL R1 readiness review：

```text
docs/RESNET20_RTL_R1_READINESS_REVIEW.md
datasets/cifar10/resnet20_export_package/rtl_r1_readiness.json
```

当前 R1-0 结论：

```text
rtl_r1_ready_for_review: true
rtl_r1_ready_for_implementation: true for R1a/R1 foundation coding
blockers: none
recommended_next_slice: R1a descriptor/task decode extension skeleton
rtl_modified: false
testbench_modified: false
rtl_r1_started: false
```

R1-0 只是 readiness review 和 implementation scope。R1a foundation 已完成：

- `task_type` 全链路扩到至少 3 bit，旧编码 `0..3` 保持不变。
- 追加 VERSION/CAPABILITY/CONV_CFG/BIAS/SRC1/ADD/GAP/POSTPROC 寄存器，地址 `0x90..0xB4`。
- R1a 当时 CAPABILITY 仅置位 legacy Conv/FC/Pool/Requant/runtime cluster config；generalized Conv full datapath、ADD、GAP 当时仍为 unsupported。
- R1a 当时 ADD/GAP task_type 请求由 `task_checker` 确定性拒绝，error code `0x0A`。
- 新寄存器 reset/default 保持 LeNet-compatible，当前不被 datapath 消费。

R1a 未实现：

- generalized Conv numerical datapath verification
- ADD datapath
- GAP datapath
- ResNet end-to-end RTL
- task queue / descriptor FIFO / shadow config

R1b generalized Conv foundation 已完成：

- `CONV_CFG` 开始被 Conv task checker、block scheduler、conv frontend 和 `npu_top` 的窗口/性能控制消费。
- `CONV_CFG[1:0]` 为 kernel selector：`0=5x5`、`1=1x1`、`2=3x3`、`3=reserved/invalid`。
- `CONV_CFG[2]` 为 stride selector：`0=stride1`、`1=stride2`。
- `CONV_CFG[3]` 为 padding selector：`0=valid`、`1=same`。
- `CONV_CFG[4]` 为 folded-bias enable reserved bit；R1b 中置位会被 `task_checker` 拒绝，folded bias 留到 R1c。
- `CONV_CFG[5]` 为 projection hint/readback bit；R1b 中只作为 1x1 projection control hint 保留，不改变 datapath。

R1b Conv task checker 接受：

- `5x5 valid stride1`：legacy 默认，`CONV_CFG=0x00`
- `3x3 same stride1`：`CONV_CFG=0x0A`
- `3x3 same stride2`：`CONV_CFG=0x0E`
- `1x1 valid stride1`：`CONV_CFG=0x01`
- `1x1 valid stride2`：`CONV_CFG=0x05`

R1b 非法组合由 `task_checker` 确定性拒绝，Conv 参数错误码为 `0x07`。ADD/GAP 在 R1b 当时仍为 unsupported，错误码为 `0x0A`。

R1b output shape 规则：

- valid：`floor((input - kernel) / stride) + 1`
- same stride1：`output = input`
- same stride2：`output = ceil(input / 2)`

R1b 当前边界：

- control / checker / scheduler / frontend 已接受上述 generalized Conv 模式。
- legacy `5x5 valid stride1` datapath 仍保持既有路径。
- 1x1 / 3x3 / stride2 / same padding 的 ResNet 数值 datapath 尚未完成端到端验证，CAPABILITY 不声明为 fully supported。
- ADD / GAP / ResNet end-to-end 在 R1b 当时仍未实现。

R1c folded bias + requant integration 已完成：

- `CONV_CFG[4]` 现在是 Conv/FC folded-bias enable。reset default 为 `0`，因此 legacy no-bias Conv/FC 行为保持不变。
- R1a 的 `BIAS_ADDR` / `BIAS_BYTES` 现在被 `npu_ctrl` 在 task start 时锁存，并进入 `task_checker` / `npu_top` control path。
- `task_checker` 只在 bias enable 时检查 bias payload：`BIAS_ADDR != 0`、`64B` 对齐、shared memory 范围合法、`BIAS_BYTES != 0`、word-aligned、且至少覆盖 `output_c * 4` bytes。缺失或非法 payload deterministic reject，error code `0x0C`。
- Conv/FC bias numeric contract 为 signed INT32、每 output channel/neuron 一个 bias。bias add domain 是 accumulator INT32 domain。
- R1c 后处理顺序固定为 `accumulator INT32 -> optional + folded bias INT32 -> requant_i32_to_i8 -> INT8`。`requant_i32_to_i8` 原语未改动。
- Conv path 和 FC path 都已接入 optional bias + requant 后处理基础；bias disabled 时继续走 legacy store/output path。
- CAPABILITY readback 更新为 `0x0000_7821`，其中 bit5 表示 folded-bias postprocess support。3x3/1x1/same/stride2/projection/ADD/GAP 不因此声明 fully supported。

R1c 当前边界：

- R1c 没有完成 ResNet task sequence runner。
- R1c 没有实现 residual ADD datapath。
- R1c 没有实现 GAP datapath。
- generalized Conv 1x1/3x3/stride2/same 数值端到端闭环仍留给后续 R1 slice。

R1d residual ADD task/datapath foundation 已完成：

- `task_type=4` 从 R1d 起是受支持的 ADD task；`task_type=5` GAP 在 R1d 当时仍为 unsupported，已在 R1e 升级为 supported directed GAP task。
- ADD 使用 `input_addr/input_bytes` 作为 src0，使用 `SRC1_ADDR/SRC1_BYTES` 作为 src1，使用 `output_addr/output_bytes` 作为 dst。
- 新增 append-only ADD requant registers：
  - `0xB8 ADD_SRC0_MULT`，reset `0`
  - `0xBC ADD_SRC0_SHIFT`，reset `0`
  - `0xC0 ADD_SRC1_MULT`，reset `0`
  - `0xC4 ADD_SRC1_SHIFT`，reset `0`
  - `0xC8 ADD_OUT_MULT`，reset `0`
  - `0xCC ADD_OUT_SHIFT`，reset `0`
- `ADD_CFG[2]` 或 `POSTPROC_CFG[0]` 使能 ADD ReLU；`ADD_CFG[3]` 或 `POSTPROC_CFG[1]` 使能 ADD post-requant。
- ADD datapath 复用 `act_buffer` 作为 src0、`wgt_buffer` 作为 src1、`acc_buffer` 作为 output staging；这只是 buffer 复用，不改变 weight semantics。
- ADD 数值顺序为 `src0 INT8/src1 INT8 -> optional branch pre-align through requant_i32_to_i8 -> INT32 add -> optional ReLU -> optional post-requant -> INT8 output`。
- ADD payload validation 检查 src0/src1/output 非零、`64B` 对齐、1MB shared-memory 范围、src0/src1/output bytes 匹配，以及 requant multiplier/shift 合法性。非法 ADD payload deterministic reject，当前使用 error code `0x0B`。
- `0x0B` 的统一语义为 numeric/scale parameter validation error，覆盖 legacy Requant 参数错误和 ADD branch/post requant 参数错误。ADD post-requant enabled 时，reset 后 multiplier 为 `0` 会被确定性拒绝；必须显式写入非零 multiplier 后才可通过。
- R1d CAPABILITY readback 为 `0x0000_7B61`，表示 legacy Conv/FC/Pool/Requant、folded bias、runtime cluster config 以及 ADD / ADD+ReLU / ADD+Requant foundation 可用；GAP capability 已在 R1e 更新。

R1d 当前边界：

- R1d 只完成 directed unit-level ADD foundation，不表示 ResNet residual block/end-to-end 已跑通。
- R1d 没有改变 `requant_i32_to_i8` 语义。
- R1d 没有改变 LeNet legacy Conv/FC/Pool/Requant contract。

R1e GAP8x8 task/datapath foundation 已完成：

- `task_type=5` 现在是受支持的 GAP task；legacy `task_type=0..4` 行为保持。
- GAP 复用 R1a `GAP_CFG` 和 `POSTPROC_CFG`，没有新增 append-only register。
- `GAP_CFG[1:0]=0` 表示 INT8 input，`GAP_CFG[3:2]=0` 表示 INT8 output，`GAP_CFG[25:20]=6` 表示 8x8 divide-by-64 fixed shift；其余 GAP_CFG bits 当前必须为 0。
- `POSTPROC_CFG[1]` 可选启用 GAP post-requant，使用现有 `requant_multiplier/requant_shift`；启用时 multiplier 必须非零，shift 必须 `0..31`。
- GAP payload validation 检查 input/output 非零、`64B` 对齐、1MB shared-memory 范围、`input_h=input_w=8`、`output_c=input_c`、`input_bytes=64*input_c`、`output_bytes=input_c`、`weight_bytes=0` 和 GAP numeric config 合法性。非法 GAP payload deterministic reject，error code `0x0B`。
- GAP datapath 复用 `act_buffer` 作为 input staging、`acc_buffer` 作为 output staging，并复用现有 store path；这不改变 shared-memory/store/AXI contract。
- GAP 数值顺序为 `INT8 feature map -> INT32 per-channel spatial sum -> signed round-half-away divide-by-64 -> optional requant_i32_to_i8 -> INT8 output`。
- CAPABILITY readback 更新为 `0x0000_7BE1`，表示 GAP8x8 directed foundation 可用；仍不声明 ResNet end-to-end 或 generalized Conv full numerical closure。

R1e 当前边界：

- R1e 只完成 directed unit-level GAP foundation，不表示 ResNet task sequence/end-to-end 已跑通。
- R1e 没有改变 `requant_i32_to_i8` 语义。
- R1e 没有改变 LeNet legacy Conv/FC/Pool/Requant contract。

## 4. 当前输出资产

R0.5 smoke fixture 输出：

- `manifest.json`
- `summary.json`
- `weights/summary.json`
- `sample_xxxxx_label_y/input.memh`
- `sample_xxxxx_label_y/label.txt`
- `sample_xxxxx_label_y/meta.json`

`manifest.json` entry 同时包含：

- `label`
- `predicted_class`

当前 manifest schema 为：

- `manifest_schema = top_level_list_v1`
- `manifest.json` 顶层直接是 sample entry list
- `arch` / `checkpoint` / `dataset_source` / `fixed_point_status` 等全局 metadata 放在 `summary.json`

当前 smoke / float fixture `input.memh` 采用：

- `input_layout = HWC`
- `input_dtype = INT8`
- `input_quantization = uint8_minus_128_smoke_or_float_placeholder`

该输入 packing 只是 R0.5 placeholder，不是最终 fixed-point CIFAR input contract。

其中 `predicted_class` 来自当前 software float forward，仅用于 smoke 链路占位。

## 5. 当前未完成项

以下事项仍未完成，不能写成已通过：

- full RTL R1 implementation closure
- generalized Conv numerical datapath verification
- package-faithful small fixture fixed-point exact match
- ResNet full block/end-to-end RTL closure

当前 `>=80%` software fixed-point accuracy gate 已通过，F6b handoff contract 已关闭，F6c/F6g export package 已生成并验证，F6d/F6e task sequence 和 `1 MB` memory map 已生成并验证，R1-0 readiness review 已完成，R1a/R1b foundation 已完成，R1c folded bias + requant integration 已完成，R1d residual ADD foundation 已完成，R1e GAP8x8 foundation 已完成，R1f task-sequence RTL smoke foundation 已完成，R1g compact fixed-point compare 已 exact-match，R1h package-faithful `input.image -> conv1` smoke 已跑通但仍存在 mismatch/unknown。当前允许继续进入 generalized Conv numerical closure / package-faithful small fixture exact-match debug；仍不表示 ResNet RTL end-to-end 已实现。

## 6. RTL 边界

当前没有启动：

- ResNet full residual block/end-to-end RTL closure

R1f task-sequence RTL smoke 当前采用 package-derived contiguous residual slice：

```text
layer1.0.conv1 -> layer1.0.conv2 -> layer1.0.add
```

该 smoke 使用 `datasets/cifar10/resnet20_export_package/task_sequence.json`、`memory_map.json` 以及部分 weight/bias/requant metadata 生成 testbench stimulus。当前增强版实例化 `npu_top`，覆盖 `task_type=0/4` 的顺序寄存器编程、busy/done/error 流程、package memory-map 派生地址消费、AXI read/write beat 观测、Conv/ADD datapath 状态触达，以及 X-aware masked checksum / unknown-byte count 观测。它不是完整 32-task ResNet-20 RTL 执行，也不是 small fixture fixed-point compare。

R1h 已关闭 handoff package 的 `input.image` address-contract gap：正式 `memory_map.json` 现在保留 byte address `0`，并从 `64` 开始分配 `input.image`。现有 `task_checker` 的 null-address reject 规则保持不变，不为 ResNet task0 增加 RTL 特例，因此不削弱 LeNet/legacy 防护。R1f/R1g compact slice 仍保留为快速 directed 证据，但不再是处理 `input.image` 正式地址的唯一手段。

R1g fixed-point compare 沿用同一个 contiguous residual slice 和 compact alias/remap：

```text
layer1.0.conv1 -> layer1.0.conv2 -> layer1.0.add
```

R1g reference 来自 `datasets/cifar10/resnet20_export_package/` 的真实 weight/bias/requant/residual alignment metadata，并按同一 compact fixture 生成 expected bytes。本轮已冻结 compact layout contract：

```text
Conv input: dense HWC INT8 byte stream at task input address
Conv output: current RTL physical store, one INT8 output in byte lane 0 of each 32-bit word
ADD input: physical byte stream exactly as stored in memory
ADD output: dense INT8 byte stream packed four values per 32-bit word by ADD datapath
```

当前比较结果：

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
status: match
first mismatch: none
```

Conv1 byte0 trace is now aligned between reference and RTL:

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

当前判断：上一轮已确认并修复 compact fixture 下 Conv bias/requant/store 的 element-count/byte-count 解释问题，unknown 已从 69 降为 0；随后 R1g TB payload 改为从 export package memh 真实加载 Conv weight/bias。compact reference 已从 lane0-word input 解释改为 RTL `conv_frontend` 实际消费的 dense HWC byte stream，使 conv1 byte0 完全对齐，并先将 total mismatch 从 `27` 降到 `5`。Conv tail writeback fix 进一步将 total mismatch 从 `5` 降到 `1`。本轮 ADD final packed-word writeback fix 将 total mismatch 从 `1` 降到 `0`。

R1g Conv tail final-element writeback 已修复。根因是 internal Conv/FC bias-requant 的最后一个 `rq_acc_wr_en_r` 脉冲在离开 `FSM_REQUANT_COMPUTE` 后被 `acc_wr_en` 状态门控屏蔽，导致最后一个 logical output element 未覆盖 raw accumulator。修复后增加 `FSM_REQUANT_DRAIN` 并允许该 drain 周期继续承认 internal requant write phase，使 final requant result 在 STORE 读取 acc_buffer 前稳定提交。

Conv tail 修复前后：

```text
before:
  layer1.0.conv1 last expected/actual word: 09 00 00 00 / 15 fd ff ff
  layer1.0.conv2 last expected/actual word: 0d 00 00 00 / 00 00 00 00
after:
  layer1.0.conv1 last expected/actual word: 09 00 00 00 / 09 00 00 00
  layer1.0.conv2 last expected/actual word: 0d 00 00 00 / 0d 00 00 00
```

ADD byte32 final mismatch 已修复。根因与 Conv tail 类似：ADD 的最后一个 packed word 由 registered `add_acc_wr_en_r` 写回，但 FSM 同周期离开 `FSM_ADD_COMPUTE` 进入 STORE，原 `acc_wr_en` 只在 `FSM_ADD_COMPUTE` 接受 ADD 写，因此最后一个 packed word 未覆盖 `acc_buffer` 中旧的 Conv2 word。修复后增加 `FSM_ADD_DRAIN` 并允许该 drain 周期继续承认 ADD write phase，使 final ADD packed word 在 STORE 读取前稳定提交。

ADD byte32 trace：

```text
src0_i8: 13
src1_i8: -111
src0_aligned: 13
src1_aligned: -80
add_raw: -67
add_after_relu: 0
post_requant_output_i8: 0
stored word bytes: 00 00 00 00
```

因此 compact layout、Conv tail final-element writeback 和 ADD final packed-word writeback 已在当前 compact residual slice 上收敛。当前 `layer1.0.conv1 -> layer1.0.conv2 -> layer1.0.add` 3-task compact slice 达到 exact match；这仍不是 full ResNet-20 closure，也不是 full-shape package-faithful execution。

R1h package-faithful small fixture compare 新增 `input.image -> conv1` 单 task smoke：

```text
input.image base_addr: 64
conv1.relu output_addr: 3136
input bytes: 3072
output/compare bytes: 16384
source: datasets/cifar10/resnet20_export_package/task_sequence.json + memory_map.json + weights/bias/requant metadata
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

R1h focused trace for `conv1 output(oh=0, ow=0, oc=0)` after fix:

```text
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
expected semantics: top row and left column are zero padding
expected semantics: input[0..5] map to taps 12..17
expected semantics: input[96..101] map to taps 21..26
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
acc0 write events: cin0/win0/col0 -> cin1/win0/col0 -> cin2/win0/col0 -> internal requant write
collect_bad_owner_count: 0
logical16 requant acc/q unknown: 0 / 0
```

`fsm=21 / wr_addr=0 / data=0` 不是 unrelated collect write；`FSM_REQUANT_COMPUTE=21`，该事件是 dense output byte0 的合法 internal requant 覆盖。真正的 global collect owner bug 位于 CP_DRAIN：CP_FEED 已计算 `window_index * output_c`，随后却被顺序 `acc_wr_ptr` 覆盖，导致从后续 window 开始出现 expected addr16 / actual addr17 的漂移。当前 Conv collect 保留 logical-window base，并拒绝超出 `comp_total_wins` 的写。

R1h byte3 ownership trace：

```text
artifact: tb/generated/resnet20_r1h_conv1_byte3_trace.json
logical output: index3 / (oh=0, ow=0, oc=3)
expected acc owner: acc_buffer[3]
requant input / q: 5434 / 0x18
pre-fix physical store: lane0-word byte12
post-fix physical store: dense packed lane3 / byte3
```

Fix summary:

```text
window placement: conv_frontend now tracks line-buffer base row for full-shape same padding
compact preservation: test-only compact alias path keeps R1g compact exact-match behavior
acc ownership: Conv collect now derives acc write base from logical window and suppresses wrap alias writes
byte-lane ownership: task output byte count selects legacy lane0-word or dense INT8 packed requant store
postprocess ordering: bias-enabled Conv/FC now applies optional ReLU after bias add and before existing requant primitive
requant_i32_to_i8 semantics: unchanged
```

当前判断：R1h full-shape package-faithful `input.image -> conv1` compare 已从原始 `12252 mismatch / 1 unknown`，经过 byte0 修复阶段的 `11049 / 1`，最终收敛到 `16384 bytes / mismatch 0 / unknown 0`。R1g compact residual exact-match 同时保持。该结论只覆盖单个 full-shape conv1 task，不是完整 32-task ResNet-20 RTL closure；地址契约、LeNet contract 和 `requant_i32_to_i8` 语义均未改变。

ResNet RTL 后续必须以 `docs/RESNET20_SOFTWARE_GOLDEN_PLAN.md` 和 `docs/RESNET20_RTL_EXTENSION_PLAN.md` 为输入，不能由 RTL testbench 隐式猜测网络结构、task sequence 或 memory reuse map。
