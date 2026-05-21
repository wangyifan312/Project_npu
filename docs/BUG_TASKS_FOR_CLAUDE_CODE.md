# Bug Tasks For Claude Code

本文档用于把当前仓库中的已确认问题转交给 Claude Code 逐项修复。

使用原则：
- 每次只处理一个 `P0/P1` 任务。
- 修改后必须补对应 testbench 或至少补一个可复现的仿真用例。
- 如果实现与文档不一致，不能只改 RTL，不同步文档。
- 除非任务明确要求，否则不要顺手大改架构。

---

## Task 1

### 标题
`P0` 参数检查完成前，NPU 可能已经开始执行

### 问题描述
当前实现违反了文档中的启动顺序。

文档要求：
1. CPU 写寄存器
2. CPU 写 `start=1`
3. NPU 做参数检查
4. 参数锁存
5. 进入执行

但当前 RTL 中：
- [rtl/npu/npu_ctrl.v](/root/Project_npu/rtl/npu/npu_ctrl.v:346) 在 `write_new_start` 后立即进入 `busy`
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:825) 看到 `ctrl_busy` 就开始主 FSM 和 DMA 流程

这意味着非法任务理论上也可能先触发 DMA、buffer 状态推进甚至计算，再被 `task_checker` 拒绝。

### 目标
保证只有在 `task_checker` 返回 `check_done=1 && checks_pass=1` 之后，`npu_top` 才能进入真实执行路径。

非法任务必须满足：
- 不发起 DMA 读写
- 不推进 buffer load/compute 状态
- 不进入计算 FSM

### 建议修改范围
- [rtl/npu/npu_ctrl.v](/root/Project_npu/rtl/npu/npu_ctrl.v:282)
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:761)

### 验收标准
- 非法任务启动后，`error=1`，`done=0`
- 非法任务期间 `m_axi_arvalid` 和 `m_axi_awvalid` 全程不拉高
- 合法任务仍能正常完成
- 新增一个“checker fail before DMA”测试

---

## Task 2

### 标题
`P0` `block_scheduler` 没有真正接入主数据路径

### 问题描述
当前 `block_scheduler` 只部分生效，导致多 block 任务不正确。

已发现的具体问题：
- 权重 DMA 使用了 block 参数  
  见 [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:846)
- 激活 DMA 又退回全局 `input_addr/input_bytes`  
  见 [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:896)
- 计算窗口总数仍按全局 `input_h/input_w` 计算  
  见 [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:911)
- STORE 阶段的数据有效长度仍按全局 `output_bytes` 判断  
  见 [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:745)

当前 `tb_npu_top` 能通过，主要是因为它只覆盖了最小单 block Conv 场景，不能说明多 block 正确。

### 目标
让单个 block 的执行全过程完全基于当前 `blk_*` 参数，而不是基于全局任务参数。

优先先打通 Conv 多 block。

### 建议修改范围
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:700)
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:904)
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:1022)
- [rtl/npu/block_scheduler.v](/root/Project_npu/rtl/npu/block_scheduler.v:73)

### 验收标准
- act DMA / weight DMA / store DMA 都使用当前 block 的地址和字节数
- 当前 block 的窗口数、输入行数、输出行数与 `block_scheduler` 输出一致
- 多 block Conv 用例能顺序执行并全部完成
- 不允许每个 block 反复读取全量输入
- 不允许每个 block 覆盖写全量输出

---

## Task 3

### 标题
`P0` `axi_interconnect` 的 AXI-Lite 路由未锁存事务目标

### 问题描述
当前 [rtl/bus/axi_interconnect.v](/root/Project_npu/rtl/bus/axi_interconnect.v:133) 直接根据实时 `cpu_awaddr/cpu_araddr` 做译码，然后在 [rtl/bus/axi_interconnect.v](/root/Project_npu/rtl/bus/axi_interconnect.v:159) 用同样的实时译码去路由 `W/B/R`。

这对 AXI-Lite 不安全，因为：
- `AW` 和 `W` 可以解耦
- `AR` 发出后，地址线后续可能变化

结果可能是：
- 地址阶段选中 NPU，但数据阶段写进 Memory
- 读请求发往一个目标，返回数据却从另一个目标取

### 目标
对写事务和读事务分别锁存目标从设备，后续 `W/B/R` 全部按锁存结果路由。

### 建议修改范围
- [rtl/bus/axi_interconnect.v](/root/Project_npu/rtl/bus/axi_interconnect.v:132)

### 验收标准
- `AW` 和 `W` 分离多拍时，写仍进入正确目标
- `AR` 发出后，即使地址线变化，返回数据仍来自原目标
- 新增至少一个 AXI-Lite 解耦测试

---

## Task 4

### 标题
`P1` 顶层不是共享主存，而是 CPU / NPU 各自独立 RAM

### 问题描述
当前顶层和架构文档不一致。

当前实现：
- CPU 连到 [rtl/soc/axi_ram.v](/root/Project_npu/rtl/soc/axi_ram.v:4)
- NPU DMA 连到 [rtl/soc/axi4_ram.v](/root/Project_npu/rtl/soc/axi4_ram.v:5)

对应顶层连接见：
- [rtl/soc/top.v](/root/Project_npu/rtl/soc/top.v:280)
- [rtl/soc/top.v](/root/Project_npu/rtl/soc/top.v:305)

这样 CPU 和 NPU 实际访问的不是同一份内存映像，异构协同语义不成立。

### 目标
让 CPU 和 NPU 至少工作在同一份物理内存映像上。

最低要求：
- CPU 写入输入数据
- NPU 从同一地址读到输入数据
- NPU 写回结果
- CPU 从同一地址空间读回结果

### 建议修改范围
- [rtl/soc/top.v](/root/Project_npu/rtl/soc/top.v:277)
- [rtl/bus/axi_interconnect.v](/root/Project_npu/rtl/bus/axi_interconnect.v:168)
- 可能需要新增统一 RAM 封装

### 验收标准
- 补一个 CPU/NPU 共享内存闭环测试
- CPU 与 NPU 看到的是同一份输入和输出数据

---

## Task 5

### 标题
`P1` FC 路径未真正接通

### 问题描述
代码中存在 `fc_frontend`，文档也宣称支持 FC，但当前实现实际上没有完整接通。

具体问题：
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:477) 中 `fc_frontend.start` 固定为 `1'b0`
- `output_size` 和 `block_start` 是悬空输入
- `iverilog -Wall` 已报 dangling input warning

当前状态更像“半成品”而不是“已支持 FC”。

### 目标
二选一：

方案 A：
- 正式接通 FC 前端、FC 调度、FC 数据路径

方案 B：
- 当前版本显式禁用 FC
- 让 `task_checker` 在检查阶段拒绝 FC 任务
- 同步修改文档，明确当前版本暂不支持 FC

### 建议修改范围
方案 A：
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:471)
- [rtl/npu/fc_frontend.v](/root/Project_npu/rtl/npu/fc_frontend.v:7)
- [rtl/npu/block_scheduler.v](/root/Project_npu/rtl/npu/block_scheduler.v:87)

方案 B：
- [rtl/npu/task_checker.v](/root/Project_npu/rtl/npu/task_checker.v:148)
- [ARCHITECTURE_SPEC.md](/root/Project_npu/ARCHITECTURE_SPEC.md:219)

### 验收标准
方案 A：
- FC 任务可启动、可执行、结果正确

方案 B：
- FC 任务在 checker 阶段被拒绝
- 不会进入任何 DMA/执行流
- 文档与实现口径一致

---

## Task 6

### 标题
`P1` 双缓冲结构存在，但没有真正启用 ping-pong

### 问题描述
当前 `npu_buffer` 模块支持双 bank 状态机，但 `npu_top` 中 bank 选择几乎全部固定为 `0`。

可见位置：
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:796)
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:842)
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:900)
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:997)
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:1034)

这使当前实现运行上等价于单 bank，不符合文档描述的双缓冲行为。

### 目标
至少实现 bank 选择切换和状态闭环。

短期即便不做完整 `load/compute/store` 重叠，也应保证：
- 当前 compute bank 不会被同时 load
- 连续 block 能切换 bank

### 建议修改范围
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:337)
- [rtl/npu/npu_buffer.v](/root/Project_npu/rtl/npu/npu_buffer.v:61)

### 验收标准
- 连续 block 场景下 bank 选择发生切换
- `EMPTY -> LOADING -> READY -> USING` 状态迁移符合预期
- 不会写入正在 `USING` 的 bank

---

## Task 7

### 标题
`P2` buffer 位宽与文档规格不一致

### 问题描述
文档当前写的是：
- `act buffer = 512-bit`
- `weight buffer = 512-bit`
- `acc/output buffer = 2048-bit`

相关位置：
- [ARCHITECTURE_SPEC.md](/root/Project_npu/ARCHITECTURE_SPEC.md:102)
- [ARCHITECTURE_SPEC.md](/root/Project_npu/ARCHITECTURE_SPEC.md:111)

但当前实现里顶层统一使用：
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:9) `BUF_DATA_W = 32`

这会导致实现与规格、带宽模型、阵列并行写回假设不一致。

### 目标
统一 RTL 与文档口径。

如果近期不升级 RTL，则必须把文档明确写成：
- 当前版本是 32-bit 功能模型
- 512/2048-bit 是未来目标，不是当前实现事实

### 建议修改范围
- [rtl/npu/npu_top.v](/root/Project_npu/rtl/npu/npu_top.v:6)
- [rtl/npu/npu_buffer.v](/root/Project_npu/rtl/npu/npu_buffer.v:6)
- [ARCHITECTURE_SPEC.md](/root/Project_npu/ARCHITECTURE_SPEC.md:98)
- [CLAUDE.md](/root/Project_npu/CLAUDE.md:79)

### 验收标准
- 文档与 RTL 口径一致
- 不再把未实现的位宽规格写成当前实现能力

---

## Task 8

### 标题
`P2` `tb_top` 不是有效 SoC 集成测试

### 问题描述
当前 [tb/integration/tb_top.v](/root/Project_npu/tb/integration/tb_top.v:35) 自己就写了：
- `direct NPU write test needs exposed ports`

实际它只验证：
- CPU 复位后没有立即 `trap`

但输出文案却容易让人误以为已经完成 SoC 集成验证。

### 目标
二选一：

方案 A：
- 把它补成真实的集成测试

方案 B：
- 明确降级为 smoke test
- 修改测试名称和输出文案，避免误导

### 建议修改范围
- [tb/integration/tb_top.v](/root/Project_npu/tb/integration/tb_top.v:1)

### 验收标准
方案 A：
- 至少覆盖一次 CPU 地址空间访问到 NPU 或共享内存

方案 B：
- 不再输出类似 “All modules connected and compiled successfully” 这种具有误导性的结论

---

## Task 9

### 标题
`P2` `tb_npu_top` 不是自包含仿真入口

### 问题描述
当前 `tb_npu_top` 默认并不是一个可直接复现的编译入口。

实测如果直接执行：

```bash
iverilog -g2012 -o /tmp/tb_npu_top.vvp tb/integration/tb_npu_top.v rtl/npu/*.v
```

会报：

```text
Unknown module type: axi4_ram
```

需要显式把 [rtl/soc/axi4_ram.v](/root/Project_npu/rtl/soc/axi4_ram.v:5) 加入编译列表。

### 目标
提供一个统一、稳定、可复现的集成仿真入口。

### 建议修改范围
- `sim/` 下新增脚本或 Makefile
- 或补到 [CLAUDE.md](/root/Project_npu/CLAUDE.md:146) / 新建仿真说明文档

### 验收标准
- `tb_npu_top` 可以通过一条固定命令编译运行
- 不需要依赖人工记忆额外源文件

---

## 推荐修复顺序

1. Task 1
2. Task 2
3. Task 3
4. Task 4
5. Task 5
6. Task 6
7. Task 7
8. Task 8
9. Task 9

说明：
- `Task 1` 和 `Task 2` 是当前最关键的功能正确性问题。
- `Task 3` 会影响 SoC 级访问正确性。
- `Task 4` 不修的话，CPU/NPU 协同语义始终不成立。
- `Task 5/6/7` 是实现能力与文档一致性问题。
- `Task 8/9` 是验证入口和工程可维护性问题。
