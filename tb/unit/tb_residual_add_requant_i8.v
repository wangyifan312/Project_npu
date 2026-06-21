// tb_residual_add_requant_i8: directed R1d residual ADD numeric checks.
`timescale 1ns / 1ps

module tb_residual_add_requant_i8;
    reg  signed [7:0]  src0;
    reg  signed [7:0]  src1;
    reg                relu_en;
    reg                requant_en;
    reg  [31:0]        src0_mult;
    reg  [5:0]         src0_shift;
    reg  [31:0]        src1_mult;
    reg  [5:0]         src1_shift;
    reg  [31:0]        out_mult;
    reg  [5:0]         out_shift;
    wire signed [7:0]  src0_aligned;
    wire signed [7:0]  src1_aligned;
    wire signed [31:0] add_raw;
    wire signed [31:0] add_relu;
    wire signed [7:0]  out_q;

    residual_add_requant_i8 dut (
        .src0_i(src0),
        .src1_i(src1),
        .relu_en_i(relu_en),
        .requant_en_i(requant_en),
        .src0_multiplier_i(src0_mult),
        .src0_shift_i(src0_shift),
        .src1_multiplier_i(src1_mult),
        .src1_shift_i(src1_shift),
        .out_multiplier_i(out_mult),
        .out_shift_i(out_shift),
        .src0_aligned_o(src0_aligned),
        .src1_aligned_o(src1_aligned),
        .add_raw_o(add_raw),
        .add_relu_o(add_relu),
        .out_o(out_q)
    );

    task check;
        input signed [7:0]  i0;
        input signed [7:0]  i1;
        input               relu;
        input               rq;
        input [31:0]        m0;
        input [5:0]         s0;
        input [31:0]        m1;
        input [5:0]         s1;
        input [31:0]        mo;
        input [5:0]         so;
        input signed [7:0]  exp_a0;
        input signed [7:0]  exp_a1;
        input signed [31:0] exp_raw;
        input signed [31:0] exp_relu;
        input signed [7:0]  exp_out;
        begin
            src0 = i0;
            src1 = i1;
            relu_en = relu;
            requant_en = rq;
            src0_mult = m0;
            src0_shift = s0;
            src1_mult = m1;
            src1_shift = s1;
            out_mult = mo;
            out_shift = so;
            #1;
            if (src0_aligned !== exp_a0 ||
                src1_aligned !== exp_a1 ||
                add_raw !== exp_raw ||
                add_relu !== exp_relu ||
                out_q !== exp_out) begin
                $display("tb_residual_add_requant_i8 FAIL");
                $display(" got a0=%0d a1=%0d raw=%0d relu=%0d out=%0d",
                         src0_aligned, src1_aligned, add_raw, add_relu, out_q);
                $display(" exp a0=%0d a1=%0d raw=%0d relu=%0d out=%0d",
                         exp_a0, exp_a1, exp_raw, exp_relu, exp_out);
                $finish;
            end
        end
    endtask

    initial begin
        check(8'sd10, -8'sd3, 1'b0, 1'b0,
              32'd1, 6'd0, 32'd1, 6'd0, 32'd1, 6'd0,
              8'sd10, -8'sd3, 32'sd7, 32'sd7, 8'sd7);

        check(-8'sd10, 8'sd3, 1'b1, 1'b0,
              32'd1, 6'd0, 32'd1, 6'd0, 32'd1, 6'd0,
              -8'sd10, 8'sd3, -32'sd7, 32'sd0, 8'sd0);

        check(8'sd20, -8'sd4, 1'b0, 1'b0,
              32'd1, 6'd1, 32'd1, 6'd0, 32'd1, 6'd0,
              8'sd10, -8'sd4, 32'sd6, 32'sd6, 8'sd6);

        check(8'sd60, 8'sd10, 1'b0, 1'b1,
              32'd1, 6'd0, 32'd1, 6'd0, 32'd1, 6'd1,
              8'sd60, 8'sd10, 32'sd70, 32'sd70, 8'sd35);

        check(8'sd127, 8'sd127, 1'b0, 1'b0,
              32'd1, 6'd0, 32'd1, 6'd0, 32'd1, 6'd0,
              8'sd127, 8'sd127, 32'sd254, 32'sd254, 8'sd127);

        check(-8'sd128, -8'sd128, 1'b0, 1'b0,
              32'd1, 6'd0, 32'd1, 6'd0, 32'd1, 6'd0,
              -8'sd128, -8'sd128, -32'sd256, -32'sd256, -8'sd128);

        $display("tb_residual_add_requant_i8 PASS");
        $finish;
    end
endmodule
