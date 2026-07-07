`timescale 1ns / 1ps

// output_arbiter: 单cluster输出直通（64x64 PE阵列）。
// CLUSTER_COUNT=1 时：无需轮询——cluster 0 直通输出。

module output_arbiter #(
    parameter CLUSTER_COUNT = 1,
    parameter CLUSTER_OUT_W = 64 * 32,
    parameter AGGREGATE_MODE = 1
) (
    input  wire                                 clk,
    input  wire                                 rst_n,
    input  wire [CLUSTER_COUNT-1:0]             cluster_enable,
    input  wire [CLUSTER_COUNT-1:0]             cluster_valid,
    input  wire [CLUSTER_COUNT-1:0]             cluster_done,
    input  wire [(CLUSTER_COUNT*CLUSTER_OUT_W)-1:0] cluster_sum_out_flat,
    output reg                                  arb_valid,
    input  wire                                 arb_ready,
    output reg  [CLUSTER_OUT_W-1:0]             arb_sum_out_flat,
    output reg  [2:0]                           arb_cluster_id,
    output wire                                 all_done
);

    // 单cluster：valid 时始终选取 cluster 0
    always @(*) begin
        arb_valid        = cluster_enable[0] && cluster_valid[0];
        arb_cluster_id   = 3'd0;
        arb_sum_out_flat = cluster_enable[0] && cluster_valid[0]
                           ? cluster_sum_out_flat[0 +: CLUSTER_OUT_W]
                           : {CLUSTER_OUT_W{1'b0}};
    end

    assign all_done = cluster_done[0] || !cluster_enable[0];

endmodule
