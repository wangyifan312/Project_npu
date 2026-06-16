`timescale 1ns / 1ps

module tb_cluster_route_aggregate_semantics;
    localparam CLUSTER_COUNT = 6;
    localparam TILE_ROWS = 16;
    localparam TILE_COLS = 16;
    localparam PE_COLS = TILE_COLS * 4;
    localparam CLUSTER_SUM_W = PE_COLS * 32;

    reg clk;
    reg rst_n;
    reg [1:0] cluster_mode;
    reg [5:0] cluster_mask_req;
    wire [5:0] cluster_enable;
    wire [2:0] cluster_count;
    wire schedule_valid;

    reg [CLUSTER_COUNT-1:0] cluster_valid;
    reg [CLUSTER_COUNT-1:0] cluster_done;
    reg [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] routed_sum_flat;
    wire arb_valid;
    wire [CLUSTER_SUM_W-1:0] arb_sum_out_flat;
    wire [2:0] arb_cluster_id;
    wire all_done;

    integer c;
    integer col;
    integer route_col;
    integer rank;
    integer count_i;
    integer base_i;
    integer end_i;
    integer global_col;
    integer owner_count [0:PE_COLS-1];
    reg [31:0] expected [0:PE_COLS-1];
    reg any_valid;

    cluster_scheduler u_sched (
        .cluster_mode(cluster_mode),
        .cluster_mask_req(cluster_mask_req),
        .cluster_enable(cluster_enable),
        .cluster_count(cluster_count),
        .schedule_valid(schedule_valid)
    );

    output_arbiter #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CLUSTER_OUT_W(CLUSTER_SUM_W),
        .AGGREGATE_MODE(1)
    ) u_arb (
        .clk(clk),
        .rst_n(rst_n),
        .cluster_enable(cluster_enable),
        .cluster_valid(cluster_valid),
        .cluster_done(cluster_done),
        .cluster_sum_out_flat(routed_sum_flat),
        .arb_valid(arb_valid),
        .arb_ready(1'b1),
        .arb_sum_out_flat(arb_sum_out_flat),
        .arb_cluster_id(arb_cluster_id),
        .all_done(all_done)
    );

    always #5 clk = ~clk;

    function integer rank_of;
        input integer cluster_id;
        integer i;
        begin
            rank_of = 0;
            for (i = 0; i < cluster_id; i = i + 1) begin
                if (cluster_enable[i])
                    rank_of = rank_of + 1;
            end
        end
    endfunction

    task reset_dut;
        begin
            clk = 1'b0;
            rst_n = 1'b0;
            cluster_mode = 2'd0;
            cluster_mask_req = 6'b11_1111;
            cluster_valid = {CLUSTER_COUNT{1'b0}};
            cluster_done = {CLUSTER_COUNT{1'b0}};
            routed_sum_flat = {(CLUSTER_COUNT*CLUSTER_SUM_W){1'b0}};
            repeat (2) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    task check_global_ownership;
        input [127:0] case_name;
        input integer active_cols;
        begin
            count_i = (cluster_count == 3'd0) ? 1 : cluster_count;
            for (col = 0; col < PE_COLS; col = col + 1)
                owner_count[col] = 0;

            for (c = 0; c < CLUSTER_COUNT; c = c + 1) begin
                if (cluster_enable[c]) begin
                    rank = rank_of(c);
                    base_i = (active_cols * rank) / count_i;
                    end_i  = (active_cols * (rank + 1)) / count_i;
                    for (col = base_i; col < end_i; col = col + 1) begin
                        if (col < active_cols && col < PE_COLS)
                            owner_count[col] = owner_count[col] + 1;
                    end
                end
            end

            for (col = 0; col < active_cols; col = col + 1) begin
                if (owner_count[col] !== 1)
                    $fatal(1, "%0s global_col=%0d owner_count=%0d expect 1",
                           case_name, col, owner_count[col]);
            end
            for (col = active_cols; col < PE_COLS; col = col + 1) begin
                if (owner_count[col] !== 0)
                    $fatal(1, "%0s inactive global_col=%0d owner_count=%0d expect 0",
                           case_name, col, owner_count[col]);
            end
        end
    endtask

    task check_route_cycle;
        input [127:0] case_name;
        input integer active_cols;
        input integer local_route_col;
        reg [31:0] value;
        begin
            routed_sum_flat = {(CLUSTER_COUNT*CLUSTER_SUM_W){1'b0}};
            cluster_valid = {CLUSTER_COUNT{1'b0}};
            any_valid = 1'b0;
            for (col = 0; col < PE_COLS; col = col + 1)
                expected[col] = 32'h0;

            count_i = (cluster_count == 3'd0) ? 1 : cluster_count;
            for (c = 0; c < CLUSTER_COUNT; c = c + 1) begin
                if (cluster_enable[c]) begin
                    rank = rank_of(c);
                    base_i = (active_cols * rank) / count_i;
                    end_i  = (active_cols * (rank + 1)) / count_i;
                    global_col = base_i + local_route_col;
                    if ((global_col < end_i) &&
                        (global_col < active_cols) &&
                        (local_route_col < PE_COLS)) begin
                        value = 32'h4000_0000 | (c[7:0] << 16) | global_col[15:0];
                        cluster_valid[c] = 1'b1;
                        routed_sum_flat[c*CLUSTER_SUM_W + global_col*32 +: 32] = value;
                        expected[global_col] = value;
                        any_valid = 1'b1;
                    end
                end
            end

            #1;
            if (arb_valid !== any_valid)
                $fatal(1, "%0s route_col=%0d arb_valid=%0b expect %0b",
                       case_name, local_route_col, arb_valid, any_valid);
            for (col = 0; col < PE_COLS; col = col + 1) begin
                if (arb_sum_out_flat[col*32 +: 32] !== expected[col])
                    $fatal(1, "%0s route_col=%0d global_col=%0d out=%08x expect=%08x",
                           case_name, local_route_col, col,
                           arb_sum_out_flat[col*32 +: 32], expected[col]);
            end
        end
    endtask

    task run_case;
        input [127:0] case_name;
        input [1:0] mode_i;
        input [5:0] mask_i;
        input integer active_cols;
        input integer expected_clusters;
        begin
            cluster_mode = mode_i;
            cluster_mask_req = mask_i;
            #1;
            if (!schedule_valid)
                $fatal(1, "%0s schedule_valid=0", case_name);
            if (cluster_count !== expected_clusters[2:0])
                $fatal(1, "%0s cluster_count=%0d expect %0d",
                       case_name, cluster_count, expected_clusters);

            check_global_ownership(case_name, active_cols);
            for (route_col = 0; route_col < PE_COLS; route_col = route_col + 1)
                check_route_cycle(case_name, active_cols, route_col);

            cluster_done = cluster_enable;
            #1;
            if (!all_done)
                $fatal(1, "%0s all_done=0 with enabled clusters done", case_name);

            $display("CLUSTER_ROUTE_AGG case=%0s mode=%0d mask=%b enable=%b active_cols=%0d clusters=%0d status=PASS",
                     case_name, mode_i, mask_i, cluster_enable, active_cols, cluster_count);
        end
    endtask

    initial begin
        reset_dut();

        run_case("single_16cols", 2'd0, 6'b11_1111, 16, 1);
        run_case("dual_50cols",   2'd1, 6'b11_1111, 50, 2);
        run_case("full_64cols",   2'd2, 6'b11_1111, 64, 6);
        run_case("mask_50cols",   2'd2, 6'b10_1011, 50, 4);

        $display("tb_cluster_route_aggregate_semantics PASS");
        $finish;
    end
endmodule
