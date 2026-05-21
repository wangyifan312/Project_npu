# CPU+NPU 异构处理器架构规格说明

本文件作为后续 RTL 设计、验证和设计文档的统一基线。

配套架构框图见 [cpu_npu_architecture.png](/root/Project_npu/cpu_npu_architecture.png)。

## 1. 设计目标

- 面向赛题三的 `CPU + NPU` 异构处理器实现。
- `CPU` 负责任务配置与控制，`NPU` 负责数据搬运与计算。
- 支持 `AXI-Lite` 控制通路和 `AXI4 burst` 数据通路。
- 以 `LeNet-style` 推理链路为应用背景，但硬件能力按固定子集收敛。
- 首版优先完成可验证、可扩展、适合 RTL 闭环的实现。

## 2. 顶层架构

### 2.1 系统组成

- `PicoRV32 CPU`
- `NPU` 加速器
- `AXI-Lite` 控制接口
- `AXI4` 共享总线
- `系统主存 / Data RAM`

### 2.2 角色划分

- `CPU`
  - 配置任务参数
  - 启动 NPU
  - 轮询 `busy/done/error`
  - 读取结果区和性能计数器
- `NPU`
  - 执行参数检查
  - 自主搬运激活和权重
  - 完成卷积、全连接、池化相关计算
  - 将结果写回主存

### 2.3 总线接口

- `CPU -> NPU`：`AXI-Lite`
- `NPU -> 主存`：`AXI4 master`
- 系统主设备：
  - `CPU`
  - `NPU(内部 DMA)`

## 3. NPU 外部抽象

对 CPU 而言，NPU 是一个“一次执行一条任务”的设备。

CPU 只负责：

1. 写统一寄存器区
2. 写 `start=1`
3. 轮询状态
4. 读取结果和统计数据

CPU 不感知以下内部细节：

- 双缓冲 `bank A/B`
- block 分块执行
- DMA 预取阶段
- bank 切换
- 内部流水调度

## 4. NPU 内部模块划分

### 4.1 主控制与状态

- `npu_ctrl`
  - 任务接受
  - 参数锁存
  - 内部初始化
  - block 调度
  - bank 切换
  - 完成和异常处理
- `task_checker`
  - 参数与地址合法性检查
- `status_error_regs`
  - `busy/done/error/error_code`

### 4.2 内部 DMA

- `dma_read_path`
  - `act_read_path`
  - `weight_read_path`
- `dma_write_path`

约束如下：

- `act_read_path` 和 `weight_read_path` 内部逻辑分开
- 对外共享一个 `AXI4` 读主口
- 不做复杂动态仲裁
- 由主状态机按固定阶段调度读激活或读权重
- 写回路径独立，对外走 AXI4 写通道

### 4.3 本地存储

三块独立私有 buffer，每块采用双缓冲（bank A / bank B）：

| Buffer | 单 Bank 大小 | 双缓冲总计 | 数据宽度 | 典型容纳 |
|--------|-------------|-----------|----------|----------|
| `act buffer` | 16 KB | 32 KB | 4B (32-bit, v1) / 64B (512-bit, future) | 20×20×32 激活 (INT8) |
| `weight buffer` | 32 KB | 64 KB | 4B (32-bit, v1) / 64B (512-bit, future) | 5×5×32×64 权重 (INT8) |
| `acc/output buffer` | 16 KB | 32 KB | 4B (32-bit, v1) / 256B (2048-bit, future) | 16×16×16 输出 (INT32) |

共同特征：

- CPU 不可直接访问
- 由 NPU 内部维护 bank 状态
- **当前版本 (v1)**: act/weight/acc buffer 统一使用 32-bit 位宽 (`BUF_DATA_W=32`)，为功能模型。
- **未来版本**: act buffer 和 weight buffer 位宽对齐 AXI4 单 beat (64B = 512-bit)；acc buffer 位宽匹配 64 个 MAC 并行输出 (64 × 32-bit = 2048-bit)

双缓冲目的：

- 支持 `load / compute / store` 三段流水重叠
- 一个 bank 被计算模块使用时，另一个 bank 可被 DMA 填充/排空

### 4.4 输入前端

- `conv_frontend`
  - 固定支持 `5x5 / stride=1 / valid`
  - 负责卷积窗口生成和数据整理
- `fc_frontend`
  - 负责向量/矩阵整理

### 4.5 计算与后处理

- `array_top`
  - 共用主乘加阵列
  - `Conv` 和 `FC` 共用
- `postproc`
  - `ReLU`
  - `2x2 MaxPool(optional), stride=2`

### 4.6 观测与统计

- `perf_counter`
  - 周期统计
  - 带宽统计
  - 阵列利用率统计

## 5. 阵列结构与低功耗

### 5.1 阵列规模

- 基础计算单元：`4x4 tile`
- 顶层目标规模：`64x64`
- 组织方式：`16 x 16` 个 `4x4 tile`

### 5.2 低功耗策略

- 首版重点实现阵列时钟门控
- 门控粒度：每个 `4x4 tile`
- 当前任务不参与计算的 tile 可以关时钟

不纳入首版主线：

- DFS
- 复杂电源域
- DMA/控制器细粒度门控

## 6. 任务模型

### 6.1 一次启动的语义

- 一次 `start` 只执行一条任务
- `busy=1` 时再次 `start`：
  - 不接受新任务
  - 置 `error`
  - 写对应 `error_code`

### 6.2 支持的任务类型

首版支持：

- `Conv`
- `FC`
- `Pool`

说明：

- `Conv` 和 `FC` 共用同一套主阵列
- `Pool` 也可作为输出后处理开关存在

### 6.3 任务内部执行方式

- CPU 提交任务全局参数
- NPU 内部自行拆成多个 `block`
- CPU 不参与 block 级控制

## 7. 数据精度与输出格式

- `activation = INT8`
- `weight = INT8`
- `accumulate = INT32`
- 首版输出写回主存格式：`INT32`

这样满足：

- 主计算按 `INT8 x INT8 -> INT32` 口径实现
- 首版结果保留 `INT32` 便于调试和验证

## 8. 算子能力边界

### 8.1 Conv

首版固定支持：

- `kernel = 5x5`
- `stride = 1`
- `padding = valid`

不支持：

- 任意核大小
- 任意 stride
- 任意 padding

### 8.2 FC

当前版本支持 `FC` 任务，且已经完成功能级验证。

- 使用同一套主乘加阵列
- 不设计专用 FC 阵列
- 当前功能路径由 `npu_top` 内部 FC 执行流承担
- 输入在进入主阵列前执行 `INT32 -> saturating INT8`
- `fc_frontend` 模块仍保留在代码中，但不是当前功能验证主路径

当前已验证范围：

- `4 -> 2`
- `800 -> 500`
- `500 -> 10`

当前说明：

- 这是一条“最小可验证”的 FC 路径，后续仍可重构为更贴近初始架构规划的前端形式

### 8.3 Pool

首版固定支持：

- `2x2 MaxPool`
- `stride = 2`

不支持：

- Average Pool
- 通用窗口
- 通用 stride

### 8.4 Bias

- 首版不支持 `bias`
- 测试参数约束为仅提供 `weight`

## 9. 后处理链

固定顺序如下：

1. `MAC accumulate`
2. `ReLU`
3. `Pool(optional)`
4. `writeback`

说明：

- `ReLU` 工作在 `INT32` 域
- `Pool` 基于 `INT32` 数据工作
- 阵列结果先进入 `acc/output buffer`
- 后处理也通过 `acc/output buffer` 衔接

## 10. 双缓冲与 bank 机制

### 10.1 双缓冲目的

支持三段流水重叠：

- `load`
- `compute`
- `store`

### 10.2 bank 状态

每个 bank 至少要支持以下逻辑状态：

- `empty`
- `loading`
- `ready`
- `using`
- `done`

### 10.3 bank 控制原则

- CPU 完全不感知 bank
- DMA 不决定 bank 策略
- `NPU 主控制器` 统一决定：
  - 当前使用哪个 bank
  - 下一批数据装到哪个 bank
  - 何时切换 bank

## 11. DMA 数据流

### 11.1 主存侧数据

CPU 配置的地址全部是主存地址：

- `input_addr`
- `weight_addr`
- `output_addr`

CPU 还需配置字节数：

- `input_bytes`
- `weight_bytes`
- `output_bytes`

### 11.2 搬运路径

单条任务数据流：

1. 主存 -> `act buffer`
2. 主存 -> `weight buffer`
3. `conv_frontend` 或 `fc_frontend`
4. `array_top`
5. `acc/output buffer`
6. `ReLU`
7. `Pool(optional)`
8. `dma_write_path`
9. 主存结果区

### 11.3 搬运能力

- 首版仅支持连续块搬运
- 不支持二维 stride 搬运
- 不支持 scatter-gather

## 12. 寄存器模型

### 12.1 统一寄存器区

采用统一寄存器区，由 `task_type` 决定字段解释方式。

统一寄存器区至少应包含：

- `task_type`
- `input_addr`
- `weight_addr`
- `output_addr`
- `input_bytes`
- `weight_bytes`
- `output_bytes`
- 尺寸参数字段
- `relu_en`
- `pool_en`
- `start`
- `busy`
- `done`
- `error`
- `error_code`
- 性能计数器寄存器

### 12.2 task_type

`task_type` 用于声明本次任务类型，例如：

- `Conv`
- `FC`
- `Pool`

### 12.3 start

- `start` 为一次性启动位
- CPU 写 `1` 发起任务
- 硬件自动清零

### 12.4 busy 期间寄存器访问规则

`busy=1` 时：

- 允许读状态寄存器
- 允许读性能计数器
- 不允许改写当前任务相关寄存器
- 若改写，置 `error` 和对应 `error_code`

## 13. 启动顺序

固定流程如下：

1. CPU 写好寄存器
2. CPU 写 `start=1`
3. NPU 做参数合法性检查
4. 锁存本次任务参数
5. 初始化内部状态
6. 进入正式执行

参数一旦锁存：

- 当前任务执行期间不再受 CPU 后续写寄存器影响

## 14. 参数与地址检查

### 14.1 必查项

- `task_type` 合法
- 字节数非零
- 地址非空
- 地址对齐
- 地址位于合法数据区
- `addr + bytes` 不越界

### 14.2 算子约束检查

- `Conv` 必须满足 `5x5 / stride=1 / valid`
- `Pool` 必须满足 `2x2 / stride=2`
- 任务尺寸关系必须合法

### 14.3 失败处理

- 不进入正式执行
- 直接置 `error`
- 写 `error_code`

## 15. 性能统计

### 15.1 统计窗口

保留两种口径：

- 总任务周期
  - 从任务被接受并通过检查开始
  - 到 `done=1` 结束
- DMA/带宽统计窗口
  - 只统计读写通道真实活跃阶段

### 15.2 最少统计项

- `total_cycle`
- `read_beat_count`
- `write_beat_count`
- `read_active_cycle`
- `write_active_cycle`
- `array_active_cycle`
- `array_stall_cycle`

### 15.3 利用率定义

- `read_bw_util = read_beat_count / read_active_cycle`
- `write_bw_util = write_beat_count / write_active_cycle`
- `array_util = array_active_cycle / (array_active_cycle + array_stall_cycle)`

### 15.4 done 与计数器关系

只有在以下条件都满足后，才置 `done=1`：

- 读写完成
- 计算完成
- 后处理完成
- 写回完成
- 性能计数器冻结完成

## 16. 错误处理

### 16.1 必须区分的错误类型

- 参数非法
- 地址非法
- 地址越界
- DMA 读错误
- DMA 写错误
- `busy` 状态重复启动
- `busy` 状态改写寄存器
- 内部状态机错误

### 16.2 错误行为

任务执行中出错时：

- 立即停止任务
- 置 `error`
- 不置 `done`
- 性能计数器保留当前值并冻结

## 17. 软件与网络适配边界

### 17.1 软件职责

软件仅负责：

- 准备主存中的输入和权重
- 配置寄存器
- 启动任务
- 轮询状态
- 读取结果和计数器

### 17.2 首版网络约束

首版面向 `LeNet-style`，但硬件能力固定为：

- `Conv`: `5x5 / stride=1 / valid`
- `FC`: 共用阵列
- `Pool`: `2x2 maxpool / stride=2`
- 无 `bias`

补充说明：

- 当前完整 `LeNet(MNIST)` 回归已经在 `npu_top + axi4_ram` 子系统级验证通过
- SoC 顶层 `top` 仍主要用于 CPU/NPU/共享内存语义与控制流验证
- `top` 默认实例化的 `shared_ram` 容量为 `64KB`
- 因此当前“完整 LeNet 跑通”的结论默认指 **NPU 子系统级**，不等同于 SoC 顶层已在相同地址图下完成整网运行

## 18. 建议 RTL 实现顺序

建议按以下顺序推进：

1. `寄存器 + start/busy/done/error`
2. `task_checker`
3. `DMA 连续块搬运`
4. `三块 buffer + 双缓冲 + bank 状态`
5. `block 调度`
6. `Conv/FC 前端`
7. `共用主阵列`
8. `ReLU + Pool`
9. `写回路径`
10. `性能计数器和错误路径`

## 19. 当前已锁定的关键结论

- CPU 核：`PicoRV32`
- 控制面：`AXI-Lite`
- 数据面：`NPU 内部 DMA + AXI4 burst`
- NPU 一次执行一条任务
- 内部可自动分 block
- `Conv/FC` 共用阵列
- `Pool` 固定为 `2x2 maxpool`
- `bias` 首版不支持
- 三块独立双缓冲私有 buffer
- `load/compute/store` 尽量流水重叠
- `4x4 tile` 级时钟门控
- 顶层目标阵列规模：`64x64`
- 当前完整 `LeNet(MNIST)` 回归已在 `npu_top` 子系统级跑通
- SoC 顶层 `top` 默认 `shared_ram` 仍为 `64KB` 功能模型
