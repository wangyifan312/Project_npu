`timescale 1ns / 1ps

module tb_perf_counter;

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
    reg [2:0] cluster_active_inc;
    reg [2:0] cluster_stall_inc;

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

    perf_counter u_dut (
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
        .cluster_active_inc(cluster_active_inc),
        .cluster_stall_inc(cluster_stall_inc),
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

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        task_active = 1'b0;
        freeze = 1'b0;
        read_beat = 1'b0;
        write_beat = 1'b0;
        read_active = 1'b0;
        write_active = 1'b0;
        array_active = 1'b0;
        array_stall = 1'b0;
        cluster_active_inc = 3'd0;
        cluster_stall_inc = 3'd0;

        repeat (2) @(posedge clk);
        rst_n = 1'b1;

        @(posedge clk);
        task_active <= 1'b1;
        read_beat <= 1'b1;
        read_active <= 1'b1;
        array_active <= 1'b1;
        cluster_active_inc <= 3'd2;

        @(posedge clk);
        read_beat <= 1'b0;
        write_beat <= 1'b1;
        read_active <= 1'b0;
        write_active <= 1'b1;
        array_active <= 1'b0;
        array_stall <= 1'b1;
        cluster_active_inc <= 3'd0;
        cluster_stall_inc <= 3'd2;

        @(posedge clk);
        write_beat <= 1'b0;
        write_active <= 1'b0;
        array_stall <= 1'b0;
        cluster_stall_inc <= 3'd0;
        freeze <= 1'b1;
        read_beat <= 1'b1;
        array_active <= 1'b1;
        cluster_active_inc <= 3'd6;

        @(posedge clk);
        freeze <= 1'b0;
        read_beat <= 1'b0;
        array_active <= 1'b0;
        cluster_active_inc <= 3'd0;
        task_active <= 1'b0;

        @(posedge clk);
        if (total_cycle_lo !== 32'd2) $fatal(1, "cycle count mismatch: %0d", total_cycle_lo);
        if (read_beat_count !== 32'd1) $fatal(1, "read beat mismatch: %0d", read_beat_count);
        if (write_beat_count !== 32'd1) $fatal(1, "write beat mismatch: %0d", write_beat_count);
        if (read_active_cycles !== 32'd1) $fatal(1, "read active mismatch: %0d", read_active_cycles);
        if (write_active_cycles !== 32'd1) $fatal(1, "write active mismatch: %0d", write_active_cycles);
        if (array_active_cycles !== 32'd1) $fatal(1, "array active mismatch: %0d", array_active_cycles);
        if (array_stall_cycles !== 32'd1) $fatal(1, "array stall mismatch: %0d", array_stall_cycles);
        if (cluster_active_cycles !== 32'd2) $fatal(1, "cluster active mismatch: %0d", cluster_active_cycles);
        if (cluster_stall_cycles !== 32'd2) $fatal(1, "cluster stall mismatch: %0d", cluster_stall_cycles);

        @(posedge clk);
        if (total_cycle_lo !== 32'd2) $fatal(1, "counters should hold after task_active drops");

        task_active <= 1'b1;
        @(posedge clk);
        task_active <= 1'b0;
        @(posedge clk);
        if (total_cycle_lo !== 32'd1) $fatal(1, "counters should reset on next task start");

        $display("tb_perf_counter PASS");
        $finish;
    end

endmodule
