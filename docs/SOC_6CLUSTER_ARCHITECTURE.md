# SoC 6-Cluster Architecture Baseline

本文件补充说明本轮正式重构后的 `CPU+NPU SoC` 结构边界，作为 `ARCHITECTURE_SPEC.md` 的专题展开。

## 1. Compute Organization

- 总体结构：`6 x cluster_16x16`
- 单 cluster：`16x16 PE`
- 基础复用单元：`4x4 tile`
- 总 PE：`1536`
- 峰值算力：`1536 x 2 x 200MHz = 0.6144 TOPS`

## 2. Module Boundary

### `cluster_16x16`

- 复用现有 `array_top`
- 封装 cluster 级 compute 接口
- 暴露 `enable / busy / valid / done / result`

### `compute_core_6cluster`

- 实例化 6 个 `cluster_16x16`
- 接收统一的任务级 compute 输入
- 输出每个 cluster 的状态与结果

### `cluster_scheduler`

- 根据模式与 cluster mask 下发 `cluster_enable[5:0]`
- 至少支持 `1 / 2 / 6` cluster 模式

### `output_arbiter`

- 汇聚 cluster 结果
- 保证写回顺序和映射稳定

## 3. Control/Data Split

`npu_top` 保持为编排层，负责：

- task_checker
- DMA
- local buffer
- block scheduler
- conv/fc frontend
- postproc
- perf counter

Cluster 级阵列组织和 cluster 模式切换必须下沉到 compute hierarchy。

## 4. Verification Contract

### NPU 子系统级

- 使用 `npu_top + axi4_ram`
- 验证 deterministic fixture
- 验证层级与网络级数值

### SoC 顶层级

- 使用 `top`
- 使用 testbench `AXI-Lite master`
- 使用 shared memory preload
- 模拟 CPU 软件配置流程

当前默认闭环不是 PicoRV32 固件整网驱动。

## 5. Shared Memory Contract

- 默认 shared memory 窗口至少 `1MB`
- 必须覆盖当前 LeNet 地址图
- CPU 与 NPU DMA 共享统一内存视图

## 6. Acceptance Focus

本轮不是“结构重命名”，而是以下能力的同时收敛：

1. 文档口径统一
2. 6-cluster compute hierarchy 落地
3. `npu_top` 接入新 compute core
4. `top/shared_ram` 能承载完整 LeNet
5. 真实权重 LeNet/MNIST 闭环
6. 性能统计与模式测试齐备
