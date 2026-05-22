`timescale 1ns / 1ps

module tb_output_arbiter;

    localparam CLUSTER_COUNT = 6;
    localparam CLUSTER_OUT_W = 16 * 32;

    reg clk;
    reg rst_n;
    reg [CLUSTER_COUNT-1:0] cluster_enable;
    reg [CLUSTER_COUNT-1:0] cluster_valid;
    reg [CLUSTER_COUNT-1:0] cluster_done;
    reg [(CLUSTER_COUNT*CLUSTER_OUT_W)-1:0] cluster_sum_out_flat;
    wire arb_valid;
    reg arb_ready;
    wire [CLUSTER_OUT_W-1:0] arb_sum_out_flat;
    wire [2:0] arb_cluster_id;
    wire all_done;

    integer cluster_idx;

    output_arbiter #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CLUSTER_OUT_W(CLUSTER_OUT_W)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .cluster_enable(cluster_enable),
        .cluster_valid(cluster_valid),
        .cluster_done(cluster_done),
        .cluster_sum_out_flat(cluster_sum_out_flat),
        .arb_valid(arb_valid),
        .arb_ready(arb_ready),
        .arb_sum_out_flat(arb_sum_out_flat),
        .arb_cluster_id(arb_cluster_id),
        .all_done(all_done)
    );

    always #5 clk = ~clk;

    task expect_pick;
        input [2:0] expected_id;
        input [31:0] expected_word;
        begin
            #1;
            if (!arb_valid) begin
                $fatal(1, "arbiter not valid when expecting cluster %0d", expected_id);
            end
            if (arb_cluster_id !== expected_id) begin
                $fatal(1, "arbiter picked cluster %0d expect %0d", arb_cluster_id, expected_id);
            end
            if (arb_sum_out_flat[31:0] !== expected_word) begin
                $fatal(1, "arbiter data=0x%08x expect 0x%08x", arb_sum_out_flat[31:0], expected_word);
            end
            @(posedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cluster_enable = 6'b0;
        cluster_valid = 6'b0;
        cluster_done = 6'b0;
        cluster_sum_out_flat = {(CLUSTER_COUNT*CLUSTER_OUT_W){1'b0}};
        arb_ready = 1'b1;

        for (cluster_idx = 0; cluster_idx < CLUSTER_COUNT; cluster_idx = cluster_idx + 1) begin
            cluster_sum_out_flat[cluster_idx*CLUSTER_OUT_W +: 32] = 32'h100 + cluster_idx;
        end

        #20;
        rst_n = 1'b1;

        cluster_enable = 6'b11_1111;
        cluster_valid = 6'b10_1010;
        expect_pick(3'd1, 32'h0000_0101);
        expect_pick(3'd3, 32'h0000_0103);
        expect_pick(3'd5, 32'h0000_0105);

        cluster_valid = 6'b00_0101;
        expect_pick(3'd0, 32'h0000_0100);
        expect_pick(3'd2, 32'h0000_0102);

        cluster_done = 6'b11_1111;
        #1;
        if (!all_done) begin
            $fatal(1, "all_done should assert when all enabled clusters are done");
        end

        $display("tb_output_arbiter PASS");
        $finish;
    end

endmodule
