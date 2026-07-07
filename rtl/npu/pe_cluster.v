`timescale 1ns / 1ps

module pe_cluster #(
    parameter TILE_ROWS = 4,
    parameter TILE_COLS = 4,
    parameter PIPELINE_CYCLES = (TILE_ROWS * 4) + (TILE_COLS * 4) + 2
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,
    input  wire                          local_enable,
    input  wire [(TILE_ROWS*4*8)-1:0]    act_in_flat,
    input  wire [(TILE_COLS*4*32)-1:0]   sum_in_flat,
    input  wire [(TILE_ROWS*TILE_COLS*16*8)-1:0] weight_flat,
    input  wire                          weight_ld,
    input  wire [(TILE_ROWS*TILE_COLS)-1:0] tile_clk_en_flat,
    output wire [(TILE_COLS*4*32)-1:0]   sum_out_flat,
    output reg                           cluster_busy,
    output reg                           cluster_valid,
    output reg                           cluster_done,

    // Phase 2: 连续流模式（保持阵列无限期活跃）
    input  wire                          continuous_mode,
    input  wire                          stream_active
);

    localparam PE_ROWS = TILE_ROWS * 4;
    localparam PE_COLS = TILE_COLS * 4;
    localparam LAT_W = 8;

    reg [LAT_W-1:0] latency_cnt;
    wire [(TILE_ROWS*TILE_COLS)-1:0] effective_tile_clk_en;

    assign effective_tile_clk_en = local_enable ? tile_clk_en_flat : {(TILE_ROWS*TILE_COLS){1'b0}};

    array_top #(
        .TILE_ROWS(TILE_ROWS),
        .TILE_COLS(TILE_COLS)
    ) u_array (
        .clk(clk),
        .rst_n(rst_n),
        .act_in_flat(act_in_flat),
        .sum_in_flat(sum_in_flat),
        .weight_flat(weight_flat),
        .weight_ld(weight_ld && local_enable),
        .sum_out_flat(sum_out_flat),
        .tile_clk_en_flat(effective_tile_clk_en)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latency_cnt   <= {LAT_W{1'b0}};
            cluster_busy  <= 1'b0;
            cluster_valid <= 1'b0;
            cluster_done  <= 1'b0;
        end else if (continuous_mode) begin
            cluster_busy  <= stream_active;
            cluster_valid <= 1'b0;
            cluster_done  <= 1'b0;
            // continuous_mode 活跃
        end else begin
            cluster_valid <= 1'b0;
            cluster_done  <= 1'b0;

            if (start && local_enable && !cluster_busy) begin
                latency_cnt  <= PIPELINE_CYCLES[LAT_W-1:0];
                cluster_busy <= 1'b1;
            end else if (cluster_busy) begin
                if (latency_cnt > {{(LAT_W-1){1'b0}}, 1'b1}) begin
                    latency_cnt <= latency_cnt - {{(LAT_W-1){1'b0}}, 1'b1};
                end else begin
                    latency_cnt   <= {LAT_W{1'b0}};
                    cluster_busy  <= 1'b0;
                    cluster_valid <= 1'b1;
                    cluster_done  <= 1'b1;
                end
            end
        end
    end

endmodule
