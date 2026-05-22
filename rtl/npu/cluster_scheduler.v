`timescale 1ns / 1ps

module cluster_scheduler (
    input  wire [1:0] cluster_mode,
    input  wire [5:0] cluster_mask_req,
    output reg  [5:0] cluster_enable,
    output reg  [2:0] cluster_count,
    output wire       schedule_valid
);

    localparam MODE_SINGLE = 2'd0;
    localparam MODE_DUAL   = 2'd1;
    localparam MODE_FULL   = 2'd2;

    integer idx;
    reg [2:0] target_count;

    always @(*) begin
        case (cluster_mode)
            MODE_SINGLE: target_count = 3'd1;
            MODE_DUAL:   target_count = 3'd2;
            default:     target_count = 3'd6;
        endcase

        cluster_enable = 6'b0;
        cluster_count  = 3'd0;
        for (idx = 0; idx < 6; idx = idx + 1) begin
            if (cluster_mask_req[idx] && (cluster_count < target_count)) begin
                cluster_enable[idx] = 1'b1;
                cluster_count = cluster_count + 3'd1;
            end
        end
    end

    assign schedule_valid = (cluster_count != 3'd0);

endmodule
