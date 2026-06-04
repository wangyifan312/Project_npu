# Performance Summary

本文件整理 `Project_npu` 当前可用于赛题答辩的正式性能结论。

强制区分三类口径：

- 理论值
- compute-core / cluster-level 测得结果
- SoC `top`-level 测得结果
- subsystem `npu_top + axi4_ram` 测得结果

不得混写。

## 0. 测试入口分层

当前性能证据必须按入口分层引用：

| 层级 | 入口 | 用途 | 引用限制 |
| --- | --- | --- | --- |
| 正式 SoC top | `tb/integration/tb_top_lenet.v`, `sim/run_top_lenet.sh` | top-level LeNet 正确性与 performance replay | 当前 LeNet replay 是 single-cluster 口径 |
| subsystem | `tb/integration/tb_lenet_network.v`, `sim/run_lenet_fixture.sh` | `npu_top + axi4_ram` 网络级交叉验证 | 不包含 CPU/shared_ram/interconnect top wrapper |
| cluster/unit | `tb/unit/tb_cluster_perf_modes.v`, `tb/unit/tb_hb2_cluster_util_counter.v` | multi-cluster compute/util 运行级覆盖 | 不等同于完整 LeNet dual/full 性能 replay |
| legacy/debug | 历史 `tb_task*`, `tb_npu_top`, 局部小阵列测试 | 定位与回归辅助 | 不作为正式功能或性能基线 |

当前 HB2 可引用结论：

- top16/top32：正式 top single-cluster LeNet performance replay
- subsystem8：subsystem single-cluster LeNet performance replay
- multi-cluster：unit/compute-core 运行级 coverage

当前不可引用结论：

- 不能宣称完整 top-level LeNet dual/full-cluster performance replay 已完成
- 不能用 legacy 小阵列测试推导正式 `16x16 x 6-cluster` 网络级性能

---

## 1. 理论峰值

固定硬件目标：

- `6-cluster` 动态可调脉动阵列
- 每个 cluster = `16x16 PE`
- 总计 `1536 PE`
- `200MHz`

理论峰值：

| 项目 | 数值 |
| --- | --- |
| 单 cluster PE 数 | `256` |
| 全阵列 PE 数 | `1536` |
| Full-cluster 理论峰值 | `0.6144 TOPS @ 200MHz` |

说明：

- 理论峰值按 `PE_count * 2 ops/cycle * 200MHz` 计算
- 这是硬件规模上限，不等于 `top` 层实测吞吐

---

## 2. Compute-Core / Cluster-Level 结果

来源：

- testbench: `tb/unit/tb_cluster_perf_modes.v`
- 命令：

```bash
iverilog -g2012 -o /tmp/tb_cluster_perf_modes_stage3.vvp \
  rtl/npu/array_top.v rtl/npu/cluster_16x16.v rtl/npu/cluster_scheduler.v \
  rtl/npu/compute_core_6cluster.v rtl/npu/mac_pe.v rtl/npu/mac_tile_4x4.v \
  tb/unit/tb_cluster_perf_modes.v && \
timeout 120s vvp /tmp/tb_cluster_perf_modes_stage3.vvp
```

结果：

| Mode | Requested Mask | Enabled Mask | Measured Cycles | Measured MAC / Launch | Measured Array Util | Enabled-Cluster Theoretical Peak |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| `single` | `111111` | `000001` | `35` | `256` | `0.028571` | `0.1024 TOPS` |
| `dual` | `111111` | `000011` | `35` | `512` | `0.028571` | `0.2048 TOPS` |
| `full` | `111111` | `111111` | `35` | `1536` | `0.028571` | `0.6144 TOPS` |
| `dynamic_mask` | `101011` | `101011` | `35` | `1024` | `0.028571` | `0.4096 TOPS` |

说明：

- 这里的 `Measured Cycles / MAC / Array Util` 来自 compute-core 微基准，不是完整网络工作负载
- 最后一列 `Enabled-Cluster Theoretical Peak` 反映当前启用 cluster 数对应的理论上限，用于证明模式缩放关系

---

## 3. SoC Top-Level 结果

### 3.1 Top-Level Conv Smoke：Single vs Dual

来源：

- `tb/integration/tb_top.v`
- `tb/integration/tb_top_cluster_modes.v`

命令：

```bash
iverilog -g2012 -o /tmp/tb_top_stage2_fix.vvp \
  rtl/soc/axi4_ram.v rtl/soc/shared_ram.v rtl/bus/axi_interconnect.v \
  rtl/npu/*.v rtl/cpu/picorv32/picorv32.v rtl/soc/top.v \
  tb/integration/tb_top.v && \
timeout 120s vvp /tmp/tb_top_stage2_fix.vvp
```

```bash
iverilog -g2012 -o /tmp/tb_top_cluster_modes_fix2.vvp \
  rtl/soc/axi4_ram.v rtl/soc/shared_ram.v rtl/bus/axi_interconnect.v \
  rtl/npu/*.v rtl/cpu/picorv32/picorv32.v rtl/soc/top.v \
  tb/integration/tb_top_cluster_modes.v && \
timeout 120s vvp /tmp/tb_top_cluster_modes_fix2.vvp
```

结果：

| Top-Level Case | cluster_cfg | Cycles | MAC Count | Array Util | Cluster Util | Functional Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `single-cluster conv smoke` | `0x00000001` | `110` | `25` | `0.3273` | `0.3273` | PASS, output=`50` |
| `dual-cluster conv smoke` | `0x00000043` | `110` | `25` | `0.3273` | `0.3273` | PASS, output=`50` |

说明：

- 这组结果属于 **SoC `top` 层真实 non-single-cluster 证据**
- P0-2 后，`top` 级 dual 模式 Conv 走 `cluster_scheduler -> compute_core_6cluster -> output_arbiter` 正式主路径，证明的是：
  - `top` 层寄存器链路 / shared memory / AXI-Lite / perf counter 在 non-single 配置下可运行
  - output arbiter 已在正式 Conv 路径上产生结果
  - 功能结果正确
- 这组结果 **不应表述为**：
  - `top` 层完整 LeNet 已完成 dual/full 吞吐映射
  - `top` 层已对所有 cluster mode 做完整网络级性能覆盖

### 3.2 Top-Level LeNet 分层性能

来源：

- `tb/integration/tb_top_lenet.v`
- 样本：`datasets/mnist/lenet_real_fixture/sample_00000_label_7`
- 命令：

```bash
SIMULATOR=vcs FIXTURE_DIR=datasets/mnist/lenet_real_fixture \
SAMPLE_NAME=sample_00000_label_7 TIMEOUT_SECS=600 \
bash sim/run_top_lenet.sh sample
```

功能结果：

- `TOP_RESULT sample=sample_00000_label_7 predicted=7 expected=7 status=PASS`

分层结果：

| Layer | cluster_cfg | Cycles | MAC Count | Array Util | Functional Result |
| --- | --- | ---: | ---: | ---: | --- |
| `Conv1` | `0x00000001` | `58606` | `288000` | `0.7273` | PASS |
| `Conv2` | `0x00000001` | `250576` | `1600000` | `0.6845` | PASS |
| `FC1` | `0x00000001` | `507751` | `400000` | `0.7878` | PASS |
| `FC2` | `0x00000001` | `6887` | `5000` | `0.7260` | PASS |

强制说明：

- 当前 `top` 级 LeNet Conv / FC 层来自正式 6-cluster 主路径；完整小批量真实样本闭环仍属于 P0-4 范围
- 因此这张表用于证明：
  - `top` 层完整 LeNet 地址图与真实权重闭环
  - `top` 层可读取正式性能寄存器
- 这张表 **不能** 被表述成 `top` 层 full-cluster LeNet 性能结论

### 3.3 HB2 256-bit Top16 Performance Replay

来源：

- testbench: `tb/integration/tb_top_lenet.v`
- script: `sim/run_top_lenet.sh`
- 结果目录：`results/hb2_top16_perf_replay`
- expected 口径：`datasets/mnist/lenet_real_manifest_100/manifest.json` 中的 `predicted_class`

命令：

```bash
SIMULATOR=vcs ACCURACY_ONLY=1 TIMEOUT_SECS=900 \
RUN_LABEL=hb2_top16_perf_replay \
RESULTS_DIR=results/hb2_top16_perf_replay \
FIXTURE_DIR=datasets/mnist/lenet_real_manifest_100 \
MANIFEST_PATH=datasets/mnist/lenet_real_manifest_100/manifest.json \
SAMPLE_ROOT_DIR=datasets/mnist/exports_full \
WEIGHTS_ROOT_DIR=datasets/mnist/lenet_real_manifest_100/weights \
INPUT_MEMH_NAME=packed_words.memh EXPECTED_FILE_NAME=label.txt \
EXPECTED_MANIFEST_FIELD=predicted_class COUNT=16 \
bash sim/run_top_lenet.sh batch
```

结果：

| Metric | Value |
| --- | ---: |
| samples | `16/16 PASS` |
| total_cycles | `15,604,224` |
| avg_cycles | `975,264` |
| total_mac | `36,688,000` |
| avg_mac | `2,293,000` |
| read_beats | `255,872` |
| write_beats | `39,936` |
| beat_bytes | `32` |
| read_bytes | `8,187,904` |
| write_bytes | `1,277,952` |
| read_active | `273,328` |
| write_active | `679,008` |
| read_bw_util | `0.936135` |
| write_bw_util | `0.058815` |
| array_active | `6,144,960` |
| array_stall | `994,304` |
| cluster_active | `6,144,960` |
| cluster_stall | `994,304` |
| array_util | `0.393801` |
| cluster_util | `0.393801` |

说明：

- `read_beats/write_beats` 使用 `256-bit` AXI beat 口径，`1 beat = 32 bytes`
- `read_bw_util/write_bw_util` 为 `beats / active_cycles`
- 当前 top-level LeNet 使用 `CLUSTER_MODE=single`，因此 `array_active` 与 `cluster_active` 数值一致是预期结果
- 该 replay 证明 256-bit 数据面下 top16 正确性与性能计数口径同时闭环

### 3.4 HB2 256-bit Subsystem8 Performance Replay

来源：

- testbench: `tb/integration/tb_lenet_network.v`
- script: `sim/run_lenet_fixture.sh`
- 结果目录：`results/hb2_subsystem8_perf_replay`

命令：

```bash
SIMULATOR=vcs ACCURACY_ONLY=1 TIMEOUT_SECS=900 \
RUN_LABEL=hb2_subsystem8_perf_replay \
RESULTS_DIR=results/hb2_subsystem8_perf_replay \
FIXTURE_DIR=datasets/mnist/lenet_real_fixture COUNT=8 \
bash sim/run_lenet_fixture.sh batch
```

结果：

| Metric | Value |
| --- | ---: |
| samples | `8/8 PASS` |
| total_cycles | `7,802,112` |
| avg_cycles | `975,264` |
| total_mac | `18,344,000` |
| avg_mac | `2,293,000` |
| read_beats | `127,936` |
| write_beats | `19,968` |
| beat_bytes | `32` |
| read_bytes | `4,093,952` |
| write_bytes | `638,976` |
| read_active | `136,664` |
| write_active | `339,504` |
| read_bw_util | `0.936135` |
| write_bw_util | `0.058815` |
| array_active | `3,072,480` |
| array_stall | `497,152` |
| cluster_active | `3,072,480` |
| cluster_stall | `497,152` |
| array_util | `0.393801` |
| cluster_util | `0.393801` |

说明：

- subsystem 入口直接实例化 `npu_top + axi4_ram`，用于和 SoC `top` 入口交叉验证性能口径
- 该入口的 hierarchical RAM preload/readback 已按 256-bit beat 组织修正为 `addr[19:5] / addr[4:2]`
- subsystem LeNet 仍为 single-cluster 配置，因此 `array_active == cluster_active` 是预期结果

### 3.5 HB2 Multi-Cluster Util Coverage

来源：

- `tb/unit/tb_hb2_cluster_util_counter.v`
- `tb/unit/tb_cluster_perf_modes.v`

命令：

```bash
iverilog -g2012 -I rtl/npu -o /tmp/tb_hb2_cluster_util_counter.vvp \
  rtl/npu/cluster_scheduler.v rtl/npu/perf_counter.v \
  tb/unit/tb_hb2_cluster_util_counter.v && \
vvp /tmp/tb_hb2_cluster_util_counter.vvp
```

```bash
iverilog -g2012 -I rtl/npu -o /tmp/tb_cluster_perf_modes.vvp \
  rtl/npu/cluster_scheduler.v rtl/npu/compute_core_6cluster.v \
  rtl/npu/cluster_16x16.v rtl/npu/array_top.v \
  rtl/npu/mac_tile_4x4.v rtl/npu/mac_pe.v \
  tb/unit/tb_cluster_perf_modes.v && \
timeout 60s vvp /tmp/tb_cluster_perf_modes.vvp
```

结果：

| Case | Enabled Mask | cluster_count | array_active | cluster_active | Status |
| --- | --- | ---: | ---: | ---: | --- |
| `single` | `000001` | `1` | `4` | `4` | PASS |
| `dual` | `000011` | `2` | `4` | `8` | PASS |
| `full` | `111111` | `6` | `4` | `24` | PASS |
| `masked_full` | `101011` | `4` | `4` | `16` | PASS |

说明：

- 该覆盖证明 perf counter 的 `cluster_active` 按 enabled cluster 数缩放，不会在 multi-cluster 下机械等于 `array_active`
- `tb_cluster_perf_modes` 同时证明 `cluster_scheduler + compute_core_6cluster` 在 single/dual/full/masked 模式下可运行
- 该覆盖属于 cluster/perf 运行级证据，不等同于 top-level LeNet multi-cluster 性能结论

### 3.6 HB2 256-bit Top32 Performance Replay

来源：

- testbench: `tb/integration/tb_top_lenet.v`
- script: `sim/run_top_lenet.sh`
- 结果目录：`results/hb2_top32_perf_replay`
- expected 口径：`datasets/mnist/lenet_real_manifest_100/manifest.json` 中的 `predicted_class`

命令：

```bash
SIMULATOR=vcs ACCURACY_ONLY=1 TIMEOUT_SECS=900 \
RUN_LABEL=hb2_top32_perf_replay \
RESULTS_DIR=results/hb2_top32_perf_replay \
FIXTURE_DIR=datasets/mnist/lenet_real_manifest_100 \
MANIFEST_PATH=datasets/mnist/lenet_real_manifest_100/manifest.json \
SAMPLE_ROOT_DIR=datasets/mnist/exports_full \
WEIGHTS_ROOT_DIR=datasets/mnist/lenet_real_manifest_100/weights \
INPUT_MEMH_NAME=packed_words.memh EXPECTED_FILE_NAME=label.txt \
EXPECTED_MANIFEST_FIELD=predicted_class COUNT=32 \
bash sim/run_top_lenet.sh batch
```

结果：

| Metric | Value |
| --- | ---: |
| samples | `32/32 PASS` |
| total_cycles | `31,208,448` |
| avg_cycles | `975,264` |
| total_mac | `73,376,000` |
| avg_mac | `2,293,000` |
| read_beats | `511,744` |
| write_beats | `79,872` |
| beat_bytes | `32` |
| read_bytes | `16,375,808` |
| write_bytes | `2,555,904` |
| read_active | `546,656` |
| write_active | `1,358,016` |
| read_bw_util | `0.936135` |
| write_bw_util | `0.058815` |
| array_active | `12,289,920` |
| array_stall | `1,988,608` |
| cluster_active | `12,289,920` |
| cluster_stall | `1,988,608` |
| array_util | `0.393801` |
| cluster_util | `0.393801` |

说明：

- top32 与 top16/subsystem8 的 per-sample 指标线性一致
- `read_beats/write_beats` 均为 256-bit beat 口径，`beat_bytes=32`
- 当前 top-level LeNet 仍为 single-cluster replay，因此 `array_active == cluster_active` 是预期结果

---

## 4. 当前可用于答辩的严格结论

可以直接成立的结论：

1. `6-cluster / 1536 PE / 0.6144 TOPS @ 200MHz` 的理论硬件目标已在文档、RTL hierarchy 和正式 Conv 主路径中统一
2. Conv / FC 已从 `npu_top` 正式接入 `cluster_scheduler / compute_core_6cluster / output_arbiter`
3. `top` 层已经补到一组真实 `dual-cluster` Conv 证据，能给出 `cluster_cfg / cycles / mac / utilization / 功能结果`
4. `top` 层完整 LeNet 已通过真实权重样本闭环，并能输出分层性能日志
5. HB2 256-bit 口径下，top32 与 subsystem8 均可输出非零且线性自洽的 read/write beat、bandwidth utilization、array/cluster utilization summary
6. multi-cluster util counter 覆盖证明 `cluster_active` 在 dual/full/masked 模式下按 enabled cluster 数缩放

当前不能过度表述的结论：

1. 不能说 `top` 层完整 LeNet 已完成 `dual/full` 模式性能覆盖
2. 不能把 compute-core / cluster-level 的模式测试结果直接当作 `top` 层网络级性能结果
