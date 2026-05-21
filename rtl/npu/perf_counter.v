// perf_counter: performance statistics for NPU tasks
// Tracks total cycles, DMA beat counts, active cycles, array utilization
`timescale 1ns / 1ps

module perf_counter (
    input  wire        clk,
    input  wire        rst_n,

    // Control
    input  wire        task_active,    // high during task execution
    input  wire        freeze,         // freeze counters on error/done

    // DMA event inputs (pulse per beat)
    input  wire        read_beat,      // one AXI read beat completed
    input  wire        write_beat,     // one AXI write beat completed
    input  wire        read_active,    // DMA reader is actively transferring
    input  wire        write_active,   // DMA writer is actively transferring

    // Array event inputs
    input  wire        array_active,   // array is computing (window_valid)
    input  wire        array_stall,    // array is stalled waiting for data

    // Counter outputs (frozen on done/error)
    output wire [31:0] total_cycle_lo,
    output wire [31:0] total_cycle_hi,
    output wire [31:0] read_beat_count,
    output wire [31:0] write_beat_count,
    output wire [31:0] read_active_cycles,
    output wire [31:0] write_active_cycles,
    output wire [31:0] array_active_cycles,
    output wire [31:0] array_stall_cycles
);

    // 64-bit cycle counter
    reg [31:0] cycle_lo, cycle_hi;

    // Beat counters
    reg [31:0] read_beats, write_beats;

    // Active cycle counters
    reg [31:0] rd_active_cyc, wr_active_cyc;
    reg [31:0] arr_active_cyc, arr_stall_cyc;

    wire counting = task_active && !freeze;

    // Cycle counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_lo <= 32'h0;
            cycle_hi <= 32'h0;
        end else if (task_active) begin
            if (!freeze) begin
                {cycle_hi, cycle_lo} <= {cycle_hi, cycle_lo} + 65'd1;
            end
        end else begin
            cycle_lo <= 32'h0;
            cycle_hi <= 32'h0;
        end
    end

    // Read beat counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_beats <= 32'h0;
        end else if (task_active) begin
            if (!freeze && read_beat)
                read_beats <= read_beats + 32'd1;
        end else begin
            read_beats <= 32'h0;
        end
    end

    // Write beat counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_beats <= 32'h0;
        end else if (task_active) begin
            if (!freeze && write_beat)
                write_beats <= write_beats + 32'd1;
        end else begin
            write_beats <= 32'h0;
        end
    end

    // Read active cycles
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active_cyc <= 32'h0;
        end else if (task_active) begin
            if (!freeze && read_active)
                rd_active_cyc <= rd_active_cyc + 32'd1;
        end else begin
            rd_active_cyc <= 32'h0;
        end
    end

    // Write active cycles
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_active_cyc <= 32'h0;
        end else if (task_active) begin
            if (!freeze && write_active)
                wr_active_cyc <= wr_active_cyc + 32'd1;
        end else begin
            wr_active_cyc <= 32'h0;
        end
    end

    // Array active cycles
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arr_active_cyc <= 32'h0;
        end else if (task_active) begin
            if (!freeze && array_active)
                arr_active_cyc <= arr_active_cyc + 32'd1;
        end else begin
            arr_active_cyc <= 32'h0;
        end
    end

    // Array stall cycles
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arr_stall_cyc <= 32'h0;
        end else if (task_active) begin
            if (!freeze && array_stall)
                arr_stall_cyc <= arr_stall_cyc + 32'd1;
        end else begin
            arr_stall_cyc <= 32'h0;
        end
    end

    assign total_cycle_lo    = cycle_lo;
    assign total_cycle_hi    = cycle_hi;
    assign read_beat_count   = read_beats;
    assign write_beat_count  = write_beats;
    assign read_active_cycles  = rd_active_cyc;
    assign write_active_cycles = wr_active_cyc;
    assign array_active_cycles = arr_active_cyc;
    assign array_stall_cycles  = arr_stall_cyc;

endmodule
