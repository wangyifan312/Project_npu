`timescale 1ns / 1ps

module tb_cluster_scheduler;

    reg [1:0] cluster_mode;
    reg [5:0] cluster_mask_req;
    wire [5:0] cluster_enable;
    wire [2:0] cluster_count;
    wire schedule_valid;

    cluster_scheduler u_dut (
        .cluster_mode(cluster_mode),
        .cluster_mask_req(cluster_mask_req),
        .cluster_enable(cluster_enable),
        .cluster_count(cluster_count),
        .schedule_valid(schedule_valid)
    );

    initial begin
        cluster_mode = 2'd0;
        cluster_mask_req = 6'b11_1111;
        #1;
        if (!schedule_valid || cluster_enable !== 6'b00_0001 || cluster_count !== 3'd1) begin
            $fatal(1, "single mode allocation mismatch: mask=%b count=%0d", cluster_enable, cluster_count);
        end

        cluster_mode = 2'd1;
        cluster_mask_req = 6'b10_1011;
        #1;
        if (!schedule_valid || cluster_enable !== 6'b00_0011 || cluster_count !== 3'd2) begin
            $fatal(1, "dual mode allocation mismatch: mask=%b count=%0d", cluster_enable, cluster_count);
        end

        cluster_mode = 2'd2;
        cluster_mask_req = 6'b10_1011;
        #1;
        if (!schedule_valid || cluster_enable !== 6'b10_1011 || cluster_count !== 3'd4) begin
            $fatal(1, "full mode allocation mismatch: mask=%b count=%0d", cluster_enable, cluster_count);
        end

        cluster_mode = 2'd1;
        cluster_mask_req = 6'b00_0000;
        #1;
        if (schedule_valid || cluster_enable !== 6'b00_0000 || cluster_count !== 3'd0) begin
            $fatal(1, "empty mask should not allocate any cluster");
        end

        $display("tb_cluster_scheduler PASS");
        $finish;
    end

endmodule
