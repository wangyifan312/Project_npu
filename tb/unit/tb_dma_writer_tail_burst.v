// tb_dma_writer_tail_burst: tests tail burst handling with non-32B-aligned
// byte counts. Verifies AWLEN, WSTRB, WLAST correctness for partial final beats.
`timescale 1ns / 1ps

module tb_dma_writer_tail_burst;

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

    wire [31:0] m_axi_awaddr;
    wire        m_axi_awvalid, m_axi_awready;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire [255:0] m_axi_wdata;
    wire        m_axi_wvalid, m_axi_wready;
    wire        m_axi_wlast;
    wire [31:0] m_axi_wstrb;
    wire [1:0]  m_axi_bresp;
    wire        m_axi_bvalid, m_axi_bready;

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
    reg         wlast_seen;  // latch WLAST to trigger BVALID
    assign m_axi_awready = slave_awready;
    assign m_axi_wready  = slave_wready;
    assign m_axi_bresp   = slave_bresp;
    assign m_axi_bvalid  = slave_bvalid;

    // === Clock ===
    always #5 clk = ~clk;

    // === BVALID logic: assert after WLAST, hold until B handshake ===
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

    // === Test ===
    integer pass_count, fail_count, i;
    reg [7:0] expected_awlen;
    reg [31:0] expected_wstrb_last;
    reg [31:0] observed_wstrb;
    reg [7:0]  observed_awlen;
    integer observed_beats;
    reg [7:0]  wlast_beat_idx;
    integer wlast_count;

    task automatic run_tail_test;
        input [31:0] test_bytes;
        input [7:0]  exp_awlen;
        input [31:0] exp_wstrb;
        input [7:0]  exp_beats;
        begin
            $display("[%0t] Tail burst test: %0d bytes", $time, test_bytes);
            byte_count = test_bytes;
            start = 1;
            @(posedge clk); start = 0;

            // Fill FIFO with enough beats (ceil(bytes/32))
            for (i = 0; i < exp_beats; i = i + 1) begin
                @(posedge clk);
                fifo_wr_data = {4{32'hB000_0000 + i}};
                fifo_wr_en = 1;
            end
            @(posedge clk); fifo_wr_en = 0;

            // Wait for AW handshake and capture AWLEN
            wait(m_axi_awvalid && m_axi_awready);
            observed_awlen = m_axi_awlen;
            $display("  AWLEN=%0d (expected %0d)", observed_awlen, exp_awlen);

            // Count W beats and check WLAST/WSTRB
            observed_beats = 0;
            wlast_count = 0;
            observed_wstrb = 32'h0;
            while (!done && !error) begin
                @(posedge clk);
                if (m_axi_wvalid && m_axi_wready) begin
                    if (m_axi_wlast) begin
                        wlast_beat_idx = observed_beats;
                        observed_wstrb = m_axi_wstrb;
                        wlast_count = wlast_count + 1;
                    end
                    observed_beats = observed_beats + 1;
                end
            end
            @(posedge clk);

            // Check AWLEN
            if (observed_awlen == exp_awlen)
                $display("  PASS: AWLEN=%0d correct", observed_awlen);
            else begin
                $display("  FAIL: AWLEN=%0d, expected %0d", observed_awlen, exp_awlen);
                fail_count = fail_count + 1;
            end

            // Check beat count
            if (observed_beats == exp_beats)
                $display("  PASS: beat_count=%0d correct", observed_beats);
            else begin
                $display("  FAIL: beat_count=%0d, expected %0d", observed_beats, exp_beats);
                fail_count = fail_count + 1;
            end

            // Check WLAST count (exactly 1 per burst)
            if (wlast_count == 1)
                $display("  PASS: WLAST asserted exactly once");
            else begin
                $display("  FAIL: WLAST count=%0d, expected 1", wlast_count);
                fail_count = fail_count + 1;
            end

            // Check WSTRB on last beat
            if (observed_wstrb == exp_wstrb)
                $display("  PASS: WSTRB last beat=%h correct", observed_wstrb);
            else begin
                $display("  FAIL: WSTRB last beat=%h, expected %h", observed_wstrb, exp_wstrb);
                fail_count = fail_count + 1;
            end

            // Check error=0
            if (!error)
                $display("  PASS: no error");
            else begin
                $display("  FAIL: error=%b code=%h", error, error_code);
                fail_count = fail_count + 1;
            end

            pass_count = pass_count + 1;
            $display("");
        end
    endtask

    initial begin
        clk = 0; rst_n = 0;
        start = 0; base_addr = 32'h1000;
        fifo_wr_en = 0; fifo_wr_data = 0; fifo_wr_strb = 32'hFFFFFFFF; fifo_wr_last = 0;
        slave_awready = 1; slave_wready = 1; slave_bresp = 2'b00;
        pass_count = 0; fail_count = 0;

        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        // Test 17 bytes: 1 beat, AWLEN=0, WSTRB=0x0001FFFF (17 bytes = lower 17 lanes)
        run_tail_test(32'd17, 8'd0, 32'h0001FFFF, 8'd1);

        // Test 40 bytes: 2 beats, AWLEN=1, WSTRB=0x000000FF (40-32=8 bytes)
        run_tail_test(32'd40, 8'd1, 32'h000000FF, 8'd2);

        // Test 63 bytes: 2 beats, AWLEN=1, WSTRB=0x7FFFFFFF (63-32=31 bytes)
        run_tail_test(32'd63, 8'd1, 32'h7FFFFFFF, 8'd2);

        // Test 64 bytes (exact 2-beat boundary): AWLEN=1, WSTRB=0xFFFFFFFF
        run_tail_test(32'd64, 8'd1, 32'hFFFFFFFF, 8'd2);

        // Test 100 bytes: 4 beats (ceil(100/32)=4), AWLEN=3, WSTRB=0x0000000F (100-96=4 bytes)
        run_tail_test(32'd100, 8'd3, 32'h0000000F, 8'd4);

        $display("[%0t] === Summary: %0d cases, %0d FAIL ===", $time, pass_count + fail_count, fail_count);
        if (fail_count > 0)
            $display("FAIL");
        else
            $display("PASS");
        $finish;
    end

    // Watchdog
    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
