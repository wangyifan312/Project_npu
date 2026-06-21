// tb_resnet20_r1b_conv_shape: generalized Conv scheduler shape checks
`timescale 1ns / 1ps

module tb_resnet20_r1b_conv_shape;
    reg clk;
    reg rst_n;
    reg task_start;
    reg block_done;
    reg [31:0] conv_cfg;
    reg [15:0] input_h;
    reg [15:0] input_w;
    reg [15:0] input_c;
    reg [15:0] output_c;

    wire block_valid;
    wire all_blocks_done;
    wire [31:0] blk_input_addr;
    wire [31:0] blk_weight_addr;
    wire [31:0] blk_output_addr;
    wire [31:0] blk_input_bytes;
    wire [31:0] blk_weight_bytes;
    wire [31:0] blk_output_bytes;
    wire [15:0] blk_input_rows;
    wire [15:0] blk_output_rows;
    wire [31:0] blk_wgt_per_cin;
    wire [15:0] blk_cin_total;

    block_scheduler #(
        .BUF_ENTRIES(8192),
        .BUF_ADDR_W(13)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .task_start(task_start),
        .task_type(3'd0),
        .input_addr(32'h0000_1000),
        .weight_addr(32'h0000_4000),
        .output_addr(32'h0000_8000),
        .input_bytes(32'd0),
        .weight_bytes(32'd0),
        .output_bytes(32'd0),
        .input_h(input_h),
        .input_w(input_w),
        .input_c(input_c),
        .output_c(output_c),
        .conv_cfg(conv_cfg),
        .block_done(block_done),
        .block_valid(block_valid),
        .all_blocks_done(all_blocks_done),
        .blk_input_addr(blk_input_addr),
        .blk_weight_addr(blk_weight_addr),
        .blk_output_addr(blk_output_addr),
        .blk_input_bytes(blk_input_bytes),
        .blk_weight_bytes(blk_weight_bytes),
        .blk_output_bytes(blk_output_bytes),
        .blk_input_rows(blk_input_rows),
        .blk_output_rows(blk_output_rows),
        .blk_wgt_per_cin(blk_wgt_per_cin),
        .blk_cin_total(blk_cin_total)
    );

    always #5 clk = ~clk;

    task fail;
        input [255:0] msg;
        begin
            $display("tb_resnet20_r1b_conv_shape FAIL: %0s", msg);
            $finish;
        end
    endtask

    task reset_case;
        begin
            rst_n = 1'b0;
            task_start = 1'b0;
            block_done = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task run_case;
        input [255:0] name;
        input [31:0] cfg;
        input [15:0] in_h;
        input [15:0] in_w;
        input [15:0] out_c;
        input [15:0] expected_out_cols;
        input [31:0] expected_wgt_per_cin;
        integer timeout;
        reg [31:0] observed_out_cols;
        begin
            reset_case;
            conv_cfg = cfg;
            input_h = in_h;
            input_w = in_w;
            input_c = 16'd8;
            output_c = out_c;
            @(posedge clk);
            task_start = 1'b1;
            @(posedge clk);
            task_start = 1'b0;

            timeout = 0;
            while (!block_valid && timeout < 20) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!block_valid) fail("block_valid timeout");
            if (blk_output_rows == 16'd0) fail("blk_output_rows is zero");
            observed_out_cols = blk_output_bytes / ({16'd0, blk_output_rows} * {16'd0, output_c} * 32'd4);
            if (observed_out_cols !== {16'd0, expected_out_cols}) begin
                $display("%0s observed_out_cols=%0d expected=%0d", name, observed_out_cols, expected_out_cols);
                fail("output column derivation mismatch");
            end
            if (blk_wgt_per_cin !== expected_wgt_per_cin) begin
                $display("%0s wgt_per_cin=%0d expected=%0d", name, blk_wgt_per_cin, expected_wgt_per_cin);
                fail("weight stride mismatch");
            end
            $display("PASS %0s rows=%0d cols=%0d in_rows=%0d wgt_per_cin=%0d",
                     name, blk_output_rows, observed_out_cols, blk_input_rows, blk_wgt_per_cin);
        end
    endtask

    initial begin
        clk = 1'b0;
        conv_cfg = 32'd0;
        input_h = 16'd32;
        input_w = 16'd32;
        input_c = 16'd8;
        output_c = 16'd16;
        task_start = 1'b0;
        block_done = 1'b0;
        rst_n = 1'b0;

        run_case("legacy_5x5_valid_s1", 32'h0000_0000, 16'd28, 16'd28, 16'd6, 16'd24, 32'd152);
        run_case("conv3x3_same_s1",    32'h0000_000a, 16'd32, 16'd32, 16'd16, 16'd32, 32'd144);
        run_case("conv3x3_same_s2",    32'h0000_000e, 16'd32, 16'd32, 16'd16, 16'd16, 32'd144);
        run_case("conv1x1_valid_s1",   32'h0000_0001, 16'd32, 16'd32, 16'd16, 16'd32, 32'd16);
        run_case("conv1x1_valid_s2",   32'h0000_0005, 16'd32, 16'd32, 16'd16, 16'd16, 32'd16);

        $display("tb_resnet20_r1b_conv_shape PASS");
        $finish;
    end
endmodule
