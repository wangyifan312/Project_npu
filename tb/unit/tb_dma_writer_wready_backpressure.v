// tb_dma_writer_wready_backpressure: tests WDATA/WSTRB/WLAST stability
// when WVALID is asserted but WREADY is deasserted.
// Uses NBA for WREADY control to avoid Verilog timing races.
`timescale 1ns / 1ps

module tb_dma_writer_wready_backpressure;

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

    // === write_beat_fifo ===
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

    // === AXI slave: WREADY, AWREADY, BVALID ===
    reg         slave_awready;
    reg         slave_wready;
    reg  [1:0]  slave_bresp;
    reg         slave_bvalid;
    reg         wlast_seen;
    assign m_axi_awready = slave_awready;
    assign m_axi_wready  = slave_wready;
    assign m_axi_bresp   = slave_bresp;
    assign m_axi_bvalid  = slave_bvalid;

    always #5 clk = ~clk;

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

    integer pass_count, fail_count, i, beat_idx;
    reg [255:0] captured_wdata;
    reg [31:0]  captured_wstrb;
    reg         captured_wlast;

    initial begin
        clk = 0; rst_n = 0;
        start = 0; base_addr = 32'h1000;
        fifo_wr_en = 0; fifo_wr_data = 0; fifo_wr_strb = 32'hFFFFFFFF; fifo_wr_last = 0;
        slave_awready = 1; slave_wready = 1; slave_bresp = 2'b00;
        pass_count = 0; fail_count = 0;

        repeat(10) @(posedge clk); rst_n = 1; repeat(5) @(posedge clk);

        // -------------------------------------------------------
        // Test 1: basic 512-byte full burst, no backpressure
        // -------------------------------------------------------
        $display("[%0t] Test 1: full burst, no backpressure", $time);
        byte_count = 512;
        start = 1; @(posedge clk); start = 0;
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            fifo_wr_data = {4{32'hA000_0000 + i}};
            fifo_wr_en = 1;
        end
        @(posedge clk); fifo_wr_en = 0;
        wait(done); @(posedge clk);
        if (!error) begin
            $display("  PASS"); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL"); fail_count = fail_count + 1;
        end

        // -------------------------------------------------------
        // Test 2: WREADY backpressure — use NBA-controlled WREADY
        // -------------------------------------------------------
        $display("[%0t] Test 2: WREADY backpressure via NBA timing", $time);
        byte_count = 64;  // 2 beats
        start = 1; @(posedge clk); start = 0;

        // Fill FIFO with exactly 2 beats
        @(posedge clk);
        fifo_wr_data = {4{32'hDEAD_BEEF}}; fifo_wr_en = 1;
        @(posedge clk);
        fifo_wr_data = {4{32'hCAFE_F00D}}; fifo_wr_en = 1;
        @(posedge clk); fifo_wr_en = 0;

        // Let AW happen naturally, then backpressure first W beat
        slave_wready <= 0;  // NBA: WREADY goes low
        @(posedge clk);
        // Wait for first beat on W channel with WREADY=0
        repeat(10) @(posedge clk);
        if (!m_axi_wvalid) begin
            // AW might still be pending; give more time
            repeat(10) @(posedge clk);
        end
        if (!m_axi_wvalid) begin
            $display("  FAIL: WVALID never asserted"); fail_count = fail_count + 1;
        end else begin
            $display("  Beat 0 on W, WREADY=0");
            // Verify stability for 3 cycles
            captured_wdata = m_axi_wdata;
            for (i = 0; i < 3; i = i + 1) begin
                @(posedge clk);
                if (m_axi_wvalid && (m_axi_wdata !== captured_wdata)) begin
                    $display("  FAIL: WDATA changed"); fail_count = fail_count + 1;
                end
            end
            // Release backpressure for exactly 1 cycle (NBA)
            slave_wready <= 1;  // beat 0 consumed this cycle
            @(posedge clk);
            slave_wready <= 0;  // backpressure resumes
            $display("  Beat 0 consumed, backpressure back on");

            // Wait for beat 1 with WREADY=0
            repeat(5) @(posedge clk);
            if (!m_axi_wvalid) begin
                $display("  FAIL: beat 1 WVALID not asserted"); fail_count = fail_count + 1;
            end else begin
                captured_wdata = m_axi_wdata;
                captured_wstrb = m_axi_wstrb;
                captured_wlast = m_axi_wlast;
                $display("  Beat 1: WDATA[31:0]=%h WLAST=%b", captured_wdata[31:0], captured_wlast);
                // Verify stability for 3 more cycles
                for (i = 0; i < 3; i = i + 1) begin
                    @(posedge clk);
                    if (m_axi_wdata !== captured_wdata) begin
                        $display("  FAIL: beat 1 WDATA changed (cycle %0d) exp=%h got=%h",
                                 i, captured_wdata[31:0], m_axi_wdata[31:0]);
                        fail_count = fail_count + 1;
                    end
                    if (m_axi_wstrb !== captured_wstrb) begin
                        $display("  FAIL: WSTRB changed"); fail_count = fail_count + 1;
                    end
                    if (m_axi_wlast !== captured_wlast) begin
                        $display("  FAIL: WLAST changed"); fail_count = fail_count + 1;
                    end
                end
                $display("  Beat 1 stability check done");
            end
        end

        // Release and finish
        slave_wready <= 1;
        wait(done); @(posedge clk);
        if (!error) begin
            $display("  PASS: backpressure test complete"); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: error after backpressure"); fail_count = fail_count + 1;
        end

        // === Results ===
        $display("[%0t] === %0d PASS, %0d FAIL ===", $time, pass_count, fail_count);
        if (fail_count > 0) $display("FAIL"); else $display("PASS");
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end
endmodule
