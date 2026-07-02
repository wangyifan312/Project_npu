// tb_dma_writer_per_beat_protocol: Characterize per-beat DMA transaction timing
// Purpose: define exact sequence for Phase 4c-2 background STORE engine.
// Simulates: two back-to-back 32-byte beats (N=8 single row, 2 cols per beat).
`timescale 1ns / 1ps

module tb_dma_writer_per_beat_protocol;
    reg clk, rst_n;
    reg start, producer_done;
    reg [31:0] base_addr, byte_count;
    wire done, error, busy;
    wire [7:0] error_code;
    wire [5:0] fifo_level;

    // FIFO signals
    reg [255:0] fifo_wr_data;
    reg [31:0]  fifo_wr_strb;
    reg         fifo_wr_last, fifo_wr_en;
    wire        fifo_wr_full;
    wire [255:0] fifo_rd_data;
    wire [31:0]  fifo_rd_strb;
    wire         fifo_rd_last, fifo_rd_valid, fifo_rd_empty;
    reg          fifo_rd_en;
    wire [4:0]   fifo_rd_level;

    // AXI slave
    reg         slave_awready, slave_wready;
    reg [1:0]   slave_bresp;
    wire [31:0]  m_axi_awaddr;
    wire         m_axi_awvalid, m_axi_awready;
    wire [7:0]   m_axi_awlen;
    wire         m_axi_wvalid, m_axi_wready;
    wire [255:0] m_axi_wdata;
    wire         m_axi_wlast;
    wire [31:0]  m_axi_wstrb;
    wire         m_axi_bvalid, m_axi_bready;

    integer cycle, txn;

    // DUT
    dma_axi_writer #(.AXI_DATA_WIDTH(256), .AXI_ADDR_WIDTH(32), .MAX_BURST_LEN(16)) u_dut (
        .clk(clk), .rst_n(rst_n), .start(start), .base_addr(base_addr),
        .byte_count(byte_count), .done(done), .error(error), .error_code(error_code),
        .busy(busy), .fifo_level(fifo_rd_level), .producer_done(producer_done),
        .data_in(fifo_rd_data), .data_valid(fifo_rd_valid), .data_ready(data_ready),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_wdata(m_axi_wdata), .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready), .m_axi_wlast(m_axi_wlast),
        .m_axi_wstrb(m_axi_wstrb), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );
    wire data_ready;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire [1:0]  m_axi_bresp;

    assign m_axi_awready = slave_awready;
    assign m_axi_wready  = slave_wready;
    assign m_axi_bvalid  = 1'b1;  // always respond
    assign m_axi_bresp   = slave_bresp;
    wire m_axi_awvalid_w, m_axi_wvalid_w, m_axi_bvalid_w;
    assign m_axi_awvalid_w = m_axi_awvalid;
    assign m_axi_wvalid_w  = m_axi_wvalid;
    wire data_in_256 = fifo_rd_data;
    wire data_valid_w = fifo_rd_valid;
    assign data_valid_w = fifo_rd_valid;
    assign fifo_rd_en = data_ready && fifo_rd_valid;

    write_beat_fifo #(16) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_data(fifo_wr_data), .wr_strb(fifo_wr_strb), .wr_last(fifo_wr_last),
        .wr_en(fifo_wr_en), .wr_full(fifo_wr_full),
        .rd_data(fifo_rd_data), .rd_strb(fifo_rd_strb), .rd_last(fifo_rd_last),
        .rd_valid(fifo_rd_valid), .rd_en(fifo_rd_en), .rd_empty(fifo_rd_empty),
        .rd_level(fifo_rd_level)
    );

    wire [31:0] bvalid_w;
    assign bvalid_w = m_axi_bvalid;

    // Clock
    always #5 clk = ~clk;

    initial begin
        clk = 0; rst_n = 0; cycle = 0; txn = 0;
        start = 0; producer_done = 0;
        base_addr = 0; byte_count = 0;
        fifo_wr_en = 0; fifo_wr_data = 0; fifo_wr_strb = 0; fifo_wr_last = 0;
        slave_awready = 1; slave_wready = 1; slave_bresp = 0;
        #15 rst_n = 1; #10;

        // ============================================================
        // Case 1: single 32-byte beat (N=8, one row)
        // ============================================================
        $display("[CASE1] T=%0t single 32-byte beat", $time);
        txn = 1;

        // Step 1: push beat into FIFO
        @(posedge clk); cycle++;
        fifo_wr_data <= 256'hDEAD_BEEF_CAFE_BABE_1111_2222_3333_4444_5555_6666_7777_8888_9999_AAAA_BBBB_CCCC_DDDD_EEEE;
        fifo_wr_strb <= 32'hFFFF_FFFF;
        fifo_wr_en   <= 1'b1;
        base_addr    <= 32'h0002_0000;
        byte_count   <= 32'd32;
        $display("  T=%0t push beat, start=0", $time);

        // Step 2: next cycle, set start=1 (same cycle as push settling)
        @(posedge clk); cycle++;
        fifo_wr_en   <= 1'b0;
        start        <= 1'b1;
        producer_done <= 1'b1;
        $display("  T=%0t start=1, producer_done=1", $time);

        // Step 3: next cycle, clear start=0
        @(posedge clk); cycle++;
        start        <= 1'b0;
        producer_done <= 1'b0;
        $display("  T=%0t start=0, wait done", $time);

        // Step 4: wait for done
        while (!done) begin
            @(posedge clk); cycle++;
        end
        $display("  T=%0t CASE1 done at cycle %0d", $time, cycle);

        // Gap before next transaction
        @(posedge clk); cycle++;
        @(posedge clk); cycle++;

        // ============================================================
        // Case 2: two back-to-back 32-byte beats
        // ============================================================
        $display("[CASE2] T=%0t two consecutive 32-byte beats", $time);
        for (txn = 1; txn <= 2; txn = txn + 1) begin
            // Push beat
            @(posedge clk); cycle++;
            fifo_wr_en <= 1'b1;
            fifo_wr_data <= txn == 1 ?
                256'hAAAA_BBBB_CCCC_DDDD_1111_2222_3333_4444_5555_6666_7777_8888_9999_0000_AAAA_BBBB_CCCC :
                256'hDDDD_EEEE_FFFF_0000_9999_8888_7777_6666_5555_4444_3333_2222_1111_0000_FFFF_EEEE_DDDD;
            base_addr <= 32'h0002_0000 + (txn-1) * 32;
            byte_count <= 32'd32;
            $display("  T=%0t txn=%0d push beat", $time, txn);

            // Start
            @(posedge clk); cycle++;
            fifo_wr_en <= 1'b0;
            start <= 1'b1;
            producer_done <= 1'b1;
            $display("  T=%0t txn=%0d start=1", $time, txn);

            // Clear start
            @(posedge clk); cycle++;
            start <= 1'b0;
            producer_done <= 1'b0;
            $display("  T=%0t txn=%0d start=0, wait done", $time, txn);

            // Wait done
            while (!done) begin
                @(posedge clk); cycle++;
            end
            $display("  T=%0t txn=%0d done at cycle %0d", $time, txn, cycle);

            // Gap
            @(posedge clk); cycle++;
            @(posedge clk); cycle++;
        end

        // ============================================================
        // Case 3: partial beat (N=65 last tile, 4 bytes)
        // ============================================================
        $display("[CASE3] T=%0t partial 4-byte beat", $time);
        @(posedge clk); cycle++;
        fifo_wr_en <= 1'b1;
        fifo_wr_data <= 256'hDDDD_CCCC_BBBB_AAAA_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0099;
        base_addr <= 32'h0002_0100;
        byte_count <= 32'd4;
        @(posedge clk); cycle++;
        fifo_wr_en <= 1'b0;
        start <= 1'b1;
        producer_done <= 1'b1;
        @(posedge clk); cycle++;
        start <= 1'b0;
        producer_done <= 1'b0;
        while (!done) @(posedge clk);
        $display("  T=%0t CASE3 done at cycle %0d", $time, cycle);

        // ============================================================
        // Case 4: start=1 in same cycle as FIFO push (simultaneous)
        // ============================================================
        $display("[CASE4] T=%0t push+start same cycle", $time);
        @(posedge clk); cycle++;
        fifo_wr_en <= 1'b1;
        fifo_wr_data <= 256'h1111_1111_2222_2222_3333_3333_4444_4444_5555_5555_6666_6666_7777_7777_8888_8888_9999;
        start <= 1'b1;          // same cycle!
        producer_done <= 1'b1;
        base_addr <= 32'h0002_0020;
        byte_count <= 32'd32;
        @(posedge clk); cycle++;
        fifo_wr_en <= 1'b0;
        start <= 1'b0;
        producer_done <= 1'b0;
        while (!done) @(posedge clk);
        $display("  T=%0t CASE4 done at cycle %0d", $time, cycle);

        // ============================================================
        // Case 5: minimal gap — start next immediately after done
        // ============================================================
        $display("[CASE5] T=%0t minimal gap between txns", $time);
        @(posedge clk); cycle++;
        fifo_wr_en <= 1'b1;
        fifo_wr_data <= 256'hAAAA_AAAA_BBBB_BBBB_CCCC_CCCC_DDDD_DDDD_EEEE_EEEE_FFFF_FFFF_0000_0000_1111_1111_2222;
        base_addr <= 32'h0002_0040;
        byte_count <= 32'd32;
        start <= 1'b1;
        producer_done <= 1'b1;
        @(posedge clk); cycle++;
        fifo_wr_en <= 1'b0;
        start <= 1'b0;
        producer_done <= 1'b0;
        while (!done) @(posedge clk);
        $display("  T=%0t txn1 done, start txn2 immediately", $time);
        // Start next txn on cycle after done
        @(posedge clk); cycle++;
        fifo_wr_en <= 1'b1;
        fifo_wr_data <= 256'h3333_3333_4444_4444_5555_5555_6666_6666_7777_7777_8888_8888_9999_9999_AAAA_AAAA_BBBB;
        base_addr <= 32'h0002_0060;
        byte_count <= 32'd32;
        start <= 1'b1;
        producer_done <= 1'b1;
        @(posedge clk); cycle++;
        fifo_wr_en <= 1'b0;
        start <= 1'b0;
        producer_done <= 1'b0;
        while (!done) @(posedge clk);
        $display("  T=%0t CASE5 done at cycle %0d", $time, cycle);

        // Summary
        $display("========================================");
        $display(" ALL CASES COMPLETE — check waveform");
        $display("========================================");
        #100 $finish;
    end

    // VCD dump
    initial begin
        $dumpfile("tb_dma_writer_per_beat_protocol.vcd");
        $dumpvars(0, tb_dma_writer_per_beat_protocol);
    end
endmodule
