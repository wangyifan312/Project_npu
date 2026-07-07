// requant_i32_to_i8: 有符号 INT32 -> INT8 requant，使用逐层 multiplier/shift
// 算术：
//   q = clamp( round_to_nearest( acc * multiplier / 2^shift ), -128, 127 )
// 舍入规则为对称"四舍五入远离零"，以匹配 Python 工具。
`timescale 1ns / 1ps

module requant_i32_to_i8 (
    input  wire signed [31:0] acc_i,
    input  wire        [31:0] multiplier_i,
    input  wire        [5:0]  shift_i,
    output wire signed [7:0]  q_o
);

    wire signed [63:0] product = acc_i * $signed({1'b0, multiplier_i});
    wire        [63:0] abs_product = product[63] ? $unsigned(-product) : $unsigned(product);
    wire        [63:0] rounding_bias =
        (shift_i == 6'd0) ? 64'd0 : (64'd1 << (shift_i - 6'd1));
    wire        [63:0] abs_rounded =
        (shift_i == 6'd0) ? abs_product : ((abs_product + rounding_bias) >> shift_i);
    wire signed [63:0] rounded = product[63] ? -$signed(abs_rounded) : $signed(abs_rounded);

    assign q_o =
        (rounded > 64'sd127)  ? 8'sd127  :
        (rounded < -64'sd128) ? -8'sd128 :
                                rounded[7:0];

endmodule
