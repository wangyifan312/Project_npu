// perf_counter: performance statistics for NPU tasks
// Tracks total cycles, DMA beat counts, active cycles, array utilization
// Enhanced with compute/load/store breakdown and valid-byte counters
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

    // --- Enhanced event inputs ---
    // 阶段-level activity signals
    input  wire        compute_active,  // high during COMPUTE/PIPE_RUN states
    input  wire        load_active,     // high during LOAD states (act/wgt DMA + LOAD_ARRAY)
    input  wire        store_active,    // high during STORE state
    input  wire        collect_active,  // high during COLLECT phase

    // 读 valid bytes (per beat: actual payload, handles partial last beat)
    // 注意：6 bits needed because max is 32 (0x20), which overflows 5 bits
    input  wire [5:0]  read_byte_cnt,   // valid bytes in this read beat (1-32)

    // 写 valid bytes (per beat: WSTRB popcount, handles partial last beat)
    input  wire [5:0]  write_byte_cnt,  // valid bytes in this write beat (1-32)

    // MAC count event (pulse with count of MACs completed this cycle)
    input  wire        mac_count_valid, // high when mac_count_add is valid
    input  wire [15:0] mac_count_add,   // MACs completed this cycle

    // Compute stall breakdown
    input  wire        stall_act,       // waiting for activation data
    input  wire        stall_wgt,       // waiting for weight data
    input  wire        stall_acc,       // waiting for acc buffer
    input  wire        stall_store,     // waiting for store/FIFO

    // Array fill/drain phase
    input  wire        array_fill_drain, // array is filling or draining (not at steady state)

    // 传统 array inputs
    input  wire        array_active,   // array is computing (window_valid)
    input  wire        array_stall,    // array is stalled waiting for data
    input  wire [2:0]  cluster_active_inc,
    input  wire [2:0]  cluster_stall_inc,

    // 写 transaction-level counter inputs
    input  wire        write_data_cycle,     // WVALID && WREADY (per AXI W beat)
    input  wire        write_txn_active,     // AW handshake -> B handshake window

    // AXI channel handshake cycle inputs
    input  wire        ar_active,            // ARVALID && ARREADY
    input  wire        aw_active,            // AWVALID && AWREADY
    input  wire        b_active,             // BVALID && BREADY
    input  wire        bus_active,           // union of AR/R/AW/W/B handshake

    // 计数器 outputs (frozen on done/error)
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
    output wire [31:0] write_txn_cycles,
    output wire [31:0] ar_handshake_cycles,
    output wire [31:0] aw_handshake_cycles,
    output wire [31:0] b_handshake_cycles,
    output wire [31:0] bus_active_cycles,

    // --- Enhanced counter outputs ---
    output wire [31:0] compute_cycles,
    output wire [31:0] load_cycles,
    output wire [31:0] store_cycles,
    output wire [31:0] collect_cycles,
    output wire [31:0] read_valid_bytes,
    output wire [31:0] write_valid_bytes,
    output wire [31:0] mac_count_lo,
    output wire [31:0] mac_count_hi,
    output wire [31:0] stall_act_cycles,
    output wire [31:0] stall_wgt_cycles,
    output wire [31:0] stall_acc_cycles,
    output wire [31:0] stall_store_cycles,
    output wire [31:0] array_fill_drain_cycles
);

    // 64-bit cycle counter
    reg [31:0] cycle_lo, cycle_hi;

    // beat counters
    reg [31:0] read_beats, write_beats;

    // 活动 cycle counters
    reg [31:0] rd_active_cyc, wr_active_cyc;
    reg [31:0] arr_active_cyc, arr_stall_cyc;
    reg [31:0] cl_active_cyc, cl_stall_cyc;
    reg [31:0] wr_data_cyc, wr_txn_cyc;
    reg [31:0] ar_cyc, aw_cyc, b_cyc, bus_cyc;
    reg        task_active_d;

    // --- Enhanced counters ---
    reg [31:0] comp_cyc;       // compute_cycles
    reg [31:0] load_cyc;       // load_cycles
    reg [31:0] store_cyc;      // store_cycles
    reg [31:0] coll_cyc;       // collect_cycles
    reg [31:0] rd_valid_bytes; // read_valid_bytes
    reg [31:0] wr_valid_bytes; // write_valid_bytes
    reg [31:0] mac_cnt_lo;     // mac_count_lo
    reg [31:0] mac_cnt_hi;     // mac_count_hi
    reg [31:0] s_act_cyc;      // stall_act_cycles
    reg [31:0] s_wgt_cyc;      // stall_wgt_cycles
    reg [31:0] s_acc_cyc;      // stall_acc_cycles
    reg [31:0] s_store_cyc;    // stall_store_cycles
    reg [31:0] fill_drain_cyc; // array_fill_drain_cycles

    wire counting = task_active && !freeze;
    wire task_start_pulse = task_active && !task_active_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            task_active_d <= 1'b0;
        else
            task_active_d <= task_active;
    end

    // 周期 counter
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

    // 读 beat counter
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

    // 写 beat counter
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

    // 读 active cycles
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

    // 写 active cycles
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

    // 写 data cycles (WVALID && WREADY)
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

    // 写 transaction cycles (AW handshake to B handshake window)
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

    // AR handshake cycles (ARVALID && ARREADY)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            ar_cyc <= (!freeze && ar_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && ar_active)
                ar_cyc <= ar_cyc + 32'd1;
        end
    end

    // AW handshake cycles (AWVALID && AWREADY)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            aw_cyc <= (!freeze && aw_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && aw_active)
                aw_cyc <= aw_cyc + 32'd1;
        end
    end

    // B handshake cycles (BVALID && BREADY)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            b_cyc <= (!freeze && b_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && b_active)
                b_cyc <= b_cyc + 32'd1;
        end
    end

    // Bus active cycles (union of AR/R/AW/W/B handshake)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            bus_cyc <= (!freeze && bus_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && bus_active)
                bus_cyc <= bus_cyc + 32'd1;
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

    // ============================================================
    // Enhanced counters
    // ============================================================

    // compute_cycles: high during compute phase (FEED_ACT/DRAIN/COLLECT)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            comp_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            comp_cyc <= (!freeze && compute_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && compute_active)
                comp_cyc <= comp_cyc + 32'd1;
        end
    end

    // load_cycles: high during LOAD states (act DMA, wgt DMA, LOAD_ARRAY, etc.)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            load_cyc <= (!freeze && load_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && load_active)
                load_cyc <= load_cyc + 32'd1;
        end
    end

    // store_cycles: high during STORE state
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            store_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            store_cyc <= (!freeze && store_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && store_active)
                store_cyc <= store_cyc + 32'd1;
        end
    end

    // collect_cycles: high during COLLECT phase specifically
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            coll_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            coll_cyc <= (!freeze && collect_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && collect_active)
                coll_cyc <= coll_cyc + 32'd1;
        end
    end

    // 读_valid_bytes: accumulate actual payload bytes from read beats
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_valid_bytes <= 32'h0;
        end else if (task_start_pulse) begin
            rd_valid_bytes <= (!freeze && read_beat) ? {26'd0, read_byte_cnt} : 32'd0;
        end else if (task_active) begin
            if (!freeze && read_beat)
                rd_valid_bytes <= rd_valid_bytes + {26'd0, read_byte_cnt};
        end
    end

    // 写_valid_bytes: accumulate actual payload bytes from write beats (WSTRB-based)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_valid_bytes <= 32'h0;
        end else if (task_start_pulse) begin
            wr_valid_bytes <= (!freeze && write_beat) ? {26'd0, write_byte_cnt} : 32'd0;
        end else if (task_active) begin
            if (!freeze && write_beat)
                wr_valid_bytes <= wr_valid_bytes + {26'd0, write_byte_cnt};
        end
    end

    // mac_count: accumulate actual MAC operations
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {mac_cnt_hi, mac_cnt_lo} <= 64'h0;
        end else if (task_start_pulse) begin
            {mac_cnt_hi, mac_cnt_lo} <= (!freeze && mac_count_valid) ?
                {48'd0, mac_count_add} : 64'h0;
        end else if (task_active) begin
            if (!freeze && mac_count_valid)
                {mac_cnt_hi, mac_cnt_lo} <= {mac_cnt_hi, mac_cnt_lo} + {48'd0, mac_count_add};
        end
    end

    // stall_act_cycles: waiting for activation data
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_act_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            s_act_cyc <= (!freeze && stall_act) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && stall_act)
                s_act_cyc <= s_act_cyc + 32'd1;
        end
    end

    // stall_wgt_cycles: waiting for weight data
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_wgt_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            s_wgt_cyc <= (!freeze && stall_wgt) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && stall_wgt)
                s_wgt_cyc <= s_wgt_cyc + 32'd1;
        end
    end

    // stall_acc_cycles: waiting for acc buffer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_acc_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            s_acc_cyc <= (!freeze && stall_acc) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && stall_acc)
                s_acc_cyc <= s_acc_cyc + 32'd1;
        end
    end

    // stall_store_cycles: waiting for store/FIFO
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_store_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            s_store_cyc <= (!freeze && stall_store) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && stall_store)
                s_store_cyc <= s_store_cyc + 32'd1;
        end
    end

    // array_fill_drain_cycles: array is filling/draining (not at steady state)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_drain_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            fill_drain_cyc <= (!freeze && array_fill_drain) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && array_fill_drain)
                fill_drain_cyc <= fill_drain_cyc + 32'd1;
        end
    end

    // ============================================================
    // 输出 assignments
    // ============================================================
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
    assign ar_handshake_cycles   = ar_cyc;
    assign aw_handshake_cycles   = aw_cyc;
    assign b_handshake_cycles    = b_cyc;
    assign bus_active_cycles     = bus_cyc;

    // Enhanced outputs
    assign compute_cycles        = comp_cyc;
    assign load_cycles           = load_cyc;
    assign store_cycles          = store_cyc;
    assign collect_cycles        = coll_cyc;
    assign read_valid_bytes      = rd_valid_bytes;
    assign write_valid_bytes     = wr_valid_bytes;
    assign mac_count_lo          = mac_cnt_lo;
    assign mac_count_hi          = mac_cnt_hi;
    assign stall_act_cycles      = s_act_cyc;
    assign stall_wgt_cycles      = s_wgt_cyc;
    assign stall_acc_cycles      = s_acc_cyc;
    assign stall_store_cycles    = s_store_cyc;
    assign array_fill_drain_cycles = fill_drain_cyc;

endmodule
