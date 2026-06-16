# CPU+NPU SoC Functional Specification

本文档描述 `Project_npu` 当前 `CPU + NPU` 异构 SoC 的功能规格。文档内容以当前 RTL 实现和正式 6-cluster SoC 基线为准，主要参考：

- `rtl/soc/top.v`
- `rtl/bus/axi_interconnect.v`
- `rtl/soc/shared_ram.v`
- `rtl/npu/npu_top.v`
- `rtl/npu/npu_ctrl.v`
- `rtl/npu/task_checker.v`
- `docs/SOC_6CLUSTER_ARCHITECTURE.md`
- `docs/LENET_MNIST_SPEC.md`

## 1. Main Feature

本 SoC 面向 LeNet(MNIST) 推理任务，采用 `PicoRV32 + NPU + shared memory` 的异构处理结构。CPU 负责控制寄存器配置和任务调度，NPU 负责卷积、池化、全连接、ReLU、requant 等神经网络计算任务。

主要特性如下：

| Feature | Specification |
| --- | --- |
| SoC 架构 | `PicoRV32 CPU + AXI interconnect + shared RAM + NPU` |
| CPU | PicoRV32，AXI-Lite master 接口 |
| 控制总线 | 32-bit AXI-Lite |
| NPU DMA 数据总线 | 256-bit AXI4 INCR burst |
| 共享内存 | 默认 `32768 x 256-bit beat`，容量 `1 MB` |
| NPU 阵列 | `6 x 16x16 PE cluster` |
| PE 总数 | `1536` |
| 峰值算力 | `0.6144 TOPS @ 200 MHz` |
| 数据类型 | `INT8 activation/weight`，`INT32 accumulate/output` |
| 目标网络 | LeNet(MNIST) |
| 正式 SoC 验证方式 | testbench AXI-Lite master 模拟 CPU 配置，shared memory preload 模拟软件数据准备 |

当前实现支持的主要任务类型：

| Task Type | Encoding | Description |
| --- | ---: | --- |
| Conv | `2'd0` | 5x5 valid convolution，INT8 x INT8 -> INT32 |
| FC | `2'd1` | fully-connected，复用 6-cluster compute hierarchy |
| Pool | `2'd2` | 2x2 max pooling，stride=2 |
| Requant | `2'd3` | INT32 -> INT8，layer-wise multiplier/shift |

## 2. Overview

SoC 顶层由 CPU、AXI interconnect、shared RAM 和 NPU 四个主要部分组成。

```text
                 +----------------+
                 |    PicoRV32    |
                 | AXI-Lite Master|
                 +-------+--------+
                         |
                         | 32-bit AXI-Lite
                         v
                 +----------------+
                 | AXI Interconnect|
                 +---+--------+---+
                     |        |
       32-bit AXI-Lite        | 32-bit AXI-Lite
                     |        |
                     v        v
              +-----------+  +----------------+
              | Shared RAM|  | NPU Registers |
              | CPU Port  |  |   npu_ctrl    |
              +-----+-----+  +-------+--------+
                    ^                |
                    |                | task/control
                    |                v
                    |        +----------------+
                    |        |    NPU Core    |
                    |        | DMA + Buffer + |
                    |        | 6-cluster MAC  |
                    |        +-------+--------+
                    |                |
                    +----------------+
                     256-bit AXI4 DMA
```

SoC 有两条主要访问路径：

1. CPU AXI-Lite 路径：CPU 或 testbench AXI-Lite master 访问 shared RAM 和 NPU 控制寄存器。
2. NPU DMA 路径：NPU 通过 256-bit AXI4 master 直接从 shared RAM 读取输入/权重，并将计算结果写回 shared RAM。

正式 top-level 验证中，PicoRV32 核保留在 SoC 中，但 testbench 可通过 `tb_axil_enable` 接管 AXI-Lite master 端口，用于快速配置 NPU 寄存器和读写共享内存。

## 3. Interface

### 3.1 SoC 外部接口

SoC 顶层模块为 `top`。外部接口主要包括时钟复位、testbench AXI-Lite 接管接口和调试状态输出。

| Signal | Width | IO | Description |
| --- | ---: | --- | --- |
| `clk` | 1 | I | SoC 全局时钟 |
| `rst_n` | 1 | I | 低有效异步复位 |
| `tb_axil_enable` | 1 | I | testbench AXI-Lite master 接管使能；为 `1` 时 CPU reset，外部 testbench 驱动 AXI-Lite |
| `tb_awvalid` | 1 | I | testbench AXI-Lite write address valid |
| `tb_awready` | 1 | O | testbench AXI-Lite write address ready |
| `tb_awaddr` | 32 | I | testbench AXI-Lite write address |
| `tb_wvalid` | 1 | I | testbench AXI-Lite write data valid |
| `tb_wready` | 1 | O | testbench AXI-Lite write data ready |
| `tb_wdata` | 32 | I | testbench AXI-Lite write data |
| `tb_wstrb` | 4 | I | testbench AXI-Lite byte write strobe |
| `tb_bvalid` | 1 | O | testbench AXI-Lite write response valid |
| `tb_bready` | 1 | I | testbench AXI-Lite write response ready |
| `tb_bresp` | 2 | O | testbench AXI-Lite write response |
| `tb_arvalid` | 1 | I | testbench AXI-Lite read address valid |
| `tb_arready` | 1 | O | testbench AXI-Lite read address ready |
| `tb_araddr` | 32 | I | testbench AXI-Lite read address |
| `tb_rvalid` | 1 | O | testbench AXI-Lite read data valid |
| `tb_rready` | 1 | I | testbench AXI-Lite read data ready |
| `tb_rdata` | 32 | O | testbench AXI-Lite read data |
| `tb_rresp` | 2 | O | testbench AXI-Lite read response |
| `cpu_trap` | 1 | O | PicoRV32 trap/debug 输出 |
| `npu_status` | 32 | O | NPU 快速状态，当前格式为 `{24'h0, error, done, busy, 1'b0}` |

### 3.2 SoC 内部接口

#### 3.2.1 CPU 到 AXI Interconnect

| Signal Name | Width | IO | Purpose |
| --- | ---: | --- | --- |
| `cpu_aw*` | 32-bit addr | CPU -> Interconnect | AXI-Lite write address channel |
| `cpu_w*` | 32-bit data | CPU -> Interconnect | AXI-Lite write data channel |
| `cpu_b*` | 2-bit resp | Interconnect -> CPU | AXI-Lite write response channel |
| `cpu_ar*` | 32-bit addr | CPU -> Interconnect | AXI-Lite read address channel |
| `cpu_r*` | 32-bit data | Interconnect -> CPU | AXI-Lite read data channel |

CPU 侧 AXI-Lite master 可由 PicoRV32 或 testbench master 驱动。`tb_axil_enable=1` 时，PicoRV32 reset，testbench 端口接入 interconnect。

#### 3.2.2 AXI Interconnect 到 NPU 寄存器

| Signal Name | Width | IO | Purpose |
| --- | ---: | --- | --- |
| `npu_aw*` | 32-bit addr | Interconnect -> NPU | NPU register write address |
| `npu_w*` | 32-bit data | Interconnect -> NPU | NPU register write data |
| `npu_b*` | 2-bit resp | NPU -> Interconnect | NPU register write response |
| `npu_ar*` | 32-bit addr | Interconnect -> NPU | NPU register read address |
| `npu_r*` | 32-bit data | NPU -> Interconnect | NPU register read data |

该接口连接到 `npu_ctrl`，地址窗口为 `0x1000_0000 ~ 0x1000_00FF`。

#### 3.2.3 AXI Interconnect 到 Shared RAM CPU Port

| Signal Name | Width | IO | Purpose |
| --- | ---: | --- | --- |
| `mem_aw*` | 32-bit addr | Interconnect -> Shared RAM | CPU-side memory write address |
| `mem_w*` | 32-bit data | Interconnect -> Shared RAM | CPU-side memory write data |
| `mem_b*` | 2-bit resp | Shared RAM -> Interconnect | CPU-side memory write response |
| `mem_ar*` | 32-bit addr | Interconnect -> Shared RAM | CPU-side memory read address |
| `mem_r*` | 32-bit data | Shared RAM -> Interconnect | CPU-side memory read data |

CPU 通过该端口以 32-bit word 访问同一份物理 shared RAM。shared RAM 内部实际组织为 256-bit beat，CPU 地址的 `addr[4:2]` 用于选择 256-bit beat 内的 32-bit word lane。

#### 3.2.4 NPU DMA 到 Shared RAM AXI4 Port

| Signal Name | Width | IO | Purpose |
| --- | ---: | --- | --- |
| `npu_m_ar*` / `mem4_ar*` | 32-bit addr | NPU -> Shared RAM | AXI4 read address channel |
| `npu_m_r*` / `mem4_r*` | 256-bit data | Shared RAM -> NPU | AXI4 read data channel |
| `npu_m_aw*` / `mem4_aw*` | 32-bit addr | NPU -> Shared RAM | AXI4 write address channel |
| `npu_m_w*` / `mem4_w*` | 256-bit data | NPU -> Shared RAM | AXI4 write data channel |
| `npu_m_b*` / `mem4_b*` | 2-bit resp | Shared RAM -> NPU | AXI4 write response channel |

DMA 数据面为 256-bit，支持 aligned `INCR` burst。当前 shared RAM 检查：

- `arsize/awsize = 3'd5`，即 32-byte beat
- `arburst/awburst = 2'b01`，即 INCR burst
- NPU DMA 地址 32-byte 对齐
- burst 范围不超过 shared RAM 容量

#### 3.2.5 NPU 内部计算接口

| Signal Name | Width | IO | Purpose |
| --- | ---: | --- | --- |
| `cluster_enable` | 6 | Scheduler -> Compute Core | 6 个 cluster 的使能 mask |
| `cluster_act_in_flat` | `CLUSTER_COUNT x CLUSTER_ACT_W` | NPU datapath -> Compute Core | 每个 cluster 的 activation 输入 |
| `cluster_weight_flat` | `CLUSTER_COUNT x CLUSTER_WGT_W` | NPU datapath -> Compute Core | 每个 cluster 的 INT8 weight 输入 |
| `cluster_sum_in_flat` | `CLUSTER_COUNT x CLUSTER_SUM_W` | NPU datapath -> Compute Core | 每个 cluster 的 INT32 partial sum 输入 |
| `cluster_sum_out_flat` | `CLUSTER_COUNT x CLUSTER_SUM_W` | Compute Core -> Arbiter | 每个 cluster 的 INT32 结果输出 |
| `cluster_valid` | 6 | Compute Core -> Arbiter | cluster 输出有效 |
| `cluster_done` | 6 | Compute Core -> Arbiter | cluster 当前 launch 完成 |
| `arb_sum_out_flat` | `CLUSTER_SUM_W` | Arbiter -> NPU datapath | 仲裁后的 INT32 输出 |
| `arb_cluster_id` | 3 | Arbiter -> NPU datapath | 当前输出来源 cluster id |

其中 `CLUSTER_COUNT=6`，`CLUSTER_ACT_W/CLUSTER_WGT_W/CLUSTER_SUM_W` 由 NPU 阵列参数推导。正式文档口径为 6 个 cluster，每个 cluster 对应 `16x16 PE` 的计算单元。

## 4. Information Flow

### 4.1 配置寄存器路径

配置路径用于 CPU 或 testbench 启动 NPU 任务。

```text
CPU / TB AXI-Lite master
  -> axi_interconnect
  -> npu_ctrl register file
  -> task_checker
  -> npu_top FSM
```

典型配置流程：

1. CPU 写入 `TASK_TYPE`、输入地址、权重地址、输出地址。
2. CPU 写入输入/权重/输出 byte count。
3. CPU 写入输入尺寸、输入/输出 channel 数。
4. CPU 写入 postprocess 和 requant 参数。
5. CPU 向 `CTRL.start` 写 `1`。
6. `npu_ctrl` 锁存任务配置，并触发 `task_checker`。
7. `task_checker` 检查任务类型、地址对齐、地址范围、byte count、维度合法性和 requant 参数。
8. 检查通过后，`npu_top` 进入执行状态；检查失败则置 `error` 和 `error_code`。

### 4.2 NPU DMA 读数据路径

NPU 通过 DMA 从 shared RAM 读取输入 feature map 和 weight。

```text
shared RAM
  -> 256-bit AXI4 read data
  -> act_read_path / weight_read_path
  -> npu_buffer / weight load register
  -> conv/fc compute datapath
```

实现中 activation 和 weight 各自有 read path，最终通过 NPU 内部 read mux 共享同一个 AXI4 read master 端口。DMA 读出的数据以 256-bit beat 进入本地 buffer 或权重装载寄存器。

### 4.3 NPU 计算路径

Conv 和 FC 正式执行流都走 6-cluster compute hierarchy。

```text
npu_buffer / weight register
  -> conv/fc frontend and FSM
  -> cluster_scheduler
  -> compute_core_6cluster
  -> 6 x cluster_16x16
  -> output_arbiter
  -> postproc / requant / writeback datapath
```

其中：

- `cluster_scheduler` 根据 `CLUSTER_MODE` 和 `CLUSTER_MASK_REQ` 产生 `cluster_enable[5:0]`。
- `compute_core_6cluster` 真正例化 6 个 `cluster_16x16`。
- 每个 `cluster_16x16` 内部复用 `array_top`，阵列规模为 `16x16 PE`。
- `output_arbiter` 汇聚多个 cluster 的结果，并输出给后续写回路径。

### 4.4 NPU DMA 写回路径

计算完成后，NPU 将 INT32 结果或 INT8 requant 结果写回 shared RAM。

```text
postproc / requant / result buffer
  -> dma_axi_writer
  -> 256-bit AXI4 write data
  -> axi_interconnect DMA pass-through
  -> shared RAM
```

写回后，CPU 或 testbench 可以通过 32-bit AXI-Lite memory port 读取 shared RAM 中的结果。

### 4.5 LeNet 层级数据流

当前固定 LeNet 数据流为：

```text
Input(28x28x1)
  -> Conv1(20, 5x5, valid)
  -> Pool1(2x2 max)
  -> Requant(INT32 -> INT8)
  -> Conv2(50, 5x5, valid)
  -> Pool2(2x2 max)
  -> Requant(INT32 -> INT8)
  -> FC1(800 -> 500)
  -> ReLU
  -> Requant(INT32 -> INT8)
  -> FC2(500 -> 10)
  -> Argmax
```

`Argmax` 当前由 testbench 或软件侧完成，不作为 NPU RTL 内部固定任务。

## 5. Sub Function

### 5.1 CPU

CPU 采用 PicoRV32，作为 SoC 的通用控制处理器。

主要功能：

- 通过 AXI-Lite master 访问 shared RAM。
- 通过 AXI-Lite master 配置 NPU 寄存器。
- 可轮询 NPU `busy/done/error` 状态。
- 可读取 NPU performance counter。
- 可在完整软件环境中承担任务编排、地址管理、结果读取和 argmax 等工作。

当前正式 SoC 验证中，为了缩短验证路径，testbench 可接管 CPU AXI-Lite master 行为。该方式模拟 CPU 软件配置流程，但不要求 PicoRV32 固件已经完整驱动 LeNet。

### 5.2 NPU

NPU 是 SoC 中的神经网络加速器，顶层模块为 `npu_top`。

NPU 内部主要子模块如下：

| Module | Function |
| --- | --- |
| `npu_ctrl` | AXI-Lite register file，任务启动、状态管理、性能寄存器读取 |
| `task_checker` | 任务参数合法性检查，防止非法 DMA/compute 启动 |
| `act_read_path` | 通过 AXI4 DMA 读取 activation/input 数据 |
| `weight_read_path` | 通过 AXI4 DMA 读取 weight 数据 |
| `npu_buffer` | 本地 activation/data buffer |
| `block_scheduler` | 生成 block 级输入、权重、输出地址和 byte count |
| `conv_frontend` | Conv 窗口/数据组织相关前端逻辑 |
| `cluster_scheduler` | 根据 cluster mode 和 mask 选择启用 cluster |
| `compute_core_6cluster` | 6 个 `cluster_16x16` 的正式计算核心 |
| `cluster_16x16` | 单个 `16x16 PE` cluster，内部复用 `array_top` |
| `output_arbiter` | 多 cluster 输出聚合与仲裁 |
| `postproc` | ReLU/Pool 等后处理 |
| `requant_i32_to_i8` | INT32 到 INT8 的 layer-wise requant |
| `dma_axi_writer` | 通过 AXI4 DMA 将结果写回 shared RAM |
| `perf_counter` | 统计 cycle、MAC、AXI beat、array/cluster active/stall 等性能指标 |

NPU 控制行为：

- 一次 `start` 只执行一条任务。
- `busy=1` 时禁止继续写配置寄存器或再次 start。
- 参数检查必须先于 DMA 和 compute 启动。
- `done=1` 表示任务数据路径、后处理、写回和性能计数冻结均已完成。
- `error=1` 表示配置、协议或任务执行异常，需要软件处理。

NPU 当前正式支持的 cluster mode：

| Mode | Encoding | Enabled Cluster Count |
| --- | ---: | ---: |
| Single | `2'd0` | 1 |
| Dual | `2'd1` | 2 |
| Full | `2'd2` 或其他 | 6 |

### 5.3 AXI 总线

AXI interconnect 负责 CPU 控制面地址 decode 和 NPU DMA 到 memory 的 pass-through。

CPU AXI-Lite decode 规则：

- 地址满足 `(addr & 32'hFFFF_FF00) == 32'h1000_0000` 时访问 NPU register window。
- 地址 `addr[31:20] == 12'h000` 时访问 shared RAM。
- 其他地址返回 decode error。

当前 AXI 支持边界：

| Path | Protocol | Width | Support Scope |
| --- | --- | ---: | --- |
| CPU -> shared RAM | AXI-Lite subset | 32-bit | 单 beat 读写，byte strobe |
| CPU -> NPU registers | AXI-Lite subset | 32-bit | 寄存器读写，非法寄存器返回 SLVERR |
| NPU DMA -> shared RAM | AXI4 subset | 256-bit | aligned INCR burst |

当前实现不声明为完整通用 AXI4/AXI-Lite IP，而是项目内受控子集实现。

## 6. 地址映射

### 6.1 SoC AXI 地址映射

| Address Range | Target | Access Width | Description |
| --- | --- | ---: | --- |
| `0x0000_0000 ~ 0x000F_FFFF` | Shared RAM | CPU 32-bit / NPU 256-bit | 1 MB shared memory |
| `0x1000_0000 ~ 0x1000_00FF` | NPU registers | CPU 32-bit AXI-Lite | NPU control/status/performance registers |
| Others | Decode error | N/A | Interconnect returns DECERR |

### 6.2 Shared RAM 地址组织

Shared RAM 物理组织为 `32768 x 256-bit beat`。

| Address Bits | Meaning |
| --- | --- |
| `addr[19:5]` | 256-bit beat index |
| `addr[4:2]` | 32-bit word lane inside 256-bit beat |
| `addr[1:0]` | byte offset inside 32-bit word |

NPU DMA 访问要求 32-byte 对齐，因此 NPU DMA base address 的 `addr[4:0]` 必须为 `0`。`task_checker` 对 NPU task 的 input/output/weight base address 进一步要求 64-byte 对齐，用于满足当前项目的 burst 和布局约束。

### 6.3 LeNet 默认内存地址图

| Region | Base Address | Description |
| --- | ---: | --- |
| Input image | `0x0000_0100` | `28x28x1` INT8 input |
| Conv1 weights | `0x0000_1000` | Conv1 INT8 weights |
| Conv1 output / Pool1 input | `0x0000_4000` | INT32 feature map |
| Pool1 output / Conv2 input | `0x0001_8000` | INT32/INT8 handoff region |
| Conv2 weights | `0x0002_0000` | Conv2 INT8 weights |
| Conv2 output / Pool2 input | `0x0006_0000` | INT32 feature map |
| Pool2 output / FC1 input | `0x0008_0000` | INT32/INT8 handoff region |
| FC1 weights | `0x0009_0000` | FC1 INT8 weights |
| FC1 output / FC2 input | `0x000F_2000` | INT32/INT8 handoff region |
| FC2 weights | `0x000F_3000` | FC2 INT8 weights |
| Final logits | `0x000F_5000` | FC2 INT32 output logits |

### 6.4 NPU store-path 写回契约

NPU 写回路径固定为：

```text
acc_buffer 32-bit word
  -> npu_top FSM_STORE pack
  -> dma_axi_writer 256-bit AXI4 INCR burst
  -> shared RAM 32768 x 256-bit beat
```

正式 packing 规则：

- `acc_buffer` 以 32-bit word 为单位保存 Conv / FC / Requant 写回数据。
- `FSM_STORE` 按递增 word index 读取并打包。
- `store_pack_lane=0..7` 对应 256-bit beat 的低到高 32-bit lane。
- 每 8 个 32-bit word 形成一个 256-bit beat。
- `store_words_active = ceil(store_bytes_active / 4)`。
- `dma_axi_writer` 使用实际 `byte_count` 生成最后一拍 `WSTRB`，低位连续 byte 有效。
- Requant INT8 输出允许最后一组不是 4B 整数倍；最后 packed word 中多余 byte 由 `WSTRB` 屏蔽。

当前验证入口：

```text
tb/unit/tb_store_pack_path.v
```

该入口直接实例化 `npu_top` 并观测真实 `FSM_STORE -> dma_axi_writer` 输出，覆盖 Conv-like、FC-like、Requant-like 三类写回和 partial beat `WSTRB`。

## 7. 中断 / 异常

当前顶层没有连接外部 interrupt output。CPU 或 testbench 通过轮询 NPU control/status registers 判断任务状态。

### 7.1 NPU 状态位

| Signal/Register Bit | Meaning |
| --- | --- |
| `busy` | NPU 正在执行任务或正在做任务检查 |
| `done` | 任务完成 |
| `error` | 任务失败或非法访问 |
| `error_code` | 错误原因编码 |

### 7.2 Task Checker 错误码

| Error Code | Name | Description |
| ---: | --- | --- |
| `0x00` | `ERR_NONE` | 无错误 |
| `0x01` | `ERR_INVALID_TASK_TYPE` | 非法 task type |
| `0x02` | `ERR_ZERO_BYTES` | 必要 byte count 为 0 |
| `0x03` | `ERR_NULL_ADDR` | 必要地址为 0 |
| `0x04` | `ERR_ADDR_ALIGN` | 地址未满足 64-byte 对齐 |
| `0x05` | `ERR_ADDR_BOUNDS` | 地址不在 shared RAM 合法窗口内 |
| `0x06` | `ERR_ADDR_OVERFLOW` | 地址加长度后越界或溢出 |
| `0x07` | `ERR_CONV_PARAM` | Conv 参数非法，例如输入尺寸小于 5x5 |
| `0x08` | `ERR_POOL_PARAM` | Pool 参数非法，例如输入宽高不是偶数 |
| `0x09` | `ERR_DIM_RELATION` | 输入/输出 channel 维度非法 |
| `0x0A` | 保留未用 | 当前 RTL 不再定义该错误码，保留数值空洞以避免和既有调试记录混淆 |
| `0x0B` | `ERR_REQUANT_PARAM` | Requant 参数非法 |

### 7.3 Control FSM 错误码

| Error Code | Description |
| ---: | --- |
| `0x10` | `busy=1` 时重复写 `CTRL.start` |
| `0x11` | `busy=1` 且非 error 状态下写配置寄存器 |

异常处理建议：

1. 软件读取 `STATUS.error_code` 定位错误。
2. 若 `busy=0`，向 `CTRL[4]` 写 `1` 清除 error/done 状态。
3. 重新写入合法配置后再次 start。

## 8. 寄存器列表

NPU register window base address 为 `0x1000_0000`，寄存器为 32-bit 宽度。下表 offset 为相对 NPU base 的 byte offset。

| Offset | Register | R/W | Bits | Description |
| ---: | --- | --- | --- | --- |
| `0x00` | `CTRL` | R/W | `[0] start`, `[1] busy`, `[2] done`, `[3] error`, `[4] clear_error` | 写 `[0]=1` 启动任务；读返回状态；写 `[4]=1` 在非 busy 时清除 error/done |
| `0x04` | `STATUS` | R | `[7:0] error_code` | 错误码 |
| `0x08` | `TASK_TYPE` | R/W | `[1:0] task_type` | `0=Conv`, `1=FC`, `2=Pool`, `3=Requant` |
| `0x0C` | `INPUT_ADDR` | R/W | `[31:0]` | 输入数据 base address |
| `0x10` | `WEIGHT_ADDR` | R/W | `[31:0]` | 权重 base address；Pool/Requant 可不使用 |
| `0x14` | `OUTPUT_ADDR` | R/W | `[31:0]` | 输出数据 base address |
| `0x18` | `INPUT_BYTES` | R/W | `[31:0]` | 输入 byte count |
| `0x1C` | `WEIGHT_BYTES` | R/W | `[31:0]` | 权重 byte count；Pool/Requant 可为 0 |
| `0x20` | `OUTPUT_BYTES` | R/W | `[31:0]` | 输出 byte count |
| `0x24` | `DIM_IN` | R/W | `[15:0] input_h`, `[31:16] input_w` | 输入 feature map 高/宽 |
| `0x28` | `DIM_OUT` | R/W | `[15:0] input_c`, `[31:16] output_c` | 输入/输出 channel 数 |
| `0x2C` | `POSTPROC` | R/W | `[0] relu_en`, `[1] pool_en` | 后处理控制 |
| `0x30` | `PERF_CYCLE_LO` | R | `[31:0]` | cycle counter low |
| `0x34` | `PERF_CYCLE_HI` | R | `[31:0]` | cycle counter high |
| `0x38` | `PERF_READ_BEATS` | R | `[31:0]` | AXI read beat count |
| `0x3C` | `PERF_WRITE_BEATS` | R | `[31:0]` | AXI write beat count |
| `0x40` | `PERF_READ_ACTIVE` | R | `[31:0]` | AXI read active cycles |
| `0x44` | `PERF_WRITE_ACTIVE` | R | `[31:0]` | AXI write active cycles |
| `0x48` | `PERF_ARRAY_ACTIVE` | R | `[31:0]` | array active cycles |
| `0x4C` | `PERF_ARRAY_STALL` | R | `[31:0]` | array stall cycles |
| `0x50` | `PERF_MAC_LO` | R | `[31:0]` | MAC count low |
| `0x54` | `PERF_MAC_HI` | R | `[31:0]` | MAC count high |
| `0x58` | `PERF_CLUSTER_ACTIVE` | R | `[31:0]` | cluster active cycles |
| `0x5C` | `PERF_CLUSTER_STALL` | R | `[31:0]` | cluster stall cycles |
| `0x60` | `PERF_CLUSTER_CFG` | R | `[31:0]` | cluster mode/mask 相关性能配置快照 |
| `0x64` | `REQUANT_SEL` | R/W | `[1:0]` | 当前任务使用的 requant 参数 slot |
| `0x68` | `REQUANT0_MULT` | R/W | `[31:0]` | requant slot 0 multiplier |
| `0x6C` | `REQUANT0_SHIFT` | R/W | `[5:0]` | requant slot 0 shift |
| `0x70` | `REQUANT1_MULT` | R/W | `[31:0]` | requant slot 1 multiplier |
| `0x74` | `REQUANT1_SHIFT` | R/W | `[5:0]` | requant slot 1 shift |
| `0x78` | `REQUANT2_MULT` | R/W | `[31:0]` | requant slot 2 multiplier |
| `0x7C` | `REQUANT2_SHIFT` | R/W | `[5:0]` | requant slot 2 shift |
| `0x80` | `REQUANT3_MULT` | R/W | `[31:0]` | requant slot 3 multiplier |
| `0x84` | `REQUANT3_SHIFT` | R/W | `[5:0]` | requant slot 3 shift |
| `0x88` | `CLUSTER_MODE` | R/W | `[1:0]` | runtime cluster mode；`0=single`, `1=dual`, `2=full`, `3=mask` |
| `0x8C` | `CLUSTER_MASK` | R/W | `[5:0]` | runtime cluster request mask；reset default 来自 `NPU_CLUSTER_MASK_REQ` |

寄存器访问约束：

- 配置寄存器仅允许在 `busy=0` 或 `error=1` 时写入。
- performance registers 为只读，由 NPU 内部性能计数器更新。
- 未定义寄存器读写返回 AXI-Lite SLVERR。
- `CTRL.start` 启动后，配置会锁存到任务执行寄存器；执行过程中修改配置会报错。
- `CLUSTER_MODE / CLUSTER_MASK` 是 runtime config；Verilog parameter 仅作为 reset default。
