# Current Project Status

本文档是 `Project_npu` 当前状态的统一入口。它用于回答“现在已经完成什么、哪些证据可引用、哪些事项仍未完成或不应夸大”。

更细的规格、契约和执行清单仍以对应专题文档为准；本文档只做状态收口，不替代底层 spec。

---

## 1. 当前主线状态

### HB 256-bit data-plane

当前高带宽数据面主线已收口：

- `HB1` 完成：256-bit 数据面功能闭环恢复，`top` 单样本、top8、top16 在当前正式 expected 口径下通过。
- `HB2` 按当前边界完成：top16/top32/subsystem8 performance summary 非零且线性自洽。
- shared memory 正式组织固定为 `1 MB = 32768 x 256-bit beat`。
- CPU 访问模式固定为 `32-bit AXI-Lite`。
- NPU DMA 访问模式固定为 `256-bit AXI4 INCR burst`。

引用边界：

- top-level LeNet performance replay 当前仍主要是 single-cluster 网络级口径。
- multi-cluster 证据来自 top non-single-cluster correctness、util counter、compute-core/cluster-mode 运行级覆盖，不等同于完整 LeNet dual/full performance full-set。

### AXI compliance

AXI compliance 已完成到当前项目支持边界：

- `AXI-1` 完成：文档与协议支持范围冻结。
- `AXI-2` 完成：AXI-Lite 控制面规范化。
- `AXI-3` 完成：256-bit AXI4 INCR burst 数据面规范化。
- `AXI-4` 完成：协议级、功能级、性能级证据补齐。

当前可准确表述为：

- 控制面：标准化 `AXI-Lite` 项目子集。
- 数据面：标准化 `256-bit AXI4 INCR burst` 项目子集。

当前不可表述为：

- 完整通用 AXI4 IP。
- 完整通用 AXI-Lite IP。
- 支持 multi-ID / multi-outstanding / out-of-order / interleaving 的商用通用 AXI 子系统。

### Delivery follow-up W1/W2/W3

当前交付补强已推进到：

- `W1` 完成：top-level LeNet non-single-cluster 网络级证据已补齐。
  - `dual-cluster top1` PASS
  - `dual-cluster top8` PASS
  - optional `full-cluster top1` PASS
- `W2` 完成：中等规模回归稳定。
  - `top64`: `64/64 PASS`
  - `subsystem64`: `64/64 PASS`
- `W3` 完成，可关闭：full-set evaluation 采用 `software full-set + RTL representative chunk evidence` 口径收口。

统一口径：

- `W1/W2/W3` 已完成并可关闭。

W3 正式证据：

- software full-set 主证据：`results/mnist_lenet_soc6_requant_candidate_final_eval.json`
- software full-set 结果：`9885/10000 = 98.85%`
- RTL subsystem representative evidence：`results/w3_subsystem_full_10000_candidate_final_chunked/merged/`
- RTL 正式 merged 样本窗口：`3000/10000`
- RTL `summary.json` 口径：`2944/3000 = 98.1333%`
- 停止时 write-out 观测值：`3000/3057 = 98.1354%`，其中 partial chunk 不计入正式 merged。

当前 W4/W5/W6 口径：

- `W4/W5/W6` 当前降级为后续增强项。
- `W4/W5/W6` 不作为正在执行的正式工单。
- 如需继续推进，必须重新显式立项并确认资源/目标/验收范围。

---

## 2. NPU RTL 整改状态

统一口径：

- NPU RTL `Workstream A/B/C` 已完成。

### Workstream A

状态：完成。

已收口结论：

- multi-cluster route / aggregate correctness 已收口。
- runtime bottleneck evidence 已增强。
- 当前 6-cluster 路径不是 inter-cluster reduce，而是：
  - activation broadcast
  - weight split
  - routed global-column OR merge

证据边界：

- route / aggregate correctness 可按 Workstream A 范围关闭。
- runtime bottleneck evidence 已增强，但不能表述为 full LeNet-wide performance attribution complete。

### Workstream B

状态：完成。

已收口结论：

- shared memory contract 已收口。
- store-path correctness 已验证。
- shared memory 固定为 `1 MB = 32768 x 256-bit beat`。
- NPU task base address contract 当前继续维持 `64B` 对齐。
- `acc_buffer -> DMA writer` 写回 packing 固定为 `32-bit word -> 256-bit AXI beat`。
- last-beat `WSTRB` 由实际 byte count 决定。

当前不可表述为：

- 地址契约已放宽到 `32B`。
- store layout 可自由重排。
- output layout 可在不更新脚本/文档/回归资产的情况下修改。

### Workstream C

状态：完成。

已收口结论：

- runtime `CLUSTER_MODE / CLUSTER_MASK` 已支持 AXI-Lite 配置。
- Verilog parameter 仍作为 reset default。
- 当前仍是单任务寄存器触发模型。

runtime cluster config 不等同于 queue / descriptor / shadow-config 架构。

---

## 3. Full-cluster first-pass optimization

first-pass full-cluster 优化已达到 `top32 + subsystem64 stronger regression stable`：

- `top32` PASS
- `subsystem64` PASS
- correctness guard/probe 继续通过

已观察到的优化方向：

- weight-side ping-pong preload 有效。
- `CIN_LOAD_WGT` 与 `LOAD_ARRAY` 有明显下降。
- `COLLECT / STORE` 未明显恶化。

当前边界：

- 这不是第二轮结构优化。
- 不引入 inter-cluster reduce。
- 不引入双 AXI read master。
- 不重写 `npu_top` 主 FSM。
- 不改变 Workstream B 的 shared memory / store-path / `64B` contract。

---

## 4. 当前正式可引用证据

### Accuracy / functional evidence

- `top` 单样本 / top8 / top16 / top32 已作为当前正式小批量与中等规模 replay 证据。
- `subsystem8` / `subsystem64` 已作为 subsystem 交叉验证证据。
- W1 提供 top-level non-single-cluster 网络级 correctness 证据。
- W3 提供 software full-set 主证据和 RTL subsystem representative chunk evidence。

### Performance evidence

- `top16` / `top32` performance replay 非零且自洽。
- `subsystem8` performance replay 非零且自洽。
- multi-cluster util / compute-core / route evidence 已有运行级覆盖。
- first-pass full-cluster 优化已有 top32 + subsystem64 stronger regression 支撑。

### Protocol evidence

- AXI-Lite 协议级测试通过。
- AXI4 INCR burst 协议级测试通过。
- top/subsystem/performance replay 未因 AXI 标准化回退。

---

## 5. 已降级或未完成事项

- 完整 RTL `10000/10000` full-set 因仿真成本过高，降级为后续增强项，不作为当前 W3 关闭阻塞项。
- top full-set 当前不作为 W3 硬性完成条件。
- full LeNet-wide stage attribution 尚未完成；当前只有 stronger runtime evidence。
- 完整 top-level dual/full-cluster LeNet performance full-set 尚未完成。
- coverage flow 尚未完成，降级为后续增强项。
- FPGA / synthesis delivery material 尚未完成，降级为后续增强项。
- final delivery hardening 尚未作为当前执行工单启动，降级为后续增强项。

---

## 6. 当前明确不做的事项

- 不把当前 AXI 子集表述成完整通用 AXI4 / AXI-Lite IP。
- 不直接引入 inter-cluster reduce。
- 不直接改成双 AXI read master。
- 不直接重写 `npu_top` 主 FSM。
- 不放宽 `64B` 地址对齐到 `32B`。
- 不改变 LeNet 地址图。
- 不改变 requant 算法语义。
- 不改变 `acc_buffer -> DMA writer` packing 或 last-beat `WSTRB` contract。
- 不把 runtime cluster config 解释为 queue / descriptor / shadow config 架构。

---

## 7. 推荐下一步

后续增强项的建议顺序：

1. `W4` coverage flow
2. `W5` FPGA / synthesis delivery material
3. `W6` final delivery hardening

当前不默认继续执行 W4/W5/W6。若项目重新启动交付增强，应按上述顺序重新立项，不应在普通文档或 RTL cleanup 中隐式推进。

NPU RTL 方向如需继续推进，推荐二选一：

- 第二轮性能优化评估：必须先定义性能目标、护栏、回归范围。
- 更高强度 runtime cluster mode 长回归：验证 AXI-Lite runtime config 在更长路径下稳定。

任何涉及地址对齐、store packing、output layout、控制模型的修改，都必须单独立项。

---

## 8. 仍保留的专题文档入口

- `docs/HB_256BIT_REFACTOR_SPEC.md` / `docs/HB_256BIT_EXECUTION_CHECKLIST.md`: HB 256-bit 数据面改造基线。
- `docs/AXI_COMPLIANCE_SPEC.md` / `docs/AXI_COMPLIANCE_EXECUTION_CHECKLIST.md`: AXI compliance 支持范围和执行证据。
- `docs/NEXT_TASK_WORKLIST.md`: W1-W6 工单定义；当前 W4-W6 已降级为后续增强项。
- `docs/NPU_RTL_TODO.md`: NPU RTL Workstream A/B/C 详细证据和 TODO 收口。
- `docs/FULL_CLUSTER_OPT_PLAN.md`: first-pass full-cluster 优化方案和护栏。
- `docs/DELIVERY_CHECKLIST.md`: 答辩/交付最小清单。
- `docs/PERFORMANCE_SUMMARY.md`: 性能证据分层和引用限制。
- `docs/MNIST_FULL_EVAL_PLAN.md`: full-set evaluation 策略和 W3 口径。
- `docs/REPO_REVIEW_2026Q2.md`: 仓库级 review 和整改背景。
