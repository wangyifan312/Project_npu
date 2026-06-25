// tb_dma_writer_awlen_wlast: verifies AWLEN = beat_count - 1,
// WLAST asserts only on last beat of each burst, B response handling.
// Tests multi-burst scenario (600 bytes = 16-beat + 3-beat bursts).
`timescale 1ns / 1ps

module tb_dma_writer_awlen_wlast;

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

    // === Clock ===
    always #5 clk = ~clk;

    // === BVALID: assert 1 cycle after WLAST, hold until handshake ===
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
    integer pass_count, fail_count, i, burst_idx;
    reg [7:0]  burst_awlen [0:15];   // up to 16 bursts
    integer    burst_beats [0:15];
    integer    burst_wlast_cnt [0:15];
    integer    burst_bresp_cnt;
    integer    total_beats;
    integer    current_burst;
    reg        in_aw;

    initial begin
        clk = 0; rst_n = 0;
        start = 0; base_addr = 32'h2000;
        fifo_wr_en = 0; fifo_wr_data = 0; fifo_wr_strb = 32'hFFFFFFFF; fifo_wr_last = 0;
        slave_awready = 1; slave_wready = 1; slave_bresp = 2'b00;
        pass_count = 0; fail_count = 0;

        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        // -------------------------------------------------------
        // Test 1: 600 bytes = 18.75 beats -> 16-beat burst + 3-beat tail burst
        // -------------------------------------------------------
        $display("[%0t] Test 1: 600 bytes multi-burst", $time);
        byte_count = 600;
        start = 1;
        @(posedge clk); start = 0;

        // Pre-fill FIFO: need 19 beats total, but FIFO is only 16 deep.
        // First fill 16 beats, then top up when space frees.
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            fifo_wr_data = {4{32'hC000_0000 + i}};
            fifo_wr_en = 1;
        end
        @(posedge clk); fifo_wr_en = 0;

        // Monitor bursts
        current_burst = 0;
        total_beats = 0;
        for (i = 0; i < 16; i = i + 1) begin
            burst_beats[i] = 0;
            burst_wlast_cnt[i] = 0;
        end
        burst_bresp_cnt = 0;

        while (!done && !error) begin
            @(posedge clk);

            // Capture AWLEN per burst
            if (m_axi_awvalid && m_axi_awready) begin
                burst_awlen[current_burst] = m_axi_awlen;
                $display("  Burst %0d: AWLEN=%0d", current_burst, m_axi_awlen);
            end

            // Count W beats and WLAST per burst
            if (m_axi_wvalid && m_axi_wready) begin
                burst_beats[current_burst] = burst_beats[current_burst] + 1;
                total_beats = total_beats + 1;
                if (m_axi_wlast) begin
                    burst_wlast_cnt[current_burst] = burst_wlast_cnt[current_burst] + 1;
                    $display("  Burst %0d: WLAST on beat %0d", current_burst, burst_beats[current_burst]);
                end
            end

            // Count B responses
            if (m_axi_bvalid && m_axi_bready) begin
                burst_bresp_cnt = burst_bresp_cnt + 1;
                $display("  Burst %0d: B response received (BRESP=%b)", current_burst, m_axi_bresp);
                current_burst = current_burst + 1;
                // Provide next batch of FIFO data for second burst
                if (current_burst == 1 && burst_beats[0] >= 2) begin
                    for (i = 0; i < 3; i = i + 1) begin
                        @(posedge clk);
                        fifo_wr_data = {4{32'hC000_1000 + i}};
                        fifo_wr_en = 1;
                    end
                    @(posedge clk); fifo_wr_en = 0;
                end
            end

        end
        @(posedge clk);

        // Check burst 0 (should be 16 beats, AWLEN=15)
        if (burst_awlen[0] == 8'd15)
            $display("  PASS: burst 0 AWLEN=15 correct");
        else begin
            $display("  FAIL: burst 0 AWLEN=%0d, expected 15", burst_awlen[0]);
            fail_count = fail_count + 1;
        end

        if (burst_beats[0] == 16)
            $display("  PASS: burst 0 beat_count=16 correct");
        else begin
            $display("  FAIL: burst 0 beat_count=%0d, expected 16", burst_beats[0]);
            fail_count = fail_count + 1;
        end

        if (burst_wlast_cnt[0] == 1)
            $display("  PASS: burst 0 WLAST count=1");
        else begin
            $display("  FAIL: burst 0 WLAST count=%0d", burst_wlast_cnt[0]);
            fail_count = fail_count + 1;
        end

        // Check burst 1 (should be 3 beats, AWLEN=2)
        if (burst_awlen[1] == 8'd2)
            $display("  PASS: burst 1 AWLEN=2 correct");
        else begin
            $display("  FAIL: burst 1 AWLEN=%0d, expected 2", burst_awlen[1]);
            fail_count = fail_count + 1;
        end

        if (burst_beats[1] == 3)
            $display("  PASS: burst 1 beat_count=3 correct");
        else begin
            $display("  FAIL: burst 1 beat_count=%0d, expected 3", burst_beats[1]);
            fail_count = fail_count + 1;
        end

        if (burst_wlast_cnt[1] == 1)
            $display("  PASS: burst 1 WLAST count=1");
        else begin
            $display("  FAIL: burst 1 WLAST count=%0d", burst_wlast_cnt[1]);
            fail_count = fail_count + 1;
        end

        // Total beats should be 19
        if (total_beats == 19)
            $display("  PASS: total_beats=19 correct");
        else begin
            $display("  FAIL: total_beats=%0d, expected 19", total_beats);
            fail_count = fail_count + 1;
        end

        // B responses = 2 bursts
        if (burst_bresp_cnt == 2)
            $display("  PASS: B response count=2");
        else begin
            $display("  FAIL: B response count=%0d", burst_bresp_cnt);
            fail_count = fail_count + 1;
        end

        // Error should be 0
        if (!error)
            $display("  PASS: error=0");
        else begin
            $display("  FAIL: error=1 code=%h", error_code);
            fail_count = fail_count + 1;
        end

        pass_count = pass_count + 1;

        // -------------------------------------------------------
        // Test 2: 512 bytes (exact 16 beats), single burst
        // -------------------------------------------------------
        $display("[%0t] Test 2: 512 bytes single burst", $time);
        byte_count = 512;
        start = 1;
        @(posedge clk); start = 0;

        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            fifo_wr_data = {4{32'hD000_0000 + i}};
            fifo_wr_en = 1;
        end
        @(posedge clk); fifo_wr_en = 0;

        wait(done);
        @(posedge clk);

        if (!error) begin
            $display("  PASS: 512 bytes done without error");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: error=1");
            fail_count = fail_count + 1;
        end

        // -------------------------------------------------------
        // Test 3: BRESP error detection
        // -------------------------------------------------------
        $display("[%0t] Test 3: BRESP error detection", $time);
        byte_count = 32;  // 1 beat
        start = 1;
        @(posedge clk); start = 0;

        @(posedge clk);
        fifo_wr_data = 256'hE000_0000_1111_2222_3333_4444_5555_6666_7777_8888;
        fifo_wr_en = 1;
        @(posedge clk); fifo_wr_en = 0;

        slave_bresp = 2'b10;  // SLVERR — set before WLAST so BVALID carries it

        wait(error);
        @(posedge clk);
        slave_bresp = 2'b00;

        if (error && error_code == 8'h30) begin
            $display("  PASS: BRESP error detected, code=0x30");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: error=%b code=%h", error, error_code);
            fail_count = fail_count + 1;
        end

        // Deassert start to clear error
        @(posedge clk);
        wait(!busy);

        // -------------------------------------------------------
        // Results
        // -------------------------------------------------------
        $display("[%0t] === Summary: %0d PASS, %0d FAIL ===", $time, pass_count, fail_count - 1 + 1, fail_count);
        if (fail_count > 0)
            $display("FAIL");
        else
            $display("PASS");
        $finish;
    end

    // Watchdog
    initial begin
        #1000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
