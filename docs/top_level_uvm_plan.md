# CPU+NPU SoC Top-level UVM 验证计划

## 0. 文档目的

本文档用于指导执行层模型或工程实现者为当前 `Project_npu` RTL 搭建一套 **Top-level only UVM 验证环境**。

本方案不做细粒度模块级 UVM 验证，而是以 SoC 顶层 `rtl/soc/top.v` 作为唯一 DUT，通过 UVM 模拟 CPU 侧 AXI-Lite 行为，完成 shared memory 数据加载、NPU 寄存器配置、任务启动、状态轮询、输出读回、golden 比对、性能计数器读取和系统级 coverage 收集。

目标是：

- 快速形成可运行、可复用、可回归的 UVM top-level 验证平台；
- 复用现有 directed fixture、MNIST/LeNet 数据和 golden 文件；
- 验证完整 SoC 数据流，而不是逐个子模块穷尽验证；
- 为比赛答辩、论文或项目汇报提供体系化验证方案。

---

## 1. 验证范围定义

### 1.1 DUT

只验证 SoC 顶层：

```text
rtl/soc/top.v
```

顶层集成对象包括：

```text
PicoRV32 CPU
AXI-Lite interconnect
shared RAM
NPU register file / npu_ctrl
NPU DMA
NPU compute datapath
```

### 1.2 当前 SoC 关键假设

| 项目 | 当前状态 |
|---|---|
| 控制面 | 32-bit AXI-Lite |
| 数据面 | NPU 侧 256-bit AXI4 INCR burst |
| shared RAM | 1 MB, `32768 x 256-bit beat` |
| CPU/TB 访问 shared RAM | 32-bit AXI-Lite word lane |
| NPU DMA 访问 shared RAM | 256-bit AXI4 beat |
| NPU register window | `0x1000_0000 ~ 0x1000_00FF` |
| shared RAM window | `0x0000_0000 ~ 0x000F_FFFF` |
| NPU status | `{24'h0, error, done, busy, 1'b0}` |
| 正式任务 | Conv, FC, Pool, Requant |
| 扩展 foundation | ADD, GAP, bias, capability, cluster config |

### 1.3 重要接口入口

`top.v` 支持 `tb_axil_enable`。当该信号置 1 时，testbench 可以接管 CPU 侧 AXI-Lite master 端口，直接访问 shared RAM 和 NPU registers。

因此 UVM 不需要让 PicoRV32 真正运行软件程序，第一版可以由 `AXI-Lite active agent` 直接模拟 CPU 软件行为。

---

## 2. 验证目标

### 2.1 不做的内容

本方案不做以下内容：

```text
1. mac_pe / mac_tile_4x4 / array_top 模块级 UVM
2. cluster_16x16 / compute_core_6cluster 模块级 UVM
3. dma_axi_reader / dma_axi_writer 模块级 UVM
4. task_checker 单独 UVM
5. 完整商用 AXI VIP 级随机协议验证
6. ResNet-20 end-to-end UVM
7. 完整 code coverage closure
8. 对所有内部 FSM 状态做 exhaustive reset/random coverage
```

### 2.2 要做的内容

本方案只关注完整 top-level 数据流：

```text
AXI-Lite preload input/weight/parameter
    ↓
配置 NPU register
    ↓
写 CTRL.start
    ↓
轮询 STATUS.done / STATUS.error
    ↓
从 shared RAM 读回 output
    ↓
与 golden output 比对
    ↓
读取 perf counter
    ↓
收集 task / cluster / memory / status / DMA coverage
```

最终应证明：

```text
1. 软件/测试平台可以正确配置 NPU；
2. shared RAM 可以作为 CPU 与 NPU 的数据交换空间；
3. NPU 可以通过 DMA 读取 input/weight/parameter；
4. NPU 可以执行 Conv/FC/Pool/Requant 等任务；
5. NPU 可以将结果写回 shared RAM；
6. UVM 可以读回结果并与 golden 自动比对；
7. status/error/perf counter 可被系统级检查；
8. 主要任务类型、cluster mode、错误路径有 coverage 记录。
```

---

## 3. 推荐目录结构

建议新增目录：

```text
verif/uvm_top/
  README.md
  filelist.f

  tb/
    tb_soc_top_uvm.sv
    soc_top_defines.svh

  interfaces/
    axil_if.sv
    reset_if.sv
    soc_probe_if.sv

  pkg/
    soc_top_uvm_pkg.sv

  agents/
    axil/
      axil_seq_item.sv
      axil_driver.sv
      axil_monitor.sv
      axil_sequencer.sv
      axil_agent.sv
      axil_agent_cfg.sv

    reset/
      reset_seq_item.sv
      reset_driver.sv
      reset_sequencer.sv
      reset_agent.sv

    dma_mon/
      axi4_dma_txn.sv
      axi4_dma_monitor.sv

    status/
      npu_status_txn.sv
      npu_status_monitor.sv

  env/
    soc_top_env.sv
    soc_top_env_cfg.sv
    soc_virtual_sequencer.sv
    soc_scoreboard.sv
    soc_mem_model.sv
    soc_golden_model.sv
    soc_coverage.sv
    soc_perf_checker.sv

  sequences/
    base/
      soc_base_seq.sv
      soc_reset_seq.sv
      axil_mem_rw_seq.sv
      npu_reg_rw_seq.sv

    common/
      shared_ram_preload_seq.sv
      npu_config_seq.sv
      npu_start_poll_seq.sv
      npu_output_read_seq.sv
      npu_perf_read_seq.sv

    tasks/
      npu_conv_task_seq.sv
      npu_fc_task_seq.sv
      npu_pool_task_seq.sv
      npu_requant_task_seq.sv
      npu_add_task_seq.sv
      npu_gap_task_seq.sv

    networks/
      npu_lenet_sample_seq.sv
      npu_lenet_batch_seq.sv

    error/
      npu_misaligned_addr_seq.sv
      npu_invalid_task_seq.sv
      npu_start_while_busy_seq.sv

  tests/
    soc_base_test.sv
    soc_reset_reg_test.sv
    soc_shared_ram_rw_test.sv
    npu_conv_smoke_test.sv
    npu_fc_smoke_test.sv
    npu_pool_smoke_test.sv
    npu_requant_smoke_test.sv
    npu_lenet_1_test.sv
    npu_lenet_8_test.sv
    npu_lenet_32_test.sv
    npu_cluster_mode_test.sv
    npu_error_test.sv

  data/
    README.md
    lenet/
      sample_*.memh
      weights.memh
      golden_*.memh
      manifest.json

  scripts/
    run_uvm.py
    make_filelist.py
    parse_uvm_report.py
```

---

## 4. Testbench 顶层设计

### 4.1 `tb_soc_top_uvm.sv` 职责

1. 例化 `top.v`。
2. 产生 `clk` 和 `rst_n`。
3. 例化 `axil_if`。
4. 例化 `reset_if`。
5. 例化 `soc_probe_if`。
6. 连接 `tb_axil_enable = 1'b1`。
7. 将 AXI-Lite TB 接口连接到 DUT 的 `tb_*` 端口。
8. 将 `npu_status` 连接到 `soc_probe_if`。
9. 可选：通过层级引用连接 DUT 内部 NPU DMA AXI4 信号到 `soc_probe_if`。
10. 将 virtual interface 放入 `uvm_config_db`。

### 4.2 顶层伪代码

```systemverilog
module tb_soc_top_uvm;

  import uvm_pkg::*;
  import soc_top_uvm_pkg::*;

  bit clk;
  bit rst_n;

  always #5 clk = ~clk;

  axil_if      axil_vif(.clk(clk), .rst_n(rst_n));
  reset_if     reset_vif(.clk(clk));
  soc_probe_if probe_vif(.clk(clk), .rst_n(rst_n));

  top dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .tb_axil_enable (1'b1),

    .tb_awvalid     (axil_vif.awvalid),
    .tb_awready     (axil_vif.awready),
    .tb_awaddr      (axil_vif.awaddr),
    .tb_wvalid      (axil_vif.wvalid),
    .tb_wready      (axil_vif.wready),
    .tb_wdata       (axil_vif.wdata),
    .tb_wstrb       (axil_vif.wstrb),
    .tb_bvalid      (axil_vif.bvalid),
    .tb_bready      (axil_vif.bready),
    .tb_bresp       (axil_vif.bresp),

    .tb_arvalid     (axil_vif.arvalid),
    .tb_arready     (axil_vif.arready),
    .tb_araddr      (axil_vif.araddr),
    .tb_rvalid      (axil_vif.rvalid),
    .tb_rready      (axil_vif.rready),
    .tb_rdata       (axil_vif.rdata),
    .tb_rresp       (axil_vif.rresp),

    .cpu_trap       (),
    .npu_status     (probe_vif.npu_status)
  );

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "*", "axil_vif", axil_vif);
    uvm_config_db#(virtual reset_if)::set(null, "*", "reset_vif", reset_vif);
    uvm_config_db#(virtual soc_probe_if)::set(null, "*", "probe_vif", probe_vif);
    run_test();
  end

endmodule
```

### 4.3 关于 DMA 内部信号连接

如果仿真器允许层级引用，可以在 `tb_soc_top_uvm.sv` 中连接 DUT 内部 NPU AXI4 信号：

```systemverilog
assign probe_vif.npu_m_arvalid = dut.npu_m_arvalid;
assign probe_vif.npu_m_arready = dut.npu_m_arready;
assign probe_vif.npu_m_araddr  = dut.npu_m_araddr;
assign probe_vif.npu_m_arlen   = dut.npu_m_arlen;
assign probe_vif.npu_m_arsize  = dut.npu_m_arsize;
assign probe_vif.npu_m_arburst = dut.npu_m_arburst;

assign probe_vif.npu_m_rvalid  = dut.npu_m_rvalid;
assign probe_vif.npu_m_rready  = dut.npu_m_rready;
assign probe_vif.npu_m_rdata   = dut.npu_m_rdata;
assign probe_vif.npu_m_rlast   = dut.npu_m_rlast;
assign probe_vif.npu_m_rresp   = dut.npu_m_rresp;

assign probe_vif.npu_m_awvalid = dut.npu_m_awvalid;
assign probe_vif.npu_m_awready = dut.npu_m_awready;
assign probe_vif.npu_m_awaddr  = dut.npu_m_awaddr;
assign probe_vif.npu_m_awlen   = dut.npu_m_awlen;
assign probe_vif.npu_m_awsize  = dut.npu_m_awsize;
assign probe_vif.npu_m_awburst = dut.npu_m_awburst;

assign probe_vif.npu_m_wvalid  = dut.npu_m_wvalid;
assign probe_vif.npu_m_wready  = dut.npu_m_wready;
assign probe_vif.npu_m_wdata   = dut.npu_m_wdata;
assign probe_vif.npu_m_wstrb   = dut.npu_m_wstrb;
assign probe_vif.npu_m_wlast   = dut.npu_m_wlast;

assign probe_vif.npu_m_bvalid  = dut.npu_m_bvalid;
assign probe_vif.npu_m_bready  = dut.npu_m_bready;
assign probe_vif.npu_m_bresp   = dut.npu_m_bresp;
```

如果层级引用不方便，第一版可以不实现 `dma_mon`，只保留 AXI-Lite + status + output compare。

---

## 5. Interface 设计

### 5.1 `axil_if.sv`

```systemverilog
interface axil_if(input logic clk, input logic rst_n);

  logic        awvalid;
  logic        awready;
  logic [31:0] awaddr;

  logic        wvalid;
  logic        wready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;

  logic        bvalid;
  logic        bready;
  logic [1:0]  bresp;

  logic        arvalid;
  logic        arready;
  logic [31:0] araddr;

  logic        rvalid;
  logic        rready;
  logic [31:0] rdata;
  logic [1:0]  rresp;

  task automatic idle();
    awvalid <= 1'b0;
    awaddr  <= '0;
    wvalid  <= 1'b0;
    wdata   <= '0;
    wstrb   <= '0;
    bready  <= 1'b0;
    arvalid <= 1'b0;
    araddr  <= '0;
    rready  <= 1'b0;
  endtask

endinterface
```

### 5.2 `reset_if.sv`

```systemverilog
interface reset_if(input logic clk);
  logic rst_n;
endinterface
```

### 5.3 `soc_probe_if.sv`

```systemverilog
interface soc_probe_if(input logic clk, input logic rst_n);

  logic [31:0] npu_status;

  logic         npu_m_arvalid;
  logic         npu_m_arready;
  logic [31:0]  npu_m_araddr;
  logic [7:0]   npu_m_arlen;
  logic [2:0]   npu_m_arsize;
  logic [1:0]   npu_m_arburst;

  logic         npu_m_rvalid;
  logic         npu_m_rready;
  logic [255:0] npu_m_rdata;
  logic         npu_m_rlast;
  logic [1:0]   npu_m_rresp;

  logic         npu_m_awvalid;
  logic         npu_m_awready;
  logic [31:0]  npu_m_awaddr;
  logic [7:0]   npu_m_awlen;
  logic [2:0]   npu_m_awsize;
  logic [1:0]   npu_m_awburst;

  logic         npu_m_wvalid;
  logic         npu_m_wready;
  logic [255:0] npu_m_wdata;
  logic [31:0]  npu_m_wstrb;
  logic         npu_m_wlast;

  logic         npu_m_bvalid;
  logic         npu_m_bready;
  logic [1:0]   npu_m_bresp;

endinterface
```

---

## 6. AXI-Lite Agent 规划

### 6.1 `axil_seq_item`

```systemverilog
class axil_seq_item extends uvm_sequence_item;

  typedef enum {AXIL_READ, AXIL_WRITE} axil_cmd_e;

  rand axil_cmd_e cmd;
  rand bit [31:0] addr;
  rand bit [31:0] data;
  rand bit [3:0]  strb;

  bit [31:0] rdata;
  bit [1:0]  resp;

  constraint word_aligned_c {
    addr[1:0] == 2'b00;
  }

  `uvm_object_utils(axil_seq_item)

  function new(string name = "axil_seq_item");
    super.new(name);
  endfunction

endclass
```

### 6.2 `axil_driver`

职责：

- 主动驱动 AXI-Lite write/read；
- 支持 blocking write 和 blocking read；
- 第一版默认无随机 delay；
- 后续可选添加 AW/W/AR/R/B 的随机 gap。

写操作伪代码：

```systemverilog
task drive_write(axil_seq_item tr);
  @(posedge vif.clk);
  vif.awaddr  <= tr.addr;
  vif.awvalid <= 1'b1;
  vif.wdata   <= tr.data;
  vif.wstrb   <= tr.strb;
  vif.wvalid  <= 1'b1;
  vif.bready  <= 1'b1;

  wait(vif.awvalid && vif.awready);
  @(posedge vif.clk);
  vif.awvalid <= 1'b0;

  wait(vif.wvalid && vif.wready);
  @(posedge vif.clk);
  vif.wvalid <= 1'b0;

  wait(vif.bvalid && vif.bready);
  tr.resp = vif.bresp;
  @(posedge vif.clk);
  vif.bready <= 1'b0;
endtask
```

读操作伪代码：

```systemverilog
task drive_read(axil_seq_item tr);
  @(posedge vif.clk);
  vif.araddr  <= tr.addr;
  vif.arvalid <= 1'b1;
  vif.rready  <= 1'b1;

  wait(vif.arvalid && vif.arready);
  @(posedge vif.clk);
  vif.arvalid <= 1'b0;

  wait(vif.rvalid && vif.rready);
  tr.rdata = vif.rdata;
  tr.resp  = vif.rresp;
  @(posedge vif.clk);
  vif.rready <= 1'b0;
endtask
```

### 6.3 `axil_monitor`

职责：

- 被动采集 AXI-Lite read/write transaction；
- 发送给 scoreboard、coverage、memory model。

输出端口：

```systemverilog
uvm_analysis_port #(axil_seq_item) ap;
```

采集内容：

```text
write transaction:
  awaddr
  wdata
  wstrb
  bresp

read transaction:
  araddr
  rdata
  rresp
```

### 6.4 `axil_agent`

组成：

```text
axil_agent
  axil_driver
  axil_monitor
  axil_sequencer
```

配置：

```systemverilog
class axil_agent_cfg extends uvm_object;
  bit is_active = 1;
  int unsigned max_wait_cycles = 1000;
  bit enable_random_gap = 0;
  `uvm_object_utils(axil_agent_cfg)
endclass
```

---

## 7. Passive DMA Monitor 规划

`dma_monitor` 是可选但推荐实现的 passive monitor。它不驱动 DUT，只观察 NPU DMA AXI4 信号。

### 7.1 目的

1. 统计 AXI4 read/write burst transaction；
2. 检查项目定义的 AXI4 子集协议；
3. 计算老师要求的事务级总线带宽利用率：

```text
事务级带宽利用率 = 事务内 VALID & READY 数据周期 / 事务总周期
```

### 7.2 `axi4_dma_txn`

```systemverilog
class axi4_dma_txn extends uvm_sequence_item;

  typedef enum {DMA_READ, DMA_WRITE} dma_dir_e;

  dma_dir_e dir;

  bit [31:0] addr;
  int unsigned len_beats;
  bit [2:0] size;
  bit [1:0] burst;

  int unsigned txn_cycles;
  int unsigned data_cycles;
  int unsigned bubble_cycles;

  bit [1:0] resp;
  bit error_seen;

  bit [31:0] last_wstrb;
  real util;

  `uvm_object_utils(axi4_dma_txn)

  function new(string name = "axi4_dma_txn");
    super.new(name);
  endfunction

endclass
```

### 7.3 读事务监控逻辑

```text
当 ARVALID && ARREADY:
  创建 read txn
  记录 addr, arlen, arsize, arburst
  txn_active = 1
  txn_cycles = 0
  expected_beats = arlen + 1

txn_active 期间:
  txn_cycles++

当 RVALID && RREADY:
  data_cycles++
  beat_count++
  检查 RRESP
  如果 RLAST:
    检查 beat_count == expected_beats
    结束 txn
    util = data_cycles / txn_cycles
    ap.write(txn)
```

### 7.4 写事务监控逻辑

```text
当 AWVALID && AWREADY:
  创建 write txn
  记录 addr, awlen, awsize, awburst
  txn_active = 1
  txn_cycles = 0
  expected_beats = awlen + 1

txn_active 期间:
  txn_cycles++

当 WVALID && WREADY:
  data_cycles++
  beat_count++
  记录 WSTRB
  检查 WLAST 是否与最后一个 beat 对齐

当 BVALID && BREADY:
  记录 BRESP
  检查 beat_count == expected_beats
  结束 txn
  util = data_cycles / txn_cycles
  ap.write(txn)
```

### 7.5 DMA checker 规则

```text
Read burst:
  ARSIZE 必须为 3'd5
  ARBURST 必须为 INCR = 2'b01
  ARADDR[4:0] 必须为 0
  R beat 数必须等于 ARLEN + 1
  RLAST 必须出现在最后一个 R beat
  RRESP 非 OKAY 时标记 error

Write burst:
  AWSIZE 必须为 3'd5
  AWBURST 必须为 INCR = 2'b01
  AWADDR[4:0] 必须为 0
  W beat 数必须等于 AWLEN + 1
  WLAST 必须出现在最后一个 W beat
  BRESP 非 OKAY 时标记 error
  每个有效 W beat 的 WSTRB 不应为 0
```

---

## 8. Status Monitor 规划

### 8.1 `npu_status_monitor`

从 `probe_vif.npu_status` 中采样：

```text
busy  = npu_status[1]
done  = npu_status[2]
error = npu_status[3]
```

### 8.2 输出事件

```text
busy_rise
busy_fall
done_rise
error_rise
timeout
```

### 8.3 `npu_status_txn`

```systemverilog
class npu_status_txn extends uvm_sequence_item;
  bit busy;
  bit done;
  bit error;
  longint unsigned cycle;

  `uvm_object_utils(npu_status_txn)

  function new(string name = "npu_status_txn");
    super.new(name);
  endfunction
endclass
```

---

## 9. Environment 规划

### 9.1 `soc_top_env`

组成：

```text
soc_top_env
  |
  +-- axil_agent           active
  +-- reset_agent          active
  +-- dma_monitor          passive, optional
  +-- npu_status_monitor   passive
  +-- virtual_sequencer
  +-- scoreboard
  +-- mem_model
  +-- golden_model
  +-- perf_checker
  +-- coverage_collector
```

### 9.2 Analysis 连接

```text
axil_monitor.ap       -> scoreboard.axil_imp
axil_monitor.ap       -> mem_model.axil_imp
axil_monitor.ap       -> coverage.axil_imp

dma_monitor.ap        -> scoreboard.dma_imp
dma_monitor.ap        -> perf_checker.dma_imp
dma_monitor.ap        -> coverage.dma_imp

status_monitor.ap     -> scoreboard.status_imp
status_monitor.ap     -> coverage.status_imp
```

### 9.3 `soc_top_env_cfg`

```systemverilog
class soc_top_env_cfg extends uvm_object;

  bit enable_dma_monitor = 1;
  bit enable_perf_check  = 1;
  bit enable_coverage    = 1;

  int unsigned timeout_cycles = 5_000_000;

  string data_dir;
  string test_name;

  bit [31:0] shared_ram_base = 32'h0000_0000;
  bit [31:0] npu_reg_base    = 32'h1000_0000;

  `uvm_object_utils(soc_top_env_cfg)

  function new(string name = "soc_top_env_cfg");
    super.new(name);
  endfunction

endclass
```

---

## 10. Memory Model 规划

### 10.1 `soc_mem_model`

UVM 侧维护 byte-addressable mirror memory。

```systemverilog
class soc_mem_model extends uvm_component;

  byte unsigned mem [int unsigned];

  `uvm_component_utils(soc_mem_model)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write32(bit [31:0] addr, bit [31:0] data, bit [3:0] strb);
    for (int i = 0; i < 4; i++) begin
      if (strb[i]) begin
        mem[addr + i] = data[8*i +: 8];
      end
    end
  endfunction

  function bit [31:0] read32(bit [31:0] addr);
    bit [31:0] data;
    for (int i = 0; i < 4; i++) begin
      data[8*i +: 8] = mem.exists(addr+i) ? mem[addr+i] : 8'h00;
    end
    return data;
  endfunction

  function void write_bytes(bit [31:0] base_addr, byte unsigned data[]);
    foreach (data[i]) begin
      mem[base_addr+i] = data[i];
    end
  endfunction

  function void read_bytes(bit [31:0] base_addr, int unsigned nbytes,
                           output byte unsigned data[]);
    data = new[nbytes];
    for (int i = 0; i < nbytes; i++) begin
      data[i] = mem.exists(base_addr+i) ? mem[base_addr+i] : 8'h00;
    end
  endfunction

endclass
```

### 10.2 Mirror 更新规则

AXI-Lite 写 shared RAM 时：

```text
if addr in 0x0000_0000 ~ 0x000F_FFFF:
  mem_model.write32(addr, wdata, wstrb)
```

NPU register 写不更新 memory mirror。

第一版不要求通过 DMA monitor 更新 mirror。任务完成后通过 AXI-Lite 从 DUT shared RAM 读回 output，作为 actual output。

---

## 11. Golden Model 规划

### 11.1 第一版：fixture-based golden

第一版不建议实现完整 SV Conv/FC golden model。优先复用现有 fixture：

```text
data/lenet/sample_xxx_input.memh
data/lenet/weights.memh
data/lenet/golden_xxx_output.memh
data/lenet/manifest.json
```

### 11.2 `soc_golden_model`

```systemverilog
class soc_golden_model extends uvm_component;

  byte unsigned expected_bytes[];
  bit [31:0] expected_words[];
  int expected_class;

  `uvm_component_utils(soc_golden_model)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void load_golden_bytes(string path);
    // 从 memh/bin 文件加载 expected_bytes
  endfunction

  function byte unsigned get_expected_byte(int unsigned offset);
    return expected_bytes[offset];
  endfunction

  function bit [31:0] get_expected_word(int unsigned offset);
    return expected_words[offset];
  endfunction

endclass
```

### 11.3 第二版可选增强

若时间允许，再添加小 shape SV reference model：

```text
conv_ref
fc_ref
pool_ref
requant_ref
```

但不是第一版优先级。

---

## 12. Scoreboard 规划

### 12.1 `soc_scoreboard` 总职责

Scoreboard 只检查系统级契约：

```text
1. AXI-Lite 正常访问应返回 OKAY；
2. reset 后状态正确；
3. start 后 busy/done/error 行为合理；
4. normal task 不应 error；
5. error task 应产生 error；
6. done 后 output memory 与 golden 一致；
7. DMA transaction 满足项目 AXI4 子集；
8. performance counter 非零且合理。
```

### 12.2 Scoreboard 输入

```text
AXI-Lite monitor:
  所有 read/write transaction

DMA monitor:
  read/write burst transaction
  txn_cycles / data_cycles / utilization

Status monitor:
  busy/done/error transition

Sequence:
  当前 task descriptor
  expected output 地址
  expected output 长度
  golden 文件路径
```

### 12.3 Checker 1：AXI-Lite response checker

正常 sequence：

```text
所有 AXI-Lite response 必须为 OKAY。
```

错误 sequence：

```text
非法地址访问允许 SLVERR/DECERR。
```

### 12.4 Checker 2：NPU status checker

正常任务期望：

```text
reset 后 busy=0, done=0, error=0
start 后 busy 在有限周期内拉高
任务期间 error=0
done 在 timeout 前出现
done 后 busy=0
```

错误任务期望：

```text
error=1 或 STATUS.error=1
error_code 可读
busy 不应永久卡死
```

### 12.5 Checker 3：output compare checker

任务完成后，sequence 用 AXI-Lite 读回 output memory，并调用 scoreboard 比对。

Byte compare：

```systemverilog
for (int i = 0; i < output_bytes; i++) begin
  if (actual[i] !== expected[i]) begin
    `uvm_error("OUTCMP", $sformatf(
      "Mismatch at byte %0d: actual=%02x expected=%02x",
      i, actual[i], expected[i]
    ))
  end
end
```

Word compare：

```systemverilog
for (int i = 0; i < output_words; i++) begin
  if (actual_word[i] !== expected_word[i]) begin
    `uvm_error("OUTCMP", $sformatf(
      "Mismatch at word %0d: actual=%08x expected=%08x",
      i, actual_word[i], expected_word[i]
    ))
  end
end
```

### 12.6 Checker 4：DMA transaction checker

若启用 `dma_monitor`：

```text
Read:
  arsize == 3'd5
  arburst == 2'b01
  araddr[4:0] == 0
  rbeat_count == arlen + 1
  rlast on final beat
  rresp == OKAY

Write:
  awsize == 3'd5
  awburst == 2'b01
  awaddr[4:0] == 0
  wbeat_count == awlen + 1
  wlast on final beat
  bresp == OKAY
  wstrb != 0 on valid beat
```

同时计算：

```text
read_util  = read_data_cycles  / read_txn_cycles
write_util = write_data_cycles / write_txn_cycles
```

### 12.7 Checker 5：performance counter checker

任务完成后读取 NPU performance counter。

第一版只做 sanity check：

```text
cycle_count > 0
read_beat_count > 0 for Conv/FC/Requant
write_beat_count > 0 for output-producing task
read_active >= read_beat_count
write_active >= write_beat_count
done 后 counter 不再异常变化
```

可选：对 LeNet32 做 reference 范围检查：

```text
read_beats  在历史 replay ±5% 范围内
write_beats 在历史 replay ±5% 范围内
cycle_count  在历史 replay ±10% 范围内
```

---

## 13. Coverage 规划

只做 top-level functional coverage。

### 13.1 Task coverage

```systemverilog
covergroup task_cg;
  task_type_cp: coverpoint task_type {
    bins conv    = {0};
    bins fc      = {1};
    bins pool    = {2};
    bins requant = {3};
    bins add     = {4};
    bins gap     = {5};
  }

  task_result_cp: coverpoint task_result {
    bins pass  = {0};
    bins error = {1};
  }

  task_x_result: cross task_type_cp, task_result_cp;
endgroup
```

### 13.2 Cluster mode coverage

```systemverilog
covergroup cluster_cg;
  cluster_mode_cp: coverpoint cluster_mode {
    bins single = {0};
    bins dual   = {1};
    bins full   = {2};
    bins mask   = {3};
  }

  cluster_mask_cp: coverpoint cluster_mask {
    bins one_hot[] = {6'b000001, 6'b000010, 6'b000100,
                      6'b001000, 6'b010000, 6'b100000};
    bins all_on    = {6'b111111};
    bins sparse[]  = {[1:62]};
  }
endgroup
```

### 13.3 AXI-Lite coverage

```systemverilog
covergroup axil_cg;
  addr_region_cp: coverpoint addr_region {
    bins shared_ram = {0};
    bins npu_regs   = {1};
    bins illegal    = {2};
  }

  op_cp: coverpoint op {
    bins read  = {0};
    bins write = {1};
  }

  resp_cp: coverpoint resp {
    bins okay   = {0};
    bins slverr = {2};
    bins decerr = {3};
  }

  region_x_op: cross addr_region_cp, op_cp;
endgroup
```

### 13.4 DMA coverage

```systemverilog
covergroup dma_cg;
  dir_cp: coverpoint dir {
    bins read  = {0};
    bins write = {1};
  }

  burst_len_cp: coverpoint len_beats {
    bins len1      = {1};
    bins len2_7    = {[2:7]};
    bins len8_15   = {[8:15]};
    bins len16     = {16};
  }

  util_cp: coverpoint util_percent {
    bins low    = {[0:25]};
    bins medium = {[26:75]};
    bins high   = {[76:100]};
  }

  dir_x_burst: cross dir_cp, burst_len_cp;
endgroup
```

### 13.5 Error coverage

```systemverilog
covergroup error_cg;
  error_type_cp: coverpoint error_type {
    bins misaligned_addr  = {0};
    bins invalid_task     = {1};
    bins start_while_busy = {2};
    bins illegal_address  = {3};
    bins timeout          = {4};
  }

  error_seen_cp: coverpoint error_seen {
    bins seen = {1};
  }
endgroup
```

---

## 14. Register / Address 定义

创建统一头文件：

```systemverilog
// soc_top_defines.svh

`define SOC_SHARED_RAM_BASE 32'h0000_0000
`define SOC_SHARED_RAM_SIZE 32'h0010_0000

`define SOC_NPU_REG_BASE    32'h1000_0000
`define SOC_NPU_REG_SIZE    32'h0000_0100
```

NPU 寄存器 offset 必须以当前 `rtl/npu/npu_ctrl.v` 为准。

执行层步骤：

```text
1. 打开 rtl/npu/npu_ctrl.v
2. 查找 localparam REG_* 或 case(addr)
3. 生成 soc_top_defines.svh
4. 所有 sequence 只使用 defines，不硬编码 offset
```

示例：

```systemverilog
`define NPU_REG_CTRL             (`SOC_NPU_REG_BASE + 32'h0000)
`define NPU_REG_STATUS           (`SOC_NPU_REG_BASE + 32'h0004)
`define NPU_REG_TASK_TYPE        (`SOC_NPU_REG_BASE + 32'h0008)
`define NPU_REG_INPUT_ADDR       (`SOC_NPU_REG_BASE + 32'h000C)
`define NPU_REG_WEIGHT_ADDR      (`SOC_NPU_REG_BASE + 32'h0010)
`define NPU_REG_OUTPUT_ADDR      (`SOC_NPU_REG_BASE + 32'h0014)
`define NPU_REG_ERROR_CODE       (`SOC_NPU_REG_BASE + 32'h00XX)
`define NPU_REG_PERF_CYCLE_LO    (`SOC_NPU_REG_BASE + 32'h00XX)
`define NPU_REG_PERF_READ_BEATS  (`SOC_NPU_REG_BASE + 32'h00XX)
`define NPU_REG_PERF_WRITE_BEATS (`SOC_NPU_REG_BASE + 32'h00XX)
```

---

## 15. Sequence 规划

### 15.1 `soc_base_seq`

所有 sequence 继承 `soc_base_seq`。

应封装如下 API：

```systemverilog
class soc_base_seq extends uvm_sequence;

  soc_virtual_sequencer vseqr;

  task axil_write32(bit [31:0] addr,
                    bit [31:0] data,
                    bit [3:0]  strb = 4'hF);
  endtask

  task axil_read32(bit [31:0] addr,
                   output bit [31:0] data);
  endtask

  task mem_write_bytes(bit [31:0] base_addr,
                       byte unsigned data[]);
  endtask

  task mem_read_bytes(bit [31:0] base_addr,
                      int unsigned nbytes,
                      output byte unsigned data[]);
  endtask

  task npu_write_reg(bit [31:0] reg_addr,
                     bit [31:0] data);
  endtask

  task npu_read_reg(bit [31:0] reg_addr,
                    output bit [31:0] data);
  endtask

  task npu_start();
  endtask

  task npu_poll_done(int unsigned timeout_cycles,
                     output bit done,
                     output bit error);
  endtask

endclass
```

### 15.2 `shared_ram_preload_seq`

输入：

```text
base_addr
data_file
nbytes
```

行为：

```text
读取 memh/bin 文件
按 32-bit word 通过 AXI-Lite 写入 shared RAM
同时更新 mem_model
写完后可选读回校验
```

### 15.3 `npu_task_desc`

定义一个统一 task descriptor：

```systemverilog
class npu_task_desc extends uvm_object;

  int unsigned task_type;

  bit [31:0] input_addr;
  bit [31:0] weight_addr;
  bit [31:0] output_addr;

  int unsigned input_bytes;
  int unsigned weight_bytes;
  int unsigned output_bytes;

  int unsigned input_w;
  int unsigned input_h;
  int unsigned input_c;
  int unsigned output_c;

  int unsigned kernel_w;
  int unsigned kernel_h;
  int unsigned stride;
  int unsigned padding;

  int unsigned cluster_mode;
  bit [5:0] cluster_mask;

  bit signed [31:0] requant_mult;
  int unsigned requant_shift;
  bit relu_enable;

  string golden_file;

  `uvm_object_utils(npu_task_desc)

  function new(string name = "npu_task_desc");
    super.new(name);
  endfunction

endclass
```

### 15.4 `npu_config_seq`

输入：`npu_task_desc desc`

行为：

```text
按照 desc 写 NPU 寄存器
写 cluster mode / cluster mask
写 requant / postproc 参数
写 input / weight / output 地址
写 input / weight / output byte count
写 shape / kernel / stride / padding 等配置
```

### 15.5 `npu_start_poll_seq`

行为：

```text
写 CTRL.start = 1
等待 busy 拉高，可选
轮询 STATUS
直到 done 或 error 或 timeout
若 timeout，报 UVM_FATAL
若 error，读取 ERROR_CODE
```

### 15.6 `npu_output_read_seq`

行为：

```text
从 output_addr 开始读 output_bytes
整理成 byte array / word array
送给 scoreboard compare
```

---

## 16. Test 用例规划

### 16.1 `soc_reset_reg_test`

目的：验证 reset 和基本寄存器状态。

步骤：

```text
1. reset DUT
2. 读 npu_status output
3. 读 NPU STATUS register
4. 读 capability register，如果存在
5. 检查 busy=0, done=0, error=0
```

通过标准：

```text
AXI-Lite response OKAY
status reset 正确
无 X/Z
```

---

### 16.2 `soc_shared_ram_rw_test`

目的：验证 AXI-Lite 到 shared RAM 的 32-bit 访问路径。

步骤：

```text
1. reset DUT
2. 向 shared RAM 写多个地址：
   0x0000_0000
   0x0000_0004
   0x0000_001C
   0x0000_0020
   0x000F_FFFC
3. 读回比较
4. 测试 byte strobe：
   wstrb=4'b0001
   wstrb=4'b0010
   wstrb=4'b0100
   wstrb=4'b1000
   wstrb=4'b1111
```

通过标准：

```text
读回数据与写入数据一致
byte strobe 正确
```

---

### 16.3 `npu_conv_smoke_test`

目的：通过 top.v 跑一个小 Conv task。

步骤：

```text
1. reset
2. preload input tensor
3. preload conv weight
4. config Conv task
5. start + poll
6. read output
7. compare golden
8. read perf counters
```

覆盖：

```text
AXI-Lite config
NPU DMA read activation
NPU DMA read weight
compute path
DMA writeback
done/status
```

---

### 16.4 `npu_fc_smoke_test`

目的：通过 top.v 跑 FC task。

重点覆盖：

```text
FC register config
FC output vector writeback
INT32 output compare
```

---

### 16.5 `npu_pool_smoke_test`

目的：通过 top.v 跑 Pool task。

建议输入：

```text
4x4 或 8x8 feature map
2x2 max pool stride=2
```

通过标准：

```text
输出与 golden pool result 一致
```

---

### 16.6 `npu_requant_smoke_test`

目的：验证 INT32 -> INT8 requant writeback。

重点检查：

```text
requant multiplier
requant shift
rounding
clamp
partial last beat WSTRB
```

---

### 16.7 `npu_lenet_1_test`

目的：LeNet 单样本 top-level end-to-end。

步骤：

```text
1. preload sample image
2. preload all LeNet weights
3. 依次配置并启动各层：
   Conv1
   Pool1
   Requant1
   Conv2
   Pool2
   Requant2
   FC1
   Requant3 / ReLU
   FC2
4. 读 final logits
5. testbench/software argmax
6. compare expected label
7. read perf counters
```

说明：Argmax 在 testbench/software 侧完成，不作为 NPU RTL 内部固定任务。

---

### 16.8 `npu_lenet_8_test`

目的：小批量 regression。

行为：

```text
循环 8 个 sample
每个 sample 跑完整 LeNet sequence
统计 pass/fail
```

通过标准：

```text
8/8 PASS 或按照现有 golden manifest 要求
```

---

### 16.9 `npu_lenet_32_test`

目的：representative regression + performance report。

行为：

```text
跑 32 个样本
记录总 cycle/read_beats/write_beats
输出分类准确率和 counter summary
```

---

### 16.10 `npu_cluster_mode_test`

目的：验证 runtime cluster mode / mask 在 top-level 可配置。

子用例：

```text
single mode: cluster_mode=0
dual mode:   cluster_mode=1
full mode:   cluster_mode=2
mask mode:   cluster_mask=6'b000011 / 6'b111111 / sparse mask
```

每个子用例跑一个小 Conv 或 FC smoke。

通过标准：

```text
任务 done
error=0
output 正确或至少 smoke pattern 正确
perf counter 有变化
```

注意：这个测试只宣称 cluster config top-level smoke，不宣称完整 full-cluster LeNet 性能闭环。

---

### 16.11 `npu_error_misaligned_addr_test`

目的：验证 task_checker / top error path。

步骤：

```text
1. 配置 input_addr 或 weight_addr 为非 64B 对齐
2. start
3. polling status
4. 期望 error=1
5. 读取 error_code
```

---

### 16.12 `npu_error_invalid_task_test`

目的：验证非法 task type。

步骤：

```text
1. task_type 写非法值
2. start
3. 期望 error=1
4. busy 不应卡死
```

---

### 16.13 `npu_start_while_busy_test`

目的：验证 busy 期间重复 start 的行为。

步骤：

```text
1. 启动一个较长任务
2. busy=1 时再次写 CTRL.start
3. 检查不会破坏当前任务
4. 任务最终 done 或产生预期 error
```

---

## 17. Regression 分层

### 17.1 Smoke regression

每次提交跑：

```text
soc_reset_reg_test
soc_shared_ram_rw_test
npu_conv_smoke_test
npu_fc_smoke_test
```

### 17.2 Basic regression

每天或重要提交跑：

```text
soc_reset_reg_test
soc_shared_ram_rw_test
npu_conv_smoke_test
npu_fc_smoke_test
npu_pool_smoke_test
npu_requant_smoke_test
npu_error_misaligned_addr_test
npu_error_invalid_task_test
```

### 17.3 Full regression

比赛/答辩前跑：

```text
所有 smoke/basic
npu_lenet_1_test
npu_lenet_8_test
npu_lenet_32_test
npu_cluster_mode_test
```

---

## 18. Report 输出要求

每个 test 结束时输出：

```text
TEST_NAME
RESULT: PASS/FAIL

AXI-LITE:
  write_count
  read_count
  error_resp_count

NPU STATUS:
  busy_seen
  done_seen
  error_seen
  error_code

OUTPUT:
  compared_bytes
  mismatch_count
  first_mismatch_offset

DMA PERF, if enabled:
  read_txn_count
  write_txn_count
  read_data_cycles
  read_txn_cycles
  write_data_cycles
  write_txn_cycles
  avg_read_util
  avg_write_util

NPU PERF COUNTERS:
  cycle_count
  read_beats
  write_beats
  read_active
  write_active
```

最终 regression 输出 CSV：

```text
test_name,result,cycles,read_beats,write_beats,mismatch_count,error_code,sim_time
```

---

## 19. 实施顺序

### Step 1：建立可编译 UVM skeleton

生成：

```text
tb_soc_top_uvm.sv
axil_if.sv
soc_probe_if.sv
soc_top_uvm_pkg.sv
soc_base_test.sv
soc_top_env.sv
```

目标：

```text
仿真能启动
DUT reset 能跑
UVM phase 能正常进入
```

### Step 2：实现 AXI-Lite agent

生成：

```text
axil_seq_item
axil_driver
axil_monitor
axil_sequencer
axil_agent
```

目标：

```text
soc_shared_ram_rw_test PASS
```

### Step 3：实现 base sequence API

生成：

```text
soc_base_seq
axil_write32
axil_read32
mem_write_bytes
mem_read_bytes
npu_write_reg
npu_read_reg
npu_start
npu_poll_done
```

目标：

```text
能用 sequence 读写 shared RAM 和 NPU register
```

### Step 4：实现 scoreboard + memory compare

生成：

```text
soc_scoreboard
soc_mem_model
soc_golden_model
```

目标：

```text
可以比较 output memory 和 golden file
```

### Step 5：实现 Conv/FC smoke

生成：

```text
npu_conv_smoke_test
npu_fc_smoke_test
npu_conv_task_seq
npu_fc_task_seq
```

目标：

```text
至少 1 个 Conv case PASS
至少 1 个 FC case PASS
```

### Step 6：接入 LeNet fixture

生成：

```text
npu_lenet_sample_seq
npu_lenet_1_test
```

目标：

```text
单样本 LeNet top-level PASS
```

### Step 7：补 DMA passive monitor

生成：

```text
soc_probe_if
axi4_dma_txn
axi4_dma_monitor
soc_perf_checker
```

目标：

```text
能统计读写 burst transaction
能输出 read/write transaction-level utilization
```

### Step 8：补 coverage

生成：

```text
soc_coverage
task_cg
cluster_cg
axil_cg
dma_cg
error_cg
```

目标：

```text
每个 test 结束输出 coverage summary
```

### Step 9：补 error tests

生成：

```text
npu_misaligned_addr_seq
npu_invalid_task_seq
npu_error_test
```

目标：

```text
error path 可验证
```

### Step 10：整理 regression 脚本

生成：

```text
scripts/run_uvm.py
scripts/parse_uvm_report.py
```

目标：

```text
一条命令跑 smoke/basic/full regression
自动输出结果表
```

---

## 20. 最终交付物清单

最终交付物包括：

```text
1. UVM top-level testbench
2. AXI-Lite active agent
3. reset agent
4. NPU status passive monitor
5. optional DMA passive monitor
6. shared memory mirror model
7. golden output compare scoreboard
8. performance checker
9. functional coverage collector
10. Conv/FC/Pool/Requant smoke tests
11. LeNet 1/8/32 tests
12. cluster mode smoke test
13. error tests
14. regression script
15. regression report
```

---

## 21. 对外描述建议

可以在论文/答辩中这样描述：

> 本项目采用 SoC top-level UVM 验证策略，以完整 CPU+NPU 异构 SoC 顶层作为 DUT。验证平台通过 AXI-Lite active agent 模拟 CPU 软件行为，对 shared RAM 和 NPU 控制寄存器进行访问，实现输入数据、权重参数和任务配置的加载；随后通过寄存器启动 NPU，并轮询状态寄存器获取 busy、done 和 error 信息。任务完成后，验证平台从 shared RAM 读回 NPU 写回结果，并与 golden reference 进行自动比对。平台同时通过 passive monitor 采集 AXI-Lite 访问、NPU status 变化以及可选的 NPU DMA AXI4 burst transaction，用于协议检查、性能统计和 functional coverage 收集。该环境重点验证从软件配置、shared memory 数据交互、NPU DMA 访存、阵列计算、后处理到结果写回的端到端系统行为。

---

## 22. 最重要的实现原则

这版 UVM 不追求每个 RTL 模块都充分验证，而是追求：

```text
1. top-level 数据流真实
2. test fixture 可复用
3. output 自动比对
4. status/error/perf 可检查
5. coverage 有体系
6. regression 可重复
```

工程上优先级如下：

```text
1. 先跑通 AXI-Lite agent + shared RAM RW
2. 再跑通 NPU register config + start/poll
3. 再接入 Conv/FC smoke
4. 再接入 LeNet single sample
5. 再补 LeNet batch / cluster / error / DMA monitor / coverage
```

最终不要宣称完成了模块级 exhaustive UVM，而应明确表述为：

```text
Top-level end-to-end UVM verification for CPU+NPU SoC.
```
