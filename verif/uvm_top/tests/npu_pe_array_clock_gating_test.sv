//=============================================================================
// npu_pe_array_clock_gating_test.sv — Phase U6-a PE Array Clock Gating Test
//
// 验证： dynamic PE array clock gating via existing tile_clk_en probe.
// When NPU is idle (FSM_IDLE/F_DONE/FSM_ERROR), ALL tile clock enables
// should be 0. During active computation (GEMM/FC/Conv), at least some
// tile 时钟使能s should be 1.
//
// Uses existing soc_probe_if.npu_cluster_tile_clk_en_flat (1536-bit).
// Sticky flags: saw_idle_zero, saw_active_one, saw_done_zero.
//=============================================================================
`timescale 1ns / 1ps

class npu_pe_array_clock_gating_test extends soc_base_test;
  `uvm_component_utils(npu_pe_array_clock_gating_test)
  function new(string name="npu_pe_array_clock_gating_test", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  //----------------------------------------------------------------------------
  // check_gating: sample tile clock enables and update sticky flags
  //----------------------------------------------------------------------------
  task check_gating(string label, output bit saw_zero, output bit saw_one);
    bit [1535:0] tile_en;
    tile_en = probe_vif.npu_cluster_tile_clk_en_flat;
    saw_zero = (tile_en == 1536'h0);
    saw_one  = (|tile_en[255:0]);
    `uvm_info("CLK_GATE", $sformatf("%s: tile_en[0]=%0d tile_en[255]=%0d any=%0d all_zero=%0d",
      label, tile_en[0], tile_en[255], saw_one, saw_zero), UVM_MEDIUM)
  endtask

  //----------------------------------------------------------------------------
  // run_gemm_and_check: run GEMM streaming, sample clock enables during/after
  //----------------------------------------------------------------------------
  task run_gemm_and_check(int M_v, int K_v, int N_v, string label,
                          output bit saw_active, output bit saw_done_zero,
                          output bit func_pass);
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

    m_seq.axil_write32(`NPU_REG_CTRL, 32'd1);

    // Sample during busy window
    repeat(100) begin
      m_seq.axil_read32(`NPU_REG_CTRL, ctrl_val);
      if (ctrl_val[1]) begin  // busy=1
        bit dummy_zero;
        check_gating({label,"_BUSY"}, dummy_zero, saw_active);
      end
      if (ctrl_val[2] || ctrl_val[3]) break;
      #10;
    end

    m_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);

    // Sample after done — allow small settle delay for FSM transition
    #10000;
    begin
      bit dummy_active;
      check_gating({label,"_POST"}, saw_done_zero, dummy_active);
    end

    // 验证输出
    if (ctrl_val[3]) begin
      m_seq.axil_read32(`NPU_REG_STATUS, rdata);
      `uvm_error("CLK_GATE", $sformatf("%s ERROR code=0x%02x", label, rdata[7:0]))
      func_pass = 1'b0;
      return;
    end

    errs = 0;
    for (r=0; r<M_v; r++)
      for (c=0; c<N_v; c++) begin
        m_seq.axil_read32(32'h0002_0000 + r*row_stride + c*4, rdata);
        if ($signed(rdata) != K_v) errs++;
      end

    func_pass = (errs == 0);
    if (func_pass)
      `uvm_info("CLK_GATE", $sformatf("%s: cycles=%0d output PASS", label, cycle_lo), UVM_NONE)
    else
      `uvm_error("CLK_GATE", $sformatf("%s: %0d mismatches", label, errs))
  endtask

  //----------------------------------------------------------------------------
  // run_phase
  //----------------------------------------------------------------------------
  task run_phase(uvm_phase phase);
    bit saw_idle_zero, saw_active_one, saw_done_zero;
    bit saw_any_active, saw_any_done_zero;
    bit func_pass;
    int total_func_fail;

    phase.raise_objection(this);
    #200;

    // ---- Test 1: Idle gating ----
    `uvm_info("CLK_GATE", "=== Test 1: IDLE clock gating ===", UVM_NONE)
    #100000;  // wait 100us (100000ns) in idle
    check_gating("IDLE", saw_idle_zero, saw_any_active);
    if (!saw_idle_zero)
      `uvm_error("CLK_GATE", "IDLE: tile_clk_en NOT zero during idle")
    else
      `uvm_info("CLK_GATE", "IDLE: tile_clk_en = 0 PASS", UVM_NONE)

    // ---- Test 2: GEMM streaming active ----
    `uvm_info("CLK_GATE", "=== Test 2: GEMM streaming active ===", UVM_NONE)
    run_gemm_and_check(8, 64, 64, "GEMM", saw_any_active, saw_any_done_zero, func_pass);
    if (!func_pass) total_func_fail++;
    if (saw_any_active)
      `uvm_info("CLK_GATE", "GEMM busy: tile_clk_en != 0 PASS", UVM_NONE)
    else
      `uvm_error("CLK_GATE", "GEMM busy: tile_clk_en WAS zero (FAIL)")
    if (saw_any_done_zero)
      `uvm_info("CLK_GATE", "GEMM done: tile_clk_en == 0 PASS", UVM_NONE)
    else
      `uvm_error("CLK_GATE", "GEMM done: tile_clk_en NOT zero (FAIL)")

    // ---- Test 3: IDLE again after task ----
    #100000;
    begin bit d; check_gating("POST_GEMM_IDLE", d, saw_any_active); end
    if (!saw_any_active)
      `uvm_info("CLK_GATE", "POST_GEMM idle: tile_clk_en = 0 PASS", UVM_NONE)

    // ---- Test 4: Back-to-back ----
    `uvm_info("CLK_GATE", "=== Test 4: B2B GEMM -> GEMM ===", UVM_NONE)
    run_gemm_and_check(4, 64, 16, "B2B_T1", saw_any_active, saw_any_done_zero, func_pass);
    if (!func_pass) total_func_fail++;
    // Small gap, then second task
    #10000;
    run_gemm_and_check(4, 128, 16, "B2B_T2", saw_any_active, saw_any_done_zero, func_pass);
    if (!func_pass) total_func_fail++;

    saw_active_one = saw_any_active;
    saw_done_zero = saw_any_done_zero;

    // ---- Summary ----
    `uvm_info("CLK_GATE", "=== Clock Gating Summary ===", UVM_NONE)
    `uvm_info("CLK_GATE", $sformatf("saw_idle_zero=%0d saw_active_one=%0d saw_done_zero=%0d func_fails=%0d",
      saw_idle_zero, saw_active_one, saw_done_zero, total_func_fail), UVM_NONE)

    if (saw_idle_zero && saw_active_one && saw_done_zero && (total_func_fail == 0))
      `uvm_info("CLK_GATE", "=== PE ARRAY CLOCK GATING PASS ===", UVM_NONE)
    else
      `uvm_error("CLK_GATE", "=== PE ARRAY CLOCK GATING FAIL ===")

    phase.drop_objection(this);
  endtask
endclass
