//=============================================================================
// npu_gap_task_seq.sv — Global Average Pooling (GAP) Task Sequence
//
// Extends soc_base_seq. Full GAP task flow:
//   1. Preload input (INT32 tensor, 8x8 per channel) to shared RAM
//   2. Configure NPU for GAP (task_type=5)
//   3. Start and poll
//   4. Read output (INT8 per-channel averages)
//
// GAP semantics:
//   - spatial: fixed 8x8 window
//   - input: [64 * channels] INT32 values (8x8 x channels)
//   - output: [channels] INT8 values (per-channel averages, requantized)
//   - weight is NOT used (weight_bytes = 0)
//
// 寄存器-programming contract:
//   GAP_CFG, REQUANT0_MULT, REQUANT0_SHIFT
//   input_h=8, input_w=8, input_c=channels, output_c=channels
//=============================================================================

`timescale 1ns / 1ps

class npu_gap_task_seq extends soc_base_seq;

  `uvm_object_utils(npu_gap_task_seq)

  // --- Configuration properties (set before start()) ---
  bit [31:0] input_base;
  bit [31:0] output_base;
  bit [15:0] channels;
  int unsigned input_ints[];   // [64 * channels] INT32 values (legacy, sign-extended)
  byte unsigned input_data[];  // [64 * channels] INT8 bytes (preferred, matches RTL INT8 input)
  bit [31:0] multiplier;
  bit [31:0] shift;
  bit [1:0]  cluster_mode;

  // --- Result properties (set after body() completes) ---
  bit done;
  bit error;
  byte unsigned actual_output[];

  function new(string name = "npu_gap_task_seq");
    super.new(name);
    input_base   = 32'h0000_0100;
    output_base  = 32'h0000_0300;
    channels     = 16'd1;
    multiplier   = 32'd1;
    shift        = 32'd0;
    cluster_mode = 2'd2;
    done  = 1'b0;
    error = 1'b0;
  endfunction

  virtual task body();
    shared_ram_preload_seq preload_seq;
    npu_config_seq         cfg_seq;
    npu_start_poll_seq     poll_seq;
    npu_output_read_seq    read_seq;
    byte unsigned preload_bytes[];
    int unsigned input_bytes;
    int unsigned output_bytes;
    int i;

    if (input_data.size() > 0) begin
      // INT8 input (preferred): data is already byte array
      input_bytes = input_data.size();
      preload_bytes = input_data;
    end else begin
      // INT32 input (legacy): convert to byte array
      input_bytes = 64 * channels * 4;
      preload_bytes = new[input_bytes];
      for (i = 0; i < input_ints.size(); i++) begin
        preload_bytes[i*4 + 0] = input_ints[i][7:0];
        preload_bytes[i*4 + 1] = input_ints[i][15:8];
        preload_bytes[i*4 + 2] = input_ints[i][23:16];
        preload_bytes[i*4 + 3] = input_ints[i][31:24];
      end
    end
    output_bytes = channels;

    `uvm_info("GAP_TASK", "=== GAP Task: Preloading ===", UVM_NONE)

    // 预加载 input INT32 tensor — GAP has no weight tensor
    preload_seq = shared_ram_preload_seq::type_id::create("preload_seq");
    preload_seq.base_addr = input_base;
    preload_seq.data = preload_bytes;
    preload_seq.start(m_sequencer);

    `uvm_info("GAP_TASK", "=== GAP Task: Configuring ===", UVM_NONE)

    cfg_seq = npu_config_seq::type_id::create("cfg_seq");
    cfg_seq.task_type    = 3'd5;            // GAP operation
    cfg_seq.input_addr   = input_base;
    cfg_seq.weight_addr  = 32'h0;           // GAP has no weight
    cfg_seq.output_addr  = output_base;
    cfg_seq.input_bytes  = input_bytes;
    cfg_seq.weight_bytes = 32'd0;           // GAP has no weight
    cfg_seq.output_bytes = output_bytes;
    cfg_seq.input_h      = 16'd8;           // GAP always 8x8 spatial
    cfg_seq.input_w      = 16'd8;
    cfg_seq.input_c      = channels;
    cfg_seq.output_c     = channels;
    cfg_seq.relu_en      = 1'b0;
    cfg_seq.pool_en      = 1'b0;
    cfg_seq.cluster_mode = cluster_mode;

    // GAP-specific configuration
    // gap_cfg bits: [25:20]=divide-by-64 shift (must be 6'd6), rest 0
    cfg_seq.gap_cfg              = 32'h0060_0000;    // bits[25:20]=6'd6 (divide-by-64)
    cfg_seq.requant_multiplier   = multiplier;
    cfg_seq.requant_shift        = shift;
    cfg_seq.requant_slot_sel     = 32'd0;

    cfg_seq.start(m_sequencer);

    `uvm_info("GAP_TASK", "=== GAP Task: Starting/Polling ===", UVM_NONE)

    poll_seq = npu_start_poll_seq::type_id::create("poll_seq");
    poll_seq.start(m_sequencer);
    done  = poll_seq.done;
    error = poll_seq.error;

    if (error) begin
      `uvm_error("GAP_TASK", $sformatf("NPU error: code=0x%02x", poll_seq.error_code))
      return;
    end
    if (!done) begin
      `uvm_error("GAP_TASK", "NPU timeout")
      return;
    end

    `uvm_info("GAP_TASK", "=== GAP Task: Reading Output ===", UVM_NONE)

    read_seq = npu_output_read_seq::type_id::create("read_seq");
    read_seq.output_addr  = output_base;
    read_seq.output_bytes = output_bytes;
    read_seq.start(m_sequencer);
    actual_output = read_seq.actual;

    `uvm_info("GAP_TASK", "=== GAP Task Complete ===", UVM_NONE)
  endtask

endclass
