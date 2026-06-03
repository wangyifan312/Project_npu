`timescale 1ns / 1ps

module tb_requant_i32_to_i8;

    reg signed [31:0] acc_i;
    reg        [31:0] multiplier_i;
    reg        [5:0]  shift_i;
    wire signed [7:0] q_o;

    requant_i32_to_i8 u_dut (
        .acc_i(acc_i),
        .multiplier_i(multiplier_i),
        .shift_i(shift_i),
        .q_o(q_o)
    );

    task check_case;
        input signed [31:0] acc_v;
        input [31:0] mult_v;
        input [5:0] shift_v;
        input signed [7:0] exp_v;
        input [255:0] name;
        begin
            acc_i = acc_v;
            multiplier_i = mult_v;
            shift_i = shift_v;
            #1;
            $display("%0s acc=%0d mult=%0d shift=%0d -> q=%0d exp=%0d", name, acc_v, mult_v, shift_v, q_o, exp_v);
            if (q_o !== exp_v)
                $error("FAIL %0s: got %0d expected %0d", name, q_o, exp_v);
        end
    endtask

    initial begin
        $dumpfile("sim/tb_requant_i32_to_i8.vcd");
        $dumpvars(0, tb_requant_i32_to_i8);

        check_case(32'sd100, 32'd1, 6'd0, 8'sd100, "identity");
        check_case(32'sd101, 32'd1, 6'd1, 8'sd51, "round_pos_half_up");
        check_case(-32'sd101, 32'd1, 6'd1, -8'sd51, "round_neg_half_away");
        check_case(32'sd255, 32'd1, 6'd1, 8'sd127, "clamp_pos");
        check_case(-32'sd300, 32'd1, 6'd1, -8'sd128, "clamp_neg");
        check_case(32'sd33, 32'd3, 6'd2, 8'sd25, "scaled_round");

        $display("tb_requant_i32_to_i8 PASS");
        #5;
        $finish;
    end

endmodule
