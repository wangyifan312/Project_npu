// gap8x8_requant_i8: R1e GAP8x8 基础模块。
// 数值顺序：
//   INT8 特征图值 -> INT32 空间求和
//   使用有符号 round-half-away-from-zero 移位除以 64
//   可选 requant_i32_to_i8 -> INT8 输出
// 本模块复用 requant_i32_to_i8 进行可选后requant，不改变
// 现有 requant 原语的语义。
`timescale 1ns / 1ps

module gap8x8_requant_i8 (
    input  wire signed [31:0] sum_i,
    input  wire        [5:0]  avg_shift_i,
    input  wire               requant_en_i,
    input  wire        [31:0] multiplier_i,
    input  wire        [5:0]  shift_i,
    output wire signed [31:0] avg_i32_o,
    output wire signed [7:0]  out_o
);

    wire [31:0] abs_sum = sum_i[31] ? $unsigned(-sum_i) : $unsigned(sum_i);
    wire [31:0] avg_round_bias =
        (avg_shift_i == 6'd0) ? 32'd0 : (32'd1 << (avg_shift_i - 6'd1));
    wire [31:0] abs_avg =
        (avg_shift_i == 6'd0) ? abs_sum : ((abs_sum + avg_round_bias) >> avg_shift_i);
    assign avg_i32_o = sum_i[31] ? -$signed(abs_avg) : $signed(abs_avg);

    wire signed [7:0] requant_q;
    requant_i32_to_i8 u_gap_requant (
        .acc_i(avg_i32_o),
        .multiplier_i(multiplier_i),
        .shift_i(shift_i),
        .q_o(requant_q)
    );

    wire signed [7:0] avg_clamped =
        (avg_i32_o > 32'sd127)  ? 8'sd127  :
        (avg_i32_o < -32'sd128) ? -8'sd128 :
                                  avg_i32_o[7:0];

    assign out_o = requant_en_i ? requant_q : avg_clamped;

endmodule
