//=============================================================================
// soc_golden_model.sv — UVM Golden Reference Model
//
// Wraps DPI-C reference model functions. Provides a clean UVM-compatible
// API for computing expected outputs of all NPU operations.
//
// Usage:
//   golden.compute_conv(input_bytes, weight_bytes, ...);
//   scoreboard.compare_output_bytes(actual, golden.get_output_bytes());
//=============================================================================

`timescale 1ns / 1ps

class soc_golden_model extends uvm_component;

  `uvm_component_utils(soc_golden_model)

  // Computed output storage
  byte unsigned output_bytes[];
  int   unsigned output_int32[];   // alternative view for INT32 outputs

  // Cached last compute parameters for debug
  string last_op;
  int    last_input_count;
  int    last_output_count;

  function new(string name = "soc_golden_model", uvm_component parent = null);
    super.new(name, parent);
    last_op = "none";
  endfunction

  //----------------------------------------------------------------------
  // compute_conv: INT8 Conv reference
  //
  // 输入_bytes:  [input_h * input_w * input_c] INT8 NHWC
  // 权重_bytes: [kernel_h * kernel_w * input_c * output_c] INT8 HWIO
  // Returns: output_bytes as [output_h * output_w * output_c] INT32 (little-endian)
  //----------------------------------------------------------------------
  function void compute_conv(
      byte unsigned input_bytes[],
      byte unsigned weight_bytes[],
      int input_h, int input_w, int input_c, int output_c,
      int kernel_h, int kernel_w, int stride, int padding
  );
    int output_h, output_w;
    int expected_count;
    byte signed   in_signed[];
    byte signed   wt_signed[];
    int           out_ints[];
    int i;

    output_h = (input_h + 2 * padding - kernel_h) / stride + 1;
    output_w = (input_w + 2 * padding - kernel_w) / stride + 1;

    // Allocate arrays
    in_signed  = new[input_bytes.size()];
    wt_signed  = new[weight_bytes.size()];
    out_ints   = new[output_h * output_w * output_c];

    // Copy to signed byte arrays for DPI
    for (i = 0; i < input_bytes.size(); i++)  in_signed[i] = input_bytes[i];
    for (i = 0; i < weight_bytes.size(); i++) wt_signed[i] = weight_bytes[i];

    // Call DPI-C reference
    void'(npu_conv_ref(in_signed, wt_signed, out_ints,
                       input_h, input_w, input_c, output_c,
                       kernel_h, kernel_w, stride, padding));

    // Convert INT32 output to byte array (little-endian)
    expected_count = output_h * output_w * output_c * 4;
    output_bytes = new[expected_count];
    output_int32 = new[output_h * output_w * output_c];
    for (i = 0; i < output_h * output_w * output_c; i++) begin
      output_int32[i] = out_ints[i];
      output_bytes[i*4 + 0] = out_ints[i][7:0];
      output_bytes[i*4 + 1] = out_ints[i][15:8];
      output_bytes[i*4 + 2] = out_ints[i][23:16];
      output_bytes[i*4 + 3] = out_ints[i][31:24];
    end

    last_op = "Conv";
    last_input_count = input_bytes.size();
    last_output_count = expected_count;

    `uvm_info("GOLDEN", $sformatf(
      "Conv ref: %0dx%0dx%0d + %0dx%0d kernel -> %0dx%0dx%0d = %0d INT32s",
      input_h, input_w, input_c, kernel_h, kernel_w,
      output_h, output_w, output_c, output_h * output_w * output_c), UVM_MEDIUM)
  endfunction

  //----------------------------------------------------------------------
  // compute_fc: INT8 FC reference
  //----------------------------------------------------------------------
  function void compute_fc(
      byte unsigned input_bytes[],
      byte unsigned weight_bytes[],
      int input_c, int output_c
  );
    byte signed in_signed[];
    byte signed wt_signed[];
    int         out_ints[];
    int i;

    in_signed = new[input_c];
    wt_signed = new[output_c * input_c];
    out_ints  = new[output_c];

    for (i = 0; i < input_c; i++)           in_signed[i] = input_bytes[i];
    for (i = 0; i < output_c * input_c; i++) wt_signed[i] = weight_bytes[i];

    void'(npu_fc_ref(in_signed, wt_signed, out_ints, input_c, output_c));

    output_bytes  = new[output_c * 4];
    output_int32  = new[output_c];
    for (i = 0; i < output_c; i++) begin
      output_int32[i] = out_ints[i];
      output_bytes[i*4 + 0] = out_ints[i][7:0];
      output_bytes[i*4 + 1] = out_ints[i][15:8];
      output_bytes[i*4 + 2] = out_ints[i][23:16];
      output_bytes[i*4 + 3] = out_ints[i][31:24];
    end

    last_op = "FC";
    last_input_count = input_c;
    last_output_count = output_c * 4;

    `uvm_info("GOLDEN", $sformatf("FC ref: %0d -> %0d", input_c, output_c), UVM_MEDIUM)
  endfunction

  //----------------------------------------------------------------------
  // compute_requant: INT32 -> INT8 requant reference
  //----------------------------------------------------------------------
  function void compute_requant(
      int   unsigned input_ints[],
      int   multiplier,
      int   shift
  );
    int   in_signed[];
    byte  signed out_bytes_signed[];
    int i;

    in_signed = new[input_ints.size()];
    out_bytes_signed = new[input_ints.size()];

    for (i = 0; i < input_ints.size(); i++)
      in_signed[i] = input_ints[i];

    void'(npu_requant_ref(in_signed, out_bytes_signed,
                          input_ints.size(), multiplier, shift));

    output_bytes = new[input_ints.size()];
    for (i = 0; i < input_ints.size(); i++)
      output_bytes[i] = out_bytes_signed[i];

    last_op = "Requant";
    last_input_count = input_ints.size();
    last_output_count = output_bytes.size();

    `uvm_info("GOLDEN", $sformatf("Requant ref: %0d INT32 -> INT8, mult=%0d shift=%0d",
      input_ints.size(), multiplier, shift), UVM_MEDIUM)
  endfunction

  //----------------------------------------------------------------------
  // compute_bias: INT32 MAC + INT32 bias → INT8 with optional ReLU/Requant
  //----------------------------------------------------------------------
  function void compute_bias(
      int unsigned input_ints[],    // [count] INT32 MAC outputs
      int unsigned bias_ints[],     // [count] INT32 bias values
      int count,
      int relu_en,
      int requant_en,
      int multiplier,
      int shift
  );
    int  in_signed[], bias_signed[];
    byte signed out_signed[];
    int i;

    in_signed   = new[count];
    bias_signed = new[count];
    out_signed  = new[count];

    for (i = 0; i < count; i++) begin
      in_signed[i]   = input_ints[i];
      bias_signed[i] = bias_ints[i];
    end

    void'(npu_bias_ref(in_signed, bias_signed, out_signed, count,
                       relu_en, requant_en, multiplier, shift));

    output_bytes = new[count];
    for (i = 0; i < count; i++)
      output_bytes[i] = out_signed[i];

    last_op = "BIAS";
    last_input_count = count;
    last_output_count = count;

    `uvm_info("GOLDEN", $sformatf(
      "BIAS ref: %0d elements, relu=%0d requant=%0d mult=%0d shift=%0d",
      count, relu_en, requant_en, multiplier, shift), UVM_MEDIUM)
  endfunction

  //----------------------------------------------------------------------
  // compute_add: INT8 ADD with pre/post requant reference
  //----------------------------------------------------------------------
  function void compute_add(
      byte unsigned src0[],
      byte unsigned src1[],
      int src0_mult, int src0_shift,
      int src1_mult, int src1_shift,
      int out_mult,  int out_shift,
      int relu_en = 0,
      int requant_en = 1
  );
    byte signed s0[], s1[], out_signed[];
    int count;
    int i;

    count = src0.size();
    s0 = new[count];
    s1 = new[count];
    out_signed = new[count];

    for (i = 0; i < count; i++) begin
      s0[i] = src0[i];
      s1[i] = src1[i];
    end

    void'(npu_add_ref(s0, s1, out_signed, count,
                      src0_mult, src0_shift, src1_mult, src1_shift,
                      out_mult, out_shift, relu_en, requant_en));

    output_bytes = new[count];
    for (i = 0; i < count; i++)
      output_bytes[i] = out_signed[i];

    last_op = "ADD";
    last_input_count = count;
    last_output_count = count;

    `uvm_info("GOLDEN", $sformatf(
      "ADD ref: %0d elements, relu=%0d requant=%0d", count, relu_en, requant_en), UVM_MEDIUM)
  endfunction

  //----------------------------------------------------------------------
  // compute_gap: 8x8 GAP reference
  //----------------------------------------------------------------------
  // compute_gap: 8x8 GAP with INT8 input (matches RTL gap_cfg[1:0]=0)
  //
  // 输入_bytes: [64 * channels] INT8 (8x8 spatial x channels)
  //----------------------------------------------------------------------
  function void compute_gap(
      byte unsigned input_bytes[],  // [64 * channels] INT8
      int channels,
      int multiplier,
      int shift
  );
    byte signed in_signed[];
    byte signed out_signed[];
    int i;

    in_signed  = new[64 * channels];
    out_signed = new[channels];

    for (i = 0; i < 64 * channels; i++)
      in_signed[i] = input_bytes[i];

    void'(npu_gap_ref(in_signed, out_signed, channels, multiplier, shift));

    output_bytes = new[channels];
    for (i = 0; i < channels; i++)
      output_bytes[i] = out_signed[i];

    last_op = "GAP";
    last_input_count = 64 * channels;
    last_output_count = channels;

    `uvm_info("GOLDEN", $sformatf("GAP ref: %0d channels INT8 input", channels), UVM_MEDIUM)
  endfunction

  //----------------------------------------------------------------------
  // compute_pool: 2x2 MaxPool reference (INT32 domain)
  //----------------------------------------------------------------------
  function void compute_pool(
      int unsigned input_ints[],
      int input_h, int input_w, int channels
  );
    int in_signed[];
    int out_ints[];
    int output_h, output_w;
    int i;

    output_h = input_h / 2;
    output_w = input_w / 2;

    in_signed = new[input_ints.size()];
    out_ints  = new[output_h * output_w * channels];

    for (i = 0; i < input_ints.size(); i++)
      in_signed[i] = input_ints[i];

    void'(npu_pool_ref(in_signed, out_ints, input_h, input_w, channels));

    output_bytes  = new[output_h * output_w * channels * 4];
    output_int32  = new[output_h * output_w * channels];
    for (i = 0; i < output_h * output_w * channels; i++) begin
      output_int32[i] = out_ints[i];
      output_bytes[i*4 + 0] = out_ints[i][7:0];
      output_bytes[i*4 + 1] = out_ints[i][15:8];
      output_bytes[i*4 + 2] = out_ints[i][23:16];
      output_bytes[i*4 + 3] = out_ints[i][31:24];
    end

    last_op = "Pool";
    last_input_count = input_ints.size();
    last_output_count = output_bytes.size();

    `uvm_info("GOLDEN", $sformatf("Pool ref: %0dx%0dx%0d -> %0dx%0dx%0d",
      input_h, input_w, channels, output_h, output_w, channels), UVM_MEDIUM)
  endfunction

  //----------------------------------------------------------------------
  // 注意：output_bytes and output_int32 are public class properties.
  // Access them directly: golden.output_bytes, golden.output_int32
  // VCS O-2018.09-SP2 does not support dynamic array function return types.
  //----------------------------------------------------------------------

endclass
