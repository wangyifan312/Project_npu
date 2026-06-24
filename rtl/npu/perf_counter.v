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
    input  wire [2:0]  cluster_active_inc,
    input  wire [2:0]  cluster_stall_inc,

    // Write transaction-level counter inputs
    input  wire        write_data_cycle,     // WVALID && WREADY (per AXI W beat)
    input  wire        write_txn_active,     // AW handshake -> B handshake window

    // Counter outputs (frozen on done/error)
    output wire [31:0] total_cycle_lo,
    output wire [31:0] total_cycle_hi,
    output wire [31:0] read_beat_count,
    output wire [31:0] write_beat_count,
    output wire [31:0] read_active_cycles,
    output wire [31:0] write_active_cycles,
    output wire [31:0] array_active_cycles,
    output wire [31:0] array_stall_cycles,
    output wire [31:0] cluster_active_cycles,
    output wire [31:0] cluster_stall_cycles,
    output wire [31:0] write_data_cycles,
    output wire [31:0] write_txn_cycles
);

    // 64-bit cycle counter
    reg [31:0] cycle_lo, cycle_hi;

    // Beat counters
    reg [31:0] read_beats, write_beats;

    // Active cycle counters
    reg [31:0] rd_active_cyc, wr_active_cyc;
    reg [31:0] arr_active_cyc, arr_stall_cyc;
    reg [31:0] cl_active_cyc, cl_stall_cyc;
    reg [31:0] wr_data_cyc, wr_txn_cyc;
    reg        task_active_d;

    wire counting = task_active && !freeze;
    wire task_start_pulse = task_active && !task_active_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            task_active_d <= 1'b0;
        else
            task_active_d <= task_active;
    end

    // Cycle counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_lo <= 32'h0;
            cycle_hi <= 32'h0;
        end else if (task_start_pulse) begin
            {cycle_hi, cycle_lo} <= freeze ? 64'h0 : 64'h1;
        end else if (task_active) begin
            if (!freeze) begin
                {cycle_hi, cycle_lo} <= {cycle_hi, cycle_lo} + 65'd1;
            end
        end
    end

    // Read beat counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_beats <= 32'h0;
        end else if (task_start_pulse) begin
            read_beats <= (!freeze && read_beat) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && read_beat)
                read_beats <= read_beats + 32'd1;
        end
    end

    // Write beat counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_beats <= 32'h0;
        end else if (task_start_pulse) begin
            write_beats <= (!freeze && write_beat) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && write_beat)
                write_beats <= write_beats + 32'd1;
        end
    end

    // Read active cycles
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            rd_active_cyc <= (!freeze && read_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && read_active)
                rd_active_cyc <= rd_active_cyc + 32'd1;
        end
    end

    // Write active cycles
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_active_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            wr_active_cyc <= (!freeze && write_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && write_active)
                wr_active_cyc <= wr_active_cyc + 32'd1;
        end
    end

    // Write data cycles (WVALID && WREADY)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_data_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            wr_data_cyc <= (!freeze && write_data_cycle) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && write_data_cycle)
                wr_data_cyc <= wr_data_cyc + 32'd1;
        end
    end

    // Write transaction cycles (AW handshake to B handshake window)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_txn_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            wr_txn_cyc <= (!freeze && write_txn_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && write_txn_active)
                wr_txn_cyc <= wr_txn_cyc + 32'd1;
        end
    end

    // Array active cycles
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arr_active_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            arr_active_cyc <= (!freeze && array_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && array_active)
                arr_active_cyc <= arr_active_cyc + 32'd1;
        end
    end

    // Array stall cycles
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arr_stall_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            arr_stall_cyc <= (!freeze && array_stall) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && array_stall)
                arr_stall_cyc <= arr_stall_cyc + 32'd1;
        end
    end

    // Aggregate enabled-cluster active cycles
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cl_active_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            cl_active_cyc <= (!freeze && (cluster_active_inc != 3'd0)) ? {29'd0, cluster_active_inc} : 32'd0;
        end else if (task_active) begin
            if (!freeze && (cluster_active_inc != 3'd0))
                cl_active_cyc <= cl_active_cyc + {29'd0, cluster_active_inc};
        end
    end

    // Aggregate enabled-cluster stall cycles
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cl_stall_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            cl_stall_cyc <= (!freeze && (cluster_stall_inc != 3'd0)) ? {29'd0, cluster_stall_inc} : 32'd0;
        end else if (task_active) begin
            if (!freeze && (cluster_stall_inc != 3'd0))
                cl_stall_cyc <= cl_stall_cyc + {29'd0, cluster_stall_inc};
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
    assign cluster_active_cycles = cl_active_cyc;
    assign cluster_stall_cycles  = cl_stall_cyc;
    assign write_data_cycles     = wr_data_cyc;
    assign write_txn_cycles      = wr_txn_cyc;

endmodule
