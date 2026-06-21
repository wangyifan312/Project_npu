// tb_gap8x8_requant_i8: directed R1e GAP8x8 numeric checks.
`timescale 1ns / 1ps

module tb_gap8x8_requant_i8;

    reg  signed [31:0] sum_i;
    reg         [5:0]  avg_shift_i;
    reg                requant_en_i;
    reg         [31:0] multiplier_i;
    reg         [5:0]  shift_i;
    wire signed [31:0] avg_i32_o;
    wire signed [7:0]  out_o;

    gap8x8_requant_i8 dut (
        .sum_i(sum_i),
        .avg_shift_i(avg_shift_i),
        .requant_en_i(requant_en_i),
        .multiplier_i(multiplier_i),
        .shift_i(shift_i),
        .avg_i32_o(avg_i32_o),
        .out_o(out_o)
    );

    task check_case;
        input signed [31:0] sum;
        input               rq_en;
        input [31:0]        mult;
        input [5:0]         shift;
        input signed [31:0] exp_avg;
        input signed [7:0]  exp_out;
        begin
            sum_i = sum;
            requant_en_i = rq_en;
            multiplier_i = mult;
            shift_i = shift;
            #1;
            if (avg_i32_o !== exp_avg) begin
                $display("FAIL avg: sum=%0d got=%0d expected=%0d", sum, avg_i32_o, exp_avg);
                $finish;
            end
            if (out_o !== exp_out) begin
                $display("FAIL out: sum=%0d got=%0d expected=%0d", sum, out_o, exp_out);
                $finish;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/tb_gap8x8_requant_i8.vcd");
        $dumpvars(0, tb_gap8x8_requant_i8);

        avg_shift_i = 6'd6;
        multiplier_i = 32'd1;
        shift_i = 6'd0;
        requant_en_i = 1'b0;
        sum_i = 32'sd0;
        #1;

        check_case(32'sd64,   1'b0, 32'd1, 6'd0, 32'sd1,   8'sd1);
        check_case(32'sd96,   1'b0, 32'd1, 6'd0, 32'sd2,   8'sd2);
        check_case(-32'sd96,  1'b0, 32'd1, 6'd0, -32'sd2, -8'sd2);
        check_case(32'sd8192, 1'b0, 32'd1, 6'd0, 32'sd128, 8'sd127);
        check_case(32'sd128,  1'b1, 32'd3, 6'd1, 32'sd2,   8'sd3);

        $display("tb_gap8x8_requant_i8 PASS");
        $finish;
    end

endmodule
