//=============================================================================
// npu_fc_task_seq.sv — Fully Connected (FC) Task Sequence
//
// Extends soc_base_seq. Full FC task flow:
//   1. Preload input (INT8 vector) and weight (INT8 matrix) to shared RAM
//   2. Configure NPU for FC (task_type=1)
//   3. Start and poll
//   4. Read output (INT32 vector)
//
// 权重 layout: row-major [output_c * input_c] INT8
//   weight[0..input_c-1]       = row 0 (output neuron 0)
//   weight[input_c..2*input_c-1] = row 1 (output neuron 1)
//   ...
//=============================================================================

`timescale 1ns / 1ps

class npu_fc_task_seq extends soc_base_seq;

  `uvm_object_utils(npu_fc_task_seq)

  // --- Configuration properties (set before start()) ---
  bit [31:0] input_base;
  bit [31:0] weight_base;
  bit [31:0] output_base;
  bit [15:0] input_c;
  bit [15:0] output_c;
  bit [1:0]  cluster_mode;
  bit [5:0]  cluster_mask;
  byte unsigned input_data[];
  byte unsigned weight_data[];

  // --- Result properties (set after body() completes) ---
  int unsigned expected_output_bytes;
  bit done;
  bit error;
  byte unsigned actual_output[];

  function new(string name = "npu_fc_task_seq");
    super.new(name);
    input_base   = 32'h0000_0100;
    weight_base  = 32'h0000_0200;
    output_base  = 32'h0000_0300;
    input_c      = 16'd4;
    output_c     = 16'd2;
    cluster_mode = 2'd2;
    cluster_mask = 6'h3F;
    expected_output_bytes = 8;
    done  = 1'b0;
    error = 1'b0;
  endfunction

  virtual task body();
    shared_ram_preload_seq preload_seq;
    npu_config_seq         cfg_seq;
    npu_start_poll_seq     poll_seq;
    npu_output_read_seq    read_seq;

    `uvm_info("FC_TASK", "=== FC Task: Preloading ===", UVM_NONE)

    // 预加载 input vector
    preload_seq = shared_ram_preload_seq::type_id::create("preload_seq");
    preload_seq.base_addr = input_base;
    preload_seq.data      = input_data;
    preload_seq.start(m_sequencer);

    // 预加载 weight matrix
    preload_seq = shared_ram_preload_seq::type_id::create("preload_seq");
    preload_seq.base_addr = weight_base;
    preload_seq.data      = weight_data;
    preload_seq.start(m_sequencer);

    `uvm_info("FC_TASK", "=== FC Task: Configuring ===", UVM_NONE)

    cfg_seq = npu_config_seq::type_id::create("cfg_seq");
    cfg_seq.task_type    = 3'd1;            // FC operation
    cfg_seq.input_addr   = input_base;
    cfg_seq.weight_addr  = weight_base;
    cfg_seq.output_addr  = output_base;
    cfg_seq.input_bytes  = input_data.size();
    cfg_seq.weight_bytes = weight_data.size();
    cfg_seq.output_bytes = expected_output_bytes;
    cfg_seq.input_h      = 16'd1;           // FC has no spatial dims
    cfg_seq.input_w      = 16'd1;
    cfg_seq.input_c      = input_c;
    cfg_seq.output_c     = output_c;
    cfg_seq.relu_en      = 1'b0;
    cfg_seq.pool_en      = 1'b0;
    cfg_seq.cluster_mode = cluster_mode;
    cfg_seq.cluster_mask = cluster_mask;
    cfg_seq.start(m_sequencer);

    `uvm_info("FC_TASK", "=== FC Task: Starting/Polling ===", UVM_NONE)

    poll_seq = npu_start_poll_seq::type_id::create("poll_seq");
    poll_seq.start(m_sequencer);
    done  = poll_seq.done;
    error = poll_seq.error;

    if (error) begin
      `uvm_error("FC_TASK", $sformatf("NPU error: code=0x%02x", poll_seq.error_code))
      return;
    end
    if (!done) begin
      `uvm_error("FC_TASK", "NPU timeout")
      return;
    end

    `uvm_info("FC_TASK", "=== FC Task: Reading Output ===", UVM_NONE)

    read_seq = npu_output_read_seq::type_id::create("read_seq");
    read_seq.output_addr  = output_base;
    read_seq.output_bytes = expected_output_bytes;
    read_seq.start(m_sequencer);
    actual_output = read_seq.actual;

    `uvm_info("FC_TASK", "=== FC Task Complete ===", UVM_NONE)
  endtask

endclass
