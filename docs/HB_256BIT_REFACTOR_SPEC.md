# HB 256-bit Data Plane Refactor Spec

本文档是 `Project_npu` 的 `256-bit` 高带宽数据面重构正式基线。后续所有 coding 工作必须以本文档为准，不得自行改变高层目标、模块边界和验收口径。

## 0. 当前 Closure 状态

截至 HB closure hardening，本文件定义的 HB 主体目标已经按当前既定范围收口：

- `HB1-A`：完成，shared memory / AXI4 RAM / interconnect / DMA 已切到 `256-bit` beat 语义
- `HB1-B`：完成，buffer / read path / feeder / `npu_top` 已接入 `256-bit` beat + byte offset 正式路径
- `HB1-C`：完成，`top` 单样本、top8、top16 在 `predicted_class` 口径下恢复
- `HB2`：完成到当前性能闭环边界，top16/top32/subsystem8 均可输出非零且线性自洽的性能 summary

当前仍必须保留的证据边界：

- top-level LeNet performance replay 是 `single-cluster` 口径，`array_active == cluster_active` 是预期现象
- multi-cluster 证据来自 util counter 与 compute-core/cluster-mode 运行级覆盖，不等同于完整 LeNet dual/full performance replay
- 本轮 closure 不改变 LeNet 地址图、requant 算法、6-cluster 计算架构或 arrayized FC 正式路径

## 1. 文档目的

本次改造的目标，不是简单把若干模块参数从 `32` 改成 `256`，而是把当前 NPU 的整条正式数据搬运链系统性升级为：

- `256-bit AXI4 DMA`
- `256-bit shared memory`
- `256-bit DMA read/write`
- `256-bit buffer`
- `256-bit feeder input path`

同时必须保持：

- 计算架构不变
- CPU 控制面不变
- shared memory 总容量不变
- 当前 LeNet 地址图不变
- 已经收敛的正式 LeNet/requant 路径不回退

本文档的目标是作为后续 coding agent 的唯一正式标准，避免实现中出现：

- 只改外部 AXI，不改片内 buffer
- 只改名义位宽，不改真实地址语义
- 片外 `256-bit`，片内正式路径又退回 `32-bit`
- CPU/NPU 访问 shared memory 同址语义不一致
- 改造后 LeNet 旧地址图失效
- 为了过测试引入临时旁路

## 2. 改造范围结论

### 2.1 本轮属于什么改造

本轮是：

- 数据面重构
- memory subsystem 重构
- DMA / buffer / feeder 重构

本轮不是：

- 计算架构重构
- cluster 架构重构
- requant 算法重构
- 网络结构重构
- 地址图重构

### 2.2 本轮正式目标

正式目标固定为：

- `AXI4 data width = 256-bit`
- `shared memory capacity = 1 MB`
- `shared memory physical organization = 32768 x 256-bit beat`
- `CPU control plane = 32-bit AXI-Lite`
- `NPU DMA data plane = 256-bit AXI4 burst`

## 3. 不允许改变的内容

后续实现中，以下内容不得改变。

### 3.1 顶层结构

- `CPU + NPU + shared memory` 总体拓扑
- CPU 仍通过 `AXI-Lite` 配置 NPU
- NPU 仍通过 AXI4 DMA 访问 shared memory

### 3.2 计算架构

- `6-cluster` 结构
- `16x16 PE per cluster`
- `cluster_scheduler -> compute_core_6cluster -> output_arbiter`
- Conv / Pool / Requant / FC 的高层功能路径
- arrayized FC 的正式主路径

### 3.3 地址图与功能语义

- 当前 LeNet 地址图
- 当前 requant 语义
- 当前 top / subsystem 正式测试入口角色
- CPU 与 NPU 共用同一份 shared memory 的语义

### 3.4 不允许采用的临时解法

- 不允许引入新的正式执行旁路
- 不允许保留长期并行的 `32-bit` 正式数据面
- 不允许为了过测试把 `256-bit` 在模块边界立刻拆回 `32-bit` 作为正式流
- 不允许通过 debug-only 数据旁路伪造宽总线功能

## 4. 允许改变的内容

本轮允许修改的对象包括：

### 4.1 memory / bus

- `rtl/soc/shared_ram.v`
- `rtl/soc/axi4_ram.v`
- `rtl/bus/axi_interconnect.v`
- `rtl/soc/top.v` 中 DMA 数据面位宽相关集成

### 4.2 DMA

- `rtl/npu/dma_axi_reader.v`
- `rtl/npu/dma_axi_writer.v`

### 4.3 buffer / load path / feeder

- `rtl/npu/npu_buffer.v`
- `rtl/npu/act_read_path.v`
- `rtl/npu/weight_read_path.v`
- `rtl/npu/npu_top.v` 中与宽 beat 装载、byte extraction、buffer 接口相关的局部实现

### 4.4 test / scripts / docs

- integration/unit testbench
- 仿真脚本
- 高带宽相关说明文档

## 5. 正式内存语义

这部分是本次改造的根基，后续任何实现都必须服从。

### 5.1 总容量

shared memory 总容量保持不变：

- `1 MB = 1,048,576 bytes`

### 5.2 物理组织

物理组织改为：

- `32768 x 256-bit beat`

解释：

- 一个 beat = `256-bit = 32 bytes`
- `1,048,576 / 32 = 32768`

### 5.3 beat 内部结构

每个 beat 内部包含：

- `32` 个 `8-bit byte lane`
- `8` 个 `32-bit word slot`

### 5.4 地址拆分规则

对任意字节地址 `addr[31:0]`，统一使用：

- `beat_addr = addr[19:5]`
- `word_in_beat = addr[4:2]`
- `byte_in_word = addr[1:0]`

这是本轮实现的唯一正式地址解释。

## 6. CPU / NPU 访问 shared memory 的统一语义

### 6.1 CPU 访问语义

CPU 继续保持：

- `32-bit AXI-Lite`

CPU 对 shared memory 的访问方式是：

- 通过 `beat_addr` 选中 `256-bit` beat
- 通过 `word_in_beat` 选中其中一个 `32-bit` word
- 通过 `cpu_wstrb[3:0]` 对该 `32-bit` word 内的字节做写掩码

### 6.2 NPU DMA 访问语义

NPU DMA 改为：

- `256-bit AXI4 burst`

NPU 对 shared memory 的访问方式是：

- 直接按 `beat_addr` 读写整 `256-bit` beat
- 写入时 `WSTRB = 32-bit`
- 每 bit 对应一个 byte lane

### 6.3 一致性要求

CPU 与 NPU 对同址 shared memory 的解释必须严格一致。

必须成立：

1. CPU `32-bit` 写，NPU `256-bit` 读，同址数据一致
2. NPU `256-bit` 写，CPU `32-bit` 读，同址数据一致
3. 同一 beat 内任意 `8` 个 word 的 lane 映射一致
4. 不允许出现 CPU 看到的是一套数据，NPU 看到的是另一套数据

## 7. LeNet 地址图保持不变

后续实现不得改变当前正式 LeNet 地址图：

- `Input image = 0x00000100`
- `Conv1 weights = 0x00001000`
- `Conv1 output / Pool1 input = 0x00004000`
- `Pool1 output / Conv2 input = 0x00018000`
- `Conv2 weights = 0x00020000`
- `Conv2 output / Pool2 input = 0x00060000`
- `Pool2 output / FC1 input = 0x00080000`
- `FC1 weights = 0x00090000`
- `FC1 output / FC2 input = 0x000F2000`
- `FC2 weights = 0x000F3000`
- `Final logits = 0x000F5000`

高带宽改造只能改变：

- 存储组织
- 访问粒度
- beat/byte 解释方式

不能改变：

- 地址本身的功能含义

## 8. 模块级正式改造要求

### 8.1 `shared_ram`

正式要求：

- 物理 `ram[]` 宽度改为 `256-bit`
- CPU `32-bit` 读写必须通过 beat 内 lane extract / merge 实现
- NPU DMA 读写必须原生支持 `256-bit`
- `npu_wstrb` 扩为 `32-bit`
- 不允许继续保留 `32-bit` 物理 RAM 作为正式实现

### 8.2 `axi4_ram`

正式要求：

- 纯 AXI4 RAM 模型改为 `256-bit`
- `WSTRB = 32-bit`
- `ARLEN/AWLEN` 按 beat 数解释
- `INCR burst` 地址步进以 `32 bytes` 为单位

### 8.3 `axi_interconnect`

正式要求：

- CPU AXI-Lite 路由尽量不变
- DMA 数据面改为 `256-bit`
- interconnect 不做 packing/unpacking
- DMA 仍应视为原生 AXI4 宽总线主口

### 8.4 `dma_axi_reader`

正式要求：

- `AXI_DATA_WIDTH = 256`
- `BEAT_BYTES = 32`
- `data_out = 256-bit`
- `ARSIZE = 5`
- burst split 逻辑按 `32-byte` beat 正确工作

### 8.5 `dma_axi_writer`

正式要求：

- `AXI_DATA_WIDTH = 256`
- `data_in = 256-bit`
- `WSTRB = 32-bit`
- `AWSIZE = 5`
- 尾 beat 掩码与地址步进必须按 `256-bit` 语义正确工作

### 8.6 `npu_buffer`

正式要求：

- 宽度改为 `256-bit`
- bank / ping-pong 语义保留
- 写入以 beat 为单位
- 读取以 beat 为单位
- 正式读路径改为同步读
- 不再把大数组组合读作为正式基线

### 8.7 `act_read_path / weight_read_path`

正式要求：

- buffer 写入口宽度同步改为 `256-bit`
- `wr_addr_cnt` 表示 beat index
- 每次写入一个完整 beat

### 8.8 `npu_top` 内部 feeder

正式要求：

- activation / weight 消费逻辑统一成：
  - 从 buffer 读取一个 `256-bit` beat
  - 在本地 beat register 中缓存
  - 按统一 byte offset 规则提取 `INT8`
- Conv 和 FC 必须共享一致的 byte offset 语义
- 不允许保留多套互相不一致的 byte selector 正式逻辑

## 9. 后续实现必须特别防止的回归问题

这是强制检查项。

### 9.1 FC byte selector 回归

必须保证：

- FC 模式不再误用只适合 `32-bit` word 的 byte selector 逻辑
- 例如不能再出现类似 `act_feed_ptr[1:0]` 直接决定 FC byte 的正式错误

### 9.2 FC 分块计数位宽

必须保证：

- `fc_chunk_inputs=64` 时相关计数器位宽足够
- 不允许再次出现计数器回绕导致 `CP_FEED_ACT` 无法退出的问题

### 9.3 FC partial accumulation 地址

必须保证：

- chunk 累加地址不会漂移
- 当前 tile 的累加始终写到该 tile 对应的合法输出槽位

### 9.4 跨 beat 边界的 byte 连续性

必须保证：

- Conv 模式跨 beat 抽窗正确
- FC 模式跨 beat 抽取正确
- 最后一个尾 chunk / 尾 beat 处理正确

## 10. 分阶段实施要求

### 10.1 HB1-A：内存与 DMA 层先收口

必须先完成：

- `shared_ram`
- `axi4_ram`
- `axi_interconnect`
- `dma_axi_reader`
- `dma_axi_writer`

此阶段目标：

- 先把 shared memory 与 DMA 宽总线语义收干净
- 先不要求 LeNet 网络级恢复

#### HB1-A 验收标准

至少要通过：

1. `256-bit` AXI4 read burst smoke
2. `256-bit` AXI4 write burst smoke
3. CPU `32-bit` 写 / NPU `256-bit` 读一致
4. NPU `256-bit` 写 / CPU `32-bit` 读一致

### 10.2 HB1-B：buffer / feeder 接入

在 HB1-A 完成后再做：

- `npu_buffer`
- `act_read_path`
- `weight_read_path`
- `npu_top` 中 Conv/FC 宽 beat 消费逻辑

#### HB1-B 验收标准

至少要通过：

1. 宽 beat 写入 buffer 后逐 byte 抽取一致
2. Conv 跨 beat 抽窗正确
3. FC 跨 beat 抽取正确
4. 尾 chunk / 尾 beat 正确

### 10.3 HB1-C：网络级正确性恢复

在 HB1-B 稳定后，再恢复正式链路：

1. top 单样本 PASS
2. top8 PASS
3. top16 PASS
4. 与 software/fixture 逐样本一致

HB1 的正式完成定义是：

> 在 `256-bit` 数据面下，当前已收敛的 LeNet 正确性不回退。

### 10.4 HB2：带宽与性能闭环

只有 HB1 稳定后，才允许进入 HB2。

HB2 内容包括：

- `read_beats/write_beats`
- burst 利用率
- `array/cluster active-stall`
- `256-bit` beat 口径下的带宽利用率验证
- 性能文档与答辩口径更新

HB2 当前完成边界：

- `read_beats/write_beats` 以 `1 beat = 32 bytes` 统计
- top16/top32 performance replay 非零且线性自洽
- subsystem8 performance replay 非零且与 top 口径一致
- read bandwidth utilization 已达到可引用口径；write utilization 反映当前网络 store 形态，不作为单独优化结论
- multi-cluster util 已有运行级覆盖，但完整 LeNet dual/full performance replay 不在当前 HB2 完成定义内

## 11. 测试要求

### 11.1 Memory semantic tests

必须新增：

- CPU `32-bit` 写，NPU `256-bit` 读
- NPU `256-bit` 写，CPU `32-bit` 读
- beat 边界附近地址测试
- 部分 byte mask 写测试

### 11.2 DMA tests

必须新增：

- `256-bit` read burst
- `256-bit` write burst
- 多 burst 拆分
- 非整 beat `byte_count`
- `INCR burst` 地址递增

### 11.3 buffer / feeder tests

必须新增：

- 宽 beat 写入后逐 byte 读出
- Conv 跨 beat 抽窗
- FC 模式 `fc_in_base=448` 类尾 chunk
- weight 跨 beat 读取

### 11.4 网络级测试

HB1 恢复后必须重新跑：

1. top 单样本
2. top8
3. top16

顺序不可颠倒。

## 12. coding agent 的工作原则

后续 coding agent 必须遵守：

1. 先统一语义，再改接口，再恢复网络级
2. 不要边改边发散去修 unrelated 问题
3. 不要为了快通过而引入临时 `32-bit` 正式旁路
4. 所有低风险修复都只能是：
   - 地址
   - 位宽
   - byte selector
   - 计数器
   - 掩码
   - lane extract / merge
5. 如果发现必须大改架构，必须先停下来汇报

## 13. 文档使用规则

本文档是后续高带宽改造的正式标准。

后续所有实现汇报必须明确写清：

- 当前阶段：`HB1-A / HB1-B / HB1-C / HB2`
- 修改了哪些模块
- 通过了哪些验收项
- 还卡在哪一层
- 是否引入了低风险局部修复

不允许使用以下模糊说法代替状态判断：

- “基本改完了”
- “大致支持 `256-bit`”
- “外面已经是 `256-bit` 了”
- “内部先临时这样跑”
- “理论上应该没问题”
