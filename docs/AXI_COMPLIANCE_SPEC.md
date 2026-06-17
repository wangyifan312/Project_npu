# AXI Compliance Spec

本文档定义 `Project_npu` 后续 AXI 整改的正式标准。

目标不是继续接受“当前项目能跑”的 AXI 子集实现，而是把当前控制面和数据面收敛成**可对外清晰说明、可验证、可交付**的协议实现。

---

## 0. 当前状态

当前仓库已经完成：

- `HB1`：`256-bit` 数据面功能闭环
- `HB2`：小批量性能计数与 replay 闭环

但当前 AXI 相关 RTL 仍更准确地属于：

- 面向本项目访问模式的 `AXI-Lite` 子集实现
- 面向本项目 DMA / shared memory 的 `AXI4 INCR burst` 子集实现

当前**不得**直接把仓库表述为：

- “完整标准 AXI4 兼容 IP”
- “完整标准 AXI-Lite 兼容 IP”

本文件的作用就是把这部分差距正式收口。

---

## 1. 正式目标

本轮 AXI 整改的正式目标固定为：

- 控制面：标准化 `AXI-Lite`
- 数据面：标准化 `AXI4 INCR burst` 子集

这里的“标准化”含义固定为：

- ready / valid 语义完整、自洽、可在 stall/backpressure 下保持稳定
- 明确支持范围
- 明确不支持范围
- 对非法事务有一致错误策略
- 具备独立协议级验证资产

本轮**不追求**的目标：

- 多 ID
- 多 outstanding
- out-of-order completion
- `WRAP/FIXED` burst
- 通用 crossbar / NoC 级互联

---

## 2. 不变项

AXI 标准化整改中，下列内容不得改变：

- `CPU + NPU + shared memory` 总体拓扑
- CPU 控制面仍为 `32-bit AXI-Lite`
- NPU DMA 数据面仍为 `256-bit AXI4 burst`
- shared memory 正式组织仍为 `32768 x 256-bit beat`
- `LeNet` 地址图不变
- `requant` 算法不变
- `6-cluster / 16x16 / arrayized FC` 主功能架构不变

---

## 3. 支持范围

## 3.1 AXI-Lite

后续正式支持范围固定为：

- 单笔读事务
- 单笔写事务
- `AW / W / B / AR / R` 五通道独立 ready/valid 语义
- `AW` 先到、`W` 后到
- `W` 先到、`AW` 后到
- `AW/W` 同拍到达
- `BVALID` 在 `BREADY` 拉低时保持稳定
- `RVALID/RDATA/RRESP` 在 `RREADY` 拉低时保持稳定

## 3.2 AXI4

后续正式支持范围固定为：

- `INCR burst`
- 单 outstanding read
- 单 outstanding write
- beat 对齐地址
- `256-bit` beat
- `WSTRB` 尾拍部分有效
- `RVALID/RDATA/RLAST/RRESP` 在 `RREADY` 拉低时保持稳定
- `WVALID/WDATA/WSTRB/WLAST` 在 `WREADY` 拉低时保持稳定

---

## 4. 不支持范围

后续文档和对外口径必须明确：

- 不支持 `FIXED burst`
- 不支持 `WRAP burst`
- 不支持多 ID
- 不支持多 outstanding read/write
- 不支持乱序完成
- 不支持 interleaving

这些不支持项不能靠“当前不会发生”来隐含处理，必须在实现或验证中被明确约束。

---

## 5. 错误策略

默认错误策略固定为：

- interconnect decode miss：`DECERR`
- slave 内非法访问：`SLVERR`
- 非法 `burst` 类型：`SLVERR`
- 非法 `size`：`SLVERR`
- 对齐错误：`SLVERR`
- 地址越界：`SLVERR`

如果后续实现发现某项必须调整，必须同步修改本文档和测试口径，不能只改 RTL。

---

## 6. 模块级整改要求

## 6.1 `shared_ram`

文件：

- `rtl/soc/shared_ram.v`

当前问题：

- CPU 口仍是工程化 `AXI-Lite` 语义，不足以对外宣称标准兼容
- NPU 口仍是项目专用 `AXI4 burst` 语义

正式目标：

- CPU 口收敛为标准化 `AXI-Lite` slave
- NPU 口收敛为标准化 `AXI4 INCR burst` slave 子集

必须补齐：

- `AW/W` 独立缓存与组合提交
- `R/B` 响应稳定保持
- 非法地址 / 非法事务错误响应
- `RDATA/WDATA` 在 non-ready 条件下稳定
- `RLAST/WLAST` 与 `LEN` 严格一致

## 6.2 `axi4_ram`

文件：

- `rtl/soc/axi4_ram.v`

正式目标：

- 成为协议参考口径清晰的 `256-bit AXI4 INCR burst` RAM model

必须补齐：

- 非法 `burst/size` 处理
- 越界处理
- backpressure 稳定保持
- `R/W last` 严格匹配

## 6.3 `dma_axi_reader`

文件：

- `rtl/npu/dma_axi_reader.v`

正式目标：

- 成为标准化 `AXI4` read master 子集

必须补齐：

- 对齐检查与错误路径
- stall 时状态稳定
- `ARLEN/RLAST` 对齐
- `RRESP` 错误传播

## 6.4 `dma_axi_writer`

文件：

- `rtl/npu/dma_axi_writer.v`

正式目标：

- 成为标准化 `AXI4` write master 子集

必须补齐：

- `AW/W/B` 解耦稳定性
- 尾拍 `WSTRB`
- `WLAST` 与 burst 长度一致
- `BRESP` 错误传播

## 6.5 `axi_interconnect`

文件：

- `rtl/bus/axi_interconnect.v`

正式目标：

- CPU 控制面成为标准化 `AXI-Lite` decode bridge
- DMA 面继续保持 point-to-point AXI4 直通

必须补齐：

- decode miss `DECERR`
- target latch 语义写入文档并由测试覆盖
- 不能依赖当前 master/slave 的宽容时序

## 6.6 `npu_ctrl`

文件：

- `rtl/npu/npu_ctrl.v`

正式目标：

- 成为标准化 AXI-Lite register slave

必须补齐：

- `AW/W` 解耦
- 读写响应稳定保持
- 非法寄存器访问错误口径

---

## 7. 协议级验证要求

协议级验证不得再混在 LeNet 功能回归里。

必须新增并长期保留以下资产：

- `tb/unit/tb_axil_shared_ram_protocol.v`
- `tb/unit/tb_axil_npu_ctrl_protocol.v`
- `tb/unit/tb_axi4_ram_protocol.v`
- `tb/unit/tb_dma_axi_reader_protocol.v`
- `tb/unit/tb_dma_axi_writer_protocol.v`

每类测试至少覆盖：

- `AW` 先到 / `W` 先到 / 同拍
- `RREADY/BREADY` stall
- `RVALID && !RREADY` 稳定
- `WVALID && !WREADY` 稳定
- `RLAST/WLAST` 与 `LEN` 一致
- 非法 `burst/size`
- 地址越界
- decode miss / response error

必须明确：

- LeNet PASS 不能替代协议 PASS
- 协议通过、功能通过、性能不回退必须分别报告

---

## 8. 验收要求

AXI 标准化完成必须同时满足：

1. 协议级测试全部通过
2. top 单样本 / top8 / top16 不回退
3. subsystem8 不回退
4. top16/top32 perf replay 不回退
5. 文档中已明确支持范围与不支持范围

任何一项不满足，都不得对外宣称“标准 AXI4 / AXI-Lite 兼容”。

---

## 9. 对外表述规则

当前计划已完成到项目正式支持边界，对外允许说：

- 控制面支持标准化 `AXI-Lite`
- 数据面支持标准化 `AXI4 INCR burst` 子集
- 当前 AXI 实现满足本项目正式路径需要
- 当前 AXI 仍属于项目子集实现

仍不允许说：

- “支持完整 AXI4 全特性”
- “支持任意第三方 AXI4 主从无约束对接”
