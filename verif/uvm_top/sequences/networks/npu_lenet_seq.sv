//=============================================================================
// npu_lenet_seq.sv — Full LeNet-5 Network Sequence
//
// Orchestrates the complete 9-layer LeNet pipeline:
//   Conv1 -> Pool1 -> Requant1(Conv2) -> Conv2 -> Pool2 ->
//   Requant2(FC1) -> FC1 -> Requant3(FC2) -> FC2
//
// Assumes ALL data (input image, weights, biases) is ALREADY preloaded
// into shared RAM via the backdoor_if virtual interface (load_memh task).
// This sequence only handles NPU register programming, start/poll, and
// final logit readback.
//
// 内存 layout mirrors tb_top_lenet.v:
//   INPUT_ADDR      = 32'h0000_0100   (784 bytes)
//   CONV1_WGT_ADDR  = 32'h0000_1000   (500 bytes)
//   CONV1_OUT_ADDR  = 32'h0000_4000   (24*24*20*4 = 46080 bytes INT32)
//   POOL1_OUT_ADDR  = 32'h0001_8000   (12*12*20*4 = 11520 bytes INT32)
//   CONV2_IN_ADDR   = 32'h0001_C000   (12*12*20   = 2880 bytes INT8)
//   CONV2_WGT_ADDR  = 32'h0002_0000   (5*5*20*50  = 25000 bytes INT8)
//   CONV2_OUT_ADDR  = 32'h0006_0000   (8*8*50*4   = 12800 bytes INT32)
//   POOL2_OUT_ADDR  = 32'h0008_0000   (4*4*50*4   = 3200 bytes INT32)
//   FC1_WGT_ADDR   = 32'h0009_0000   (4*4*50*500 = 400000 bytes INT8)
//   FC1_OUT_ADDR   = 32'h000F_2000   (500*4       = 2000 bytes INT32)
//   FC2_WGT_ADDR   = 32'h000F_3000   (500*10      = 5000 bytes INT8)
//   FC2_OUT_ADDR   = 32'h000F_5000   (10*4        = 40 bytes INT32)
//
// Properties (set before start()):
//   input_addr, conv1_wgt_addr, conv1_out_addr, pool1_out_addr,
//   conv2_in_addr, conv2_wgt_addr, conv2_out_addr, pool2_out_addr,
//   fc1_wgt_addr, fc1_out_addr, fc2_wgt_addr, fc2_out_addr
//   rq_conv2_mult, rq_conv2_shift, rq_fc1_mult, rq_fc1_shift,
//   rq_fc2_mult, rq_fc2_shift
//   cluster_mode
//
// 结果s (read after body()):
//   done, error, error_code
//   fc2_logits[0:9] — 10 signed INT32 logit values
//=============================================================================

`timescale 1ns / 1ps

class npu_lenet_seq extends soc_base_seq;

  `uvm_object_utils(npu_lenet_seq)

  //-----------------------------------------------------------------------------
  // 内存 layout (defaults match tb_top_lenet.v)
  //-----------------------------------------------------------------------------
  bit [31:0] input_addr;
  bit [31:0] conv1_wgt_addr;
  bit [31:0] conv1_out_addr;
  bit [31:0] pool1_out_addr;
  bit [31:0] conv2_in_addr;
  bit [31:0] conv2_wgt_addr;
  bit [31:0] conv2_out_addr;
  bit [31:0] pool2_out_addr;
  bit [31:0] fc1_wgt_addr;
  bit [31:0] fc1_out_addr;
  bit [31:0] fc2_wgt_addr;
  bit [31:0] fc2_out_addr;

  //-----------------------------------------------------------------------------
  // 重量化 parameters (defaults: pass-through, overridden by test)
  //-----------------------------------------------------------------------------
  int unsigned rq_conv2_mult;
  int unsigned rq_conv2_shift;
  int unsigned rq_fc1_mult;
  int unsigned rq_fc1_shift;
  int unsigned rq_fc2_mult;
  int unsigned rq_fc2_shift;

  //-----------------------------------------------------------------------------
  // Cluster configuration
  //-----------------------------------------------------------------------------
  bit [1:0] cluster_mode;

  //-----------------------------------------------------------------------------
  // Polling timeout (cycles)
  //-----------------------------------------------------------------------------
  int unsigned poll_timeout;

  //-----------------------------------------------------------------------------
  // 结果s
  //-----------------------------------------------------------------------------
  bit           done;
  bit           error;
  bit [7:0]     error_code;
  int signed    fc2_logits[10];

  function new(string name = "npu_lenet_seq");
    super.new(name);

    input_addr      = 32'h0000_0100;
    conv1_wgt_addr  = 32'h0000_1000;
    conv1_out_addr  = 32'h0000_4000;
    pool1_out_addr  = 32'h0001_8000;
    conv2_in_addr   = 32'h0001_C000;
    conv2_wgt_addr  = 32'h0002_0000;
    conv2_out_addr  = 32'h0006_0000;
    pool2_out_addr  = 32'h0008_0000;
    fc1_wgt_addr    = 32'h0009_0000;
    fc1_out_addr    = 32'h000F_2000;
    fc2_wgt_addr    = 32'h000F_3000;
    fc2_out_addr    = 32'h000F_5000;

    rq_conv2_mult   = 1;
    rq_conv2_shift  = 0;
    rq_fc1_mult     = 1;
    rq_fc1_shift    = 0;
    rq_fc2_mult     = 1;
    rq_fc2_shift    = 0;

    cluster_mode    = 2'd2;
    poll_timeout    = 10000000;

    done   = 1'b0;
    error  = 1'b0;
    error_code = 8'h0;
  endfunction

  //-----------------------------------------------------------------------------
  // Internal helper: configure and run a single NPU layer.
  // Returns via poll_seq.done / poll_seq.error.
  //-----------------------------------------------------------------------------
  task run_npu_layer(
    input bit [2:0]  task_type,
    input bit [31:0] in_addr,
    input bit [31:0] wgt_addr,
    input bit [31:0] out_addr,
    input bit [31:0] in_bytes,
    input bit [31:0] wgt_bytes,
    input bit [31:0] out_bytes,
    input bit [15:0] iw,
    input bit [15:0] ih,
    input bit [15:0] ic,
    input bit [15:0] oc,
    input bit        relu,
    input bit        pool,
    input bit [31:0] conv_cfg_val,
    input bit [31:0] requant_slot_sel_val,
    input bit [31:0] requant_mult_val,
    input bit [31:0] requant_shift_val,
    input bit [31:0] bias_addr_val,
    input bit [31:0] bias_bytes_val,
    input bit [31:0] src1_addr_val,
    input bit [31:0] src1_bytes_val,
    input bit [31:0] add_cfg_val,
    input bit [31:0] add_src0_mult_val,
    input bit [31:0] add_src0_shift_val,
    input bit [31:0] add_src1_mult_val,
    input bit [31:0] add_src1_shift_val,
    input bit [31:0] add_out_mult_val,
    input bit [31:0] add_out_shift_val,
    input bit [31:0] postproc_cfg_ext_val,
    input bit [31:0] gap_cfg_val,
    input string     layer_name
  );
    npu_config_seq     cfg_seq;
    npu_start_poll_seq poll_seq;
    begin
      `uvm_info("LENET", $sformatf("=== %0s: Configuring ===", layer_name), UVM_NONE)

      cfg_seq = npu_config_seq::type_id::create("cfg_seq");
      cfg_seq.task_type    = task_type;
      cfg_seq.input_addr   = in_addr;
      cfg_seq.weight_addr  = wgt_addr;
      cfg_seq.output_addr  = out_addr;
      cfg_seq.input_bytes  = in_bytes;
      cfg_seq.weight_bytes = wgt_bytes;
      cfg_seq.output_bytes = out_bytes;
      cfg_seq.input_h      = ih;
      cfg_seq.input_w      = iw;
      cfg_seq.input_c      = ic;
      cfg_seq.output_c     = oc;
      cfg_seq.relu_en      = relu;
      cfg_seq.pool_en      = pool;
      cfg_seq.conv_cfg     = conv_cfg_val;
      cfg_seq.cluster_mode = cluster_mode;
      cfg_seq.cluster_mask = 6'h3F;

      cfg_seq.requant_slot_sel   = requant_slot_sel_val;
      cfg_seq.requant_multiplier = requant_mult_val;
      cfg_seq.requant_shift      = requant_shift_val;

      cfg_seq.bias_addr        = bias_addr_val;
      cfg_seq.bias_bytes       = bias_bytes_val;
      cfg_seq.src1_addr        = src1_addr_val;
      cfg_seq.src1_bytes       = src1_bytes_val;
      cfg_seq.add_cfg          = add_cfg_val;
      cfg_seq.add_src0_mult    = add_src0_mult_val;
      cfg_seq.add_src0_shift   = add_src0_shift_val;
      cfg_seq.add_src1_mult    = add_src1_mult_val;
      cfg_seq.add_src1_shift   = add_src1_shift_val;
      cfg_seq.add_out_mult     = add_out_mult_val;
      cfg_seq.add_out_shift    = add_out_shift_val;
      cfg_seq.postproc_cfg_ext = postproc_cfg_ext_val;
      cfg_seq.gap_cfg          = gap_cfg_val;

      cfg_seq.start(m_sequencer);

      `uvm_info("LENET", $sformatf("=== %0s: Starting/Polling ===", layer_name), UVM_NONE)

      poll_seq = npu_start_poll_seq::type_id::create("poll_seq");
      poll_seq.timeout_cycles = poll_timeout;
      poll_seq.start(m_sequencer);

      if (poll_seq.error) begin
        `uvm_error("LENET", $sformatf("%0s NPU error: code=0x%02x", layer_name, poll_seq.error_code))
        error      = 1'b1;
        error_code = poll_seq.error_code;
      end
      if (!poll_seq.done && !poll_seq.error) begin
        `uvm_error("LENET", $sformatf("%0s NPU timeout", layer_name))
        error = 1'b1;
      end
    end
  endtask

  //-----------------------------------------------------------------------------
  // body: Full LeNet pipeline
  //-----------------------------------------------------------------------------
  virtual task body();
    int s;
    npu_output_read_seq read_seq;

    done   = 1'b0;
    error  = 1'b0;
    error_code = 8'h0;
    for (s = 0; s < 10; s++)
      fc2_logits[s] = 32'sd0;

    //---------------------------------------------------------------------------
    // 0. Program requantization slots
    //    Slot 0: Conv2 requant  (Pool1 INT32 -> Conv2 input INT8)
    //    Slot 1: FC1 requant    (Pool2 INT32 -> FC1 input INT8)
    //    Slot 2: FC2 requant    (FC1 INT32  -> FC2 input INT8)
    //---------------------------------------------------------------------------
    `uvm_info("LENET", "=== Programming Requant Slots ===", UVM_NONE)

    axil_write32(`NPU_REG_REQUANT0_MULT,  rq_conv2_mult[31:0]);
    axil_write32(`NPU_REG_REQUANT0_SHIFT, rq_conv2_shift[31:0]);
    axil_write32(`NPU_REG_REQUANT1_MULT,  rq_fc1_mult[31:0]);
    axil_write32(`NPU_REG_REQUANT1_SHIFT, rq_fc1_shift[31:0]);
    axil_write32(`NPU_REG_REQUANT2_MULT,  rq_fc2_mult[31:0]);
    axil_write32(`NPU_REG_REQUANT2_SHIFT, rq_fc2_shift[31:0]);

    //---------------------------------------------------------------------------
    // 1. Conv1: 5x5 kernel, 1->20 channels, valid (no padding), 28x28 input
    //    H_out = 28 - 5 + 1 = 24, W_out = 24
    //    Output: 24*24*20 = 11520 INT32 elements, 46080 bytes
    //---------------------------------------------------------------------------
    run_npu_layer(
      /* task_type      */ 3'd0,
      /* in_addr        */ input_addr,
      /* wgt_addr       */ conv1_wgt_addr,
      /* out_addr       */ conv1_out_addr,
      /* in_bytes       */ 32'd784,
      /* wgt_bytes      */ 32'd500,
      /* out_bytes      */ 32'd46080,
      /* iw             */ 16'd28,
      /* ih             */ 16'd28,
      /* ic             */ 16'd1,
      /* oc             */ 16'd20,
      /* relu           */ 1'b0,
      /* pool           */ 1'b0,
      /* conv_cfg       */ 32'h0,
      /* requant_sel    */ 32'd0,
      /* requant_mult   */ 32'd0,
      /* requant_shift  */ 32'd0,
      /* bias_addr      */ 32'd0,
      /* bias_bytes     */ 32'd0,
      /* src1_addr      */ 32'd0,
      /* src1_bytes     */ 32'd0,
      /* add_cfg        */ 32'd0,
      /* add_src0_mult  */ 32'd0,
      /* add_src0_shift */ 32'd0,
      /* add_src1_mult  */ 32'd0,
      /* add_src1_shift */ 32'd0,
      /* add_out_mult   */ 32'd0,
      /* add_out_shift  */ 32'd0,
      /* postproc_cfg   */ 32'd0,
      /* gap_cfg        */ 32'd0,
      /* layer_name     */ "Conv1"
    );
    if (error) return;

    //---------------------------------------------------------------------------
    // 2. Pool1: 2x2 MaxPool stride 2, 24x24x20 -> 12x12x20
    //    Output: 12*12*20 = 2880 INT32 elements, 11520 bytes
    //---------------------------------------------------------------------------
    run_npu_layer(
      /* task_type      */ 3'd2,
      /* in_addr        */ conv1_out_addr,
      /* wgt_addr       */ 32'h0,
      /* out_addr       */ pool1_out_addr,
      /* in_bytes       */ 32'd46080,
      /* wgt_bytes      */ 32'd0,
      /* out_bytes      */ 32'd11520,
      /* iw             */ 16'd24,
      /* ih             */ 16'd24,
      /* ic             */ 16'd20,
      /* oc             */ 16'd20,
      /* relu           */ 1'b0,
      /* pool           */ 1'b1,
      /* conv_cfg       */ 32'h0,
      /* requant_sel    */ 32'd0,
      /* requant_mult   */ 32'd0,
      /* requant_shift  */ 32'd0,
      /* bias_addr      */ 32'd0,
      /* bias_bytes     */ 32'd0,
      /* src1_addr      */ 32'd0,
      /* src1_bytes     */ 32'd0,
      /* add_cfg        */ 32'd0,
      /* add_src0_mult  */ 32'd0,
      /* add_src0_shift */ 32'd0,
      /* add_src1_mult  */ 32'd0,
      /* add_src1_shift */ 32'd0,
      /* add_out_mult   */ 32'd0,
      /* add_out_shift  */ 32'd0,
      /* postproc_cfg   */ 32'd0,
      /* gap_cfg        */ 32'd0,
      /* layer_name     */ "Pool1"
    );
    if (error) return;

    //---------------------------------------------------------------------------
    // 3. Requant1: Pool1 INT32 -> Conv2 input INT8
    //    12*12*20 = 2880 elements
    //    Uses requant slot 0 (rq_conv2_mult / rq_conv2_shift)
    //    Note: we write REQUANT_SEL directly, then pass requant_mult=0 to
    //          npu_config_seq to avoid it overwriting slot 0's values.
    //---------------------------------------------------------------------------
    `uvm_info("LENET", "=== Requant1 (Conv2): Pool1 INT32 -> Conv2 INT8 ===", UVM_NONE)

    axil_write32(`NPU_REG_REQUANT_SEL, 32'd0);

    run_npu_layer(
      /* task_type      */ 3'd3,
      /* in_addr        */ pool1_out_addr,
      /* wgt_addr       */ 32'h0,
      /* out_addr       */ conv2_in_addr,
      /* in_bytes       */ 32'd11520,
      /* wgt_bytes      */ 32'd0,
      /* out_bytes      */ 32'd2880,
      /* iw             */ 16'd2880,
      /* ih             */ 16'd1,
      /* ic             */ 16'd1,
      /* oc             */ 16'd1,
      /* relu           */ 1'b0,
      /* pool           */ 1'b0,
      /* conv_cfg       */ 32'h0,
      /* requant_sel    */ 32'd0,
      /* requant_mult   */ 32'd0,
      /* requant_shift  */ 32'd0,
      /* bias_addr      */ 32'd0,
      /* bias_bytes     */ 32'd0,
      /* src1_addr      */ 32'd0,
      /* src1_bytes     */ 32'd0,
      /* add_cfg        */ 32'd0,
      /* add_src0_mult  */ 32'd0,
      /* add_src0_shift */ 32'd0,
      /* add_src1_mult  */ 32'd0,
      /* add_src1_shift */ 32'd0,
      /* add_out_mult   */ 32'd0,
      /* add_out_shift  */ 32'd0,
      /* postproc_cfg   */ 32'd0,
      /* gap_cfg        */ 32'd0,
      /* layer_name     */ "Requant1"
    );
    if (error) return;

    //---------------------------------------------------------------------------
    // 4. Conv2: 5x5 kernel, 20->50 channels, valid, 12x12 input
    //    H_out = 12 - 5 + 1 = 8, W_out = 8
    //    Output: 8*8*50 = 3200 INT32 elements, 12800 bytes
    //---------------------------------------------------------------------------
    run_npu_layer(
      /* task_type      */ 3'd0,
      /* in_addr        */ conv2_in_addr,
      /* wgt_addr       */ conv2_wgt_addr,
      /* out_addr       */ conv2_out_addr,
      /* in_bytes       */ 32'd2880,
      /* wgt_bytes      */ 32'd25000,
      /* out_bytes      */ 32'd12800,
      /* iw             */ 16'd12,
      /* ih             */ 16'd12,
      /* ic             */ 16'd20,
      /* oc             */ 16'd50,
      /* relu           */ 1'b0,
      /* pool           */ 1'b0,
      /* conv_cfg       */ 32'h0,
      /* requant_sel    */ 32'd0,
      /* requant_mult   */ 32'd0,
      /* requant_shift  */ 32'd0,
      /* bias_addr      */ 32'd0,
      /* bias_bytes     */ 32'd0,
      /* src1_addr      */ 32'd0,
      /* src1_bytes     */ 32'd0,
      /* add_cfg        */ 32'd0,
      /* add_src0_mult  */ 32'd0,
      /* add_src0_shift */ 32'd0,
      /* add_src1_mult  */ 32'd0,
      /* add_src1_shift */ 32'd0,
      /* add_out_mult   */ 32'd0,
      /* add_out_shift  */ 32'd0,
      /* postproc_cfg   */ 32'd0,
      /* gap_cfg        */ 32'd0,
      /* layer_name     */ "Conv2"
    );
    if (error) return;

    //---------------------------------------------------------------------------
    // 5. Pool2: 2x2 MaxPool stride 2, 8x8x50 -> 4x4x50
    //    Output: 4*4*50 = 800 INT32 elements, 3200 bytes
    //---------------------------------------------------------------------------
    run_npu_layer(
      /* task_type      */ 3'd2,
      /* in_addr        */ conv2_out_addr,
      /* wgt_addr       */ 32'h0,
      /* out_addr       */ pool2_out_addr,
      /* in_bytes       */ 32'd12800,
      /* wgt_bytes      */ 32'd0,
      /* out_bytes      */ 32'd3200,
      /* iw             */ 16'd8,
      /* ih             */ 16'd8,
      /* ic             */ 16'd50,
      /* oc             */ 16'd50,
      /* relu           */ 1'b0,
      /* pool           */ 1'b1,
      /* conv_cfg       */ 32'h0,
      /* requant_sel    */ 32'd0,
      /* requant_mult   */ 32'd0,
      /* requant_shift  */ 32'd0,
      /* bias_addr      */ 32'd0,
      /* bias_bytes     */ 32'd0,
      /* src1_addr      */ 32'd0,
      /* src1_bytes     */ 32'd0,
      /* add_cfg        */ 32'd0,
      /* add_src0_mult  */ 32'd0,
      /* add_src0_shift */ 32'd0,
      /* add_src1_mult  */ 32'd0,
      /* add_src1_shift */ 32'd0,
      /* add_out_mult   */ 32'd0,
      /* add_out_shift  */ 32'd0,
      /* postproc_cfg   */ 32'd0,
      /* gap_cfg        */ 32'd0,
      /* layer_name     */ "Pool2"
    );
    if (error) return;

    //---------------------------------------------------------------------------
    // 6. Requant2: Pool2 INT32 -> FC1 input INT8
    //    4*4*50 = 800 elements
    //    Uses requant slot 1 (rq_fc1_mult / rq_fc1_shift)
    //    Note: directed TB writes the result back to pool2_out_addr (in-place)
    //---------------------------------------------------------------------------
    `uvm_info("LENET", "=== Requant2 (FC1): Pool2 INT32 -> FC1 INT8 ===", UVM_NONE)

    axil_write32(`NPU_REG_REQUANT_SEL, 32'd1);

    run_npu_layer(
      /* task_type      */ 3'd3,
      /* in_addr        */ pool2_out_addr,
      /* wgt_addr       */ 32'h0,
      /* out_addr       */ pool2_out_addr,
      /* in_bytes       */ 32'd3200,
      /* wgt_bytes      */ 32'd0,
      /* out_bytes      */ 32'd800,
      /* iw             */ 16'd800,
      /* ih             */ 16'd1,
      /* ic             */ 16'd1,
      /* oc             */ 16'd1,
      /* relu           */ 1'b0,
      /* pool           */ 1'b0,
      /* conv_cfg       */ 32'h0,
      /* requant_sel    */ 32'd1,
      /* requant_mult   */ 32'd0,
      /* requant_shift  */ 32'd0,
      /* bias_addr      */ 32'd0,
      /* bias_bytes     */ 32'd0,
      /* src1_addr      */ 32'd0,
      /* src1_bytes     */ 32'd0,
      /* add_cfg        */ 32'd0,
      /* add_src0_mult  */ 32'd0,
      /* add_src0_shift */ 32'd0,
      /* add_src1_mult  */ 32'd0,
      /* add_src1_shift */ 32'd0,
      /* add_out_mult   */ 32'd0,
      /* add_out_shift  */ 32'd0,
      /* postproc_cfg   */ 32'd0,
      /* gap_cfg        */ 32'd0,
      /* layer_name     */ "Requant2"
    );
    if (error) return;

    //---------------------------------------------------------------------------
    // 7. FC1: 800->500, RELU enabled
    //    Input:  800 INT8 elements  (at pool2_out_addr, after in-place requant)
    //    Weight: 800*500 = 400000 INT8 bytes
    //    Output: 500 INT32 elements, 2000 bytes
    //---------------------------------------------------------------------------
    run_npu_layer(
      /* task_type      */ 3'd1,
      /* in_addr        */ pool2_out_addr,
      /* wgt_addr       */ fc1_wgt_addr,
      /* out_addr       */ fc1_out_addr,
      /* in_bytes       */ 32'd800,
      /* wgt_bytes      */ 32'd400000,
      /* out_bytes      */ 32'd2000,
      /* iw             */ 16'd1,
      /* ih             */ 16'd1,
      /* ic             */ 16'd800,
      /* oc             */ 16'd500,
      /* relu           */ 1'b1,
      /* pool           */ 1'b0,
      /* conv_cfg       */ 32'h0,
      /* requant_sel    */ 32'd0,
      /* requant_mult   */ 32'd0,
      /* requant_shift  */ 32'd0,
      /* bias_addr      */ 32'd0,
      /* bias_bytes     */ 32'd0,
      /* src1_addr      */ 32'd0,
      /* src1_bytes     */ 32'd0,
      /* add_cfg        */ 32'd0,
      /* add_src0_mult  */ 32'd0,
      /* add_src0_shift */ 32'd0,
      /* add_src1_mult  */ 32'd0,
      /* add_src1_shift */ 32'd0,
      /* add_out_mult   */ 32'd0,
      /* add_out_shift  */ 32'd0,
      /* postproc_cfg   */ 32'd0,
      /* gap_cfg        */ 32'd0,
      /* layer_name     */ "FC1"
    );
    if (error) return;

    //---------------------------------------------------------------------------
    // 8. Requant3: FC1 INT32 -> FC2 input INT8
    //    500 elements
    //    Uses requant slot 2 (rq_fc2_mult / rq_fc2_shift)
    //    Note: directed TB writes the result back to fc1_out_addr (in-place)
    //---------------------------------------------------------------------------
    `uvm_info("LENET", "=== Requant3 (FC2): FC1 INT32 -> FC2 INT8 ===", UVM_NONE)

    axil_write32(`NPU_REG_REQUANT_SEL, 32'd2);

    run_npu_layer(
      /* task_type      */ 3'd3,
      /* in_addr        */ fc1_out_addr,
      /* wgt_addr       */ 32'h0,
      /* out_addr       */ fc1_out_addr,
      /* in_bytes       */ 32'd2000,
      /* wgt_bytes      */ 32'd0,
      /* out_bytes      */ 32'd500,
      /* iw             */ 16'd500,
      /* ih             */ 16'd1,
      /* ic             */ 16'd1,
      /* oc             */ 16'd1,
      /* relu           */ 1'b0,
      /* pool           */ 1'b0,
      /* conv_cfg       */ 32'h0,
      /* requant_sel    */ 32'd2,
      /* requant_mult   */ 32'd0,
      /* requant_shift  */ 32'd0,
      /* bias_addr      */ 32'd0,
      /* bias_bytes     */ 32'd0,
      /* src1_addr      */ 32'd0,
      /* src1_bytes     */ 32'd0,
      /* add_cfg        */ 32'd0,
      /* add_src0_mult  */ 32'd0,
      /* add_src0_shift */ 32'd0,
      /* add_src1_mult  */ 32'd0,
      /* add_src1_shift */ 32'd0,
      /* add_out_mult   */ 32'd0,
      /* add_out_shift  */ 32'd0,
      /* postproc_cfg   */ 32'd0,
      /* gap_cfg        */ 32'd0,
      /* layer_name     */ "Requant3"
    );
    if (error) return;

    //---------------------------------------------------------------------------
    // 9. FC2: 500->10, no RELU (final logits)
    //    Input:  500 INT8 elements  (at fc1_out_addr, after in-place requant)
    //    Weight: 500*10 = 5000 INT8 bytes
    //    Output: 10 INT32 elements, 40 bytes
    //---------------------------------------------------------------------------
    run_npu_layer(
      /* task_type      */ 3'd1,
      /* in_addr        */ fc1_out_addr,
      /* wgt_addr       */ fc2_wgt_addr,
      /* out_addr       */ fc2_out_addr,
      /* in_bytes       */ 32'd500,
      /* wgt_bytes      */ 32'd5000,
      /* out_bytes      */ 32'd40,
      /* iw             */ 16'd1,
      /* ih             */ 16'd1,
      /* ic             */ 16'd500,
      /* oc             */ 16'd10,
      /* relu           */ 1'b0,
      /* pool           */ 1'b0,
      /* conv_cfg       */ 32'h0,
      /* requant_sel    */ 32'd0,
      /* requant_mult   */ 32'd0,
      /* requant_shift  */ 32'd0,
      /* bias_addr      */ 32'd0,
      /* bias_bytes     */ 32'd0,
      /* src1_addr      */ 32'd0,
      /* src1_bytes     */ 32'd0,
      /* add_cfg        */ 32'd0,
      /* add_src0_mult  */ 32'd0,
      /* add_src0_shift */ 32'd0,
      /* add_src1_mult  */ 32'd0,
      /* add_src1_shift */ 32'd0,
      /* add_out_mult   */ 32'd0,
      /* add_out_shift  */ 32'd0,
      /* postproc_cfg   */ 32'd0,
      /* gap_cfg        */ 32'd0,
      /* layer_name     */ "FC2"
    );
    if (error) return;

    //---------------------------------------------------------------------------
    // 10. Read FC2 output logits (10 x INT32 = 40 bytes)
    //---------------------------------------------------------------------------
    `uvm_info("LENET", "=== Reading FC2 Output Logits ===", UVM_NONE)

    read_seq = npu_output_read_seq::type_id::create("read_seq");
    read_seq.output_addr  = fc2_out_addr;
    read_seq.output_bytes = 40;
    read_seq.start(m_sequencer);

    for (s = 0; s < 10; s++) begin
      fc2_logits[s] = {read_seq.actual[s*4 + 3],
                       read_seq.actual[s*4 + 2],
                       read_seq.actual[s*4 + 1],
                       read_seq.actual[s*4 + 0]};
    end

    done  = 1'b1;
    error = 1'b0;

    `uvm_info("LENET", $sformatf("=== LeNet Pipeline Complete: logits=[%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d] ===",
      fc2_logits[0], fc2_logits[1], fc2_logits[2], fc2_logits[3], fc2_logits[4],
      fc2_logits[5], fc2_logits[6], fc2_logits[7], fc2_logits[8], fc2_logits[9]), UVM_NONE)
  endtask

endclass
