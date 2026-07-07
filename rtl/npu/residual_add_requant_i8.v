// residual_add_requant_i8: R1d 残差 ADD 基础模块。
// 数值顺序：
//   src0 INT8 -> 预对齐 requant -> INT32
//   src1 INT8 -> 预对齐 requant -> INT32
//   加法 -> 可选 ReLU -> 后 requant -> INT8
// 本模块复用 requant_i32_to_i8 进行所有尺度转换，不改变
// 现有 round/clamp 语义。
`timescale 1ns / 1ps

module residual_add_requant_i8 (
    input  wire signed [7:0]  src0_i,
    input  wire signed [7:0]  src1_i,
    input  wire               relu_en_i,
    input  wire               requant_en_i,
    input  wire [31:0]        src0_multiplier_i,
    input  wire [5:0]         src0_shift_i,
    input  wire [31:0]        src1_multiplier_i,
    input  wire [5:0]         src1_shift_i,
    input  wire [31:0]        out_multiplier_i,
    input  wire [5:0]         out_shift_i,
    output wire signed [7:0]  src0_aligned_o,
    output wire signed [7:0]  src1_aligned_o,
    output wire signed [31:0] add_raw_o,
    output wire signed [31:0] add_relu_o,
    output wire signed [7:0]  out_o
);

    wire signed [31:0] src0_i32 = {{24{src0_i[7]}}, src0_i};
    wire signed [31:0] src1_i32 = {{24{src1_i[7]}}, src1_i};

    requant_i32_to_i8 u_src0_align (
        .acc_i(src0_i32),
        .multiplier_i(src0_multiplier_i),
        .shift_i(src0_shift_i),
        .q_o(src0_aligned_o)
    );

    requant_i32_to_i8 u_src1_align (
        .acc_i(src1_i32),
        .multiplier_i(src1_multiplier_i),
        .shift_i(src1_shift_i),
        .q_o(src1_aligned_o)
    );

    wire signed [31:0] src0_aligned_i32 = {{24{src0_aligned_o[7]}}, src0_aligned_o};
    wire signed [31:0] src1_aligned_i32 = {{24{src1_aligned_o[7]}}, src1_aligned_o};

    assign add_raw_o = src0_aligned_i32 + src1_aligned_i32;
    assign add_relu_o = (relu_en_i && add_raw_o[31]) ? 32'sd0 : add_raw_o;

    wire signed [7:0] post_requant_q;
    requant_i32_to_i8 u_post_requant (
        .acc_i(add_relu_o),
        .multiplier_i(out_multiplier_i),
        .shift_i(out_shift_i),
        .q_o(post_requant_q)
    );

    assign out_o = requant_en_i ? post_requant_q :
                   (add_relu_o > 32'sd127)  ? 8'sd127 :
                   (add_relu_o < -32'sd128) ? -8'sd128 :
                                              add_relu_o[7:0];

endmodule
