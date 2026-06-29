# CPU+NPU SoC 设计规范

**项目**: Project_npu
**日期**: 2026-06-25
**版本**: R1a（寄存器映射版本 0x0001_000A）
**状态**: 实现完成；验证进行中（见附录验证状态）

---

## 1. Main feature

### 1.1 核心架构

| 特性 | 规格 |
|------|------|
| SoC 类型 | CPU+NPU 异构 SoC |
| CPU 核 | PicoRV32（RISC-V RV32IMC） |
| NPU 架构 | 6×16×16 INT8 脉动阵列 |
| 总 PE 数 | 1536（6 个 cluster × 256 PE/cluster） |
| 理论峰值 | 0.6144 TOPS @ 200 MHz（1536 PE × 2 ops/MAC × 200 MHz） |
| 控制面 | 32-bit AXI-Lite，内存映射寄存器访问 |
| 数据面 | 256-bit AXI4 INCR burst DMA（读 + 写） |
| 共享内存 | 1 MB（32768 × 256-bit beat），统一地址空间 |
| 时钟 | 单全局时钟域，目标 200 MHz |
| 复位 | 单异步低有效复位（`rst_n`） |

### 1.2 支持的操作

| 操作 | 任务类型码 | 状态 |
|------|-----------|------|
| 卷积（Conv） | 0 | 已实现并验证（1×1、3×3、5×5；stride 1/2；valid/same padding） |
| 全连接（FC） | 1 | 已实现并验证（tile-based multi-pass，多 cluster） |
| 池化（MaxPool） | 2 | 已实现并验证（2×2 INT32 域） |
| 重量化（Requant） | 3 | 已实现并验证（INT32→INT8，4 个参数槽位） |
| 残差加法（Add） | 4 | 已实现并验证（前后重量化，支持 ReLU） |
| 全局平均池化（GAP） | 5 | 已实现并验证（8×8 空间，逐通道） |

### 1.3 关键能力

- **运行时 cluster 配置**: 单 cluster、双 cluster、全 6 cluster、mask 模式
- **AXI4 burst DMA**: 256-bit INCR burst，最大 16 beat，W 通道 skid buffer 优化
- **DMA 写入事务级利用率**: 80.00%（Phase A/B/B2 完成，`producer_done` 尾 burst 修复）
- **性能计数器**: 周期计数、读写 beat 数、MAC 计数、cluster 活跃/停顿、写入事务指标
- **错误检测**: 任务参数校验（task_checker）、AXI 响应错误、地址对齐违规、地址越界
- **背靠背任务执行**: 空闲时写 CTRL.start 自动清除 done/error
- **UVM 验证环境**: 定向测试 + UVM smoke + 结构性 UVM 测试

### 1.4 已修复问题

| 问题 | 根因 | 修复 | 状态 |
|------|------|------|------|
| 背靠背启动被阻塞 | `write_new_start` 条件要求 `!done` | `npu_ctrl.v`: CTRL[0]=1 空闲时自动清除 done/error | 已修复 |
| 寄存器地址冲突（0x88/0x8C） | 性能计数器与 CLUSTER_MODE/MASK 共用地址 | 性能计数器移至 0xD0/0xD4 | 已修复 |
| Conv 多 cluster 不匹配 | 误诊：背靠背启动 bug 阻止第 2-4 轮迭代执行 | 澄清：修复后 4 种模式全部 PASS | 已解决 |
| Conv 多窗口排空挂起 | DMA writer S_WAIT_DATA 尾 burst 死锁 | `dma_axi_writer.v` + `npu_top.v`: `producer_done` 机制 | 已修复 |

### 1.5 待完成 / 未来工作

| 项目 | 状态 |
|------|------|
| Phase C: acc_buffer 256-bit 位宽扩展 | 暂缓 |
| FPGA 综合与时序收敛 | 待完成 |
| 代码覆盖率收集与报告 | 待完成 |
| 低功耗门控验证 | 待完成 |
| ResNet-20 完整端到端 RTL 验证 | 待完成（已有 foundation / directed 测试至 R1i） |

---

## 2. over view

### 2.1 SoC 框图

```
 +----------------------------------------------------------------+
 |                          top.v                                  |
 |                                                                |
 |  +----------------+        +------------------+                 |
 |  |  PicoRV32 CPU  |<------>| AXI 互联         |<-----------+   |
 |  |  (AXI-Lite M)  |        | (axi_interconnect |            |   |
 |  +----------------+        |  地址译码)        |            |   |
 |                            +--------+---------+            |   |
 |                                     |                      |   |
 |                     +---------------+--------------+       |   |
 |                     |                              |       |   |
 |                +----v----+                  +------v------+|   |
 |                | 共享    |<-- NPU AXI4 DMA--|    NPU      ||   |
 |                |  RAM    |   (256-bit)      |  (npu_top)  ||   |
 |                | 1 MB    |                  |             ||   |
 |                | 32768 x |-- CPU AXI-Lite-->| 寄存器文件  ||   |
 |                | 256-bit |   (32-bit)       | /控制器     ||   |
 |                +---------+                  +-------------+|   |
 |                                                                |
 |  TB AXI-Lite（tb_axil_enable=1 时绕过 CPU）                    |
 |  +-- tb_aw*, tb_w*, tb_b*, tb_ar*, tb_r* (32-bit)            |
 +----------------------------------------------------------------+
```

### 2.2 控制面与数据面分离

**控制面（32-bit AXI-Lite）**:
- CPU 或测试台（TB）通过 AXI-Lite 寄存器写操作发起所有 NPU 操作
- AXI 互联根据地址范围译码：`0x0000_0000 - 0x000F_FFFF` → 共享 RAM，`0x1000_0000+` → NPU 寄存器
- NPU 不发起控制事务；它是纯 AXI-Lite 从设备
- 轮询模式：CPU/TB 读 CTRL 寄存器（done/error/busy 位）监控任务完成

**数据面（256-bit AXI4 INCR Burst）**:
- NPU DMA 读写器是 AXI4 总线主设备
- NPU DMA 通过 256-bit INCR burst 从共享 RAM 读取输入激活和权重
- NPU DMA 通过 256-bit INCR burst 将计算结果写回共享 RAM
- AXI4 burst 类型为 INCR，每 burst 最大 16 beat（MAX_BURST_LEN=16）
- Burst 大小编码：AWSIZE/ARSIZE = 5（32 字节 = 256-bit beat）
- CPU 不参与大数据搬运；DMA 处理所有大块数据传输

### 2.3 控制面与数据面分离的原因

- **CPU 使用 32-bit AXI-Lite**: 足以处理寄存器访问和小量数据预载。配置不需要 burst 能力。
- **NPU DMA 使用 256-bit AXI4 burst**: 高带宽大块数据传输需要宽位宽 INCR burst，以最大化内存吞吐量并减少事务开销。
- **共享 RAM**: CPU 和 NPU 通过各自端口访问同一物理内存（CPU: 32-bit AXI-Lite, NPU: 256-bit AXI4）。这使得 CPU 能够预载输入/权重数据并在任务完成后读回输出，无需额外 DMA。

### 2.4 任务执行流程

```
1.  CPU/TB 将输入/权重/偏置数据预载到共享 RAM
2.  CPU/TB 通过 AXI-Lite 写 NPU 任务配置寄存器
3.  CPU/TB 写 CTRL 寄存器 start 位（bit[0]=1）
4.  NPU task_checker 校验任务参数
5.  NPU DMA 读取器从共享 RAM 加载激活和权重
6.  conv_frontend / fc_frontend 为脉动阵列准备计算流
7.  cluster_scheduler 将工作分配到各使能的 cluster
8.  compute_core_6cluster 执行 INT8 MAC 计算
9.  output_arbiter 从各 cluster 收集结果
10. postproc 应用 ReLU / Pool / Bias+Requant（如使能）
11. store_pack 将 32-bit 字组装为 256-bit beat → write_beat_fifo
12. dma_axi_writer 通过 AXI4 burst 将输出写入共享 RAM
13. CPU/TB 轮询 CTRL 寄存器 done/error 状态
14. CPU/TB 按需读取性能计数器
15. CPU/TB 从共享 RAM 读取输出数据
```

---

## 3. Interface

### 3.1 SoC 顶层端口

| 端口 | 方向 | 位宽 | 描述 |
|------|------|------|------|
| `clk` | 输入 | 1 | 全局时钟（目标 200 MHz） |
| `rst_n` | 输入 | 1 | 全局异步低有效复位 |
| `tb_axil_enable` | 输入 | 1 | TB 模式: 1=绕过 CPU，使用 TB AXI-Lite 信号 |
| **TB AXI-Lite 写地址** | | | |
| `tb_awvalid` | 输入 | 1 | 写地址有效 |
| `tb_awready` | 输出 | 1 | 写地址就绪 |
| `tb_awaddr` | 输入 | 32 | 写地址（字节寻址） |
| **TB AXI-Lite 写数据** | | | |
| `tb_wvalid` | 输入 | 1 | 写数据有效 |
| `tb_wready` | 输出 | 1 | 写数据就绪 |
| `tb_wdata` | 输入 | 32 | 写数据 |
| `tb_wstrb` | 输入 | 4 | 字节选通 |
| **TB AXI-Lite 写响应** | | | |
| `tb_bvalid` | 输出 | 1 | 写响应有效 |
| `tb_bready` | 输入 | 1 | 写响应就绪 |
| `tb_bresp` | 输出 | 2 | 写响应（00=OKAY, 10=SLVERR） |
| **TB AXI-Lite 读地址** | | | |
| `tb_arvalid` | 输入 | 1 | 读地址有效 |
| `tb_arready` | 输出 | 1 | 读地址就绪 |
| `tb_araddr` | 输入 | 32 | 读地址 |
| **TB AXI-Lite 读数据** | | | |
| `tb_rvalid` | 输出 | 1 | 读数据有效 |
| `tb_rready` | 输入 | 1 | 读数据就绪 |
| `tb_rdata` | 输出 | 32 | 读数据 |
| `tb_rresp` | 输出 | 2 | 读响应 |
| **状态** | | | |
| `cpu_trap` | 输出 | 1 | PicoRV32 trap 指示（调试用） |
| `npu_status` | 输出 | 32 | NPU 状态: {24'h0, error, done, busy, 1'b0} |

### 3.2 NPU AXI-Lite 从设备寄存器接口

NPU 在基地址 `0x1000_0000` 处提供 256 字节寄存器空间。所有寄存器为 32-bit，通过 AXI-Lite（AW/W/B/AR/R 通道）访问。

内部 AXI-Lite 信号（非顶层端口）:
- `s_axi_awaddr[31:0]`, `s_axi_awvalid`, `s_axi_awready`
- `s_axi_wdata[31:0]`, `s_axi_wstrb[3:0]`, `s_axi_wvalid`, `s_axi_wready`
- `s_axi_bresp[1:0]`, `s_axi_bvalid`, `s_axi_bready`
- `s_axi_araddr[31:0]`, `s_axi_arvalid`, `s_axi_arready`
- `s_axi_rdata[31:0]`, `s_axi_rresp[1:0]`, `s_axi_rvalid`, `s_axi_rready`

### 3.3 NPU AXI4 DMA 主设备接口

**DMA 读（dma_axi_reader）**:

| 信号 | 方向 | 位宽 | 描述 |
|------|------|------|------|
| `m_axi_araddr` | 输出 | 32 | 读地址（beat 对齐） |
| `m_axi_arvalid` | 输出 | 1 | 读地址有效 |
| `m_axi_arready` | 输入 | 1 | 读地址就绪 |
| `m_axi_arlen` | 输出 | 8 | Burst 长度（beat 数 - 1，最大 15） |
| `m_axi_arsize` | 输出 | 3 | Burst 大小（=5 for 256-bit） |
| `m_axi_arburst` | 输出 | 2 | Burst 类型（=1 INCR） |
| `m_axi_rdata` | 输入 | 256 | 读数据 |
| `m_axi_rvalid` | 输入 | 1 | 读数据有效 |
| `m_axi_rready` | 输出 | 1 | 读数据就绪 |
| `m_axi_rlast` | 输入 | 1 | 读最后一 beat |
| `m_axi_rresp` | 输入 | 2 | 读响应 |

**DMA 写（dma_axi_writer）**:

| 信号 | 方向 | 位宽 | 描述 |
|------|------|------|------|
| `m_axi_awaddr` | 输出 | 32 | 写地址（beat 对齐） |
| `m_axi_awvalid` | 输出 | 1 | 写地址有效 |
| `m_axi_awready` | 输入 | 1 | 写地址就绪 |
| `m_axi_awlen` | 输出 | 8 | Burst 长度（beat 数 - 1） |
| `m_axi_awsize` | 输出 | 3 | Burst 大小（=5 for 256-bit） |
| `m_axi_awburst` | 输出 | 2 | Burst 类型（=1 INCR） |
| `m_axi_wdata` | 输出 | 256 | 写数据 |
| `m_axi_wvalid` | 输出 | 1 | 写数据有效 |
| `m_axi_wready` | 输入 | 1 | 写数据就绪 |
| `m_axi_wlast` | 输出 | 1 | 写最后一 beat |
| `m_axi_wstrb` | 输出 | 32 | 字节选通（32 通道） |
| `m_axi_bresp` | 输入 | 2 | 写响应 |
| `m_axi_bvalid` | 输入 | 1 | 写响应有效 |
| `m_axi_bready` | 输出 | 1 | 写响应就绪（固定为 1） |

### 3.4 共享 RAM 接口

共享 RAM 是双端口统一内存：

| 端口 | 数据位宽 | 协议 | 用途 |
|------|---------|------|------|
| CPU 端口 | 32-bit | AXI-Lite | CPU/TB 预载和输出回读 |
| NPU 端口 | 256-bit | AXI4 (INCR burst) | NPU DMA 读写 |

**参数**: `RAM_DEPTH = 32768`，位宽 = 256-bit。总容量 = 1 MB。

CPU 端口对 256-bit beat 内的单个 word 执行 32-bit 读-改-写。NPU 端口使用完整 256-bit beat 访问，配合字节选通。

---

## 4. information flow

### 4.1 完整任务生命周期

**阶段 1: 数据预载**
1. CPU（或 TB）将输入激活数据写入共享 RAM，起始地址为 `input_addr`
2. CPU 将权重数据写入共享 RAM，起始地址为 `weight_addr`
3. 如使用偏置: CPU 将偏置数据写入共享 RAM，起始地址为 `bias_addr`

**阶段 2: 任务配置**
4. CPU 通过 AXI-Lite 写 NPU 配置寄存器:
   - `TASK_TYPE` (0x08): 操作类型（0=Conv, 1=FC 等）
   - `INPUT_ADDR` / `WEIGHT_ADDR` / `OUTPUT_ADDR`: 数据指针
   - `INPUT_BYTES` / `WEIGHT_BYTES` / `OUTPUT_BYTES`: 数据大小
   - `DIM_IN` / `DIM_OUT`: 张量形状（H, W, C_IN, C_OUT）
   - `POSTPROC`: ReLU/Pool 使能
   - `CLUSTER_MODE` / `CLUSTER_MASK`: cluster 配置
   - 其他任务特定的寄存器（requant, bias, add, GAP, conv_cfg）

**阶段 3: 任务启动**
5. CPU 写 `CTRL` 寄存器 bit[0]=1（启动）
6. 若空闲且 `done=1`: RTL 自动清除 `done` 和 `error`，启动新任务
7. 若空闲且 `error=1`: CPU 必须先写 CTRL bit[4]=1 清除 error，再启动
8. 若忙时: 写 CTRL bit[0]=1 触发 `busy_start_violation`（error_code=0x10）

**阶段 4: 任务校验**
9. `task_checker` 校验所有任务参数:
   - 地址对齐（数据地址 64 字节对齐）
   - 参数一致性（字节数与形状匹配）
   - 任务类型特定检查（kernel 大小、stride、padding、通道数）
   - Buffer 容量（输入/权重在 BUF_ENTRIES 限制内）
   - 若检查失败: 置 error，终止任务

**阶段 5: 数据加载**
10. DMA 读取器从共享 RAM 加载输入激活数据至 `act_buffer`（npu_buffer, 256-bit, 16384 项）
11. Conv: DMA 读取器加载权重至 `wgt_buffer`; `conv_frontend` 通过 5 行 line buffer 提取 5×5（或 3×3、1×1）窗口
12. FC: DMA 读取器以 tile 大小分块加载权重; `fc_frontend` 管理 tile pass 排序
13. 预取优化: 多通道 Conv 在当前通道计算期间预取下一通道的权重

**阶段 6: 计算分发**
14. `cluster_scheduler` 根据 `CLUSTER_MODE` 和 `CLUSTER_MASK` 确定活跃 cluster mask
15. 权重基于输出列分区路由到各活跃 cluster
16. `compute_core_6cluster` 将激活和权重送入脉动阵列
17. 各 cluster 的 PE 阵列以脉动方式执行 INT8 MAC

**阶段 7: 输出收集**
18. `output_arbiter` 从所有活跃 cluster 收集部分和（AGGREGATE_MODE 下为 OR 合并）
19. 各列结果在 `col_results[]` 数组中累加
20. 多输入通道 Conv: 部分和跨通道在 `acc_buffer` 中累加
21. 带偏置的 FC: 偏置值加到累加结果上

**阶段 8: 后处理**
22. 若 ReLU 使能: 负值钳位到零
23. 若 Pool 使能: 通过 `postproc` 在 INT32 域执行 2×2 MaxPool
24. 若 Bias+Requant 使能: 通过 `bias_add_requant_i32_to_i8` 加上 INT32 偏置后重量化至 INT8

**阶段 9: 输出回写**
25. `store_pack` 从 `acc_buffer` 读取 32-bit 字，打包为 256-bit beat
26. 打包后的 beat 推入 `write_beat_fifo`（深度 16 项）
27. `dma_axi_writer` 向共享 RAM 发起 AXI4 INCR 写入 burst
28. `producer_done` 信号确保尾 burst 即使在 FIFO 部分填充时也能完成

**阶段 10: 完成**
29. `dma_axi_writer` 置 `done`; NPU FSM 转为 `FSM_DONE`
30. `ctrl_done` 被寄存; `busy` 撤销
31. CPU 轮询 `CTRL` 寄存器: bit[2]=done, bit[3]=error
32. CPU 按需通过 AXI-Lite 读取性能计数器
33. CPU 从共享 RAM 读取输出数据，起始地址为 `output_addr`

### 4.2 背靠背任务执行

当任务完成后（done=1, busy=0），CPU 可立即启动下一个任务:
- 写入新的任务配置寄存器（busy=0 或 error=1 时允许）
- 写 CTRL bit[0]=1 → 自动清除 done 和 error，锁存新配置，启动任务

若上一任务以 error 结束（error=1, busy=0）:
- CPU 必须先写 CTRL bit[4]=1 显式清除 error，再启动
- 或: 写 CTRL bit[0]=1，但 error=1 时不会自动启动（error 优先）

### 4.3 多 Cluster 数据流

多 cluster Conv/FC 任务:
1. `cluster_scheduler` 确定哪些 cluster 被使能（基于 mode + mask）
2. 输出通道范围在使能的 cluster 之间分区:
   - Cluster N 得到输出列 [N×cols/N_clusters : (N+1)×cols/N_clusters]
3. 各 cluster 所需输出通道范围的权重被路由至该 cluster 的权重 buffer
4. 所有 cluster 并行计算
5. `output_arbiter` 通过 OR 合并（AGGREGATE_MODE=1）汇总所有 cluster 的输出

---

## 5. Sub-function

### 5.1 CPU 控制子系统

**模块**: PicoRV32 (`rtl/cpu/picorv32/picorv32.v`)
- RISC-V RV32IMC ISA（整数、乘除、压缩指令）
- AXI-Lite 存储器接口
- Trap 输出（`cpu_trap`）用于调试
- TB 旁路: `tb_axil_enable=1` 时 TB AXI-Lite 信号替代 CPU; CPU 保持复位
- 状态: 已集成且功能正常。仅在非 TB 模式下使用。

### 5.2 AXI 互联 / 地址译码

**模块**: `axi_interconnect` (`rtl/bus/axi_interconnect.v`)
- 将 CPU/TB 的 AXI-Lite 事务路由到共享 RAM 或 NPU 寄存器
- 地址映射:
  - `0x0000_0000 – 0x000F_FFFF` → 共享 RAM（1 MB）
  - `0x1000_0000 – 0x1000_00FF` → NPU 寄存器（256 字节）
  - 其他全部地址 → DECERR (2'b11)
- 根据 `tb_axil_enable` 多路复用 CPU 和 TB 的 AXI-Lite 信号
- 状态: 已实现并验证。

### 5.3 共享 RAM

**模块**: `shared_ram` (`rtl/soc/shared_ram.v`)
- 32768 × 256-bit 统一内存（1 MB）
- 双端口: CPU 32-bit AXI-Lite + NPU 256-bit AXI4
- 地址分解: `beat_addr = addr[19:5]`, `word_in_beat = addr[4:2]`, `byte_in_word = addr[1:0]`
- NPU 端口校验: 仅接受 INCR burst、size=5（256-bit）、对齐地址
- 无效请求 → SLVERR
- 状态: 已实现并验证。REQ-1 测试台预载问题已解决。

### 5.4 NPU 寄存器文件 / 控制 FSM

**模块**: `npu_ctrl` (`rtl/npu/npu_ctrl.v`)
- AXI-Lite 从设备: 接受 `0x1000_0000 – 0x1000_00FF` 地址空间的寄存器读写
- 寄存器文件: 52 个配置寄存器 + 16 个性能计数器读取端口
- 控制 FSM: 管理 busy/done/error 状态、任务启动、背靠背恢复
- 背靠背修复: 空闲时 CTRL[0]=1 自动清除 done/error 并启动新任务
- 地址修复: PERF_WRITE_DATA_CYC 在 0xD0, PERF_WRITE_TXN_CYC 在 0xD4（不再与 0x88/0x8C 冲突）
- 状态: 已实现、已修复、已验证。

### 5.5 任务检查器

**模块**: `task_checker` (`rtl/npu/task_checker.v`)
- 对所有任务参数进行执行前校验
- 检查: 任务类型有效性、地址对齐（数据 64B）、字节数一致性、维度有效性、buffer 容量
- 各任务类型特定检查: Conv（kernel 大小/stride/padding）、FC（tile 容量）、Pool（维度）、Requant（乘数/移位数）
- 错误码通过 STATUS 寄存器报告
- 状态: 已实现并验证。

### 5.6 DMA 读取器

**模块**: `dma_axi_reader` (`rtl/npu/dma_axi_reader.v`)
- AXI4 读主设备: 256-bit INCR burst，最大 16 beat
- 将大字节数拆分为 burst 长度大小的块
- 错误检测: 地址对齐（ERR_ALIGN=0x21）、RRESP 错误（ERR_RRESP=0x20）、内部 RLAST 错误（ERR_INTERNAL=0x22）
- 零字节处理: 立即完成，不发起 AXI 事务
- 状态: 已实现并验证。

### 5.7 DMA 写入器

**模块**: `dma_axi_writer` (`rtl/npu/dma_axi_writer.v`)
- AXI4 写主设备: 256-bit INCR burst，最大 16 beat
- Phase B2 skid buffer: 下一 beat 预取消除 W 通道气泡（事务级利用率 80.00%）
- 延迟 AW: 在 `S_WAIT_DATA` 等待 `fifo_level >= beats_in_burst` 后发起 AW
- `producer_done` 机制: 置位时使用 FIFO 中可用数据完成最后 burst（防止尾 burst 死锁）
- WSTRB 生成: 正确生成每 beat 的字节选通，包括部分填充的最后一 beat
- 错误检测: 对齐（ERR_ALIGN=0x31）、BRESP 错误（ERR_BRESP=0x30）
- 零字节处理: 立即完成，不发起 AXI 事务
- 状态: 已实现、已修复、已验证。

### 5.8 写入 Beat FIFO

**模块**: `write_beat_fifo` (`rtl/npu/write_beat_fifo.v`)
- 深度 16 × 256-bit 基于寄存器的 FIFO
- 组合读端口: `rd_data` 始终展示队列头部
- `rd_level[4:0]` 输出供 DMA writer FIFO 水位控制使用
- 状态: 已实现并验证。

### 5.9 Conv 前端

**模块**: `conv_frontend` (`rtl/npu/conv_frontend.v`)
- 通过 5 行 line buffer 从 act_buffer 提取卷积窗口
- 支持 kernel 大小: 1×1、3×3、5×5（由 `conv_kernel_sel` 选择）
- 支持 stride 1 和 stride 2
- 支持 valid 和 same padding 模式
- 向计算流水线输出窗口有效/数据信号
- 状态: 已实现并验证。kernel < 5×5 时 `lb_base_row` 为负值已确认无害（边界检查保护访问）。

### 5.10 FC 前端

**模块**: `fc_frontend` (`rtl/npu/fc_frontend.v`)
- Legacy/调试模块。正式 FC 执行直接在 `npu_top` 中通过 tile-based pass 机制实现。
- 状态: Legacy 模块; 不用于正式 FC 路径。

### 5.11 Pool / Requant / 后处理

**Pool**: `postproc` 模块 (`rtl/npu/postproc.v`) — INT32 域 2×2 MaxPool，ReLU 钳位
**Requant**: `requant_i32_to_i8` (`rtl/npu/requant_i32_to_i8.v`) — INT32→INT8，round-half-away-from-zero，钳位 [-128,127]
**Bias+Requant**: `bias_add_requant_i32_to_i8` — 折叠 INT32 bias + requant
**残差加法**: `residual_add_requant_i8` — src0+src1，前后 requant，ReLU 可选
**GAP**: `gap8x8_requant_i8` — 逐通道 8×8 空间平均
- 状态: 全部已实现并验证。

### 5.12 Cluster 调度器

**模块**: `cluster_scheduler` (`rtl/npu/cluster_scheduler.v`)
- 组合逻辑将 `CLUSTER_MODE` 和 `CLUSTER_MASK` 映射为各 cluster 使能
- 模式: MODE_SINGLE（目标=1）、MODE_DUAL（目标=2）、MODE_FULL/default（目标=6）
- Mask 过滤候选 cluster; 最多使能 `target_count` 个（最低位序的置位 bit 优先）
- 输出: `cluster_enable[5:0]`, `cluster_count[2:0]`, `schedule_valid`
- 状态: 已实现并验证（UVM 测试中 4 种模式均 PASS）。

### 5.13 计算核心（6-Cluster）

**模块**: `compute_core_6cluster` (`rtl/npu/compute_core_6cluster.v`)
- 实例化 6 个 `cluster_16x16` 模块
- 展平总线分发: 激活、部分和、权重、tile 时钟使能广播至所有 cluster
- 各 cluster 输出: `cluster_busy`, `cluster_valid`, `cluster_done`, `sum_out_flat`
- 流水线延迟: `PIPELINE_CYCLES = (TILE_ROWS×4) + (TILE_COLS×4) + 2`
- 状态: 已实现并验证。

### 5.14 PE 阵列

**层次**: `cluster_16x16` → `array_top` → `mac_tile_4x4` (× TILE_ROWS×TILE_COLS) → `mac_pe` (×16 per tile)

**mac_pe**: INT8 乘累加单元
- 寄存器: `act_reg[7:0]`, `weight_reg[7:0]`, `sum_out_reg[31:0]`
- `product[15:0] = $signed(act_reg) × $signed(weight_reg)`
- `sum_out = sum_in + product`
- 激活向右传递; 部分和向下传递（脉动流）
- 状态: 已实现并验证。

### 5.15 输出仲裁器

**模块**: `output_arbiter` (`rtl/npu/output_arbiter.v`)
- 收集各 cluster 的 `sum_out` 向量
- AGGREGATE_MODE=1: 所有使能 cluster 输出的 OR 合并
- 生成 `arb_valid`, `arb_sum_out_flat`, `arb_cluster_id`, `all_done`
- 状态: 已实现并验证。

### 5.16 性能计数器

**模块**: `perf_counter` (`rtl/npu/perf_counter.v`)
- 每次任务启动时（`task_active` 上升沿）计数器复位
- 可通过 NPU 寄存器文件读取（见 §6 地址映射）
- 计数器: cycle_count (64-bit), read_beats, write_beats, read_active_cycles, write_active_cycles, array_active_cycles, array_stall_cycles, MAC_count (64-bit), cluster_active_cycles, cluster_stall_cycles, cluster_cfg, WRITE_DATA_CYC, WRITE_TXN_CYC
- WRITE_DATA_CYC: 写事务期间的 WVALID && WREADY 周期
- WRITE_TXN_CYC: AW-to-B 事务窗口周期
- 状态: 已实现并验证。

### 5.17 运行时 Cluster 配置

- 通过 AXI-Lite 写 `CLUSTER_MODE` (0x88) 和 `CLUSTER_MASK` (0x8C) 进行配置
- Mode 值: 0=单 cluster, 1=双 cluster, 2=全 6 cluster, 3=mask 模式（最多 6 个，由 mask 过滤）
- Mask: 6-bit 位图，LSB=cluster 0
- 两个寄存器均为 RW; 可在任务之间更改
- 状态: 已实现并验证（`npu_cluster_mode_test` 和 cluster_mask_sweep 中所有模式均 PASS）。

### 5.18 时钟门控 / Tile 使能

- 通过 `cluster_tile_clk_en_all_flat` 向量实现逐 tile 时钟使能
- 目前所有 tile 始终使能（`array_clk_en = {N_TILES{1'b1}}`）
- `array_top` 生成 `gated_clk[ti] = clk && tile_clk_en_flat[ti]`
- 存在选择性 tile 功耗门控的基础设施; 功耗节省的验证待完成

---

## 6. Address map

### 6.1 SoC 存储器映射

| 地址范围 | 目标 | 大小 | 访问 |
|----------|------|------|------|
| `0x0000_0000 – 0x000F_FFFF` | 共享 RAM | 1 MB | CPU: 32-bit AXI-Lite RW; NPU: 256-bit AXI4 RW |
| `0x1000_0000 – 0x1000_00FF` | NPU 寄存器 | 256 字节 | CPU: 32-bit AXI-Lite RW/RO |
| 其他 | — | — | DECERR (2'b11) |

### 6.2 NPU 寄存器映射

基地址: `0x1000_0000`。所有寄存器 32-bit，字对齐（字节偏移 = 字偏移 × 4）。

#### 控制 / 状态

| 字节偏移 | 字偏移 | 名称 | 访问 | 描述 |
|----------|--------|------|------|------|
| 0x00 | 0 | CTRL | RW/RO | [0]=start (W1S), [1]=busy (RO), [2]=done (RO), [3]=error (RO), [4]=clear_error (W1S, 仅 !busy 时) |
| 0x04 | 1 | STATUS | RO | [7:0]=error_code |

#### 任务配置

| 字节偏移 | 名称 | 访问 | 描述 |
|----------|------|------|------|
| 0x08 | TASK_TYPE | RW | [2:0]=任务类型（0=Conv,1=FC,2=Pool,3=Requant,4=Add,5=GAP） |
| 0x0C | INPUT_ADDR | RW | 共享 RAM 中输入数据起始地址 |
| 0x10 | WEIGHT_ADDR | RW | 权重数据起始地址 |
| 0x14 | OUTPUT_ADDR | RW | 输出数据目标地址 |
| 0x18 | INPUT_BYTES | RW | 输入数据字节数 |
| 0x1C | WEIGHT_BYTES | RW | 权重数据字节数 |
| 0x20 | OUTPUT_BYTES | RW | 输出数据字节数 |
| 0x24 | DIM_IN | RW | [15:0]=H（输入高度）, [31:16]=W（输入宽度） |
| 0x28 | DIM_OUT | RW | [15:0]=C_IN（输入通道）, [31:16]=C_OUT（输出通道） |
| 0x2C | POSTPROC | RW | [0]=relu_en, [1]=pool_en |

#### 性能计数器（只读）

| 字节偏移 | 名称 | 描述 |
|----------|------|------|
| 0x30 | PERF_CYCLE_LO | 周期计数器，低 32 位 |
| 0x34 | PERF_CYCLE_HI | 周期计数器，高 32 位 |
| 0x38 | PERF_READ_BEATS | DMA 读 beat 数 |
| 0x3C | PERF_WRITE_BEATS | DMA 写 beat 数 |
| 0x40 | PERF_READ_ACTIVE | DMA 读活跃周期 |
| 0x44 | PERF_WRITE_ACTIVE | DMA 写活跃周期 |
| 0x48 | PERF_ARRAY_ACTIVE | 脉动阵列活跃周期 |
| 0x4C | PERF_ARRAY_STALL | 脉动阵列停顿周期 |
| 0x50 | PERF_MAC_LO | MAC 操作计数，低 32 位 |
| 0x54 | PERF_MAC_HI | MAC 操作计数，高 32 位 |
| 0x58 | PERF_CLUSTER_ACTIVE | Cluster 活跃周期 |
| 0x5C | PERF_CLUSTER_STALL | Cluster 停顿周期 |
| 0x60 | PERF_CLUSTER_CFG | Cluster 重配置计数 |
| **0xD0** | **PERF_WRITE_DATA_CYC** | 写数据周期（WVALID && WREADY） |
| **0xD4** | **PERF_WRITE_TXN_CYC** | 写事务周期（AW-to-B 窗口） |

#### 重量化参数

| 字节偏移 | 名称 | 访问 | 描述 |
|----------|------|------|------|
| 0x64 | REQUANT_SEL | RW | [1:0]=参数槽位选择（0-3） |
| 0x68 | REQUANT0_MULT | RW | 槽位 0 乘数 |
| 0x6C | REQUANT0_SHIFT | RW | 槽位 0 右移量 [5:0] |
| 0x70 | REQUANT1_MULT | RW | 槽位 1 乘数 |
| 0x74 | REQUANT1_SHIFT | RW | 槽位 1 移量 [5:0] |
| 0x78 | REQUANT2_MULT | RW | 槽位 2 乘数 |
| 0x7C | REQUANT2_SHIFT | RW | 槽位 2 移量 [5:0] |
| 0x80 | REQUANT3_MULT | RW | 槽位 3 乘数 |
| 0x84 | REQUANT3_SHIFT | RW | 槽位 3 移量 [5:0] |

#### Cluster 配置

| 字节偏移 | 名称 | 访问 | 描述 |
|----------|------|------|------|
| **0x88** | **CLUSTER_MODE** | RW | [1:0]=cluster 模式（0=单, 1=双, 2=全, 3=mask） |
| **0x8C** | **CLUSTER_MASK** | RW | [5:0]=cluster 使能掩码 |

#### 版本 / 能力（只读）

| 字节偏移 | 名称 | 值 | 描述 |
|----------|------|-----|------|
| 0x90 | VERSION | 0x0001_000A | R1a 寄存器映射版本 |
| 0x94 | CAPABILITY | 0x0000_7FE1 | 支持的功能位图（Conv5×5, Bias, Add, GAP, AddReLU, AddRequant, FC, Pool, Requant, ClusterCfg） |

#### 扩展任务参数

| 字节偏移 | 名称 | 访问 | 描述 |
|----------|------|------|------|
| 0x98 | CONV_CFG | RW | [5:0]=卷积 kernel/stride/pad 配置 |
| 0x9C | BIAS_ADDR | RW | 偏置数据基地址 |
| 0xA0 | BIAS_BYTES | RW | 偏置数据字节数 |
| 0xA4 | SRC1_ADDR | RW | 残差加法源 1 基地址 |
| 0xA8 | SRC1_BYTES | RW | 残差加法源 1 字节数 |
| 0xAC | ADD_CFG | RW | [3:0]=残差加法配置 |
| 0xB0 | GAP_CFG | RW | [25:0]=GAP 配置 |
| 0xB4 | POSTPROC_CFG | RW | 扩展后处理配置 |
| 0xB8 | ADD_SRC0_MULT | RW | 加法源 0 预对齐乘数 |
| 0xBC | ADD_SRC0_SHIFT | RW | 加法源 0 预对齐移量 [5:0] |
| 0xC0 | ADD_SRC1_MULT | RW | 加法源 1 预对齐乘数 |
| 0xC4 | ADD_SRC1_SHIFT | RW | 加法源 1 预对齐移量 [5:0] |
| 0xC8 | ADD_OUT_MULT | RW | 加法后 requant 乘数 |
| 0xCC | ADD_OUT_SHIFT | RW | 加法后 requant 移量 [5:0] |

---

## 7. Interrupt

### 7.1 当前实现

**当前设计没有专用的中断输出。** `npu_status[31:0]` 输出端口提供实时状态，但未作为 CPU 中断路由。

### 7.2 轮询模型

CPU/TB 通过 AXI-Lite 轮询 NPU CTRL 寄存器监控任务完成:
- **Bit[1] (busy)**: 任务执行中为高
- **Bit[2] (done)**: 任务成功完成时置高
- **Bit[3] (error)**: 任务失败时置高; 错误码在 STATUS[7:0]

轮询流程:
```
while (CTRL.busy) { 等待; }
if (CTRL.error) { 读 STATUS.error_code; 处理错误; }
else if (CTRL.done) { 读输出; 读性能计数器; 继续; }
```

### 7.3 性能计数器访问

所有性能计数器通过寄存器读取获取。无 DMA 或中断方式的计数器访问。

### 7.4 未来中断支持

添加中断输出引脚并连接到 CPU 中断输入作为潜在未来工作。`npu_status` 线已提供必要的状态信号; 将其作为中断边沿路由需要:
1. 在 `top.v` 中添加 `npu_irq` 输出
2. 连接到 PicoRV32 IRQ 输入
3. 可在 NPU 寄存器文件中添加中断使能/掩码寄存器

---

## 8. Error Handing

### 8.1 错误分类

#### 任务校验错误（task_checker）

| 错误码 | 描述 |
|--------|------|
| 0x01 | 无效任务类型（非 0-5） |
| 0x02 | 输入/权重/输出地址未对齐（须 64B 对齐） |
| 0x03 | 输入字节数超出 buffer 容量 |
| 0x04 | 权重字节数超出 buffer 容量 |
| 0x05 | 输出字节数超出 buffer 容量 |
| 0x06 | 无效维度参数（H=0, W=0 等） |
| 0x07 | Conv: 无效 kernel 大小或配置 |
| 0x08 | FC: tile 容量超出 |
| 0x09-0x0F | 保留 |

#### 运行时错误（npu_ctrl FSM）

| 错误码 | 描述 |
|--------|------|
| 0x10 | 忙时启动违规: 任务进行中写 CTRL.start |
| 0x11 | 忙时写违规: 任务进行中写寄存器 |

#### DMA 错误

| 错误码 | 来源 | 描述 |
|--------|------|------|
| 0x20 | dma_axi_reader | AXI RRESP 错误（读返回 SLVERR 或 DECERR） |
| 0x21 | dma_axi_reader | 地址未对齐 |
| 0x22 | dma_axi_reader | 内部: RLAST 不匹配 |
| 0x30 | dma_axi_writer | AXI BRESP 错误（写返回 SLVERR 或 DECERR） |
| 0x31 | dma_axi_writer | 地址未对齐 |

#### 共享 RAM 错误

- NPU 端口: 无效 burst 类型（非 INCR）、无效 size（非 5/256-bit）或未对齐地址 → SLVERR
- CPU 端口: 标准 AXI-Lite 错误响应

### 8.2 错误恢复

**清除错误**: NPU 空闲时（!busy）写 CTRL 寄存器 bit[4]=1。此操作同时清除 `error` 和 `done` 位。

**清除错误后**:
- CPU 必须重新配置所有任务参数（寄存器可能已损坏）
- CPU 写 CTRL bit[0]=1 启动新任务

**Done 状态恢复**:
- 无需显式清除; CPU 可直接写 CTRL bit[0]=1 启动下一任务
- 从 done 状态启动新任务时 RTL 自动清除 `done` 和 `error`

**恢复流程**:
```
1. 读 CTRL 寄存器
2. 若 error=1:
   a. 读 STATUS 寄存器获取 error_code
   b. 写 CTRL=0x10（clear_error）
   c. 重新配置所有任务寄存器
   d. 写 CTRL=0x01（start）
3. 若 done=1:
   a. 读取输出数据和性能计数器
   b. 写 CTRL=0x01（start）— 自动清除 done，启动下一任务
4. 若 busy=1:
   a. 等待 busy→0 或超时
   b. 若超时且未置 error: 硬件挂起; 发起复位
```

### 8.3 零字节和尾 Burst 处理

**零字节写**: DMA writer 对 `byte_count=0` 的处理为直接从 `S_IDLE` 跳转到 `S_DONE`，不发起任何 AXI 事务。`tb_dma_writer_zero_byte` 已验证。

**尾 burst**（部分填充的最后一 beat）: 最后一 beat 的 WSTRB 正确反映仅有效字节。`calc_wstrb()` 根据 `valid_bytes_this_beat` 计算精确字节选通掩码。`tb_dma_writer_tail_burst` 已验证。

**Producer-done 尾 burst**: 当 `producer_done=1` 且 `fifo_level < beats_in_burst` 时，DMA writer 使用 FIFO 中可用数据完成最后 burst，而非无限等待。修复由 `tb_dma_writer_hang_expose` 验证。

### 8.4 忙时写保护

当 `busy=1` 且 `error=0` 时，写任何寄存器（包括 CTRL）触发 `busy_write_violation`（error_code=0x11）。这保护当前任务不被寄存器损坏。

例外: 当 `error=1` 时，允许寄存器写（以允许恢复前的重新配置）。

---

## 附录: 验证状态

### A.1 验证环境

- **定向 Verilog 测试**: `sim/run_sim.sh`，单元和集成 testbench
- **UVM testbench**: `verif/uvm_top/`，基于 VCS，UVM-1.2
- **Golden 参考模型**: DPI-C 函数，位于 `verif/uvm_top/ref_model/`
- **Scoreboard**: 与 DPI-C golden 逐字节输出比对

### A.2 定向测试结果

| 类别 | 数量 | 结果 |
|------|------|------|
| DMA writer 定向测试 | 5 | PASS（backpressure, tail_burst, awlen_wlast, zero_byte, long_burst） |
| DMA 挂起暴露测试 | 1 | PASS（producer_done 修复已验证） |
| NPU 集成测试 | 3 | PASS（tb_npu_top, tb_task_requant, tb_shared） |
| **DMA + 集成小计** | **9** | **PASS** |

### A.3 UVM 测试结果

| 类别 | 数量 | 结果 |
|------|------|------|
| UVM smoke | 3 | PASS（conv, fc, requant） |
| 结构性 FC 测试 | 5 | PASS（full_array, full_cluster, mask_sweep, perf_scaling, back_to_back） |
| Conv cluster 诊断 | 2 | PASS（single_16oc, dual_32oc） |
| Conv 多窗口诊断 | 3 | PASS（1x1_multiwindow, 3x3_multiwindow, 5x5_singlewindow） |
| Cluster 模式测试 | 1 | 4/4 模式 PASS（single, dual, full, mask） |
| **UVM 小计** | **14** | **PASS** |

### A.4 性能验证

| 指标 | 值 | 状态 |
|------|-----|------|
| DMA 写入事务级利用率 | 80.00%（16-beat long burst） | 已验证 |
| DMA 写入数据周期（16 beats） | 16 | 已验证 |
| DMA 写入事务周期（16 beats） | 20 | 已验证 |
| 性能计数器非零（所有测试） | 已确认 | 已验证 |
| Cluster mask sweep（4 模式） | 全部 PASS | 已验证 |
| 背靠背任务执行 | 无需 workaround | 已验证 |
| Conv 多 cluster 数值正确性 | 4/4 模式 PASS | 已验证 |

**关于 80.00% 的说明**: 这是 AXI 写入**事务级**利用率，定义为 `write_data_cycles / write_txn_cycles`。系统级写入吞吐量受 32-bit `acc_buffer` / `store_pack` 路径独立限制。Phase C（`acc_buffer` 256-bit 位宽扩展）已暂缓。

### A.5 已知局限

| 局限 | 状态 |
|------|------|
| 系统级写入吞吐量（单 beat 约 12.5%） | 受 32-bit acc_buffer/store_pack 路径限制 |
| ResNet-20 完整 32 任务端到端 RTL 验证 | 待完成（foundation/directed 测试已至 R1i） |
| FPGA 综合与时序 | 待完成 |
| 代码覆盖率报告 | 待完成 |
| 低功耗门控验证 | 待完成 |

### A.6 已解决已知问题

| 问题 | 根因 | 修复 | 日期 |
|------|------|------|------|
| 背靠背启动被阻塞 | `write_new_start` 要求 `!done` | CTRL[0]=1 自动清除 done/error | 2026-06-24 |
| 0x88/0x8C 地址冲突 | 性能计数器与 cluster 配置共用地址 | 性能计数器移至 0xD0/0xD4 | 2026-06-24 |
| Conv 多 cluster 不匹配 | 误诊: 背靠背启动 bug | 澄清: 4 种模式均 PASS | 2026-06-25 |
| Conv 多窗口排空挂起 | DMA writer S_WAIT_DATA 尾 burst 死锁 | producer_done 机制 | 2026-06-25 |

---

*文档结束*
