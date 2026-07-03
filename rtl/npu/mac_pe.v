// mac_pe：脉动阵列的单 MAC 处理单元
// INT8 激活 × INT8 权重 → INT32 累加
// 权重驻留：权重预加载，激活从左向右流动，部分和从上向下流动
`timescale 1ns / 1ps

module mac_pe (
    input  wire        clk,
    input  wire        rst_n,

    // 数据 flow: activation left→right, partial sum top→bottom
    input  wire [7:0]  act_in,
    output wire [7:0]  act_out,
    input  wire [31:0] sum_in,
    output wire [31:0] sum_out,

    // 权重 loading
    input  wire [7:0]  weight,
    input  wire        weight_ld
);

    // 寄存器ed activation (forwarded to right neighbor)
    reg [7:0]  act_reg;
    // 权重 storage (stationary)
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

    // Multiply: INT8 × INT8 → INT16 (combinational)
    wire signed [15:0] product;
    assign product = $signed(act_reg) * $signed(weight_reg);

    // Accumulate with pipeline register (1 cycle per PE for systolic rhythm)
    reg [31:0] sum_out_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sum_out_reg <= 32'h0;
        else
            sum_out_reg <= $signed(sum_in) + $signed(product);
    end
    assign sum_out = sum_out_reg;

    // Forward activation (registered via act_reg)
    assign act_out = act_reg;

endmodule
