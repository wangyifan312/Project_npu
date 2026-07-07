`timescale 1ns / 1ps

// cluster_scheduler: 单cluster使能控制（64x64 PE阵列）。
// CLUSTER_COUNT=1 时简化为始终使能 cluster 0。

module cluster_scheduler #(
    parameter CLUSTER_COUNT = 1
) (
    input  wire [1:0] cluster_mode,
    input  wire [CLUSTER_COUNT-1:0] cluster_mask_req,
    output reg  [CLUSTER_COUNT-1:0] cluster_enable,
    output reg  [2:0] cluster_count,
    output wire       schedule_valid
);

    always @(*) begin
        // 单cluster：mask bit 0 置位时使能
        cluster_enable = {CLUSTER_COUNT{1'b0}};
        cluster_enable[0] = cluster_mask_req[0];
        cluster_count   = cluster_enable[0] ? 3'd1 : 3'd0;
    end

    assign schedule_valid = (cluster_count != 3'd0);

endmodule
