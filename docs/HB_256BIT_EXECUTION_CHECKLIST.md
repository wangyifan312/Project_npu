# HB 256-bit Execution Checklist

本文档是 `HB_256BIT_REFACTOR_SPEC.md` 的执行清单版本。用途是把 `256-bit` 高带宽改造拆成可执行阶段，供后续 coding agent 逐项完成、逐项验收。

## 0. Closure 状态

截至 HB closure hardening，当前状态为：

| 阶段 | 状态 | 已确认验收证据 |
| --- | --- | --- |
| `HB1-A` | 完成 | `shared_ram/axi4_ram/interconnect/DMA` 256-bit smoke 与 CPU/NPU 同址语义通过 |
| `HB1-B` | 完成 | `npu_buffer/read_path/feeder` 256-bit beat 接入与模块级 smoke 通过 |
| `HB1-C` | 完成 | `top` 单样本、top8、top16 在 `predicted_class` 口径下恢复 |
| `HB2` | 按当前边界完成 | top16/top32/subsystem8 performance summary 非零且线性自洽；multi-cluster util 有运行级覆盖 |

后续不得再把本清单理解为“HB1/HB2 主体仍待开发”。若继续工作，应以 cleanup、文档固化、交付材料补强为主。

当前边界说明：

- top-level LeNet performance replay 仍是 `single-cluster` 口径
- multi-cluster 证据是 util counter 与 compute-core/cluster-mode 覆盖，不是完整 LeNet dual/full replay
- `accuracy-only` replay 在当前脚本中仍保留 perf reads，除非显式设置 `SKIP_PERF_READS=1`

## 1. 使用规则

执行要求：

1. 严格按阶段顺序推进：
   - `HB1-A`
   - `HB1-B`
   - `HB1-C`
   - `HB2`
2. 不允许跳阶段。
3. 每完成一个阶段，必须先完成该阶段验收，再进入下一阶段。
4. 若某阶段失败，不允许靠后续阶段顺带修掉。
5. 所有汇报必须明确写：
   - 当前阶段
   - 修改文件
   - 新增/修改测试
   - 运行命令
   - 运行结果
   - 是否达到该阶段完成标准
   - 残留风险

## 2. 阶段总览

| 阶段 | 目标 | 允许范围 | 不允许范围 |
| --- | --- | --- | --- |
| `HB1-A` | 先收 shared memory + DMA 的 `256-bit` 语义 | memory / bus / DMA | 不急着恢复 LeNet 全链路 |
| `HB1-B` | 把片内 buffer / feeder 接到 `256-bit` 正式数据面 | buffer / read path / feeder / npu_top 局部适配 | 不改高层 FSM 语义 |
| `HB1-C` | 恢复网络级正确性 | top/subsystem 正式链路 | 不做性能结论 |
| `HB2` | 带宽与性能闭环 | perf counter / performance docs / replay | 不把 accuracy-only 当性能证据 |

## 3. HB1-A：Memory / Bus / DMA 256-bit 化

### 3.1 阶段目标

先完成：

- `shared_ram` 真正变成 `256-bit` 物理存储
- `axi4_ram` 真正支持 `256-bit AXI4 burst`
- `axi_interconnect` DMA 数据面位宽切到 `256-bit`
- `dma_axi_reader` / `dma_axi_writer` 真正按 `256-bit beat` 工作
- CPU / NPU 对 shared memory 的同址语义一致

这个阶段只解决：

- 地址语义
- lane 语义
- beat 语义
- DMA 宽总线语义

不要求先恢复 LeNet 全链路。

### 3.2 必须修改的文件

- `rtl/soc/shared_ram.v`
- `rtl/soc/axi4_ram.v`
- `rtl/bus/axi_interconnect.v`
- `rtl/npu/dma_axi_reader.v`
- `rtl/npu/dma_axi_writer.v`
- 如需要，`rtl/soc/top.v` 的数据面位宽集成

### 3.3 必须完成的实现项

#### shared_ram

- [ ] 物理 `ram[]` 宽度改为 `256-bit`
- [ ] 深度改为 `32768`
- [ ] CPU `32-bit` 读逻辑改为 beat 内 lane extract
- [ ] CPU `32-bit` 写逻辑改为 beat 内 word merge
- [ ] NPU 读逻辑改为整 beat 返回
- [ ] NPU 写逻辑改为 `32-bit wstrb`
- [ ] CPU/NPU 共用同一份 `ram[]`

#### axi4_ram

- [ ] 物理存储改为 `256-bit`
- [ ] `WSTRB` 改为 `32-bit`
- [ ] `ARLEN/AWLEN` 按 beat 数解释
- [ ] 地址步进改为 `32 bytes`
- [ ] `INCR burst` 仍正确

#### axi_interconnect

- [ ] DMA 侧 `rdata/wdata` 改为 `256-bit`
- [ ] DMA 侧 `wstrb` 改为 `32-bit`
- [ ] CPU AXI-Lite 路由不被破坏
- [ ] 不在 interconnect 里做 packing/unpacking

#### dma_axi_reader

- [ ] `AXI_DATA_WIDTH = 256`
- [ ] `BEAT_BYTES = 32`
- [ ] `ARSIZE = 5`
- [ ] burst split 按 `32-byte` beat 正确
- [ ] 非整 beat `byte_count` 行为正确

#### dma_axi_writer

- [ ] `AXI_DATA_WIDTH = 256`
- [ ] `WSTRB = 32-bit`
- [ ] `AWSIZE = 5`
- [ ] burst split / 尾 beat 处理正确
- [ ] 地址步进正确

### 3.4 必须新增或更新的测试

- [ ] shared memory CPU `32-bit` 写 / NPU `256-bit` 读对拍测试
- [ ] shared memory NPU `256-bit` 写 / CPU `32-bit` 读对拍测试
- [ ] axi4_ram `256-bit` read burst smoke
- [ ] axi4_ram `256-bit` write burst smoke
- [ ] dma_axi_reader `256-bit` burst smoke
- [ ] dma_axi_writer `256-bit` burst smoke
- [ ] 非整 beat 尾部测试
- [ ] 多 burst 拆分测试

### 3.5 HB1-A 完成标准

必须同时满足：

- [ ] CPU/NPU shared memory 同址一致性通过
- [ ] `256-bit` DMA 读通过
- [ ] `256-bit` DMA 写通过
- [ ] burst split 与尾部处理通过
- [ ] 无“名义 `256-bit`，内部仍按 `32-bit` 正式语义工作”的残留路径

若未满足，不得进入 `HB1-B`。

## 4. HB1-B：Buffer / Feeder 256-bit 接入

### 4.1 阶段目标

把外部 `256-bit` 数据面真正接入 NPU 内部，不让带宽在片内入口重新退化成 `32-bit`。

本阶段要完成：

- `npu_buffer` 改成 `256-bit` 正式 buffer
- `act_read_path` / `weight_read_path` 改成按 beat 写 buffer
- `npu_top` 中 Conv/FC feeder 改成统一的 beat-register + byte-extract 语义

### 4.2 必须修改的文件

- `rtl/npu/npu_buffer.v`
- `rtl/npu/act_read_path.v`
- `rtl/npu/weight_read_path.v`
- `rtl/npu/npu_top.v`

### 4.3 必须完成的实现项

#### npu_buffer

- [ ] `DATA_WIDTH` 改为 `256`
- [ ] 写入单位改为 beat
- [ ] 读出单位改为 beat
- [ ] bank / ping-pong 语义保留
- [ ] 正式读路径改为同步读
- [ ] 去掉大数组组合读作为正式基线

#### act_read_path

- [ ] `BUF_DATA_W = 256`
- [ ] `buf_wr_data = 256-bit`
- [ ] `wr_addr_cnt` 改为 beat index
- [ ] 一次 `buf_wr_en` 表示一个完整 beat 写入

#### weight_read_path

- [ ] `BUF_DATA_W = 256`
- [ ] beat 级写入 weight buffer
- [ ] 相关地址计数与 beat 语义一致

#### npu_top feeder

- [ ] activation feeder 使用 beat register
- [ ] weight feeder 使用 beat register
- [ ] 统一使用 byte offset 规则从 beat 内提取 `INT8`
- [ ] Conv 和 FC 共享一致的 byte selection 语义
- [ ] 不保留旧的 `32-bit` word 正式 byte selector 逻辑

### 4.4 必须重点检查的高风险回归点

- [ ] FC byte selector 不再误用 `32-bit` word 口径
- [ ] `fc_chunk_inputs=64` 类路径位宽足够
- [ ] FC partial accumulation 地址不漂移
- [ ] Conv 跨 beat 抽窗正确
- [ ] FC 跨 beat 抽取正确
- [ ] 尾 chunk / 尾 beat 正确

### 4.5 必须新增或更新的测试

- [ ] 宽 beat 写入 buffer 后逐 byte 读出测试
- [ ] Conv 跨 beat 抽窗测试
- [ ] FC `fc_in_base=0` 的 chunk 提取测试
- [ ] FC `fc_in_base=448` 尾 chunk 提取测试
- [ ] weight 跨 beat 提取测试

### 4.6 HB1-B 完成标准

必须同时满足：

- [ ] `256-bit` 数据已进入 buffer 正式路径
- [ ] buffer / feeder 不再立即退回 `32-bit` 正式流
- [ ] Conv 模式 byte 抽取正确
- [ ] FC 模式 byte 抽取正确
- [ ] 关键历史 bug 风险点已被专门验证

若未满足，不得进入 `HB1-C`。

## 5. HB1-C：网络级正确性恢复

### 5.1 阶段目标

在新的 `256-bit` 数据面下，恢复当前已经收敛的 LeNet 正确性。

### 5.2 必须使用的正式入口

- `tb/integration/tb_top_lenet.v`
- `tb/integration/tb_top.v`
- `tb/integration/tb_lenet_network.v`

### 5.3 推荐恢复顺序

必须按顺序恢复：

1. [ ] `top` 单样本 PASS
2. [ ] `top8` PASS
3. [ ] `top16` PASS
4. [ ] 与 software/fixture 逐样本一致

不要跳过单样本直接跑大批量。

### 5.4 必须重点确认的内容

- [ ] Conv1 正确
- [ ] Pool1 正确
- [ ] Conv2 正确
- [ ] Pool2 正确
- [ ] FC1 正确
- [ ] FC2 正确
- [ ] final logits 正确
- [ ] `TOP_RESULT` 正确
- [ ] 与当前 fixture/software 一致

### 5.5 若恢复失败，定位顺序

一旦失败，必须按下面顺序缩小，不要散打：

1. [ ] shared memory 内容是否一致
2. [ ] DMA 读写是否正确
3. [ ] buffer / feeder 是否取错 byte
4. [ ] Conv/FC 哪一层 first failing
5. [ ] 控制流问题还是数值问题

### 5.6 HB1-C 完成标准

必须同时满足：

- [ ] `top` 单样本 PASS
- [ ] `top8` PASS
- [ ] `top16` PASS
- [ ] 与 software/fixture 逐样本一致
- [ ] 当前正式 LeNet 正确性不回退

满足后，`HB1` 才算完成。

## 6. HB2：带宽与性能闭环

### 6.1 阶段目标

在 `HB1` 稳定后，再建立可信的高带宽性能证据。

### 6.2 必须修改/检查的对象

- `perf_counter`
- `PERFORMANCE_SUMMARY` 相关文档
- beat 统计口径
- `read_beats/write_beats`
- burst 利用率计算
- `array_active/stall`
- `cluster_active/stall`

### 6.3 必须完成的实现项

- [ ] `read_beats` 在 `256-bit` 口径下重新核准
- [ ] `write_beats` 在 `256-bit` 口径下重新核准
- [ ] burst 利用率计算按 `32-byte` beat 更新
- [ ] array/cluster util 统计重新核准
- [ ] 性能文档与当前计数一致

### 6.4 必须完成的测试/回放

- [ ] 宽 AXI smoke under top path
- [ ] top16/top32 accuracy-only 不回退
- [ ] 性能统计 replay
- [ ] 带宽利用率报告可输出

### 6.5 HB2 完成标准

必须同时满足：

- [ ] `256-bit` 数据面下性能计数可信
- [ ] burst 利用率统计可信
- [ ] 正确性与性能口径一致
- [ ] 不再使用 `32-bit` 性能口径

## 7. 每轮实现汇报模板

后续 coding agent 每轮汇报必须使用以下结构：

- 当前任务：
- 当前阶段：`HB1-A/HB1-B/HB1-C/HB2`
- 修改摘要
- 修改文件列表
- 新增/修改的测试
- 运行命令
- 运行结果
- 当前阶段是否达到完成标准
- 当前卡在哪个验收项
- 是否引入低风险局部修复
- 残留风险

## 8. 明确禁止项

后续实现中，禁止：

- [ ] 为了快通过保留 `32-bit` 正式数据旁路
- [ ] 外部 `256-bit` / 内部 `32-bit` 长期并行
- [ ] 改 LeNet 地址图
- [ ] 改 requant 算法
- [ ] 改 cluster 高层调度语义
- [ ] 跳过模块级语义测试直接冲网络级
- [ ] 用“理论上支持 `256-bit`”代替真实验收
- [ ] 用 debug-only 伪结果旁路代替正式路径

## 9. 最终通过标准

这轮高带宽改造只有满足下面两层标准才算真正完成：

### HB1 通过

- [x] `256-bit` 数据面功能闭环完成
- [x] LeNet top 单样本 / top8 / top16 恢复
- [x] 与当前 software/fixture `predicted_class` 口径一致

### HB2 通过

- [x] `256-bit` 带宽与性能统计闭环完成
- [x] burst 利用率与性能文档可信
- [x] 可以作为当前 HB2 边界内的正式性能口径引用

HB2 引用限制：

- top-level LeNet 的性能 replay 仅代表 single-cluster 网络级口径
- multi-cluster 只可引用为运行级 util/compute-core 覆盖
- 不得把当前结果表述为完整 LeNet dual/full-cluster 性能闭环
