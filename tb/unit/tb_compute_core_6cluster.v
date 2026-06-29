`timescale 1ns / 1ps

module tb_compute_core;

    localparam CLUSTER_COUNT = 6;
    localparam TILE_ROWS = 4;
    localparam TILE_COLS = 4;
    localparam PE_ROWS = TILE_ROWS * 4;
    localparam PE_COLS = TILE_COLS * 4;
    localparam TILE_COUNT = TILE_ROWS * TILE_COLS;
    localparam CLUSTER_ACT_W = PE_ROWS * 8;
    localparam CLUSTER_SUM_W = PE_COLS * 32;
    localparam CLUSTER_WGT_W = TILE_COUNT * 16 * 8;
    localparam CLUSTER_TILE_EN_W = TILE_COUNT;

    reg clk;
    reg rst_n;
    reg start;
    reg [CLUSTER_COUNT-1:0] cluster_enable;
    reg [(CLUSTER_COUNT*CLUSTER_ACT_W)-1:0] cluster_act_in_flat;
    reg [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] cluster_sum_in_flat;
    reg [(CLUSTER_COUNT*CLUSTER_WGT_W)-1:0] cluster_weight_flat;
    reg [CLUSTER_COUNT-1:0] cluster_weight_ld;
    reg [(CLUSTER_COUNT*CLUSTER_TILE_EN_W)-1:0] cluster_tile_clk_en_flat;
    wire [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] cluster_sum_out_flat;
    wire [CLUSTER_COUNT-1:0] cluster_busy;
    wire [CLUSTER_COUNT-1:0] cluster_valid;
    wire [CLUSTER_COUNT-1:0] cluster_done;
    wire any_cluster_busy;
    wire all_enabled_done;

    integer cluster_idx;
    integer elem_idx;
    integer wgt_idx;

    compute_core #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .TILE_ROWS(TILE_ROWS),
        .TILE_COLS(TILE_COLS)
    ) u_dut (
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

    always #5 clk = ~clk;

    function [31:0] get_sum;
        input integer cluster_id;
        input integer col;
        integer base;
        begin
            base = cluster_id * CLUSTER_SUM_W + col * 32;
            get_sum = cluster_sum_out_flat[base +: 32];
        end
    endfunction

    task load_cluster_weights;
        input integer cluster_id;
        input [7:0] value;
        begin
            for (wgt_idx = 0; wgt_idx < TILE_COUNT * 16; wgt_idx = wgt_idx + 1) begin
                cluster_weight_flat[(cluster_id*CLUSTER_WGT_W) + (wgt_idx*8) +: 8] = value;
            end
        end
    endtask

    task check_cluster_sum;
        input integer cluster_id;
        input integer expected_sum;
        begin
            if ($signed(get_sum(cluster_id, 0)) !== expected_sum) begin
                $fatal(1, "cluster %0d sum_out[0]=%0d expect %0d", cluster_id, $signed(get_sum(cluster_id, 0)), expected_sum);
            end
            if ($signed(get_sum(cluster_id, 15)) !== expected_sum) begin
                $fatal(1, "cluster %0d sum_out[15]=%0d expect %0d", cluster_id, $signed(get_sum(cluster_id, 15)), expected_sum);
            end
        end
    endtask

    task pulse_start;
        begin
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
        end
    endtask

    task pulse_weight_ld;
        input [CLUSTER_COUNT-1:0] mask;
        begin
            @(posedge clk);
            cluster_weight_ld <= mask;
            @(posedge clk);
            cluster_weight_ld <= {CLUSTER_COUNT{1'b0}};
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        cluster_enable = {CLUSTER_COUNT{1'b0}};
        cluster_act_in_flat = {(CLUSTER_COUNT*CLUSTER_ACT_W){1'b0}};
        cluster_sum_in_flat = {(CLUSTER_COUNT*CLUSTER_SUM_W){1'b0}};
        cluster_weight_flat = {(CLUSTER_COUNT*CLUSTER_WGT_W){1'b0}};
        cluster_weight_ld = {CLUSTER_COUNT{1'b0}};
        cluster_tile_clk_en_flat = {(CLUSTER_COUNT*CLUSTER_TILE_EN_W){1'b1}};

        #20;
        rst_n = 1'b1;

        for (cluster_idx = 0; cluster_idx < CLUSTER_COUNT; cluster_idx = cluster_idx + 1) begin
            for (elem_idx = 0; elem_idx < PE_ROWS; elem_idx = elem_idx + 1) begin
                cluster_act_in_flat[(cluster_idx*CLUSTER_ACT_W) + (elem_idx*8) +: 8] = 8'd1;
            end
            load_cluster_weights(cluster_idx, cluster_idx + 1);
        end

        cluster_enable = 6'b00_0001;
        pulse_weight_ld(6'b00_0001);
        pulse_start();
        wait (all_enabled_done === 1'b1);
        #1;
        if (cluster_done !== 6'b00_0001 || cluster_valid !== 6'b00_0001) begin
            $fatal(1, "single-cluster mode done/valid mismatch: done=%b valid=%b", cluster_done, cluster_valid);
        end
        check_cluster_sum(0, 16);

        cluster_enable = 6'b00_0101;
        pulse_weight_ld(6'b00_0101);
        pulse_start();
        wait (all_enabled_done === 1'b1);
        #1;
        if (cluster_done !== 6'b00_0101 || cluster_valid !== 6'b00_0101) begin
            $fatal(1, "dual-cluster mode done/valid mismatch: done=%b valid=%b", cluster_done, cluster_valid);
        end
        check_cluster_sum(0, 16);
        check_cluster_sum(2, 48);

        cluster_enable = 6'b11_1111;
        pulse_weight_ld(6'b11_1111);
        pulse_start();
        wait (all_enabled_done === 1'b1);
        #1;
        if (cluster_done !== 6'b11_1111 || cluster_valid !== 6'b11_1111) begin
            $fatal(1, "six-cluster mode done/valid mismatch: done=%b valid=%b", cluster_done, cluster_valid);
        end
        if (any_cluster_busy) begin
            $fatal(1, "all clusters should be idle after completion");
        end
        check_cluster_sum(0, 16);
        check_cluster_sum(1, 32);
        check_cluster_sum(2, 48);
        check_cluster_sum(3, 64);
        check_cluster_sum(4, 80);
        check_cluster_sum(5, 96);

        $display("tb_compute_core PASS");
        $finish;
    end

endmodule
