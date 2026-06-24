//=============================================================================
// npu_add_task_seq.sv — ADD Task Sequence
//
// Extends soc_base_seq. Full ADD task flow:
//   1. Preload src0 (INT8 tensor) and src1 (INT8 tensor) to shared RAM
//   2. Configure NPU for ADD (task_type=4) with per-source requant
//   3. Start and poll
//   4. Read output (INT8 tensor, element-wise sum after requant/clamp)
//
// ADD uses:
//   - src0 as the primary input tensor (loaded to input_base)
//   - src1 as the secondary input tensor (loaded to src1_base)
//   - weight is NOT used by ADD (weight_bytes = 0)
//   - output is INT8, same element count as src0/src1
//
// Register-programming contract:
//   SRC1_ADDR, SRC1_BYTES, ADD_CFG,
//   ADD_SRC0_MULT, ADD_SRC0_SHIFT,
//   ADD_SRC1_MULT, ADD_SRC1_SHIFT,
//   ADD_OUT_MULT, ADD_OUT_SHIFT,
//   POSTPROC_CFG
//=============================================================================

`timescale 1ns / 1ps

class npu_add_task_seq extends soc_base_seq;

  `uvm_object_utils(npu_add_task_seq)

  // --- Configuration properties (set before start()) ---
  bit [31:0] src0_base;
  bit [31:0] src1_base;
  bit [31:0] output_base;
  int unsigned element_count;
  byte unsigned src0_data[];
  byte unsigned src1_data[];
  bit [31:0] src0_mult;
  bit [31:0] src0_shift;
  bit [31:0] src1_mult;
  bit [31:0] src1_shift;
  bit [31:0] out_mult;
  bit [31:0] out_shift;
  bit [1:0]  cluster_mode;

  // --- Result properties (set after body() completes) ---
  bit done;
  bit error;
  byte unsigned actual_output[];

  function new(string name = "npu_add_task_seq");
    super.new(name);
    src0_base     = 32'h0000_0100;
    src1_base     = 32'h0000_0200;
    output_base   = 32'h0000_0300;
    element_count = 4;
    src0_mult     = 32'd1;
    src0_shift    = 32'd0;
    src1_mult     = 32'd1;
    src1_shift    = 32'd0;
    out_mult      = 32'd1;
    out_shift     = 32'd0;
    cluster_mode  = 2'd2;
    done  = 1'b0;
    error = 1'b0;
  endfunction

  virtual task body();
    shared_ram_preload_seq preload_seq;
    npu_config_seq         cfg_seq;
    npu_start_poll_seq     poll_seq;
    npu_output_read_seq    read_seq;

    `uvm_info("ADD_TASK", "=== ADD Task: Preloading ===", UVM_NONE)

    // Preload src0 (primary input tensor) to src0_base
    preload_seq = shared_ram_preload_seq::type_id::create("preload_seq");
    preload_seq.base_addr = src0_base;
    preload_seq.data = src0_data;
    preload_seq.start(m_sequencer);

    // Preload src1 (secondary input tensor) to src1_base
    preload_seq = shared_ram_preload_seq::type_id::create("preload_seq");
    preload_seq.base_addr = src1_base;
    preload_seq.data = src1_data;
    preload_seq.start(m_sequencer);

    `uvm_info("ADD_TASK", "=== ADD Task: Configuring ===", UVM_NONE)

    cfg_seq = npu_config_seq::type_id::create("cfg_seq");
    cfg_seq.task_type    = 3'd4;            // ADD operation
    cfg_seq.input_addr   = src0_base;       // src0 is the primary input
    cfg_seq.weight_addr  = 32'h0;           // ADD has no weight
    cfg_seq.output_addr  = output_base;
    cfg_seq.input_bytes  = element_count;   // INT8 src0
    cfg_seq.weight_bytes = 32'd0;           // ADD has no weight
    cfg_seq.output_bytes = element_count;   // INT8 result
    cfg_seq.input_h      = 16'd1;           // ADD has no spatial dims
    cfg_seq.input_w      = 16'd1;
    cfg_seq.input_c      = element_count[15:0];
    cfg_seq.output_c     = element_count[15:0];
    cfg_seq.relu_en      = 1'b0;
    cfg_seq.pool_en      = 1'b0;
    cfg_seq.cluster_mode = cluster_mode;

    // ADD-specific configuration: src1 address and requant parameters
    cfg_seq.src1_addr       = src1_base;
    cfg_seq.src1_bytes      = element_count;   // INT8 src1
    cfg_seq.add_cfg         = 32'd0;
    cfg_seq.add_src0_mult   = src0_mult;
    cfg_seq.add_src0_shift  = src0_shift;
    cfg_seq.add_src1_mult   = src1_mult;
    cfg_seq.add_src1_shift  = src1_shift;
    cfg_seq.add_out_mult    = out_mult;
    cfg_seq.add_out_shift   = out_shift;
    cfg_seq.postproc_cfg_ext = 32'd0;
    cfg_seq.requant_multiplier = 32'd0;    // ADD uses its own requant, not the shared one

    cfg_seq.start(m_sequencer);

    `uvm_info("ADD_TASK", "=== ADD Task: Starting/Polling ===", UVM_NONE)

    poll_seq = npu_start_poll_seq::type_id::create("poll_seq");
    poll_seq.start(m_sequencer);
    done  = poll_seq.done;
    error = poll_seq.error;

    if (error) begin
      `uvm_error("ADD_TASK", $sformatf("NPU error: code=0x%02x", poll_seq.error_code))
      return;
    end
    if (!done) begin
      `uvm_error("ADD_TASK", "NPU timeout")
      return;
    end

    `uvm_info("ADD_TASK", "=== ADD Task: Reading Output ===", UVM_NONE)

    read_seq = npu_output_read_seq::type_id::create("read_seq");
    read_seq.output_addr  = output_base;
    read_seq.output_bytes = element_count;
    read_seq.start(m_sequencer);
    actual_output = read_seq.actual;

    `uvm_info("ADD_TASK", "=== ADD Task Complete ===", UVM_NONE)
  endtask

endclass
