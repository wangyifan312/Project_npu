//=============================================================================
// npu_ref_model.c — NPU Reference Model DPI-C Implementation
//
// Bit-accurate C reference implementations using svOpenArrayHandle.
// Designed to match the RTL behavior exactly.
//=============================================================================

#include "npu_ref_model.h"
#include <string.h>

//-------------------------------------------------------------------------
// Helper: saturating clamp to INT8 range
//-------------------------------------------------------------------------
static inline int8_t clamp_int8(int32_t val) {
    if (val > 127)  return 127;
    if (val < -128) return -128;
    return (int8_t)val;
}

//-------------------------------------------------------------------------
// Helper: requantize a single INT32 value to INT8
//   result = clamp(round((val * multiplier) >> shift), -128, 127)
//   Rounding: half-up (add (1 << (shift-1)) before truncating)
//-------------------------------------------------------------------------
static inline int8_t requant_val(int32_t val, int32_t multiplier, int shift) {
    int64_t prod = (int64_t)val * multiplier;
    int8_t sign;
    uint64_t abs_prod, abs_rounded, rounding_bias;

    if (shift == 0) {
        return clamp_int8((int32_t)prod);
    }

    // Absolute value
    if (prod < 0) {
        abs_prod = (uint64_t)(-prod);
        sign = -1;
    } else {
        abs_prod = (uint64_t)prod;
        sign = 1;
    }

    rounding_bias = (uint64_t)1 << (shift - 1);
    abs_rounded = (abs_prod + rounding_bias) >> shift;

    int64_t rounded = (int64_t)abs_rounded;
    if (sign < 0) rounded = -rounded;

    return clamp_int8((int32_t)rounded);
}

//===========================================================================
// Conv: INT8 input × INT8 weight → INT32 output
//===========================================================================
int npu_conv_ref(
    const svOpenArrayHandle input_hdl,
    const svOpenArrayHandle weight_hdl,
    svOpenArrayHandle       output_hdl,
    int                     input_h,
    int                     input_w,
    int                     input_c,
    int                     output_c,
    int                     kernel_h,
    int                     kernel_w,
    int                     stride,
    int                     padding)
{
    const int8_t *input  = (const int8_t *)svGetArrayPtr(input_hdl);
    const int8_t *weight = (const int8_t *)svGetArrayPtr(weight_hdl);
    int32_t      *output = (int32_t      *)svGetArrayPtr(output_hdl);

    int pad_h = 0, pad_w = 0;
    int output_h, output_w;
    int oh, ow, oc, kh, kw, ic;
    int in_h, in_w;
    int out_size;

    if (padding == 1) {
        pad_h = kernel_h / 2;
        pad_w = kernel_w / 2;
    }

    output_h = (input_h + 2 * pad_h - kernel_h) / stride + 1;
    output_w = (input_w + 2 * pad_w - kernel_w) / stride + 1;
    out_size = output_h * output_w * output_c;

    memset(output, 0, (size_t)out_size * sizeof(int32_t));

    for (oh = 0; oh < output_h; oh++) {
        for (ow = 0; ow < output_w; ow++) {
            for (oc = 0; oc < output_c; oc++) {
                int32_t accum = 0;
                for (kh = 0; kh < kernel_h; kh++) {
                    for (kw = 0; kw < kernel_w; kw++) {
                        in_h = oh * stride + kh - pad_h;
                        in_w = ow * stride + kw - pad_w;
                        if (in_h >= 0 && in_h < input_h &&
                            in_w >= 0 && in_w < input_w) {
                            for (ic = 0; ic < input_c; ic++) {
                                int in_idx  = (in_h * input_w + in_w) * input_c + ic;
                                int wgt_idx = (ic * kernel_h * kernel_w + kh * kernel_w + kw)
                                              * output_c + oc;
                                accum += (int32_t)input[in_idx]
                                       * (int32_t)weight[wgt_idx];
                            }
                        }
                    }
                }
                output[(oh * output_w + ow) * output_c + oc] = accum;
            }
        }
    }

    return 0;
}

//===========================================================================
// FC: INT8 input × INT8 weight → INT32 output
//===========================================================================
int npu_fc_ref(
    const svOpenArrayHandle input_hdl,
    const svOpenArrayHandle weight_hdl,
    svOpenArrayHandle       output_hdl,
    int                     input_c,
    int                     output_c)
{
    const int8_t *input  = (const int8_t *)svGetArrayPtr(input_hdl);
    const int8_t *weight = (const int8_t *)svGetArrayPtr(weight_hdl);
    int32_t      *output = (int32_t      *)svGetArrayPtr(output_hdl);
    int oc, ic;

    for (oc = 0; oc < output_c; oc++) {
        int32_t accum = 0;
        for (ic = 0; ic < input_c; ic++) {
            accum += (int32_t)input[ic] * (int32_t)weight[oc * input_c + ic];
        }
        output[oc] = accum;
    }

    return 0;
}

//===========================================================================
// Pool: 2x2 MaxPool on INT32, stride=2
//===========================================================================
int npu_pool_ref(
    const svOpenArrayHandle input_hdl,
    svOpenArrayHandle       output_hdl,
    int                     input_h,
    int                     input_w,
    int                     channels)
{
    const int32_t *input  = (const int32_t *)svGetArrayPtr(input_hdl);
    int32_t       *output = (int32_t       *)svGetArrayPtr(output_hdl);
    int output_h = input_h / 2;
    int output_w = input_w / 2;
    int oh, ow, c, ph, pw;

    for (oh = 0; oh < output_h; oh++) {
        for (ow = 0; ow < output_w; ow++) {
            for (c = 0; c < channels; c++) {
                int32_t max_val = INT32_MIN;
                for (ph = 0; ph < 2; ph++) {
                    for (pw = 0; pw < 2; pw++) {
                        int idx = ((oh * 2 + ph) * input_w + (ow * 2 + pw))
                                  * channels + c;
                        if (input[idx] > max_val)
                            max_val = input[idx];
                    }
                }
                output[(oh * output_w + ow) * channels + c] = max_val;
            }
        }
    }

    return 0;
}

//===========================================================================
// Requant: INT32 → INT8
//===========================================================================
int npu_requant_ref(
    const svOpenArrayHandle input_hdl,
    svOpenArrayHandle       output_hdl,
    int                     count,
    int                     multiplier,
    int                     shift)
{
    const int32_t *input  = (const int32_t *)svGetArrayPtr(input_hdl);
    int8_t        *output = (int8_t        *)svGetArrayPtr(output_hdl);
    int i;

    for (i = 0; i < count; i++) {
        output[i] = requant_val(input[i], multiplier, shift);
    }

    return 0;
}

//===========================================================================
// BIAS: INT32 MAC outputs + INT32 bias → INT8 with optional ReLU/Requant
//===========================================================================
int npu_bias_ref(
    const svOpenArrayHandle input_hdl,
    const svOpenArrayHandle bias_hdl,
    svOpenArrayHandle       output_hdl,
    int                     count,
    int                     relu_en,
    int                     requant_en,
    int                     multiplier,
    int                     shift)
{
    const int32_t *input = (const int32_t *)svGetArrayPtr(input_hdl);
    const int32_t *bias  = (const int32_t *)svGetArrayPtr(bias_hdl);
    int8_t        *output = (int8_t *)svGetArrayPtr(output_hdl);
    int i;
    for (i = 0; i < count; i++) {
        int32_t val = input[i] + bias[i];
        if (relu_en && val < 0) val = 0;
        if (requant_en)
            output[i] = requant_val(val, multiplier, shift);
        else
            output[i] = clamp_int8(val);
    }
    return 0;
}

//===========================================================================
// ADD: INT8 tensor add with pre/post requant
//===========================================================================
int npu_add_ref(
    const svOpenArrayHandle src0_hdl,
    const svOpenArrayHandle src1_hdl,
    svOpenArrayHandle       output_hdl,
    int                     count,
    int                     src0_multiplier,
    int                     src0_shift,
    int                     src1_multiplier,
    int                     src1_shift,
    int                     out_multiplier,
    int                     out_shift,
    int                     relu_en,
    int                     requant_en)
{
    const int8_t *src0   = (const int8_t *)svGetArrayPtr(src0_hdl);
    const int8_t *src1   = (const int8_t *)svGetArrayPtr(src1_hdl);
    int8_t       *output = (int8_t       *)svGetArrayPtr(output_hdl);
    int i;

    for (i = 0; i < count; i++) {
        int32_t s0 = requant_val((int32_t)src0[i], src0_multiplier, src0_shift);
        int32_t s1 = requant_val((int32_t)src1[i], src1_multiplier, src1_shift);
        int32_t sum = s0 + s1;
        if (relu_en && sum < 0) sum = 0;
        if (requant_en)
            output[i] = requant_val(sum, out_multiplier, out_shift);
        else
            output[i] = clamp_int8(sum);
    }

    return 0;
}

//===========================================================================
// GAP: 8x8 Global Average Pool with requant (INT8 input)
//===========================================================================
int npu_gap_ref(
    const svOpenArrayHandle input_hdl,
    svOpenArrayHandle       output_hdl,
    int                     channels,
    int                     multiplier,
    int                     shift)
{
    const int8_t *input  = (const int8_t *)svGetArrayPtr(input_hdl);
    int8_t       *output = (int8_t       *)svGetArrayPtr(output_hdl);
    int c, i;

    for (c = 0; c < channels; c++) {
        int32_t sum = 0;
        for (i = 0; i < 64; i++) {
            // Sign-extend INT8 to INT32, matching RTL behavior
            sum += (int32_t)input[i * channels + c];
        }
        // Divide by 64 with round-half-away-from-zero
        int32_t avg;
        if (sum >= 0)
            avg = (sum + 32) / 64;
        else
            avg = (sum - 32) / 64;
        output[c] = requant_val(avg, multiplier, shift);
    }

    return 0;
}
