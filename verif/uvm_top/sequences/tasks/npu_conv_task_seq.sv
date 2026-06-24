`timescale 1ns / 1ps

class npu_conv_task_seq extends soc_base_seq;

  `uvm_object_utils(npu_conv_task_seq)

  bit [31:0] input_base;
  bit [31:0] weight_base;
  bit [31:0] output_base;
  bit [15:0] input_h;
  bit [15:0] input_w;
  bit [15:0] input_c;
  bit [15:0] output_c;
  bit [1:0]  cluster_mode;
  bit [31:0] conv_cfg;
  bit [31:0] requant_slot_sel;
  bit [31:0] requant_multiplier;
  bit [31:0] requant_shift;
  bit [31:0] bias_addr;
  bit [31:0] bias_bytes;
  bit [31:0] src1_addr;
  bit [31:0] src1_bytes;
  bit [31:0] add_cfg;
  bit [31:0] add_src0_mult;
  bit [31:0] add_src0_shift;
  bit [31:0] add_src1_mult;
  bit [31:0] add_src1_shift;
  bit [31:0] add_out_mult;
  bit [31:0] add_out_shift;
  bit [31:0] postproc_cfg_ext;
  bit [31:0] gap_cfg;
  byte unsigned input_data[];
  byte unsigned weight_data[];
  int unsigned expected_output_bytes;
  byte unsigned expected_output[];
  bit done;
  bit error;
  byte unsigned actual_output[];

  function new(string name = "npu_conv_task_seq");
    super.new(name);
    input_base   = 32'h0000_0100;
    weight_base  = 32'h0000_0200;
    output_base  = 32'h0000_0300;
    input_h      = 16'd5;
    input_w      = 16'd5;
    input_c      = 16'd1;
    output_c     = 16'd1;
    cluster_mode = 2'd2;
    conv_cfg         = 32'h0;
    requant_slot_sel  = 32'd0;
    requant_multiplier = 32'd1;
    requant_shift      = 32'd0;
    bias_addr    = 32'd0;
    bias_bytes   = 32'd0;
    src1_addr    = 32'd0;
    src1_bytes   = 32'd0;
    add_cfg      = 32'd0;
    add_src0_mult  = 32'd1;
    add_src0_shift = 32'd0;
    add_src1_mult  = 32'd1;
    add_src1_shift = 32'd0;
    add_out_mult   = 32'd1;
    add_out_shift  = 32'd0;
    postproc_cfg_ext = 32'd0;
    gap_cfg      = 32'd0;
    expected_output_bytes = 4;
    done  = 1'b0;
    error = 1'b0;
  endfunction

  virtual task body();
    shared_ram_preload_seq preload_seq;
    npu_config_seq         cfg_seq;
    npu_start_poll_seq     poll_seq;
    npu_output_read_seq    read_seq;

    `uvm_info("CONV_TASK", "=== Conv Task: Preloading ===", UVM_NONE)

    preload_seq = shared_ram_preload_seq::type_id::create("preload_seq");
    preload_seq.base_addr = input_base;
    preload_seq.data = input_data;
    preload_seq.start(m_sequencer);

    preload_seq = shared_ram_preload_seq::type_id::create("preload_seq");
    preload_seq.base_addr = weight_base;
    preload_seq.data = weight_data;
    preload_seq.start(m_sequencer);

    `uvm_info("CONV_TASK", "=== Conv Task: Configuring ===", UVM_NONE)

    cfg_seq = npu_config_seq::type_id::create("cfg_seq");
    cfg_seq.task_type    = 3'd0;
    cfg_seq.input_addr   = input_base;
    cfg_seq.weight_addr  = weight_base;
    cfg_seq.output_addr  = output_base;
    cfg_seq.input_bytes  = input_data.size();
    cfg_seq.weight_bytes = weight_data.size();
    cfg_seq.output_bytes = expected_output_bytes;
    cfg_seq.input_h      = input_h;
    cfg_seq.input_w      = input_w;
    cfg_seq.input_c      = input_c;
    cfg_seq.output_c     = output_c;
    cfg_seq.relu_en      = 1'b0;
    cfg_seq.pool_en      = 1'b0;
    cfg_seq.cluster_mode      = cluster_mode;
    cfg_seq.conv_cfg           = conv_cfg;
    cfg_seq.requant_slot_sel   = requant_slot_sel;
    cfg_seq.requant_multiplier = requant_multiplier;
    cfg_seq.requant_shift      = requant_shift;
    cfg_seq.bias_addr          = bias_addr;
    cfg_seq.bias_bytes         = bias_bytes;
    cfg_seq.src1_addr          = src1_addr;
    cfg_seq.src1_bytes         = src1_bytes;
    cfg_seq.add_cfg            = add_cfg;
    cfg_seq.add_src0_mult      = add_src0_mult;
    cfg_seq.add_src0_shift     = add_src0_shift;
    cfg_seq.add_src1_mult      = add_src1_mult;
    cfg_seq.add_src1_shift     = add_src1_shift;
    cfg_seq.add_out_mult       = add_out_mult;
    cfg_seq.add_out_shift      = add_out_shift;
    cfg_seq.postproc_cfg_ext   = postproc_cfg_ext;
    cfg_seq.gap_cfg            = gap_cfg;
    cfg_seq.start(m_sequencer);

    `uvm_info("CONV_TASK", "=== Conv Task: Starting/Polling ===", UVM_NONE)

    poll_seq = npu_start_poll_seq::type_id::create("poll_seq");
    poll_seq.start(m_sequencer);
    done  = poll_seq.done;
    error = poll_seq.error;

    if (error) begin
      `uvm_error("CONV_TASK", $sformatf("NPU error: code=0x%02x", poll_seq.error_code))
      return;
    end
    if (!done) begin
      `uvm_error("CONV_TASK", "NPU timeout")
      return;
    end

    `uvm_info("CONV_TASK", "=== Conv Task: Reading Output ===", UVM_NONE)

    read_seq = npu_output_read_seq::type_id::create("read_seq");
    read_seq.output_addr  = output_base;
    read_seq.output_bytes = expected_output_bytes;
    read_seq.start(m_sequencer);
    actual_output = read_seq.actual;

    `uvm_info("CONV_TASK", "=== Conv Task Complete ===", UVM_NONE)
  endtask

endclass
