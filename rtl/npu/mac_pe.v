// mac_pe: 脉动阵列的单个 MAC 处理单元
// INT8 激活 × INT8 权重 → INT32 累加
// 权重驻留：权重预加载，激活从左→右流动，部分和从上→下流动
`timescale 1ns / 1ps

module mac_pe (
    input  wire        clk,
    input  wire        rst_n,

    // 数据流：激活左→右，部分和上→下
    input  wire [7:0]  act_in,
    output wire [7:0]  act_out,
    input  wire [31:0] sum_in,
    output wire [31:0] sum_out,

    // 权重加载
    input  wire [7:0]  weight,
    input  wire        weight_ld
);

    // 寄存的激活值（转发给右侧邻居）
    reg [7:0]  act_reg;
    // 权重存储（驻留）
    reg [7:0]  weight_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_reg    <= 8'h0;
            weight_reg <= 8'h0;
        end else begin
            act_reg <= act_in;
            if (weight_ld)
                weight_reg <= weight;
        end
    end

    // 乘法：INT8 × INT8 → INT16（组合逻辑）
    wire signed [15:0] product;
    assign product = $signed(act_reg) * $signed(weight_reg);

    // 带流水线寄存器的累加（每个 PE 1 周期以匹配脉动节拍）
    reg [31:0] sum_out_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sum_out_reg <= 32'h0;
        else
            sum_out_reg <= $signed(sum_in) + $signed(product);
    end
    assign sum_out = sum_out_reg;

    // 转发激活值（经 act_reg 寄存）
    assign act_out = act_reg;

endmodule
