// tb_dma_writer_long_burst: multi-case long burst write utilization test
// Exercises 5 byte_count cases, measures perf, verifies burst splitting.
`timescale 1ns / 1ps

module tb_dma_writer_long_burst;

    reg clk, rst_n;

    // === DUT: dma_axi_writer ===
    reg         start;
    reg  [31:0] base_addr;
    reg  [31:0] byte_count;
    wire        done, error, busy, write_txn_active;
    wire [7:0]  error_code;
    wire [5:0]  fifo_level;

    wire [255:0] data_in;
    wire         data_valid;
    wire         data_ready;

    wire [31:0]  m_axi_awaddr;
    wire         m_axi_awvalid, m_axi_awready;
    wire [7:0]   m_axi_awlen;
    wire [2:0]   m_axi_awsize;
    wire [1:0]   m_axi_awburst;
    wire [255:0] m_axi_wdata;
    wire         m_axi_wvalid, m_axi_wready;
    wire         m_axi_wlast;
    wire [31:0]  m_axi_wstrb;
    wire [1:0]   m_axi_bresp;
    wire         m_axi_bvalid, m_axi_bready;

    // === FIFO ===
    reg  [255:0] fifo_wr_data;
    reg  [31:0]  fifo_wr_strb;
    reg          fifo_wr_last;
    reg          fifo_wr_en;
    wire         fifo_wr_full;
    wire [255:0] fifo_rd_data;
    wire [31:0]  fifo_rd_strb;
    wire         fifo_rd_last;
    wire         fifo_rd_valid;
    reg          fifo_rd_en;
    wire         fifo_rd_empty;
    wire [4:0]   fifo_rd_level;

    dma_axi_writer #(
        .AXI_DATA_WIDTH(256), .AXI_ADDR_WIDTH(32), .MAX_BURST_LEN(16)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .base_addr(base_addr), .byte_count(byte_count),
        .done(done), .error(error), .error_code(error_code), .busy(busy),
        .write_txn_active(write_txn_active),
        .fifo_level(fifo_rd_level),
        .producer_done(1'b0),
        .data_in(fifo_rd_data), .data_valid(fifo_rd_valid), .data_ready(data_ready),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_wdata(m_axi_wdata), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_wlast(m_axi_wlast), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );

    assign data_in       = fifo_rd_data;
    assign data_valid    = fifo_rd_valid;
    assign fifo_rd_en    = data_ready && fifo_rd_valid;

    write_beat_fifo #(16) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_data(fifo_wr_data), .wr_strb(fifo_wr_strb), .wr_last(fifo_wr_last),
        .wr_en(fifo_wr_en), .wr_full(fifo_wr_full),
        .rd_data(fifo_rd_data), .rd_strb(fifo_rd_strb), .rd_last(fifo_rd_last),
        .rd_valid(fifo_rd_valid), .rd_en(fifo_rd_en), .rd_empty(fifo_rd_empty),
        .rd_level(fifo_rd_level)
    );

    // === AXI slave ===
    reg         slave_awready;
    reg         slave_wready;
    reg  [1:0]  slave_bresp;
    reg         slave_bvalid;
    reg         wlast_seen;
    assign m_axi_awready = slave_awready;
    assign m_axi_wready  = slave_wready;
    assign m_axi_bresp   = slave_bresp;
    assign m_axi_bvalid  = slave_bvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wlast_seen   <= 0;
            slave_bvalid <= 0;
        end else begin
            if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
                wlast_seen <= 1;
            if (wlast_seen && !slave_bvalid)
                slave_bvalid <= 1;
            if (m_axi_bvalid && m_axi_bready) begin
                slave_bvalid <= 0;
                wlast_seen   <= 0;
            end
        end
    end

    // === Perf counter ===
    wire write_data_cycle;
    wire [31:0] write_data_cycles_out;
    wire [31:0] write_txn_cycles_out;
    wire [31:0] total_cycle_lo, total_cycle_hi;
    wire [31:0] read_beat_count, write_beat_count;
    wire [31:0] read_active_cycles, write_active_cycles;
    wire [31:0] array_active_cycles, array_stall_cycles;
    wire [31:0] cluster_active_cycles, cluster_stall_cycles;

    assign write_data_cycle = m_axi_wvalid && m_axi_wready;

    reg task_active;
    wire freeze = 1'b0;

    perf_counter u_perf (
        .clk(clk),
        .rst_n(rst_n),
        .task_active(task_active),
        .freeze(freeze),
        .read_beat(1'b0),
        .write_beat(1'b0),
        .read_active(1'b0),
        .write_active(1'b0),
        .array_active(1'b0),
        .array_stall(1'b0),
        .cluster_active_inc(3'd0),
        .cluster_stall_inc(3'd0),
        .write_data_cycle(write_data_cycle),
        .write_txn_active(write_txn_active),
        .total_cycle_lo(total_cycle_lo),
        .total_cycle_hi(total_cycle_hi),
        .read_beat_count(read_beat_count),
        .write_beat_count(write_beat_count),
        .read_active_cycles(read_active_cycles),
        .write_active_cycles(write_active_cycles),
        .array_active_cycles(array_active_cycles),
        .array_stall_cycles(array_stall_cycles),
        .cluster_active_cycles(cluster_active_cycles),
        .cluster_stall_cycles(cluster_stall_cycles),
        .write_data_cycles(write_data_cycles_out),
        .write_txn_cycles(write_txn_cycles_out)
    );

    // === Clock ===
    always #5 clk = ~clk;

    // === AWLEN capture ===
    reg [7:0] awlen_log [0:7];

    // === Test variables ===
    integer case_idx, i;
    integer total_fail, case_fail;
    integer total_beats, expected_bursts, dummy_limit;
    integer beats_fed, beats_observed, wlast_count, aw_count;
    integer wr_data_cyc_start, wr_txn_cyc_start;
    integer case_wr_data_cyc, case_wr_txn_cyc;
    real    write_transaction_util;

    reg [31:0] bc_table [0:4];

    // ================================================================
    initial begin
        clk = 0; rst_n = 0;
        start = 0; base_addr = 32'h1000;
        byte_count = 32'd0;
        fifo_wr_en = 0; fifo_wr_data = 0; fifo_wr_strb = 32'hFFFFFFFF; fifo_wr_last = 0;
        slave_awready = 1; slave_wready = 1; slave_bresp = 2'b00;
        task_active = 0;
        total_fail = 0;

        bc_table[0] = 32'd512;
        bc_table[1] = 32'd1024;
        bc_table[2] = 32'd1536;
        bc_table[3] = 32'd520;
        bc_table[4] = 32'd1000;

        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        $display("============================================================");
        $display("  DMA Writer Long-Burst Multi-Case Test");
        $display("============================================================");
        $display("");

        for (case_idx = 0; case_idx < 5; case_idx = case_idx + 1) begin
            byte_count = bc_table[case_idx];
            case_fail = 0;

            total_beats     = (byte_count + 31) / 32;
            expected_bursts = (byte_count + 511) / 512;
            // Feed generously: keep feeding until done, up to a generous limit
            dummy_limit     = total_beats + 64;

            $display("------------------------------------------------------------");
            $display("  Case %0d: byte_count=%0d, beats=%0d bursts=%0d",
                     case_idx, byte_count, total_beats, expected_bursts);
            $display("------------------------------------------------------------");

            // Ensure DMA idle
            task_active = 0;
            @(posedge clk);

            // ----------------------------------------------------------
            // Fill FIFO to >= 16 entries
            // ----------------------------------------------------------
            beats_fed = 0;
            while (fifo_rd_level < 16 && beats_fed < dummy_limit) begin
                @(posedge clk);
                if (!fifo_wr_full) begin
                    fifo_wr_data = {4{32'hCAFE_0000 + beats_fed[15:0]}};
                    fifo_wr_strb = 32'hFFFFFFFF;
                    fifo_wr_last = (beats_fed == total_beats - 1) ? 1'b1 : 1'b0;
                    fifo_wr_en   = 1;
                    beats_fed    = beats_fed + 1;
                end else begin
                    fifo_wr_en = 0;
                end
            end
            @(posedge clk);
            fifo_wr_en  = 0;
            $display("[%0t] FIFO fill: beats_fed=%0d level=%0d",
                     $time, beats_fed, fifo_rd_level);

            // ----------------------------------------------------------
            // Capture perf counter baselines (before task_active 0→1 reset)
            // ----------------------------------------------------------
            wr_data_cyc_start = write_data_cycles_out;
            wr_txn_cyc_start  = write_txn_cycles_out;

            // ----------------------------------------------------------
            // Start DMA
            // ----------------------------------------------------------
            @(posedge clk);
            start = 1;
            task_active = 1;
            @(posedge clk);
            start = 0;

            // ----------------------------------------------------------
            // Monitor + feed until done
            // ----------------------------------------------------------
            beats_observed = 0;
            wlast_count    = 0;
            aw_count       = 0;

            while (!done && !error) begin
                @(posedge clk);

                // Keep feeding while DMA is running (up to dummy_limit)
                if (beats_fed < dummy_limit) begin
                    if (!fifo_wr_full) begin
                        fifo_wr_data = {4{32'hCAFE_0000 + beats_fed[15:0]}};
                        fifo_wr_strb = 32'hFFFFFFFF;
                        fifo_wr_last = (beats_fed == total_beats - 1) ? 1'b1 : 1'b0;
                        fifo_wr_en   = 1;
                        beats_fed    = beats_fed + 1;
                    end else begin
                        fifo_wr_en = 0;
                    end
                end else begin
                    fifo_wr_en = 0;
                end

                // Count W beats and WLASTs
                if (m_axi_wvalid && m_axi_wready) begin
                    if (m_axi_wlast)
                        wlast_count = wlast_count + 1;
                    beats_observed = beats_observed + 1;
                end

                // Count AW bursts and capture AWLEN
                if (m_axi_awvalid && m_axi_awready) begin
                    if (aw_count < 8) begin
                        awlen_log[aw_count] = m_axi_awlen;
                    end
                    aw_count = aw_count + 1;
                end
            end

            @(posedge clk);
            task_active = 0;
            fifo_wr_en  = 0;

            // Compute per-case perf counter deltas
            case_wr_data_cyc = write_data_cycles_out - wr_data_cyc_start;
            case_wr_txn_cyc  = write_txn_cycles_out  - wr_txn_cyc_start;

            // ----------------------------------------------------------
            // Report
            // ----------------------------------------------------------
            if (error) begin
                $display("  Case %0d %0d bytes:", case_idx, byte_count);
                $display("    ERROR: error_code=0x%02h", error_code);
                $display("    FAIL");
                case_fail = case_fail + 1;
            end else begin
                write_transaction_util = 0.0;
                if (case_wr_txn_cyc > 0) begin
                    write_transaction_util = $itor(case_wr_data_cyc) * 100.0
                                           / $itor(case_wr_txn_cyc);
                end

                $display("  Case %0d %0d bytes:", case_idx, byte_count);
                $display("    write_data_cycles = %0d", case_wr_data_cyc);
                $display("    write_txn_cycles  = %0d", case_wr_txn_cyc);
                $display("    write_transaction_util = %.2f%%", write_transaction_util);
                $display("    WLAST count = %0d", wlast_count);
                $display("    AW burst count = %0d", aw_count);

                if (wlast_count != aw_count) begin
                    $display("    FAIL: WLAST count (%0d) != AW burst count (%0d)",
                             wlast_count, aw_count);
                    case_fail = case_fail + 1;
                end
                if (aw_count != expected_bursts) begin
                    $display("    FAIL: AW burst count (%0d) != expected (%0d)",
                             aw_count, expected_bursts);
                    case_fail = case_fail + 1;
                end
                if (beats_observed != total_beats) begin
                    $display("    FAIL: observed beats (%0d) != expected (%0d)",
                             beats_observed, total_beats);
                    case_fail = case_fail + 1;
                end

                begin
                    integer b, exp_beats_this_burst;
                    for (b = 0; b < aw_count; b = b + 1) begin
                        if (b < aw_count - 1)
                            exp_beats_this_burst = 16;
                        else
                            exp_beats_this_burst = total_beats - (aw_count - 1) * 16;
                        if (awlen_log[b] != (exp_beats_this_burst - 1)) begin
                            $display("    FAIL: burst %0d AWLEN=%0d (expected %0d)",
                                     b, awlen_log[b], exp_beats_this_burst - 1);
                            case_fail = case_fail + 1;
                        end
                    end
                end

                if (byte_count % 512 == 0) begin
                    if (write_transaction_util < 80.0) begin
                        $display("    FAIL: aligned case util %.2f%% < 80%%",
                                 write_transaction_util);
                        case_fail = case_fail + 1;
                    end
                end

                if (case_wr_data_cyc < total_beats) begin
                    $display("    FAIL: write_data_cycles (%0d) < total_beats (%0d)",
                             case_wr_data_cyc, total_beats);
                    case_fail = case_fail + 1;
                end

                if (case_fail == 0) begin
                    $display("    PASS");
                end else begin
                    $display("    FAIL (%0d failures)", case_fail);
                end
            end

            $display("");
            total_fail = total_fail + case_fail;
            repeat(50) @(posedge clk);
        end

        $display("============================================================");
        $display("  Final Summary");
        $display("============================================================");
        if (total_fail == 0) begin
            $display("  tb_dma_writer_long_burst PASS");
            $display("");
            $display("PASS");
        end else begin
            $display("  FAIL (%0d total failures)", total_fail);
            $display("");
            $display("FAIL");
        end
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
