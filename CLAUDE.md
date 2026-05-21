# CLAUDE.md — CPU+NPU 异构处理器项目规范

## 硬性约束 (不可逾越)

1. **工作目录限制**：所有代码、文档、脚本的创建和修改必须限制在 `/root/Project_npu/` 目录下，严禁修改该目录以外的任何文件。
2. **硬件描述语言**：所有 RTL 设计代码必须使用 **Verilog** 语法（IEEE 1364-2001 或 SystemVerilog 可综合子集）。
3. **仿真工具链**：使用 **iverilog** (Icarus Verilog) 作为编译/仿真工具，使用 **vvp** 作为运行引擎，使用 **gtkwave** 查看波形（可选）。
4. **CPU 核**：使用 **PicoRV32**（自带 AXI4 接口），不自研 CPU。
5. **一次只做一件事**：每个 task 聚焦单一模块，完成并通过编译后再进入下一步。避免跨模块同时修改。
6. **参数化设计**：关键位宽、阵列规模、buffer 深度等使用 parameter 定义，方便后期调整。
7. **得分导向**：RTL 实现优先覆盖评分点，再考虑锦上添花。
8. **自主执行权限**：在 `/root/Project_npu/` 范围内的常规操作（创建文件、编辑代码、编译仿真、运行测试等），无需反复向用户确认，可自行判断并执行。仅在涉及以下情况时需要征求用户同意：(a) 大范围删除文件或重构；(b) 涉及 `/root/Project_npu/` 以外的路径；(c) 安装系统级软件包或修改系统配置。

## 项目概览

赛题三：**智核融合·低耗强算 — 基于 CPU 和 NPU 的异构处理器设计**

设计一个 CPU + NPU 异构处理器，CPU 使用 PicoRV32，NPU 为自研 32 位加速器。CPU 负责任务配置与控制，NPU 负责数据搬运与矩阵计算。通过 AXI-Lite（控制面）和 AXI4 burst（数据面）实现高效通信。

## 顶层架构

```
┌──────────┐     AXI-Lite      ┌──────────────────────────┐
│ PicoRV32 │ ←───────────────→ │  NPU Accelerator         │
│   CPU    │                   │  ┌─────────────────────┐ │
└────┬─────┘                   │  │ npu_ctrl + regs     │ │
     │                         │  │ task_checker        │ │
     │                         │  │ status/error/perf   │ │
     │                         │  ├─────────────────────┤ │
     │                         │  │ DMA (act/weight rd) │ │
     │                         │  │ DMA (result wr)     │ │
     │                         │  ├─────────────────────┤ │
     │  AXI4 Shared Bus        │  │ act buffer (双缓冲) │ │
     ├─────────────────────────┤  │ weight buffer (双缓冲)│ │
     │                         │  │ acc/output buffer   │ │
     │                         │  ├─────────────────────┤ │
     └─────────────────────────┤  │ conv_frontend       │ │
                               │  │ fc_frontend         │ │
                               │  │ array_top (64×64)   │ │
                               │  │ postproc (ReLU+Pool)│ │
                               │  └─────────────────────┘ │
                               └──────────────────────────┘
```

## 关键设计指标

| 指标 | 基础要求 | 优化目标 |
|------|----------|----------|
| NPU 算力 | ≥ 0.5 TOPS @ INT8 | ≥ 1 TOPS @ INT8 |
| 仿真频率 | 200 MHz | — |
| 总线带宽利用率 (burst) | ≥ 60% | ≥ 80% |
| 代码覆盖率 | ≥ 95% | — |
| 阵列架构 | 4×4 脉动阵列 | 动态可调脉动阵列 |
| 低功耗 | 时钟门控 | DFS / 电源门控 |

## 精度与数据类型

- 激活值 (activation): **INT8**
- 权重 (weight): **INT8**
- 累加 (accumulate): **INT32**
- 输出写回格式 (首版): **INT32**

## 算子能力边界 (首版)

| 算子 | 规格 | 约束 |
|------|------|------|
| Conv | 5×5 kernel, stride=1, valid padding | 固定规格，不支持可变 |
| FC | 共用主乘加阵列 | 当前版本走已接通的 FC 执行路径；输入先做 INT32→INT8 饱和转换 |
| Pool | 2×2 MaxPool, stride=2 | 固定规格 |
| Bias | 不支持 | 首版无 bias |
| ReLU | INT32 域 | 固定后处理链内 |

## 后处理链 (固定顺序)

```
MAC accumulate → ReLU → Pool (optional) → writeback
```

## NPU 内部模块

- `npu_ctrl` — 主控制器（任务接受、参数锁存、block 调度、bank 切换、完成/异常）
- `task_checker` — 参数与地址合法性检查
- `status_error_regs` — busy/done/error/error_code
- `dma_read_path` — act_read_path + weight_read_path（共享 AXI4 读口）
- `dma_write_path` — 结果写回（独立 AXI4 写口）
- `act_buffer` / `weight_buffer` / `acc_buffer` — 三块独立双缓冲
- `conv_frontend` — 5×5 卷积窗口生成
- `fc_frontend` — 向量/矩阵整理（当前保留但不是主功能路径）
- `array_top` — 共用 MAC 阵列 (64×64 = 16×16 个 4×4 tile)
- `postproc` — ReLU + MaxPool
- `perf_counter` — 周期/带宽/利用率统计

## 当前验证层级

- `top`：用于 CPU/NPU/共享内存集成与控制流验证
- `npu_top + axi4_ram`：用于大容量 feature map / 权重条件下的完整 LeNet 回归

说明：

- `rtl/soc/top.v` 中默认 `shared_ram` 容量为 `64KB`
- 当前完整 `LeNet(MNIST)` 回归使用的是更大的仿真 RAM 模型，而不是直接在 `top` 的默认内存配置上完成
- 因此文档中若提到“整网 LeNet 已跑通”，默认指 **NPU 子系统级验证**，不是 SoC 顶层软件驱动级验证

## 双缓冲 bank 状态机

每个 bank 至少支持: `empty → loading → ready → using → done`

三段流水重叠: `load / compute / store`

## 寄存器模型 (统一寄存器区)

- `task_type` / `input_addr` / `weight_addr` / `output_addr`
- `input_bytes` / `weight_bytes` / `output_bytes`
- 尺寸参数 / `relu_en` / `pool_en`
- `start` (硬件自动清零) / `busy` / `done` / `error` / `error_code`
- 性能计数器寄存器组

## 启动流程

1. CPU 写寄存器 → 2. CPU 写 start=1 → 3. NPU 参数检查 → 4. 参数锁存 → 5. 进入执行

`busy=1` 时: 允许读状态和计数器，禁止写任务寄存器（违规则置 error）。

## 需要区分的错误类型

- 参数非法 / 地址非法 / 地址越界
- DMA 读错误 / DMA 写错误
- busy 状态重复启动 / busy 状态改写寄存器
- 内部状态机错误

发生错误 → 立即停止 → 置 error → 不置 done → 性能计数器冻结

## 建议 RTL 实现顺序

1. 寄存器模块 + start/busy/done/error 状态机
2. task_checker（参数与地址校验）
3. DMA 连续块搬运（读/写）
4. 三块 buffer + 双缓冲 + bank 状态
5. block 调度逻辑
6. Conv/FC 前端
7. 共用主阵列 (先从 4×4 tile 做起，再扩展到 64×64)
8. ReLU + Pool 后处理
9. 写回路径
10. 性能计数器和错误路径完善

## Verilog 编码约定

- 使用 `parameter` 定义可配置常量，避免硬编码数值
- 模块名与文件名一致（小写 + 下划线，如 `npu_ctrl.v`）
- 信号名使用小写 + 下划线（snake_case）
- 时钟信号统一命名为 `clk`，复位信号统一命名为 `rst_n`（低电平有效）
- 状态机使用 `localparam` 定义状态枚举
- 每个模块单独一个 `.v` 文件
- testbench 文件命名: `tb_<module_name>.v`
- 顶层集成文件: `top.v`

## iverilog 编译/仿真命令范式

```bash
# 编译
iverilog -o <output.vvp> -g2012 <source_files...>

# 运行仿真
vvp <output.vvp>

# 生成波形 (testbench 中使用 $dumpfile/$dumpvars)
vvp <output.vvp>   # 生成 .vcd 文件

# 查看波形 (可选)
gtkwave <wave.vcd>
```

## 目录结构约定

```
/root/Project_npu/
├── CLAUDE.md                  # 本规范文件
├── ARCHITECTURE_SPEC.md       # 架构规格说明
├── cpu_npu_architecture.png   # 架构框图
├── 赛题三.docx                # 原始赛题说明
├── rtl/                       # RTL 设计源码
│   ├── cpu/                   # PicoRV32 相关
│   ├── npu/                   # NPU 各模块
│   ├── bus/                   # AXI 总线互联
│   └── top.v                  # 顶层集成
├── tb/                        # Testbench
├── sim/                       # 仿真脚本和输出
├── scripts/                   # 辅助脚本
└── docs/                      # 设计文档
```

## 禁止事项

- 禁止使用 Xilinx/Altera 等特定厂商 IP（保持工具链中立）
- 禁止在 RTL 中使用 `initial` 块（仅 testbench 可用）
- 禁止在可综合代码中使用 `$finish`、`$display` 等系统函数（仅 testbench 可用）
- 禁止修改 PicoRV32 源码（仅允许使用其标准接口进行集成）
- 禁止在 `/root/Project_npu/` 外创建或修改文件

## RTL 调试与任务验收规范

以下规则来自本项目多轮 RTL 调试的实战经验，与上述硬性约束具有同等约束力。

### 1. 任务完成标准

以下任一项单独成立都**不能**宣称任务完成：

- `done=1` / `no error` / 输出不再是 `x`
- "结构已接通" / "框架已存在" / "task 已被接受"
- 仅检查 `done` 而不检查数值正确性

**任务完成的充要条件**：

1. 指定的严格 testbench **PASS**（退出码为 0 且无 mismatch）
2. 输出数值与 golden/reference **逐点一致**
3. 已有回归测试**未被破坏**
4. 文档、testbench 预期、RTL 行为**三者一致**

缺少任一条，任务不得关闭。

### 2. 一次只收一个任务

- 若当前任务（如 Task 3）的严格测试仍在 **FAIL**，**禁止**进入下一任务
- 禁止将未收敛的层拼接为"网络级 testbench"作为进度展示
- 必须：隔离当前任务 → 严格测试 → RTL 修复 → 测试 PASS → 才能移动

此规则优先级最高。

### 3. 先修 testbench，再改 RTL

常见反模式（必须避免）：

- mismatch 只 `$display` 打印，不触发 `$fatal` 或非零退出码
- 测试只检查 `done`，不检查输出数值
- 用弱代理场景（如 `4->20`）替代真实需求（如 `20->50`）
- 将 "FC accepted" 当作 "FC 功能正确"

**在修改 RTL 之前**，必须先确认 testbench 满足：

1. 与 golden/expected 逐元素比较
2. mismatch 时 `$fatal` 或等效失败退出
3. timeout 也视为失败
4. 覆盖的是任务单上的**真实需求**，而非代理

### 4. 先查简单根因，再怀疑复杂时序

出现 data mismatch 时，**按以下顺序排查**，不要直接从"阵列时序"开始：

1. 地址计算（AXI address / offset）
2. byte count（是否包含 alignment padding）
3. 64B 对齐
4. stride / 通道间跨度
5. block 尺寸（buffer 容量是否满足）
6. valid/ready 握手（是否丢第一拍或最后一拍）
7. start/done 脉冲时序（是否与数据有效周期重叠）
8. 同一 cycle 内使用尚未更新的寄存器

只有在以上全部排除后，才考虑：

- 流水线对齐
- 多列传播延迟
- 脉动阵列 drain 时序

本项目实际教训：多次"阵列时序问题"最终根因是 weight chunk 对齐或 testbench 接线错误。

### 5. 最小可验证闭环

调试和开发必须从**最小可验证规模**开始，逐步放大：

1. 最小空间尺寸（能覆盖路径即可）
2. 最小通道数（能覆盖多通道逻辑即可）
3. 单 block 优先于多 block
4. 可手算 golden 优先于大回归
5. 单层优先于完整网络

示例：调试 `FC 4->2` 再扩到 `800->500`；调试 `Pool 4×4×1` 再扩到 `24×24×20`。

**如果最小闭环不过，更大规模的测试不会提供有用信号。**

### 6. 功能正确优先于架构优雅

- 如果一个已有路径（如 `fc_frontend + array`）迟迟不收敛，**不要无限堆补丁**
- 优先实现最短的正确路径，使其数值通过，再考虑架构优化
- 正确性 > 优雅性；收敛 > 完美

### 7. 文档 / 测试 / RTL 同步

每次 RTL 行为变更时，必须同步检查并更新：

- 任务 spec（算子约束、weight layout、内存布局）
- 参数化约定（对齐填充、stride 规则）
- testbench 预期值（golden 函数、预加载格式）
- 单元测试断言（如 FC 从 rejected 变为 accepted）

**禁止**：RTL 允许 FC 但单测仍断言 FC rejected；weight layout 改了但 preload 格式未同步。

### 8. 修改后必须报告

每次 RTL 修改完成后，必须输出：

1. 失败现象
2. 根因
3. 修改文件列表
4. 精确的编译/仿真命令
5. 仿真结果（通过/失败/剩余错误数）
6. 是否满足验收标准
7. 残留风险（如存在）

使用具体语言。好的例子：`Pool 丢失第一拍因为 pp_start 与第一个 data_valid 周期重叠`。不好的例子：`minor timing issue remains`。
