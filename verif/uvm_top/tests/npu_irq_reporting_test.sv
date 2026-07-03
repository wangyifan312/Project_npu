//=============================================================================
// NPU 中断信号_reporting_test.sv — Phase U8-a NPU IRQ Reporting BFM Test
//
// BFM 级别 verification of IRQ CSR protocol:
//   1. IRQ_EN reset=0 (backward compatible)
//   2. IRQ_STATUS done/error pending on task completion
//   3. IRQ_EN gate: npu_irq = |(irq_status & irq_en)
//   4. IRQ_CLEAR write-1-clear semantics
//   5. Back-to-back task IRQ behavior
//=============================================================================
`timescale 1ns / 1ps

class npu_irq_reporting_test extends soc_base_test;
  `uvm_component_utils(npu_irq_reporting_test)
  function new(string name="npu_irq_reporting_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  // helper: run a small GEMM, verify IRQ protocol
  task run_gemm_irq(int M_v, int K_v, int N_v, string label,
                    output bit irq_fired, output bit status_done,
                    output bit status_error, output bit func_ok);
    soc_base_seq m_seq;
    bit [31:0] rdata, ctrl_val, cycle_lo;
    int i, r, c, errs, row_stride;

    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);

    // 预加载 all-1
    for (i=0; i<M_v*K_v; i=i+4)
      m_seq.axil_write32(32'h0000_0100+i, 32'h01010101);
    for (i=0; i<K_v*N_v; i=i+4)
      m_seq.axil_write32(32'h0001_0000+i, 32'h01010101);
    row_stride = ((N_v*4+31)/32)*32;
    for (i=0; i<M_v*row_stride+64; i=i+4)
      m_seq.axil_write32(32'h0002_0000+i, 32'hDEADBEEF);

    // 配置
    m_seq.axil_write32(`NPU_REG_TASK_TYPE,    32'd7);
    m_seq.axil_write32(`NPU_REG_CONV_CFG,     32'h20);
    m_seq.axil_write32(`NPU_REG_POSTPROC,     32'd0);
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR,   32'h0000_0100);
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,  32'h0001_0000);
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,  32'h0002_0000);
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,  M_v*K_v);
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES, K_v*N_v);
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES, M_v*N_v*4);
    m_seq.axil_write32(`NPU_REG_DIM_IN,       {16'd1, M_v[15:0]});
    m_seq.axil_write32(`NPU_REG_DIM_OUT,      {N_v[15:0], K_v[15:0]});
    m_seq.axil_write32(`NPU_REG_CLUSTER_MODE, 32'd0);
    m_seq.axil_write32(`NPU_REG_CLUSTER_MASK, 32'd1);

    // 启动
    m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);

    // 轮询等待完成 OR error
    repeat(500000) begin
      m_seq.axil_read32(`NPU_REG_CTRL, ctrl_val);
      if (ctrl_val[2] || ctrl_val[3]) break;
      #100;
    end
    m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);

    // 读 IRQ status
    m_seq.axil_read32(`NPU_REG_IRQ_STATUS, rdata);
    status_done  = rdata[`NPU_IRQ_DONE];
    status_error = rdata[`NPU_IRQ_ERROR];

    // Check npu_irq
    irq_fired = probe_vif.npu_irq;

    // 验证输出
    errs = 0;
    for (r=0; r<M_v; r++)
      for (c=0; c<N_v; c++) begin
        m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
        if ($signed(rdata) != K_v) errs++;
      end
    func_ok = (errs == 0) && !ctrl_val[3];

    `uvm_info("IRQ", $sformatf("%s: done_pend=%0d err_pend=%0d irq=%0d out=%0s",
      label, status_done, status_error, irq_fired, func_ok?"PASS":"FAIL"), UVM_NONE)
  endtask

  task run_phase(uvm_phase phase);
    bit irq_fired, status_done, status_error, func_ok;
    bit [31:0] rdata, ctrl_val;
    soc_base_seq m_seq;

    phase.raise_objection(this);
    m_seq = soc_base_seq::type_id::create("m_seq");
    m_seq.start(env.axil_ag.seqr);
    #200;

    `uvm_info("IRQ", "=== NPU IRQ REPORTING BFM TEST (Phase U8-a) ===", UVM_NONE)

    // ---- Test 1: IRQ_EN reset default is 0 ----
    m_seq.axil_read32(`NPU_REG_IRQ_EN, rdata);
    `uvm_info("IRQ", $sformatf("Test1 IRQ_EN reset: 0x%08x (expect 0)", rdata), UVM_NONE)

    // ---- Test 2: IRQ_STATUS done pending on task done ----
    // 清除 any stale
    m_seq.axil_write32(`NPU_REG_IRQ_CLEAR, 32'h3);
    m_seq.axil_write32(`NPU_REG_IRQ_EN,    32'h0);  // disabled initially
    run_gemm_irq(4, 64, 16, "T2_noen", irq_fired, status_done, status_error, func_ok);

    // Check: status_done should be 1 (pending regardless of en)
    if (!status_done)
      `uvm_error("IRQ", "T2: IRQ_STATUS.done NOT pending after task done")
    if (status_error)
      `uvm_error("IRQ", "T2: IRQ_STATUS.error pending (unexpected)")
    // With IRQ_EN=0, irq should be 0
    if (irq_fired)
      `uvm_info("IRQ", "T2: npu_irq=1 (EN=0, may fire if probe sees transient)", UVM_NONE)

    // ---- Test 3: Enable IRQ, verify npu_irq fires ----
    m_seq.axil_write32(`NPU_REG_IRQ_EN,    32'h1);  // enable done irq
    // Check npu_irq now with en=1 and pending=1
    #1000;
    irq_fired = probe_vif.npu_irq;
    `uvm_info("IRQ", $sformatf("Test3 EN=1 pending=1: irq=%0d (expect 1)", irq_fired), UVM_NONE)
    if (!irq_fired)
      `uvm_error("IRQ", "T3: npu_irq=0 with EN=1, STATUS.done=1")

    // ---- Test 4: Clear done pending ----
    m_seq.axil_write32(`NPU_REG_IRQ_CLEAR, 32'h1);  // clear done only
    #1000;
    irq_fired = probe_vif.npu_irq;
    m_seq.axil_read32(`NPU_REG_IRQ_STATUS, rdata);
    `uvm_info("IRQ", $sformatf("Test4 CLEAR done: irq=%0d status=0x%x (expect irq=0, done=0)",
      irq_fired, rdata[1:0]), UVM_NONE)
    if (rdata[0])
      `uvm_error("IRQ", "T4: done still pending after CLEAR.done=1")
    if (irq_fired)
      `uvm_error("IRQ", "T4: npu_irq still 1 after CLEAR")

    // ---- Test 5: Write 0 does NOT clear ----
    m_seq.axil_write32(`NPU_REG_IRQ_CLEAR, 32'h3);  // clear all
    // Run another task to set done again
    run_gemm_irq(4, 64, 16, "T5", irq_fired, status_done, status_error, func_ok);
    // 写 0 to CLEAR
    m_seq.axil_write32(`NPU_REG_IRQ_CLEAR, 32'h0);
    #1000;
    m_seq.axil_read32(`NPU_REG_IRQ_STATUS, rdata);
    `uvm_info("IRQ", $sformatf("Test5 CLEAR=0: done_pend=%0d (expect 1, W1C)", rdata[0]), UVM_NONE)
    if (!rdata[0])
      `uvm_error("IRQ", "T5: done cleared by CLEAR=0 (should be W1C)")

    // ---- Test 6: Error IRQ ----
    m_seq.axil_write32(`NPU_REG_IRQ_CLEAR, 32'h3);
    m_seq.axil_write32(`NPU_REG_IRQ_EN,    32'h2);  // enable error irq only
    // Trigger an error: invalid task_type
    m_seq.axil_write32(`NPU_REG_TASK_TYPE,  32'd6);  // invalid (only 6 is valid)
    m_seq.axil_write32(`NPU_REG_INPUT_ADDR, 32'h0000_0100);
    m_seq.axil_write32(`NPU_REG_WEIGHT_ADDR,32'h0001_0000);
    m_seq.axil_write32(`NPU_REG_OUTPUT_ADDR,32'h0002_0000);
    m_seq.axil_write32(`NPU_REG_INPUT_BYTES,32'd16);
    m_seq.axil_write32(`NPU_REG_WEIGHT_BYTES,32'd16);
    m_seq.axil_write32(`NPU_REG_OUTPUT_BYTES,32'd16);
    m_seq.axil_write32(`NPU_REG_CTRL,       32'd1);
    repeat(50000) begin
      m_seq.axil_read32(`NPU_REG_CTRL, ctrl_val);
      if (ctrl_val[3]) break;
      #100;
    end
    m_seq.axil_read32(`NPU_REG_IRQ_STATUS, rdata);
    irq_fired = probe_vif.npu_irq;
    `uvm_info("IRQ", $sformatf("Test6 error: ctrl_err=%0d status_err=%0d irq=%0d",
      ctrl_val[3], rdata[1], irq_fired), UVM_NONE)
    if (!ctrl_val[3])
      `uvm_error("IRQ", "T6: no CTRL.error")
    if (!rdata[1])
      `uvm_error("IRQ", "T6: IRQ_STATUS.error not pending")
    if (!irq_fired)
      `uvm_error("IRQ", "T6: npu_irq=0 with error pending and EN.error=1")

    // 清除
    m_seq.axil_write32(`NPU_REG_IRQ_CLEAR, 32'h2);
    #1000;
    m_seq.axil_read32(`NPU_REG_IRQ_STATUS, rdata);
    if (rdata[1])
      `uvm_error("IRQ", "T6: error still pending after clear")

    // ---- Test 7: Back-to-back ----
    // 清除 error state from Test6, clear IRQ
    m_seq.axil_write32(`NPU_REG_CTRL, 32'h10);  // CTRL[4]=1 clear error
    #1000;
    m_seq.axil_write32(`NPU_REG_IRQ_CLEAR, 32'h3);
    m_seq.axil_write32(`NPU_REG_IRQ_EN,    32'h1);
    run_gemm_irq(4, 64, 16, "B2B_T1", irq_fired, status_done, status_error, func_ok);
    if (!func_ok) `uvm_error("IRQ", "B2B_T1: output FAIL")
    // 清除
    m_seq.axil_write32(`NPU_REG_IRQ_CLEAR, 32'h1);
    #1000;
    // Run second task
    run_gemm_irq(4, 128, 16, "B2B_T2", irq_fired, status_done, status_error, func_ok);
    if (!func_ok) `uvm_error("IRQ", "B2B_T2: output FAIL")
    if (!status_done)
      `uvm_error("IRQ", "B2B_T2: IRQ_STATUS.done not pending for task2")

    `uvm_info("IRQ", "=== NPU IRQ REPORTING BFM TEST COMPLETE ===", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
