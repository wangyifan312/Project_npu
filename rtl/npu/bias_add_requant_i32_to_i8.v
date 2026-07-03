// 偏置_add_requant_i32_to_i8: optional INT32 folded bias add before existing requant primitive.
// R1c keeps requant_i32_to_i8 arithmetic unchanged and makes the ordering explicit:
//   accumulator INT32 -> optional + folded bias INT32 -> optional ReLU
//   -> requant_i32_to_i8 -> INT8.
`timescale 1ns / 1ps

module bias_add_requant_i32_to_i8 (
    input  wire signed [31:0] acc_i,
    input  wire signed [31:0] bias_i,
    input  wire               bias_en_i,
    input  wire               relu_en_i,
    input  wire        [31:0] multiplier_i,
    input  wire        [5:0]  shift_i,
    output wire signed [31:0] biased_acc_o,
    output wire signed [7:0]  q_o
);

    assign biased_acc_o = bias_en_i ? ($signed(acc_i) + $signed(bias_i)) : $signed(acc_i);
    wire signed [31:0] post_relu_acc = (relu_en_i && biased_acc_o[31]) ? 32'sd0 : biased_acc_o;

    requant_i32_to_i8 u_requant (
        .acc_i(post_relu_acc),
        .multiplier_i(multiplier_i),
        .shift_i(shift_i),
        .q_o(q_o)
    );

endmodule
