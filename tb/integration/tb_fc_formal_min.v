// tb_fc_formal_min: runtime smoke for the formal arrayized FC path.
//
// This test intentionally avoids the old scalar FC frontend/state machine. It
// drives the same formal path used by FC after P0-3:
// cluster_scheduler -> compute_core_6cluster -> output_arbiter.
`timescale 1ns / 1ps

module tb_fc_formal_min;
    localparam CLUSTER_COUNT = 6;
    localparam TILE_ROWS = 4;  // 4 tiles x 4 PE rows = 16 PE rows per cluster
    localparam TILE_COLS = 4;  // 4 tiles x 4 PE cols = 16 PE cols per cluster
    localparam CLUSTER_ACT_W = TILE_ROWS * 4 * 8;
    localparam CLUSTER_SUM_W = TILE_COLS * 4 * 32;
    localparam CLUSTER_WGT_W = TILE_ROWS * TILE_COLS * 16 * 8;
    localparam CLUSTER_TILE_EN_W = TILE_ROWS * TILE_COLS;

    reg clk;
    reg rst_n;
    reg start;
    reg [5:0] cluster_weight_ld;
    reg [1:0] cluster_mode;
    reg [5:0] cluster_mask_req;

    reg  [(CLUSTER_COUNT*CLUSTER_ACT_W)-1:0] cluster_act_in_flat;
    reg  [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] cluster_sum_in_flat;
    reg  [(CLUSTER_COUNT*CLUSTER_WGT_W)-1:0] cluster_weight_flat;
    reg  [(CLUSTER_COUNT*CLUSTER_TILE_EN_W)-1:0] cluster_tile_clk_en_flat;
    reg  [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] routed_sum_out_flat;

    wire [5:0] cluster_enable;
    wire [2:0] scheduled_cluster_count;
    wire schedule_valid;
    wire [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] cluster_sum_out_flat;
    wire [5:0] cluster_busy;
    wire [5:0] cluster_valid;
    wire [5:0] cluster_done;
    wire any_cluster_busy;
    wire all_enabled_done;
    wire arb_valid;
    wire [CLUSTER_SUM_W-1:0] arb_sum_out_flat;
    wire [2:0] arb_cluster_id;
    wire arb_all_done;

    reg seen_output_arbiter;
    reg signed [31:0] captured_out0;
    reg signed [31:0] captured_out1;

    cluster_scheduler u_scheduler (
        .cluster_mode(cluster_mode),
        .cluster_mask_req(cluster_mask_req),
        .cluster_enable(cluster_enable),
        .cluster_count(scheduled_cluster_count),
        .schedule_valid(schedule_valid)
    );

    compute_core_6cluster #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .TILE_ROWS(TILE_ROWS),
        .TILE_COLS(TILE_COLS)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .cluster_enable(cluster_enable),
        .cluster_act_in_flat(cluster_act_in_flat),
        .cluster_sum_in_flat(cluster_sum_in_flat),
        .cluster_weight_flat(cluster_weight_flat),
        .cluster_weight_ld(cluster_weight_ld),
        .cluster_tile_clk_en_flat(cluster_tile_clk_en_flat),
        .cluster_sum_out_flat(cluster_sum_out_flat),
        .cluster_busy(cluster_busy),
        .cluster_valid(cluster_valid),
        .cluster_done(cluster_done),
        .any_cluster_busy(any_cluster_busy),
        .all_enabled_done(all_enabled_done)
    );

    output_arbiter #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CLUSTER_OUT_W(CLUSTER_SUM_W),
        .AGGREGATE_MODE(1)
    ) u_output_arbiter (
        .clk(clk),
        .rst_n(rst_n),
        .cluster_enable(cluster_enable),
        .cluster_valid(cluster_valid),
        .cluster_done(cluster_done),
        .cluster_sum_out_flat(routed_sum_out_flat),
        .arb_valid(arb_valid),
        .arb_ready(1'b1),
        .arb_sum_out_flat(arb_sum_out_flat),
        .arb_cluster_id(arb_cluster_id),
        .all_done(arb_all_done)
    );

    always #2.5 clk = ~clk;

    integer route_idx;
    integer wait_cycles;
    always @(*) begin
        routed_sum_out_flat = {(CLUSTER_COUNT*CLUSTER_SUM_W){1'b0}};

        for (route_idx = 0; route_idx < CLUSTER_COUNT; route_idx = route_idx + 1) begin
            if (route_idx == 0) begin
                routed_sum_out_flat[0*CLUSTER_SUM_W + 0*32 +: 32] =
                    cluster_sum_out_flat[0*CLUSTER_SUM_W + 0*32 +: 32];
            end else if (route_idx == 1) begin
                routed_sum_out_flat[1*CLUSTER_SUM_W + 1*32 +: 32] =
                    cluster_sum_out_flat[1*CLUSTER_SUM_W + 0*32 +: 32];
            end
        end
    end

    task set_cluster_input4;
        input integer cluster_idx;
        input signed [7:0] in0;
        input signed [7:0] in1;
        input signed [7:0] in2;
        input signed [7:0] in3;
        integer base;
        begin
            base = cluster_idx * CLUSTER_ACT_W;
            cluster_act_in_flat[base + 0*8 +: 8] = in0;
            cluster_act_in_flat[base + 1*8 +: 8] = in1;
            cluster_act_in_flat[base + 2*8 +: 8] = in2;
            cluster_act_in_flat[base + 3*8 +: 8] = in3;
        end
    endtask

    task set_cluster_col0_weight4;
        input integer cluster_idx;
        input signed [7:0] w0;
        input signed [7:0] w1;
        input signed [7:0] w2;
        input signed [7:0] w3;
        integer base;
        begin
            base = cluster_idx * CLUSTER_WGT_W;
            cluster_weight_flat[base + (0*4 + 0)*8 +: 8] = w0;
            cluster_weight_flat[base + (1*4 + 0)*8 +: 8] = w1;
            cluster_weight_flat[base + (2*4 + 0)*8 +: 8] = w2;
            cluster_weight_flat[base + (3*4 + 0)*8 +: 8] = w3;
        end
    endtask

    task fail;
        input [1023:0] msg;
        begin
            $fatal(1, "FC_FORMAL_MIN FAIL: %0s", msg);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        cluster_weight_ld = 6'b0;
        cluster_mode = 2'd1;       // dual-cluster formal mode
        cluster_mask_req = 6'b000011;
        cluster_act_in_flat = {(CLUSTER_COUNT*CLUSTER_ACT_W){1'b0}};
        cluster_sum_in_flat = {(CLUSTER_COUNT*CLUSTER_SUM_W){1'b0}};
        cluster_weight_flat = {(CLUSTER_COUNT*CLUSTER_WGT_W){1'b0}};
        cluster_tile_clk_en_flat = {(CLUSTER_COUNT*CLUSTER_TILE_EN_W){1'b1}};
        seen_output_arbiter = 1'b0;
        captured_out0 = 32'sd0;
        captured_out1 = 32'sd0;

        set_cluster_input4(0, 8'sd5, -8'sd3, 8'sd2, 8'sd7);
        set_cluster_input4(1, 8'sd5, -8'sd3, 8'sd2, 8'sd7);
        set_cluster_col0_weight4(0, 8'sd1, 8'sd1, 8'sd1, 8'sd1);
        set_cluster_col0_weight4(1, 8'sd2, 8'sd2, 8'sd2, 8'sd2);

        #20 rst_n = 1'b1;
        #10;

        if (!schedule_valid || cluster_enable !== 6'b000011 || scheduled_cluster_count !== 3'd2)
            fail("cluster_scheduler did not select dual-cluster mask 000011");

        @(posedge clk);
        cluster_weight_ld <= cluster_enable;
        @(posedge clk);
        cluster_weight_ld <= 6'b0;

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        wait_cycles = 0;
        while ((arb_valid !== 1'b1) && (wait_cycles < 200)) begin
            @(posedge clk);
            #1;
            wait_cycles = wait_cycles + 1;
        end
        if (arb_valid !== 1'b1)
            fail("output_arbiter arb_valid timeout");

        seen_output_arbiter = 1'b1;
        captured_out0 = $signed(arb_sum_out_flat[0*32 +: 32]);
        captured_out1 = $signed(arb_sum_out_flat[1*32 +: 32]);

        if (!seen_output_arbiter)
            fail("output_arbiter was not observed");
        if (captured_out0 !== 32'sd11)
            fail("output0 mismatch");
        if (captured_out1 !== 32'sd22)
            fail("output1 mismatch");
        if (!arb_all_done || !all_enabled_done)
            fail("enabled clusters did not report done");

        $display("FC_FORMAL_MIN PASS out0=%0d out1=%0d cluster_enable=%b arb_valid=%b",
                 captured_out0, captured_out1, cluster_enable, arb_valid);
        $finish;
    end
endmodule
