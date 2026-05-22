`timescale 1ns / 1ps

module tb_cluster_perf_modes;

    localparam CLUSTER_COUNT = 6;
    localparam TILE_ROWS = 4;
    localparam TILE_COLS = 4;
    localparam CLUSTER_ACT_W = TILE_ROWS * 4 * 8;
    localparam CLUSTER_SUM_W = TILE_COLS * 4 * 32;
    localparam CLUSTER_WGT_W = TILE_ROWS * TILE_COLS * 16 * 8;
    localparam CLUSTER_TILE_EN_W = TILE_ROWS * TILE_COLS;
    localparam PE_PER_CLUSTER = 16 * 16;
    localparam PIPELINE_CYCLES = (TILE_ROWS * 4) + (TILE_COLS * 4) + 2;

    reg clk;
    reg rst_n;
    reg start;
    reg [1:0] cluster_mode;
    reg [5:0] cluster_mask_req;
    wire [5:0] cluster_enable;
    wire [2:0] cluster_count;
    wire schedule_valid;
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
    integer cycles;
    integer enabled_count;
    integer mac_count;
    integer expected_sum;
    real array_util;
    real peak_tops;

    cluster_scheduler u_sched (
        .cluster_mode(cluster_mode),
        .cluster_mask_req(cluster_mask_req),
        .cluster_enable(cluster_enable),
        .cluster_count(cluster_count),
        .schedule_valid(schedule_valid)
    );

    compute_core_6cluster #(
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

    always #2.5 clk = ~clk;

    function integer get_sum;
        input integer cluster_id;
        input integer col;
        integer base;
        begin
            base = cluster_id * CLUSTER_SUM_W + col * 32;
            get_sum = $signed(cluster_sum_out_flat[base +: 32]);
        end
    endfunction

    task load_cluster_weights;
        input integer cluster_id;
        input [7:0] value;
        integer wgt_idx;
        begin
            for (wgt_idx = 0; wgt_idx < TILE_ROWS*TILE_COLS*16; wgt_idx = wgt_idx + 1)
                cluster_weight_flat[(cluster_id*CLUSTER_WGT_W) + (wgt_idx*8) +: 8] = value;
        end
    endtask

    task run_case;
        input [127:0] case_name;
        input [1:0] mode_i;
        input [5:0] mask_i;
        begin
            cluster_mode = mode_i;
            cluster_mask_req = mask_i;
            start = 1'b0;
            cluster_weight_ld = {CLUSTER_COUNT{1'b0}};
            @(posedge clk);

            if (!schedule_valid)
                $fatal(1, "%0s schedule invalid", case_name);

            cluster_weight_ld = cluster_enable;
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            cluster_weight_ld = {CLUSTER_COUNT{1'b0}};

            cycles = 1;
            while (!all_enabled_done && cycles < 128) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (!all_enabled_done)
                $fatal(1, "%0s timeout", case_name);

            if (cycles !== (PIPELINE_CYCLES + 1))
                $fatal(1, "%0s cycles=%0d expect %0d", case_name, cycles, PIPELINE_CYCLES + 1);

            enabled_count = cluster_count;
            mac_count = enabled_count * PE_PER_CLUSTER;
            array_util = mac_count;
            array_util = array_util / (enabled_count * PE_PER_CLUSTER * cycles);
            peak_tops = enabled_count * PE_PER_CLUSTER * 2.0 * 200000000.0 / 1.0e12;

            $display("PERF case=%0s mode=%0d req_mask=%b enable=%b cycles=%0d mac=%0d array_util=%0.6f peak_tops=%0.4f",
                     case_name, mode_i, mask_i, cluster_enable, cycles, mac_count, array_util, peak_tops);

            for (cluster_idx = 0; cluster_idx < CLUSTER_COUNT; cluster_idx = cluster_idx + 1) begin
                if (cluster_enable[cluster_idx]) begin
                    expected_sum = (cluster_idx + 1) * 16;
                    if (get_sum(cluster_idx, 0) !== expected_sum)
                        $fatal(1, "%0s cluster %0d sum_out[0]=%0d expect %0d",
                               case_name, cluster_idx, get_sum(cluster_idx, 0), expected_sum);
                end
            end

            @(posedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        cluster_mode = 2'd0;
        cluster_mask_req = 6'b0;
        cluster_act_in_flat = {(CLUSTER_COUNT*CLUSTER_ACT_W){1'b0}};
        cluster_sum_in_flat = {(CLUSTER_COUNT*CLUSTER_SUM_W){1'b0}};
        cluster_weight_flat = {(CLUSTER_COUNT*CLUSTER_WGT_W){1'b0}};
        cluster_weight_ld = {CLUSTER_COUNT{1'b0}};
        cluster_tile_clk_en_flat = {(CLUSTER_COUNT*CLUSTER_TILE_EN_W){1'b1}};

        repeat (2) @(posedge clk);
        rst_n = 1'b1;

        for (cluster_idx = 0; cluster_idx < CLUSTER_COUNT; cluster_idx = cluster_idx + 1) begin
            for (elem_idx = 0; elem_idx < TILE_ROWS*4; elem_idx = elem_idx + 1)
                cluster_act_in_flat[(cluster_idx*CLUSTER_ACT_W) + (elem_idx*8) +: 8] = 8'd1;
            load_cluster_weights(cluster_idx, cluster_idx + 1);
        end

        $display("case mode req_mask enable cycles mac array_util peak_tops");
        run_case("single", 2'd0, 6'b11_1111);
        run_case("dual", 2'd1, 6'b11_1111);
        run_case("full", 2'd2, 6'b11_1111);
        run_case("dynamic_mask", 2'd2, 6'b10_1011);

        $display("tb_cluster_perf_modes PASS");
        $finish;
    end

endmodule
