# CLAUDE.md — Project_npu Working Baseline

本文件是项目内的工程约束与架构工作基线，服务于本轮 `6-cluster + SoC` 正式重构。

## 1. 不可逾越约束

1. 所有修改必须限制在 `/root/Project_npu/` 内。
2. RTL 使用 Verilog / 可综合 SystemVerilog 子集。
3. 默认仿真工具链为 `iverilog + vvp`，可保留其他已有后端用于大回归。
4. CPU 核固定为 `PicoRV32`，不得改成自研 CPU。
5. 一次只收敛一个任务；当前任务严格测试未通过，禁止进入下一任务。
6. 关键规模、位宽、cluster 数量和 shared memory 容量必须参数化。
7. 以赛题交付为导向，优先保证可验证性与闭环。
8. 不允许把“结构已接通”当成完成。

## 2. 本轮重构目标

- 正式废弃旧阵列目标口径
- 切换为 `6-cluster` 动态可调脉动阵列
- 每个 cluster = `16x16 PE`
- 总计 `1536 PE`
- `200MHz` 理论峰值 `0.6144 TOPS`
- `npu_top` 从大一统结构重构为“编排层 + compute hierarchy”
- `top/shared_ram` 升级到可承载完整 LeNet 地址图
- 用真实训练权重闭合 `LeNet/MNIST`
- 一次补齐性能统计与验证体系

## 3. 顶层架构

### SoC 层

- `rtl/soc/top.v`
- `rtl/soc/shared_ram.v`
- `rtl/bus/axi_interconnect.v`
- `rtl/cpu/picorv32/...`

### NPU 编排层

- `npu_ctrl`
- `task_checker`
- `block_scheduler`
- DMA read/write path
- `npu_buffer`
- `conv_frontend`
- `fc_frontend` 或等价 FC 执行流
- `postproc`
- `perf_counter`
- `npu_top`

### 新 compute hierarchy

- `cluster_16x16.v`
- `compute_core_6cluster.v`
- `cluster_scheduler.v`
- `output_arbiter.v`

要求：

- `cluster_16x16` 复用现有 `array_top` / `4x4 tile` 资产
- `compute_core_6cluster` 必须真正例化 6 个 cluster
- `cluster_enable[5:0]` 是正式接口，不是测试专用信号
- Conv / FC 都必须走新 compute hierarchy

## 4. 验证层级与口径

### NPU 子系统级

`npu_top + axi4_ram` 用于：

- deterministic fixture
- 层级黄金对拍
- 大容量 LeNet 回归

### SoC 顶层级

`top` 用于：

- CPU/NPU/shared memory 统一语义
- AXI-Lite 控制闭环
- 完整 LeNet 地址图
- shared memory 预加载与结果回读
- 当前 SoC 顶层性能路径仍主要验证 `single-cluster compatibility mode`

本轮 SoC 级默认方法：

- testbench `AXI-Lite master` 模拟 CPU 软件行为
- memory preload 提前写入输入和权重
- 不要求 PicoRV32 固件先驱动完整 LeNet

补充口径：

- `single / dual / full / dynamic mask` 的 cluster 模式覆盖当前主要来自 compute-core / cluster-level 回归
- 不应将这部分覆盖表述成“完整 SoC 顶层已覆盖所有 cluster 模式”

## 5. 固定网络与数据规则

- 网络：`LeNet(MNIST)`
- feature map layout：`HWC`
- conv weight layout：`[in_c][k_h][k_w][out_c]` + per-`in_c` 32-bit 对齐
- fc weight layout：`[out_neuron][in_neuron]`
- activation / weight：`INT8`
- accumulate / output：`INT32`
- FC 输入规则：`INT32 -> saturating INT8`
- `Pool = 2x2 MaxPool, stride=2`
- `ReLU` 在 `INT32` 域
- `bias` 本轮不支持

## 6. Shared Memory 基线

- `top` 不允许继续停留在默认 `64KB` 小容量模型
- 默认共享内存窗口必须覆盖 LeNet 地址图
- 当前基线按至少 `1MB` 共享内存窗口规划
- `task_checker` 地址合法范围必须与 `shared_ram` 容量一致

## 7. 不回退门槛

以下项目视为本轮强制不回退约束：

- 参数检查必须先于 DMA / compute 启动
- `block_scheduler` 必须接入真实主数据路径
- `AXI-Lite interconnect` 必须保持事务目标锁存安全
- CPU / NPU 必须继续共享同一份内存语义
- FC 不能再按“未支持”处理
- deterministic fixture 不能被真实权重流替代掉

## 8. 调试与验收规则

### 完成判定

以下都不算完成：

- `done=1`
- `no error`
- 输出非 `x`
- accepted / framework exists / structure complete

必须同时满足：

1. 严格 testbench PASS
2. 数值与 golden/reference 一致
3. 退出原因为正确完成，而不是偶然结束
4. 相关回归未破坏
5. 文档、RTL、testbench 口径一致

### 调试顺序

出现 mismatch 时，优先检查：

1. 地址计算
2. byte count
3. 对齐
4. stride / channel 跨度
5. block 尺寸
6. valid/ready 握手
7. start/done 时序
8. 同周期旧值使用

简单问题未排除前，不要先归因为深层阵列时序。

### 最小闭环优先

- 先最小空间尺寸
- 先最小通道数
- 先单 block
- 先手算 golden
- 先单层再整网

## 9. 任务完成后必须报告

每完成一个任务，必须报告：

- Task 编号
- 修改摘要
- 修改文件列表
- 新增/修改的测试
- 运行命令
- 仿真/验证结果
- 是否满足该任务验收标准
- 残留风险
