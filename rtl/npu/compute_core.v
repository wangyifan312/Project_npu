`timescale 1ns / 1ps

module compute_core #(
    parameter CLUSTER_COUNT = 1,
    parameter TILE_ROWS = 4,
    parameter TILE_COLS = 4,
    parameter CLUSTER_ACT_W = TILE_ROWS * 4 * 8,
    parameter CLUSTER_SUM_W = TILE_COLS * 4 * 32,
    parameter CLUSTER_WGT_W = TILE_ROWS * TILE_COLS * 16 * 8,
    parameter CLUSTER_TILE_EN_W = TILE_ROWS * TILE_COLS
) (
    input  wire                                     clk,
    input  wire                                     rst_n,
    input  wire                                     start,
    input  wire [CLUSTER_COUNT-1:0]                 cluster_enable,
    input  wire [(CLUSTER_COUNT*CLUSTER_ACT_W)-1:0] cluster_act_in_flat,
    input  wire [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] cluster_sum_in_flat,
    input  wire [(CLUSTER_COUNT*CLUSTER_WGT_W)-1:0] cluster_weight_flat,
    input  wire [CLUSTER_COUNT-1:0]                 cluster_weight_ld,
    input  wire [(CLUSTER_COUNT*CLUSTER_TILE_EN_W)-1:0] cluster_tile_clk_en_flat,
    output wire [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] cluster_sum_out_flat,
    output wire [CLUSTER_COUNT-1:0]                 cluster_busy,
    output wire [CLUSTER_COUNT-1:0]                 cluster_valid,
    output wire [CLUSTER_COUNT-1:0]                 cluster_done,
    output wire                                     any_cluster_busy,
    output wire                                     all_enabled_done
);

    genvar cluster_idx;
    generate
        for (cluster_idx = 0; cluster_idx < CLUSTER_COUNT; cluster_idx = cluster_idx + 1) begin : gen_cluster
            pe_cluster #(
                .TILE_ROWS(TILE_ROWS),
                .TILE_COLS(TILE_COLS)
            ) u_cluster (
                .clk(clk),
                .rst_n(rst_n),
                .start(start),
                .local_enable(cluster_enable[cluster_idx]),
                .act_in_flat(cluster_act_in_flat[cluster_idx*CLUSTER_ACT_W +: CLUSTER_ACT_W]),
                .sum_in_flat(cluster_sum_in_flat[cluster_idx*CLUSTER_SUM_W +: CLUSTER_SUM_W]),
                .weight_flat(cluster_weight_flat[cluster_idx*CLUSTER_WGT_W +: CLUSTER_WGT_W]),
                .weight_ld(cluster_weight_ld[cluster_idx]),
                .tile_clk_en_flat(cluster_tile_clk_en_flat[cluster_idx*CLUSTER_TILE_EN_W +: CLUSTER_TILE_EN_W]),
                .sum_out_flat(cluster_sum_out_flat[cluster_idx*CLUSTER_SUM_W +: CLUSTER_SUM_W]),
                .cluster_busy(cluster_busy[cluster_idx]),
                .cluster_valid(cluster_valid[cluster_idx]),
                .cluster_done(cluster_done[cluster_idx])
            );
        end
    endgenerate

    assign any_cluster_busy = |cluster_busy;
    assign all_enabled_done = &((~cluster_enable) | cluster_done);

endmodule
