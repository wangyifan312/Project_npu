`timescale 1ns / 1ps

module tb_hb2_cluster_util_counter;
    reg clk;
    reg rst_n;
    reg task_active;
    reg freeze;
    reg read_beat;
    reg write_beat;
    reg read_active;
    reg write_active;
    reg array_active;
    reg array_stall;
    reg [1:0] cluster_mode;
    reg [5:0] cluster_mask_req;

    wire [5:0] cluster_enable;
    wire [2:0] cluster_count;
    wire schedule_valid;
    wire [31:0] total_cycle_lo;
    wire [31:0] total_cycle_hi;
    wire [31:0] read_beat_count;
    wire [31:0] write_beat_count;
    wire [31:0] read_active_cycles;
    wire [31:0] write_active_cycles;
    wire [31:0] array_active_cycles;
    wire [31:0] array_stall_cycles;
    wire [31:0] cluster_active_cycles;
    wire [31:0] cluster_stall_cycles;

    cluster_scheduler u_sched (
        .cluster_mode(cluster_mode),
        .cluster_mask_req(cluster_mask_req),
        .cluster_enable(cluster_enable),
        .cluster_count(cluster_count),
        .schedule_valid(schedule_valid)
    );

    perf_counter u_perf (
        .clk(clk),
        .rst_n(rst_n),
        .task_active(task_active),
        .freeze(freeze),
        .read_beat(read_beat),
        .write_beat(write_beat),
        .read_active(read_active),
        .write_active(write_active),
        .array_active(array_active),
        .array_stall(array_stall),
        .cluster_active_inc(array_active ? cluster_count : 3'd0),
        .cluster_stall_inc(array_stall ? cluster_count : 3'd0),
        .total_cycle_lo(total_cycle_lo),
        .total_cycle_hi(total_cycle_hi),
        .read_beat_count(read_beat_count),
        .write_beat_count(write_beat_count),
        .read_active_cycles(read_active_cycles),
        .write_active_cycles(write_active_cycles),
        .array_active_cycles(array_active_cycles),
        .array_stall_cycles(array_stall_cycles),
        .cluster_active_cycles(cluster_active_cycles),
        .cluster_stall_cycles(cluster_stall_cycles)
    );

    always #2.5 clk = ~clk;

    task reset_counter;
        begin
            rst_n = 1'b0;
            task_active = 1'b0;
            freeze = 1'b0;
            read_beat = 1'b0;
            write_beat = 1'b0;
            read_active = 1'b0;
            write_active = 1'b0;
            array_active = 1'b0;
            array_stall = 1'b0;
            repeat (2) @(posedge clk);
            rst_n = 1'b1;
            repeat (1) @(posedge clk);
        end
    endtask

    task run_mode;
        input [127:0] name;
        input [1:0] mode_i;
        input [5:0] mask_i;
        input [2:0] expected_count;
        integer i;
        begin
            reset_counter();
            cluster_mode = mode_i;
            cluster_mask_req = mask_i;
            #1;
            if (!schedule_valid)
                $fatal(1, "%0s schedule invalid", name);
            if (cluster_count !== expected_count)
                $fatal(1, "%0s cluster_count=%0d expect %0d", name, cluster_count, expected_count);

            @(posedge clk);
            task_active <= 1'b1;
            for (i = 0; i < 4; i = i + 1) begin
                array_active <= 1'b1;
                read_active <= 1'b1;
                read_beat <= (i == 0);
                write_active <= 1'b1;
                write_beat <= (i == 3);
                @(posedge clk);
            end
            array_active <= 1'b0;
            read_active <= 1'b0;
            read_beat <= 1'b0;
            write_active <= 1'b0;
            write_beat <= 1'b0;
            task_active <= 1'b0;
            @(posedge clk);

            if (array_active_cycles !== 32'd4)
                $fatal(1, "%0s array_active=%0d expect 4", name, array_active_cycles);
            if (cluster_active_cycles !== (32'd4 * expected_count))
                $fatal(1, "%0s cluster_active=%0d expect %0d",
                       name, cluster_active_cycles, 4 * expected_count);
            if (read_beat_count !== 32'd1)
                $fatal(1, "%0s read_beats=%0d expect 1", name, read_beat_count);
            if (write_beat_count !== 32'd1)
                $fatal(1, "%0s write_beats=%0d expect 1", name, write_beat_count);

            $display("HB2_CLUSTER_UTIL_RESULT case=%0s mode=%0d enable=%b cluster_count=%0d array_active=%0d cluster_active=%0d read_beats=%0d write_beats=%0d status=PASS",
                     name, mode_i, cluster_enable, cluster_count, array_active_cycles,
                     cluster_active_cycles, read_beat_count, write_beat_count);
        end
    endtask

    initial begin
        clk = 1'b0;
        cluster_mode = 2'd0;
        cluster_mask_req = 6'b11_1111;
        run_mode("single", 2'd0, 6'b11_1111, 3'd1);
        run_mode("dual", 2'd1, 6'b11_1111, 3'd2);
        run_mode("full", 2'd2, 6'b11_1111, 3'd6);
        run_mode("masked_full", 2'd2, 6'b10_1011, 3'd4);
        $display("tb_hb2_cluster_util_counter PASS");
        $finish;
    end
endmodule
