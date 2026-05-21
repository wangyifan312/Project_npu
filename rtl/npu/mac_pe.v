// mac_pe: single MAC Processing Element for systolic array
// INT8 activation × INT8 weight → INT32 accumulation
// Weight-stationary: weight pre-loaded, activation flows left→right, sum flows top→bottom
`timescale 1ns / 1ps

module mac_pe (
    input  wire        clk,
    input  wire        rst_n,

    // Data flow: activation left→right, partial sum top→bottom
    input  wire [7:0]  act_in,
    output wire [7:0]  act_out,
    input  wire [31:0] sum_in,
    output wire [31:0] sum_out,

    // Weight loading
    input  wire [7:0]  weight,
    input  wire        weight_ld
);

    // Registered activation (forwarded to right neighbor)
    reg [7:0]  act_reg;
    // Weight storage (stationary)
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
