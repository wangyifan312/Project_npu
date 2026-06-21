`timescale 1ns / 1ps

module tb_bias_add_requant_i32_to_i8;
    reg  signed [31:0] acc;
    reg  signed [31:0] bias;
    reg                bias_en;
    reg                relu_en;
    reg  [31:0]        multiplier;
    reg  [5:0]         shift;
    wire signed [31:0] biased_acc;
    wire signed [7:0]  q;

    bias_add_requant_i32_to_i8 dut (
        .acc_i(acc),
        .bias_i(bias),
        .bias_en_i(bias_en),
        .relu_en_i(relu_en),
        .multiplier_i(multiplier),
        .shift_i(shift),
        .biased_acc_o(biased_acc),
        .q_o(q)
    );

    task check_case;
        input signed [31:0] in_acc;
        input signed [31:0] in_bias;
        input in_bias_en;
        input in_relu_en;
        input [31:0] in_mult;
        input [5:0] in_shift;
        input signed [31:0] exp_biased;
        input signed [7:0] exp_q;
        begin
            acc = in_acc;
            bias = in_bias;
            bias_en = in_bias_en;
            relu_en = in_relu_en;
            multiplier = in_mult;
            shift = in_shift;
            #1;
            if (biased_acc !== exp_biased) begin
                $display("FAIL biased_acc got=%0d expect=%0d", biased_acc, exp_biased);
                $finish;
            end
            if (q !== exp_q) begin
                $display("FAIL q got=%0d expect=%0d", q, exp_q);
                $finish;
            end
        end
    endtask

    initial begin
        check_case(32'sd10,  32'sd5,   1'b1, 1'b0, 32'd1, 6'd0,  32'sd15,  8'sd15);
        check_case(32'sd10,  32'sd5,   1'b0, 1'b0, 32'd1, 6'd0,  32'sd10,  8'sd10);
        check_case(32'sd7,   32'sd0,   1'b1, 1'b0, 32'd1, 6'd1,  32'sd7,   8'sd4);
        check_case(-32'sd7,  32'sd0,   1'b1, 1'b0, 32'd1, 6'd1, -32'sd7,  -8'sd4);
        check_case(-32'sd7,  32'sd0,   1'b1, 1'b1, 32'd1, 6'd1, -32'sd7,   8'sd0);
        check_case(32'sd200, 32'sd100, 1'b1, 1'b0, 32'd1, 6'd0,  32'sd300, 8'sd127);
        check_case(-32'sd200,-32'sd100,1'b1, 1'b0, 32'd1, 6'd0, -32'sd300,-8'sd128);
        $display("tb_bias_add_requant_i32_to_i8 PASS");
        $finish;
    end
endmodule
