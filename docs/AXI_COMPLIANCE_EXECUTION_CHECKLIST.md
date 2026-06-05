# AXI Compliance Execution Checklist

本文档是 `AXI_COMPLIANCE_SPEC.md` 的执行清单版本。

目标是把 AXI 标准化整改拆成可执行阶段，供 coding agent 逐项实现、逐项验收。

---

## 0. 使用规则

执行要求：

1. 严格按阶段顺序推进：
   - `AXI-1`
   - `AXI-2`
   - `AXI-3`
   - `AXI-4`
2. 不允许跳阶段。
3. 每阶段完成后必须先通过本阶段验收，再进入下一阶段。
4. 任何阶段都不得破坏当前 `HB1/HB2` 已收敛的功能与性能基线。

---

## 1. 阶段总览

| 阶段 | 目标 | 主要范围 |
| --- | --- | --- |
| `AXI-1` | 冻结协议支持范围与错误口径 | docs / status / contract |
| `AXI-2` | 规范化 AXI-Lite 控制面 | `shared_ram` CPU口 / `npu_ctrl` / `axi_interconnect` CPU面 |
| `AXI-3` | 规范化 AXI4 INCR burst 数据面 | `shared_ram` NPU口 / `axi4_ram` / DMA reader/writer |
| `AXI-4` | 系统级回归与交付证据 | top / subsystem / perf / docs |

---

## 2. AXI-1：契约冻结

### 目标

先把协议支持范围、错误策略和验收口径写死，防止实现过程中继续模糊化。

### 必做项

- [ ] 新增 `docs/AXI_COMPLIANCE_SPEC.md`
- [ ] 在 `README.md` 写明当前 AXI 仍是项目子集实现，标准化整改另行推进
- [ ] 在 `docs/REPO_REVIEW_2026Q2.md` 中新增 AXI 标准化待办结论
- [ ] 在 `docs/DELIVERY_CHECKLIST.md` 中补充：若要宣称标准协议兼容，必须先完成 AXI plan

### 完成标准

- [ ] 协议支持范围无歧义
- [ ] 不支持范围无歧义
- [ ] 错误策略无歧义
- [ ] coding agent 不需要再自行决定“标准兼容”的边界

---

## 3. AXI-2：AXI-Lite 规范化

### 当前状态

`AXI-2` 已完成并关项。关闭证据固定为：

- `shared_ram` CPU AXI-Lite 口支持 `AW` 先到 / `W` 先到 / 同拍，且 `BVALID/RVALID` 在 backpressure 下保持稳定
- `npu_ctrl` 支持 `AW/W` 解耦、`WSTRB` 合并、非法寄存器访问 `SLVERR`
- `axi_interconnect` CPU 侧为单 outstanding AXI-Lite bridge，decode miss 本地返回 `DECERR`，target 在事务内锁存
- 协议级测试通过：
  - `tb/unit/tb_axil_shared_ram_protocol.v`
  - `tb/unit/tb_axil_npu_ctrl_protocol.v`
  - `tb/unit/tb_axil_interconnect_protocol.v`
- VCS formal smoke 通过：
  - top 单样本：`results/axi2_top1_smoke_vcs_packed`
  - subsystem 单样本：`results/axi2_subsystem1_smoke_vcs`

Legacy 分类：

- `tb/integration/tb_task3_axilite.v` 是历史 Task3 AXI-Lite target-latch micro-test，仍按旧“W-before-AW 应被 interconnect 阻塞”的项目子集口径编写，不作为 `AXI-2` 标准化验收项
- `tb/integration/tb_task4_system.v` 是历史 32-bit padded Task4 system smoke，保留为 legacy/micro/debug 资产，不作为 `AXI-2` 标准化验收项
- `AXI-2` 合规证据以新增 `tb_axil_*_protocol` 测试和 top/subsystem formal smoke 为准

### 目标

先把 CPU 控制面做成标准化 AXI-Lite 语义。

### 主要模块

- `rtl/soc/shared_ram.v`
- `rtl/npu/npu_ctrl.v`
- `rtl/bus/axi_interconnect.v`

### 必做项

- [ ] `shared_ram` CPU 口支持 `AW` 先到 / `W` 先到 / 同拍
- [ ] `shared_ram` `BVALID` 在 `BREADY` 前保持
- [ ] `shared_ram` `RVALID/RDATA/RRESP` 在 `RREADY` 前保持
- [ ] `npu_ctrl` 做同样的读写解耦与稳定保持
- [ ] `axi_interconnect` 对 decode miss 返回 `DECERR`
- [ ] `axi_interconnect` 写清并验证 target latch 行为

### 必增测试

- [ ] `tb/unit/tb_axil_shared_ram_protocol.v`
- [ ] `tb/unit/tb_axil_npu_ctrl_protocol.v`

### 完成标准

- [ ] AXI-Lite 协议级测试通过
- [ ] top/subsystem 编译与 smoke 不回退

---

## 4. AXI-3：AXI4 INCR burst 规范化

### 当前状态

`AXI-3` 已完成初始关项。关闭证据固定为：

- `axi4_ram` 作为 `256-bit AXI4 INCR burst` RAM model，补齐非法 `burst/size`、未对齐/越界 `SLVERR`、`RVALID` stall 保持、`RLAST/WLAST` 与 `LEN` 严格一致
- `shared_ram` NPU DMA 口与 `axi4_ram` 保持一致的 AXI4 slave 错误响应和 read-data 稳定保持语义，CPU AXI-Lite 口不回退
- `dma_axi_reader` 补齐 beat 对齐启动检查、`RRESP` 错误传播、`RLAST` 与 `ARLEN` 严格校验，并修复 split burst 后 `beat_counter` 复位
- `dma_axi_writer` 补齐 beat 对齐启动检查、`BRESP` 错误传播，并将 `WDATA/WSTRB/WLAST` 注册化以满足 `WVALID && !WREADY` 稳定保持
- `npu_top` 的 weight DMA 请求在 master 端下对齐到 32-byte beat，同时保留既有 `byte_offset` feeder 抽取语义，避免破坏 LeNet 地址图
- 协议级测试通过：
  - `tb/unit/tb_axi4_ram_protocol.v`
  - `tb/unit/tb_dma_axi_reader_protocol.v`
  - `tb/unit/tb_dma_axi_writer_protocol.v`
- 集成 smoke 通过：
  - `tb/unit/tb_hb1a_256_data_plane.v`
  - top 单样本：`results/axi3_top1_after_wgt_align`

### 目标

把 shared memory 与 DMA 数据面收敛成标准化 AXI4 INCR burst 子集。

### 主要模块

- `rtl/soc/shared_ram.v`
- `rtl/soc/axi4_ram.v`
- `rtl/npu/dma_axi_reader.v`
- `rtl/npu/dma_axi_writer.v`

### 必做项

- [ ] 非法 `burst` 返回 `SLVERR`
- [ ] 非法 `size` 返回 `SLVERR`
- [ ] 地址越界返回 `SLVERR`
- [ ] `RVALID && !RREADY` 时 `RDATA/RLAST/RRESP` 保持稳定
- [ ] `WVALID && !WREADY` 时 `WDATA/WSTRB/WLAST` 保持稳定
- [ ] `RLAST/WLAST` 与 `LEN` 严格一致
- [ ] DMA reader 对齐检查和 `RRESP` 错误路径明确
- [ ] DMA writer 对齐检查、尾拍 `WSTRB`、`BRESP` 错误路径明确

### 必增测试

- [ ] `tb/unit/tb_axi4_ram_protocol.v`
- [ ] `tb/unit/tb_dma_axi_reader_protocol.v`
- [ ] `tb/unit/tb_dma_axi_writer_protocol.v`

### 完成标准

- [ ] AXI4 协议级测试通过
- [ ] HB1/HB2 回归不回退

---

## 5. AXI-4：系统级回归与交付证据

### 当前状态

`AXI-4` 已完成并关项。关闭证据固定为：

- 协议级测试保持通过：
  - `tb/unit/tb_axil_shared_ram_protocol.v`
  - `tb/unit/tb_axil_npu_ctrl_protocol.v`
  - `tb/unit/tb_axil_interconnect_protocol.v`
  - `tb/unit/tb_axi4_ram_protocol.v`
  - `tb/unit/tb_dma_axi_reader_protocol.v`
  - `tb/unit/tb_dma_axi_writer_protocol.v`
- 功能回归通过：
  - top8：`results/axi4_top8_vcs`
  - top16 当前正式口径：`results/make_perf_top16`
  - subsystem8 clean summary：`results/axi4_subsystem8_clean`
- 性能回归通过：
  - top16 perf replay：`results/make_perf_top16`
  - top32 perf replay：`results/make_perf_top32`
  - subsystem8 perf replay：`results/axi4_perf_subsystem8_clean`
- 三类证据必须分开引用：
  - 协议级：`tb_axil_*_protocol` / `tb_axi4_*_protocol`
  - 功能级：top8 / top16 / subsystem8
  - 性能级：top16 perf / top32 perf / subsystem8 perf

引用边界：

- 当前完成的是项目内正式支持范围上的 `AXI-Lite + 256-bit AXI4 INCR burst` 标准化，不等同于完整通用 AXI4 IP
- top-level LeNet performance replay 仍是 `single-cluster` 网络级口径
- multi-cluster 证据仍以 util counter / compute-core cluster-mode 覆盖为准，不等同于完整 dual/full-cluster top-level LeNet performance replay

### 目标

在协议整改完成后，证明功能和性能没有回退，并形成可以引用的交付证据。

### 必跑回归

- [x] top 单样本
- [x] top8
- [x] top16
- [x] subsystem8
- [x] top16 perf replay
- [x] top32 perf replay
- [x] subsystem8 perf replay

### 报告要求

- [x] 协议测试结果单独报告
- [x] 功能回归结果单独报告
- [x] 性能回归结果单独报告

### 完成标准

- [x] 可明确说明“标准化 AXI-Lite + AXI4 INCR burst 子集”已完成
- [x] 现有 HB 结果不回退
- [x] 文档与代码状态一致

---

## 6. 禁止项

后续实现中禁止：

- [ ] 借功能 PASS 掩盖协议未通过
- [ ] 借 testbench 宽容行为掩盖 slave/master 不稳定
- [ ] 修改 LeNet 地址图
- [ ] 修改 requant 算法
- [ ] 修改 `6-cluster / 16x16 / arrayized FC` 主功能架构
- [ ] 把不支持的 AXI 特性写成“理论支持”

---

## 7. 每轮汇报模板

后续 coding agent 每轮汇报必须使用：

- 当前任务：AXI compliance
- 当前阶段：AXI-1 / AXI-2 / AXI-3 / AXI-4
- 修改摘要
- 修改文件列表
- 新增/修改的协议测试
- 运行命令
- 运行结果
- 当前阶段是否达到完成标准
- 当前卡在哪个验收项
- 是否影响 HB1/HB2 已有结果
- 残留风险
