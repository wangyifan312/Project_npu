`timescale 1ns / 1ps

module output_arbiter #(
    parameter CLUSTER_COUNT = 6,
    parameter CLUSTER_OUT_W = 16 * 32,
    parameter AGGREGATE_MODE = 0
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

    integer probe;
    integer agg_idx;
    reg [2:0] rr_ptr;
    reg [2:0] pick_idx;
    reg       pick_found;

    always @(*) begin
        pick_found = 1'b0;
        pick_idx   = rr_ptr;
        for (probe = 0; probe < CLUSTER_COUNT; probe = probe + 1) begin
            if (!pick_found) begin
                if (cluster_enable[(rr_ptr + probe) % CLUSTER_COUNT] &&
                    cluster_valid[(rr_ptr + probe) % CLUSTER_COUNT]) begin
                    pick_found = 1'b1;
                    pick_idx   = (rr_ptr + probe) % CLUSTER_COUNT;
                end
            end
        end
    end

    always @(*) begin
        arb_valid        = pick_found;
        arb_cluster_id   = pick_idx;
        arb_sum_out_flat = {CLUSTER_OUT_W{1'b0}};
        if (AGGREGATE_MODE != 0) begin
            arb_valid = |(cluster_enable & cluster_valid);
            for (agg_idx = 0; agg_idx < CLUSTER_COUNT; agg_idx = agg_idx + 1) begin
                if (cluster_enable[agg_idx] && cluster_valid[agg_idx]) begin
                    arb_sum_out_flat = arb_sum_out_flat |
                        cluster_sum_out_flat[agg_idx*CLUSTER_OUT_W +: CLUSTER_OUT_W];
                end
            end
        end else if (pick_found) begin
            arb_sum_out_flat = cluster_sum_out_flat[pick_idx*CLUSTER_OUT_W +: CLUSTER_OUT_W];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_ptr <= 3'd0;
        end else if (arb_valid && arb_ready) begin
            if (pick_idx == CLUSTER_COUNT-1) begin
                rr_ptr <= 3'd0;
            end else begin
                rr_ptr <= pick_idx + 3'd1;
            end
        end
    end

    assign all_done = &((~cluster_enable) | cluster_done);

endmodule
