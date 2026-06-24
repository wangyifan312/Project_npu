//=============================================================================
// npu_requant_task_seq.sv — Requantization Task Sequence
//
// Extends soc_base_seq. Full Requant task flow:
//   1. Preload input (INT32 tensor) to shared RAM
//   2. Configure NPU for Requant (task_type=3)
//   3. Start and poll
//   4. Read output (INT8 vector)
//
// Requant: INT32 -> INT8 with configurable multiplier and shift.
// Uses requant slot 0 (REQUANT_SEL=0).
// No weight or bias — pure element-wise quantization with clamp to [-128,127].
//
// Properties:
//   input_base          — shared RAM address for input INT32 data
//   output_base         — shared RAM address for output INT8 data
//   element_count       — number of INT32 elements to requantize
//   input_ints[]        — input INT32 values (one per element)
//   multiplier          — requant multiplier (REQUANT0_MULT)
//   shift               — requant shift     (REQUANT0_SHIFT)
//   expected_output_bytes — output byte count for readback (element_count)
//   done / error        — task outcome
//   actual_output[]     — raw INT8 output bytes read from shared RAM
//=============================================================================

`timescale 1ns / 1ps

class npu_requant_task_seq extends soc_base_seq;

  `uvm_object_utils(npu_requant_task_seq)

  //---------------------------------------------------------------------------
  // Configuration properties (set before start())
  //---------------------------------------------------------------------------
  bit [31:0]    input_base;
  bit [31:0]    output_base;
  int unsigned  element_count;
  int unsigned  input_ints[];
  int unsigned  multiplier;
  int unsigned  shift;

  //---------------------------------------------------------------------------
  // Result properties (set after body() completes)
  //---------------------------------------------------------------------------
  int unsigned  expected_output_bytes;
  bit           done;
  bit           error;
  byte unsigned actual_output[];

  function new(string name = "npu_requant_task_seq");
    super.new(name);
    input_base    = 32'h0000_0100;
    output_base   = 32'h0000_0300;
    element_count = 8;
    multiplier    = 1;
    shift         = 0;
    expected_output_bytes = 8;
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
    input_bytes = element_count * 4;
    output_bytes = element_count;
    input_data = new[input_bytes];
    for (i = 0; i < element_count; i++) begin
      input_data[i*4 + 0] = input_ints[i][7:0];
      input_data[i*4 + 1] = input_ints[i][15:8];
      input_data[i*4 + 2] = input_ints[i][23:16];
      input_data[i*4 + 3] = input_ints[i][31:24];
    end

    `uvm_info("REQUANT_TASK", "=== Requant Task: Preloading ===", UVM_NONE)

    // Preload input only — Requant has no weight tensor
    preload_seq = shared_ram_preload_seq::type_id::create("preload_seq");
    preload_seq.base_addr = input_base;
    preload_seq.data      = input_data;
    preload_seq.start(m_sequencer);

    `uvm_info("REQUANT_TASK", "=== Requant Task: Configuring ===", UVM_NONE)

    cfg_seq = npu_config_seq::type_id::create("cfg_seq");
    cfg_seq.task_type    = 3'd3;            // Requant operation
    cfg_seq.input_addr   = input_base;
    cfg_seq.weight_addr  = 32'h0;           // Requant has no weight
    cfg_seq.output_addr  = output_base;
    cfg_seq.input_bytes  = input_bytes;
    cfg_seq.weight_bytes = 32'd0;           // Requant has no weight
    cfg_seq.output_bytes = output_bytes;
    cfg_seq.input_h      = 16'd1;           // Flat 1D: H=1, W=element_count
    cfg_seq.input_w      = element_count[15:0];
    cfg_seq.input_c      = 16'd1;
    cfg_seq.output_c     = 16'd1;
    cfg_seq.relu_en      = 1'b0;
    cfg_seq.pool_en      = 1'b0;
    cfg_seq.cluster_mode = 2'd2;            // Full cluster
    cfg_seq.requant_slot_sel   = 32'd0;     // Slot 0
    cfg_seq.requant_multiplier = multiplier;
    cfg_seq.requant_shift      = shift;
    cfg_seq.start(m_sequencer);

    `uvm_info("REQUANT_TASK", "=== Requant Task: Starting/Polling ===", UVM_NONE)

    poll_seq = npu_start_poll_seq::type_id::create("poll_seq");
    poll_seq.start(m_sequencer);
    done  = poll_seq.done;
    error = poll_seq.error;

    if (error) begin
      `uvm_error("REQUANT_TASK", $sformatf("NPU error: code=0x%02x", poll_seq.error_code))
      return;
    end
    if (!done) begin
      `uvm_error("REQUANT_TASK", "NPU timeout")
      return;
    end

    `uvm_info("REQUANT_TASK", "=== Requant Task: Reading Output ===", UVM_NONE)

    read_seq = npu_output_read_seq::type_id::create("read_seq");
    read_seq.output_addr  = output_base;
    read_seq.output_bytes = output_bytes;
    read_seq.start(m_sequencer);
    actual_output = read_seq.actual;

    `uvm_info("REQUANT_TASK", "=== Requant Task Complete ===", UVM_NONE)
  endtask

endclass
