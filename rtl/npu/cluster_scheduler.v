`timescale 1ns / 1ps

// cluster_scheduler: single-cluster enable control (64x64 PE array).
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
        // Single cluster: enable if mask bit 0 is set
        cluster_enable = {CLUSTER_COUNT{1'b0}};
        cluster_enable[0] = cluster_mask_req[0];
        cluster_count   = cluster_enable[0] ? 3'd1 : 3'd0;
    end

    assign schedule_valid = (cluster_count != 3'd0);

endmodule
