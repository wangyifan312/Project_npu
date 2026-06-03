# Performance Summary

本文件整理 `Project_npu` 当前可用于赛题答辩的正式性能结论。

强制区分三类口径：

- 理论值
- compute-core / cluster-level 测得结果
- SoC `top`-level 测得结果

不得混写。

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

---

## 4. 当前可用于答辩的严格结论

可以直接成立的结论：

1. `6-cluster / 1536 PE / 0.6144 TOPS @ 200MHz` 的理论硬件目标已在文档、RTL hierarchy 和正式 Conv 主路径中统一
2. Conv / FC 已从 `npu_top` 正式接入 `cluster_scheduler / compute_core_6cluster / output_arbiter`
3. `top` 层已经补到一组真实 `dual-cluster` Conv 证据，能给出 `cluster_cfg / cycles / mac / utilization / 功能结果`
4. `top` 层完整 LeNet 已通过真实权重样本闭环，并能输出分层性能日志

当前不能过度表述的结论：

1. 不能说 `top` 层完整 LeNet 已完成 `dual/full` 模式性能覆盖
2. 不能把 compute-core / cluster-level 的模式测试结果直接当作 `top` 层网络级性能结果
