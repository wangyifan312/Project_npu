//=============================================================================
// npu_ref_model.h — NPU Reference Model C API
//
// Bit-accurate reference implementations using DPI-C svOpenArrayHandle.
// Designed for DPI-C integration with SystemVerilog UVM environment.
//
// All output buffers are caller-allocated (via SV open arrays).
// Functions return 0 on success.
//=============================================================================

#ifndef NPU_REF_MODEL_H
#define NPU_REF_MODEL_H

#include <stdint.h>
#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif

//===========================================================================
// Conv: INT8 input × INT8 weight → INT32 output
//
// valid padding, stride >= 1
// NHWC input × IHWO weight → NHWC INT32 output
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
    int                     padding
);

//===========================================================================
// FC: INT8 input × INT8 weight → INT32 output
//===========================================================================
int npu_fc_ref(
    const svOpenArrayHandle input_hdl,
    const svOpenArrayHandle weight_hdl,
    svOpenArrayHandle       output_hdl,
    int                     input_c,
    int                     output_c
);

//===========================================================================
// Pool: 2x2 MaxPool on INT32 domain, stride=2
//===========================================================================
int npu_pool_ref(
    const svOpenArrayHandle input_hdl,
    svOpenArrayHandle       output_hdl,
    int                     input_h,
    int                     input_w,
    int                     channels
);

//===========================================================================
// Requant: INT32 → INT8
//===========================================================================
int npu_requant_ref(
    const svOpenArrayHandle input_hdl,
    svOpenArrayHandle       output_hdl,
    int                     count,
    int                     multiplier,
    int                     shift
);

//===========================================================================
// BIAS: INT32 MAC outputs + INT32 bias → INT8 with optional ReLU/Requant
//===========================================================================
int npu_bias_ref(
    const svOpenArrayHandle input_hdl,   // INT32 [count] MAC outputs
    const svOpenArrayHandle bias_hdl,    // INT32 [count] bias values
    svOpenArrayHandle       output_hdl,  // INT8 [count]
    int                     count,
    int                     relu_en,
    int                     requant_en,
    int                     multiplier,
    int                     shift
);

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
    int                     requant_en
);

//===========================================================================
// GAP: 8x8 Global Average Pool with requant (INT8 input)
// Input: 64*channels INT8 values (8x8 spatial x channels)
// Each INT8 is sign-extended, summed, divided by 64 with round-half-up,
// then optionally requantized to INT8.
//===========================================================================
int npu_gap_ref(
    const svOpenArrayHandle input_hdl,   // INT8: [64 * channels]
    svOpenArrayHandle       output_hdl,  // INT8: [channels]
    int                     channels,
    int                     multiplier,
    int                     shift
);

#ifdef __cplusplus
}
#endif

#endif // NPU_REF_MODEL_H
