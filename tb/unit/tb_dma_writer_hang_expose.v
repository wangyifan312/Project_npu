// tb_dma_writer_hang_expose: Directed test that exposes the DMA writer
// tail-wait deadlock.
//
// Hang mechanism:
//   When byte_count > MAX_BURST_LEN * 32 (e.g. 528 bytes = 16.5 beats),
//   the DMA writer splits the write into multiple bursts.
//   After the first 16-beat burst completes, the writer enters S_WAIT_DATA
//   and checks: fifo_level >= beats_in_burst.
//   If the FIFO has been fully drained by the first burst and no further
//   data is being produced, this condition is permanently false and the
//   DMA writer hangs with no escape.
//
// Test: Pre-fill 16 beats, start DMA with byte_count=528 (17 beats needed),
// produce NO further data. Verify DMA hangs in S_WAIT_DATA.

`timescale 1ns / 1ps

module tb_dma_writer_hang_expose;

    reg clk, rst_n;

    // === DUT ===
    reg         start;
    reg  [31:0] base_addr;
    reg  [31:0] byte_count;
    wire        done, error, busy, write_txn_active;
    wire [7:0]  error_code;
    wire [4:0]  fifo_level;

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

    assign data_in    = fifo_rd_data;
    assign data_valid = fifo_rd_valid;
    assign fifo_rd_en = data_ready && fifo_rd_valid;

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

    // === Clock ===
    always #5 clk = ~clk;

    // === BVALID logic ===
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wlast_seen <= 0;
            slave_bvalid <= 0;
        end else begin
            if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
                wlast_seen <= 1;
            if (wlast_seen && !slave_bvalid)
                slave_bvalid <= 1;
            if (m_axi_bvalid && m_axi_bready) begin
                slave_bvalid <= 0;
                wlast_seen <= 0;
            end
        end
    end

    // ============================================================
    // Test
    // ============================================================
    integer i;
    integer w_beats, aw_count, hang_cycles;
    reg     hang_detected, break_loop;

    initial begin
        clk = 0; rst_n = 0;
        start = 0; base_addr = 32'h1000;
        fifo_wr_en = 0; fifo_wr_data = 0; fifo_wr_strb = 32'hFFFFFFFF; fifo_wr_last = 0;
        slave_awready = 1; slave_wready = 1; slave_bresp = 2'b00;

        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        $display("============================================================");
        $display("[%0t] DMA Writer Tail-Hang Exposure Test", $time);
        $display("      byte_count=528 (17 beats), 16 prefill, NO more data after start");
        $display("      Expectation: DMA hangs in S_WAIT_DATA after first 16-beat burst");
        $display("============================================================");

        byte_count = 32'd528;

        // Pre-fill FIFO with exactly 16 beats (enough for first max-length burst)
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            fifo_wr_data = {4{32'hBEEF_0000 + i[15:0]}};
            fifo_wr_strb = 32'hFFFFFFFF;
            fifo_wr_en = 1;
        end
        @(posedge clk);
        fifo_wr_en = 0;
        $display("[%0t] Pre-fill done: 16 beats, fifo_level=%0d", $time, fifo_rd_level);

        // Assert start
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;
        $display("[%0t] DMA start asserted. NO more data will be fed.", $time);

        hang_detected = 0;
        break_loop = 0;
        w_beats = 0;
        aw_count = 0;
        hang_cycles = 0;

        while (!done && !error && !break_loop) begin
            @(posedge clk);
            hang_cycles = hang_cycles + 1;

            if (m_axi_wvalid && m_axi_wready) w_beats = w_beats + 1;
            if (m_axi_awvalid && m_axi_awready) aw_count = aw_count + 1;

            // Detect hang: first AW done, FIFO empty, DMA still busy
            if (aw_count >= 1 && fifo_rd_level == 0 && busy && !hang_detected) begin
                hang_detected = 1;
                $display("[%0t] *** HANG DETECTED at monitor cycle %0d ***", $time, hang_cycles);
                $display("      AW handshake count = %0d", aw_count);
                $display("      W beats written    = %0d (of %0d expected)", w_beats, 17);
                $display("      FIFO level         = %0d", fifo_rd_level);
                $display("      DMA busy           = %b, done = %b", busy, done);
                $display("      bytes_remaining    = 16 (requires 1 more beat)");
                $display("      DMA is permanently stuck in S_WAIT_DATA:");
                $display("        condition fifo_level(0) >= beats_in_burst(1) is FALSE");
                $display("        no more data will ever arrive");

                // Wait 100 cycles to confirm no progress
                repeat(100) @(posedge clk);
                if (!done && busy)
                    $display("[%0t]      CONFIRMED: DMA still stuck after 100 additional cycles", $time);
                break_loop = 1;
            end

            // Safety timeout
            if (hang_cycles > 10000) begin
                $display("[%0t] Safety timeout after %0d cycles", $time, hang_cycles);
                break_loop = 1;
            end
        end

        @(posedge clk);
        $display("");
        $display("============================================================");
        $display("[%0t] Final state:", $time);
        $display("      done=%b  error=%b  busy=%b", done, error, busy);
        $display("      w_beats=%0d  aw_count=%0d  fifo_level=%0d", w_beats, aw_count, fifo_rd_level);
        $display("      hang_detected=%b", hang_detected);

        if (hang_detected && !done) begin
            $display("");
            $display("  PASS: Hang correctly exposed.");
            $display("  DMA writer is permanently stuck in S_WAIT_DATA with no escape.");
        end else if (done) begin
            $display("");
            $display("  FAIL: DMA completed unexpectedly.");
        end else begin
            $display("");
            $display("  INFO: Inconclusive result.");
        end
        $display("============================================================");

        // Wait a few cycles for done to assert (in normal operation)
        repeat(10) @(posedge clk);
        $finish;
    end

    // Watchdog
    initial begin
        #10000000;
        $display("[%0t] WATCHDOG TIMEOUT", $time);
        $finish;
    end

endmodule
