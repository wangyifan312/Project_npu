// mac_tile_4x4: 4×4 脉动阵列 tile（扁平端口以兼容 iverilog）
// INT8 激活 × INT8 权重 → INT32 累加，权重驻留
`timescale 1ns / 1ps

module mac_tile_4x4 (
    input  wire        clk,
    input  wire        rst_n,

    // 激活: 4 个输入（每行一个），从左→右流动
    input  wire [7:0]  act_in_0,
    input  wire [7:0]  act_in_1,
    input  wire [7:0]  act_in_2,
    input  wire [7:0]  act_in_3,

    // 来自顶部的部分和: 4 个输入（每列一个）
    input  wire [31:0] sum_in_0,
    input  wire [31:0] sum_in_1,
    input  wire [31:0] sum_in_2,
    input  wire [31:0] sum_in_3,

    // 权重: 4×4（扁平，行优先: w[0][0], w[0][1], ..., w[3][3]）
    input  wire [7:0]  weight_00, weight_01, weight_02, weight_03,
    input  wire [7:0]  weight_10, weight_11, weight_12, weight_13,
    input  wire [7:0]  weight_20, weight_21, weight_22, weight_23,
    input  wire [7:0]  weight_30, weight_31, weight_32, weight_33,
    input  wire        weight_ld,

    // 输出
    output wire [7:0]  act_out_0,
    output wire [7:0]  act_out_1,
    output wire [7:0]  act_out_2,
    output wire [7:0]  act_out_3,
    output wire [31:0] sum_out_0,
    output wire [31:0] sum_out_1,
    output wire [31:0] sum_out_2,
    output wire [31:0] sum_out_3
);

    // 重新打包为内部连线
    wire [7:0]  act_in  [0:3];
    wire [31:0] sum_in  [0:3];
    wire [7:0]  weight [0:3][0:3];
    wire [7:0]  act_out [0:3];
    wire [31:0] sum_out [0:3];

    assign act_in[0] = act_in_0;
    assign act_in[1] = act_in_1;
    assign act_in[2] = act_in_2;
    assign act_in[3] = act_in_3;

    assign sum_in[0] = sum_in_0;
    assign sum_in[1] = sum_in_1;
    assign sum_in[2] = sum_in_2;
    assign sum_in[3] = sum_in_3;

    assign weight[0][0] = weight_00; assign weight[0][1] = weight_01; assign weight[0][2] = weight_02; assign weight[0][3] = weight_03;
    assign weight[1][0] = weight_10; assign weight[1][1] = weight_11; assign weight[1][2] = weight_12; assign weight[1][3] = weight_13;
    assign weight[2][0] = weight_20; assign weight[2][1] = weight_21; assign weight[2][2] = weight_22; assign weight[2][3] = weight_23;
    assign weight[3][0] = weight_30; assign weight[3][1] = weight_31; assign weight[3][2] = weight_32; assign weight[3][3] = weight_33;

    assign act_out_0 = act_out[0];
    assign act_out_1 = act_out[1];
    assign act_out_2 = act_out[2];
    assign act_out_3 = act_out[3];

    assign sum_out_0 = sum_out[0];
    assign sum_out_1 = sum_out[1];
    assign sum_out_2 = sum_out[2];
    assign sum_out_3 = sum_out[3];

    // 内部连线
    wire [7:0]  act_h [0:3][0:4];
    wire [31:0] sum_v [0:4][0:3];

    genvar r, c;
    generate
        for (r = 0; r < 4; r = r + 1) begin : row
            assign act_h[r][0] = act_in[r];
            assign act_out[r] = act_h[r][4];

            for (c = 0; c < 4; c = c + 1) begin : col
                if (r == 0)
                    assign sum_v[0][c] = sum_in[c];

                mac_pe u_pe (
                    .clk        (clk),
                    .rst_n      (rst_n),
                    .act_in     (act_h[r][c]),
                    .act_out    (act_h[r][c+1]),
                    .sum_in     (sum_v[r][c]),
                    .sum_out    (sum_v[r+1][c]),
                    .weight     (weight[r][c]),
                    .weight_ld  (weight_ld)
                );
            end
        end
    endgenerate

    generate
        for (c = 0; c < 4; c = c + 1) begin : sum_out_gen
            assign sum_out[c] = sum_v[4][c];
        end
    endgenerate

endmodule
