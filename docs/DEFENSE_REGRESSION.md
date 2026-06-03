# Defense Regression Entry Points

本文件冻结当前赛题答辩使用的回归入口。

原则：

- 每条命令都给出用途
- 每条命令都给出验证层级
- 不混淆 subsystem 与 `top`
- 不混淆 deterministic 与 real-weight

---

## 1. Deterministic Quick Regression

用途：

- 最快的 deterministic LeNet 网络级 smoke/regression
- 用于答辩前快速确认 deterministic fixture、层级 golden 和基础网络闭环未回退

验证层级：

- `npu_top + axi4_ram` subsystem

命令：

```bash
SIMULATOR=vcs FIXTURE_DIR=datasets/mnist/lenet_fixture \
SAMPLE_NAME=sample_00000_label_7 TIMEOUT_SECS=600 \
bash sim/run_lenet_fixture.sh sample
```

期望关键信号：

- `LeNet network PASSED`
- 最终 `pred=9 exp=9`

---

## 2. Real-Weight Subsystem Regression

用途：

- 用真实训练权重 + 真实 MNIST 样本验证 `npu_top` 层完整 LeNet
- 用于证明不是只有 deterministic fixture 路径可跑

验证层级：

- `npu_top + axi4_ram` subsystem

命令：

```bash
SIMULATOR=vcs FIXTURE_DIR=datasets/mnist/lenet_real_fixture \
TIMEOUT_SECS=600 bash sim/run_lenet_fixture.sh all
```

期望关键信号：

- 每个样本输出 `pred / exp`
- 最终 `8/8 PASS`

---

## 3. Real-Weight Top Regression

用途：

- 用真实训练权重 + 真实 MNIST 样本验证 `top` 层 shared memory / AXI-Lite / NPU 编排 / 最终分类
- 是当前赛题答辩最关键的 `top` 级证据链

验证层级：

- SoC `top`

命令：

```bash
SIMULATOR=vcs FIXTURE_DIR=datasets/mnist/lenet_real_fixture \
TIMEOUT_SECS=600 bash sim/run_top_lenet.sh all
```

期望关键信号：

- 每个样本输出 `TOP_RESULT sample=... predicted=... expected=... status=PASS`
- 最终 `TOP_SUMMARY pass=8 total=8 status=8/8`

---

## 4. Perf Mode Regression

用途：

- 固定 compute-core / cluster-level 模式覆盖回归
- 用于答辩时展示 `single / dual / full / dynamic mask` 的模式缩放证据

验证层级：

- compute-core / cluster-level

命令：

```bash
bash sim/run_sim.sh tb_cluster_perf
```

期望关键信号：

- `PERF case=single`
- `PERF case=dual`
- `PERF case=full`
- `PERF case=dynamic_mask`

---

## 5. Top-Level Non-Single-Cluster Evidence

用途：

- 固定 `top` 层 dual-cluster compatibility smoke
- 用于答辩时补充 `cluster_cfg / cycles / mac / utilization / 功能结果`

验证层级：

- SoC `top`

命令：

```bash
bash sim/run_sim.sh tb_top_cluster_modes
```

期望关键信号：

- `TOP_CLUSTER_RESULT mode=dual`
- `cluster_cfg=0x00000043`
- `status=PASS`

---

## 6. 口径限制

这些入口允许成立的说法：

1. deterministic / real-weight / top-level / perf-mode 入口已经冻结
2. `top` 层 real-weight 多样本回归可直接复现
3. `top` 层 non-single-cluster 已有独立证据入口

这些入口不允许被过度表述为：

1. `top` 层完整 LeNet 已完成 dual/full 模式网络级性能覆盖
2. compute-core 模式回归等同于 SoC `top` 层完整模式覆盖

---

## 7. Accuracy-Only Full-Eval Entry

用途：

- 绕开 subsystem 默认 perf-heavy testbench 路径
- 用于完整测试集 accuracy 统计，而不是答辩 perf 证据

验证层级：

- `npu_top + axi4_ram` subsystem

命令：

```bash
SIMULATOR=vcs ACCURACY_ONLY=1 \
FIXTURE_DIR=datasets/mnist/lenet_real_manifest_100 \
MANIFEST_PATH=datasets/mnist/lenet_real_manifest_100/manifest.json \
SAMPLE_ROOT_DIR=datasets/mnist/exports_full \
WEIGHTS_ROOT_DIR=datasets/mnist/lenet_real_manifest_100/weights \
INPUT_MEMH_NAME=packed_words.memh EXPECTED_FILE_NAME=label.txt \
COUNT=100 RESULTS_DIR=results/mnist_full_subsystem_100_accuracy_only \
bash sim/run_lenet_fixture.sh batch
```

当前正式结果：

- `correct=37`
- `total=100`
- `accuracy=0.37`
- `avg_cycles=858370`
- `avg_mac=2293000`

口径限制：

- 这是 accuracy-only full-eval 入口，不是 perf 证据入口
- 该模式下 `read/write beats` 与 utilization 默认不采集
