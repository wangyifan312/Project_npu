//=============================================================================
// npu_pool_task_seq.sv — Pool Task Sequence
//
// Full 2x2 MaxPool (stride 2) task flow on the INT32 domain:
//   1. Preloads input (INT32 tensor) to shared RAM
//   2. Configures NPU for Pool (task_type=2, pool_en=1)
//      Note: Pool only uses input and output — no weight needed
//   3. Starts and polls
//   4. Reads output (INT32 tensor after 2x2 max pool)
//=============================================================================

`timescale 1ns / 1ps

class npu_pool_task_seq extends soc_base_seq;

  `uvm_object_utils(npu_pool_task_seq)

  bit [31:0] input_base;
  bit [31:0] output_base;
  bit [15:0] input_h;
  bit [15:0] input_w;
  bit [15:0] channels;
  bit [1:0]  cluster_mode;
  int unsigned input_ints[];
  int unsigned expected_output_bytes;
  bit done;
  bit error;
  byte unsigned actual_output[];

  function new(string name = "npu_pool_task_seq");
    super.new(name);
    input_base    = 32'h0000_0100;
    output_base   = 32'h0000_0300;
    input_h       = 16'd4;
    input_w       = 16'd4;
    channels      = 16'd1;
    cluster_mode  = 2'd2;
    expected_output_bytes = 16;
    done  = 1'b0;
    error = 1'b0;
  endfunction

  virtual task body();
    shared_ram_preload_seq preload_seq;
    npu_config_seq         cfg_seq;
    npu_start_poll_seq     poll_seq;
    npu_output_read_seq    read_seq;
    byte unsigned input_data[];
    int unsigned input_bytes;
    int unsigned output_bytes;
    int i;

    // Convert INT32 input to little-endian bytes for shared RAM preload
    input_bytes = input_h * input_w * channels * 4;
    output_bytes = (input_h / 2) * (input_w / 2) * channels * 4;
    input_data = new[input_bytes];
    for (i = 0; i < input_ints.size(); i++) begin
      input_data[i*4 + 0] = input_ints[i][7:0];
      input_data[i*4 + 1] = input_ints[i][15:8];
      input_data[i*4 + 2] = input_ints[i][23:16];
      input_data[i*4 + 3] = input_ints[i][31:24];
    end

    `uvm_info("POOL_TASK", "=== Pool Task: Preloading ===", UVM_NONE)

    // 预加载 input only — Pool has no weight tensor
    preload_seq = shared_ram_preload_seq::type_id::create("preload_seq");
    preload_seq.base_addr = input_base;
    preload_seq.data = input_data;
    preload_seq.start(m_sequencer);

    `uvm_info("POOL_TASK", "=== Pool Task: Configuring ===", UVM_NONE)

    cfg_seq = npu_config_seq::type_id::create("cfg_seq");
    cfg_seq.task_type    = 3'd2;          // Pool
    cfg_seq.input_addr   = input_base;
    cfg_seq.weight_addr  = 32'h0;         // Pool has no weight
    cfg_seq.output_addr  = output_base;
    cfg_seq.input_bytes  = input_bytes;
    cfg_seq.weight_bytes = 32'd0;         // Pool has no weight
    cfg_seq.output_bytes = output_bytes;
    cfg_seq.input_h      = input_h;
    cfg_seq.input_w      = input_w;
    cfg_seq.input_c      = channels;
    cfg_seq.output_c     = channels;
    cfg_seq.relu_en      = 1'b0;
    cfg_seq.pool_en      = 1'b1;          // Enable 2x2 max pool
    cfg_seq.cluster_mode = cluster_mode;
    cfg_seq.requant_multiplier = 32'd0;   // Pool uses no requant
    cfg_seq.start(m_sequencer);

    `uvm_info("POOL_TASK", "=== Pool Task: Starting/Polling ===", UVM_NONE)

    poll_seq = npu_start_poll_seq::type_id::create("poll_seq");
    poll_seq.start(m_sequencer);
    done  = poll_seq.done;
    error = poll_seq.error;

    if (error) begin
      `uvm_error("POOL_TASK", $sformatf("NPU error: code=0x%02x", poll_seq.error_code))
      return;
    end
    if (!done) begin
      `uvm_error("POOL_TASK", "NPU timeout")
      return;
    end

    `uvm_info("POOL_TASK", "=== Pool Task: Reading Output ===", UVM_NONE)

    read_seq = npu_output_read_seq::type_id::create("read_seq");
    read_seq.output_addr  = output_base;
    read_seq.output_bytes = output_bytes;
    read_seq.start(m_sequencer);
    actual_output = read_seq.actual;

    `uvm_info("POOL_TASK", "=== Pool Task Complete ===", UVM_NONE)
  endtask

endclass
