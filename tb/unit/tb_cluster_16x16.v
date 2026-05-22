`timescale 1ns / 1ps

module tb_cluster_16x16;

    localparam TILE_ROWS = 4;
    localparam TILE_COLS = 4;
    localparam PE_ROWS = TILE_ROWS * 4;
    localparam PE_COLS = TILE_COLS * 4;
    localparam TILE_COUNT = TILE_ROWS * TILE_COLS;
    localparam ACT_W = PE_ROWS * 8;
    localparam SUM_W = PE_COLS * 32;
    localparam WGT_W = TILE_COUNT * 16 * 8;

    reg clk;
    reg rst_n;
    reg start;
    reg local_enable;
    reg [ACT_W-1:0] act_in_flat;
    reg [SUM_W-1:0] sum_in_flat;
    reg [WGT_W-1:0] weight_flat;
    reg weight_ld;
    reg [TILE_COUNT-1:0] tile_clk_en_flat;
    wire [SUM_W-1:0] sum_out_flat;
    wire cluster_busy;
    wire cluster_valid;
    wire cluster_done;

    integer idx;
    integer tile_idx;

    cluster_16x16 #(
        .TILE_ROWS(TILE_ROWS),
        .TILE_COLS(TILE_COLS)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .local_enable(local_enable),
        .act_in_flat(act_in_flat),
        .sum_in_flat(sum_in_flat),
        .weight_flat(weight_flat),
        .weight_ld(weight_ld),
        .tile_clk_en_flat(tile_clk_en_flat),
        .sum_out_flat(sum_out_flat),
        .cluster_busy(cluster_busy),
        .cluster_valid(cluster_valid),
        .cluster_done(cluster_done)
    );

    always #5 clk = ~clk;

    function [31:0] get_sum;
        input integer col;
        begin
            get_sum = sum_out_flat[col*32 +: 32];
        end
    endfunction

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        local_enable = 1'b0;
        act_in_flat = {ACT_W{1'b0}};
        sum_in_flat = {SUM_W{1'b0}};
        weight_flat = {WGT_W{1'b0}};
        weight_ld = 1'b0;
        tile_clk_en_flat = {TILE_COUNT{1'b1}};

        #20;
        rst_n = 1'b1;

        for (idx = 0; idx < PE_ROWS; idx = idx + 1) begin
            act_in_flat[idx*8 +: 8] = 8'd1;
        end
        for (tile_idx = 0; tile_idx < TILE_COUNT * 16; tile_idx = tile_idx + 1) begin
            weight_flat[tile_idx*8 +: 8] = 8'd1;
        end

        @(posedge clk);
        weight_ld <= 1'b1;
        local_enable <= 1'b1;
        @(posedge clk);
        weight_ld <= 1'b0;
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        wait (cluster_done === 1'b1);
        #1;

        if (!cluster_valid) begin
            $fatal(1, "cluster_valid did not assert with cluster_done");
        end
        if (cluster_busy) begin
            $fatal(1, "cluster_busy should deassert after completion");
        end
        if ($signed(get_sum(0)) !== 32'sd16) begin
            $fatal(1, "sum_out[0]=%0d expect 16", $signed(get_sum(0)));
        end
        if ($signed(get_sum(7)) !== 32'sd16) begin
            $fatal(1, "sum_out[7]=%0d expect 16", $signed(get_sum(7)));
        end
        if ($signed(get_sum(15)) !== 32'sd16) begin
            $fatal(1, "sum_out[15]=%0d expect 16", $signed(get_sum(15)));
        end

        @(posedge clk);
        start <= 1'b1;
        local_enable <= 1'b0;
        @(posedge clk);
        start <= 1'b0;
        if (cluster_busy || cluster_done || cluster_valid) begin
            $fatal(1, "disabled cluster should not start");
        end

        $display("tb_cluster_16x16 PASS");
        $finish;
    end

endmodule
