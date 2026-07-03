`timescale 1ns / 1ps

class npu_config_seq extends soc_base_seq;

  `uvm_object_utils(npu_config_seq)

  // 任务 configuration — set before start()
  bit [2:0]  task_type;
  bit [31:0] input_addr;
  bit [31:0] weight_addr;
  bit [31:0] output_addr;
  bit [31:0] input_bytes;
  bit [31:0] weight_bytes;
  bit [31:0] output_bytes;
  bit [15:0] input_h;
  bit [15:0] input_w;
  bit [15:0] input_c;
  bit [15:0] output_c;
  bit        relu_en;
  bit        pool_en;
  bit [31:0] conv_cfg;
  bit [1:0]  cluster_mode;
  bit [5:0]  cluster_mask;

  // 重量化
  bit [31:0] requant_slot_sel;
  bit [31:0] requant_multiplier;
  bit [31:0] requant_shift;

  // ADD
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

  // GAP
  bit [31:0] gap_cfg;

  // 偏置
  bit [31:0] bias_addr;
  bit [31:0] bias_bytes;

  function new(string name = "npu_config_seq");
    super.new(name);
    task_type    = 3'd0;
    input_addr   = 32'h0;
    weight_addr  = 32'h0;
    output_addr  = 32'h0;
    input_bytes  = 32'd0;
    weight_bytes = 32'd0;
    output_bytes = 32'd0;
    input_h      = 16'd0;
    input_w      = 16'd0;
    input_c      = 16'd1;
    output_c     = 16'd1;
    relu_en      = 1'b0;
    pool_en      = 1'b0;
    conv_cfg     = 32'h0;
    cluster_mode = 2'd2;
    cluster_mask = 6'h3F;

    requant_slot_sel    = 32'd0;
    requant_multiplier  = 32'd1;
    requant_shift       = 32'd0;

    src1_addr       = 32'd0;
    src1_bytes      = 32'd0;
    add_cfg         = 32'd0;
    add_src0_mult   = 32'd1;
    add_src0_shift  = 32'd0;
    add_src1_mult   = 32'd1;
    add_src1_shift  = 32'd0;
    add_out_mult    = 32'd1;
    add_out_shift   = 32'd0;
    postproc_cfg_ext = 32'd0;

    gap_cfg  = 32'd0;

    bias_addr  = 32'd0;
    bias_bytes = 32'd0;
  endfunction

  virtual task body();
    `uvm_info("NPU_CFG", $sformatf("Config: task=%0d H=%0d W=%0d Cin=%0d Cout=%0d cluster=%0d",
      task_type, input_h, input_w, input_c, output_c, cluster_mode), UVM_MEDIUM)

    axil_write32(`NPU_REG_TASK_TYPE,   {29'd0, task_type});
    axil_write32(`NPU_REG_INPUT_ADDR,  input_addr);
    axil_write32(`NPU_REG_WEIGHT_ADDR, weight_addr);
    axil_write32(`NPU_REG_OUTPUT_ADDR, output_addr);
    axil_write32(`NPU_REG_INPUT_BYTES,  input_bytes);
    axil_write32(`NPU_REG_WEIGHT_BYTES, weight_bytes);
    axil_write32(`NPU_REG_OUTPUT_BYTES, output_bytes);
    axil_write32(`NPU_REG_DIM_IN,      {input_w, input_h});
    axil_write32(`NPU_REG_DIM_OUT,     {output_c, input_c});
    axil_write32(`NPU_REG_POSTPROC,    {30'd0, pool_en, relu_en});
    axil_write32(`NPU_REG_CONV_CFG,    conv_cfg);

    if (requant_multiplier != 0) begin
      axil_write32(`NPU_REG_REQUANT_SEL,    requant_slot_sel);
      axil_write32(`NPU_REG_REQUANT0_MULT,  requant_multiplier);
      axil_write32(`NPU_REG_REQUANT0_SHIFT, requant_shift);
    end

    if (bias_bytes > 0) begin
      axil_write32(`NPU_REG_BIAS_ADDR,  bias_addr);
      axil_write32(`NPU_REG_BIAS_BYTES, bias_bytes);
    end

    if (src1_bytes > 0) begin
      axil_write32(`NPU_REG_SRC1_ADDR,      src1_addr);
      axil_write32(`NPU_REG_SRC1_BYTES,     src1_bytes);
      axil_write32(`NPU_REG_ADD_CFG,        add_cfg);
      axil_write32(`NPU_REG_ADD_SRC0_MULT,  add_src0_mult);
      axil_write32(`NPU_REG_ADD_SRC0_SHIFT, add_src0_shift);
      axil_write32(`NPU_REG_ADD_SRC1_MULT,  add_src1_mult);
      axil_write32(`NPU_REG_ADD_SRC1_SHIFT, add_src1_shift);
      axil_write32(`NPU_REG_ADD_OUT_MULT,   add_out_mult);
      axil_write32(`NPU_REG_ADD_OUT_SHIFT,  add_out_shift);
      axil_write32(`NPU_REG_POSTPROC_CFG,   postproc_cfg_ext);
    end

    if (gap_cfg != 0) begin
      axil_write32(`NPU_REG_GAP_CFG, gap_cfg);
    end

    axil_write32(`NPU_REG_CLUSTER_MODE, {30'd0, cluster_mode});
    axil_write32(`NPU_REG_CLUSTER_MASK, {26'd0, cluster_mask});

    `uvm_info("NPU_CFG", "NPU configuration complete", UVM_MEDIUM)
  endtask

endclass
