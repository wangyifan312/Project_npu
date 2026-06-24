//=============================================================================
// npu_ref_dpi.sv — DPI-C Import Declarations for NPU Reference Model
//
// Maps C functions from npu_ref_model.c to SystemVerilog tasks/functions.
//=============================================================================

`timescale 1ns / 1ps

//-------------------------------------------------------------------------
// DPI-C function imports
//-------------------------------------------------------------------------
import "DPI-C" function int npu_conv_ref(
    input  byte   input_data[],    // INT8: [input_h * input_w * input_c]
    input  byte   weight_data[],   // INT8: [kernel_h * kernel_w * input_c * output_c]
    output int    output_data[],   // INT32: [output_h * output_w * output_c]
    input  int    input_h,
    input  int    input_w,
    input  int    input_c,
    input  int    output_c,
    input  int    kernel_h,
    input  int    kernel_w,
    input  int    stride,
    input  int    padding
);

import "DPI-C" function int npu_fc_ref(
    input  byte   input_data[],    // INT8: [input_c]
    input  byte   weight_data[],   // INT8: [output_c * input_c]
    output int    output_data[],   // INT32: [output_c]
    input  int    input_c,
    input  int    output_c
);

import "DPI-C" function int npu_pool_ref(
    input  int    input_data[],    // INT32: [input_h * input_w * channels]
    output int    output_data[],   // INT32: [output_h/2 * output_w/2 * channels]
    input  int    input_h,
    input  int    input_w,
    input  int    channels
);

import "DPI-C" function int npu_requant_ref(
    input  int    input_data[],    // INT32: [count]
    output byte   output_data[],   // INT8: [count]
    input  int    count,
    input  int    multiplier,
    input  int    shift
);

import "DPI-C" function int npu_bias_ref(
    input  int    input_data[],    // INT32: [count] MAC outputs
    input  int    bias_data[],     // INT32: [count] bias values
    output byte   output_data[],   // INT8: [count]
    input  int    count,
    input  int    relu_en,
    input  int    requant_en,
    input  int    multiplier,
    input  int    shift
);

import "DPI-C" function int npu_add_ref(
    input  byte   src0_data[],     // INT8: [count]
    input  byte   src1_data[],     // INT8: [count]
    output byte   output_data[],   // INT8: [count]
    input  int    count,
    input  int    src0_multiplier,
    input  int    src0_shift,
    input  int    src1_multiplier,
    input  int    src1_shift,
    input  int    out_multiplier,
    input  int    out_shift,
    input  int    relu_en,
    input  int    requant_en
);

import "DPI-C" function int npu_gap_ref(
    input  byte   input_data[],    // INT8: [64 * channels] sign-extended to INT32 in C
    output byte   output_data[],   // INT8: [channels]
    input  int    channels,
    input  int    multiplier,
    input  int    shift
);
