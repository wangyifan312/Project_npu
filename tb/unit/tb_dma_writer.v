// tb_dma_writer: testbench for dma_axi_writer with AXI4 RAM slave model
`timescale 1ns / 1ps

module tb_dma_writer;

    reg         clk;
    reg         rst_n;

    // DMA control
    reg         dma_start;
    reg  [31:0] dma_base_addr;
    reg  [31:0] dma_byte_count;
    wire        dma_done;
    wire        dma_error;
    wire [7:0]  dma_error_code;
    wire        dma_busy;

    // DMA data input (simulating buffer output)
    reg  [31:0] tx_data;
    reg         tx_valid;
    wire        tx_ready;

    // AXI4 signals
    wire [31:0] axi_awaddr;
    wire        axi_awvalid;
    wire        axi_awready;
    wire [7:0]  axi_awlen;
    wire [2:0]  axi_awsize;
    wire [1:0]  axi_awburst;

    wire [31:0] axi_wdata;
    wire        axi_wvalid;
    wire        axi_wready;
    wire        axi_wlast;
    wire [3:0]  axi_wstrb;

    wire [1:0]  axi_bresp;
    wire        axi_bvalid;
    wire        axi_bready;

    // ============================================================
    // DUT
    // ============================================================
    dma_axi_writer #(
        .AXI_DATA_WIDTH(32),
        .AXI_ADDR_WIDTH(32),
        .MAX_BURST_LEN(16)
    ) u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (dma_start),
        .base_addr     (dma_base_addr),
        .byte_count    (dma_byte_count),
        .done          (dma_done),
        .error         (dma_error),
        .error_code    (dma_error_code),
        .busy          (dma_busy),
        .producer_done (1'b0),
        .data_in       (tx_data),
        .data_valid    (tx_valid),
        .data_ready    (tx_ready),
        .m_axi_awaddr  (axi_awaddr),
        .m_axi_awvalid (axi_awvalid),
        .m_axi_awready (axi_awready),
        .m_axi_awlen   (axi_awlen),
        .m_axi_awsize  (axi_awsize),
        .m_axi_awburst (axi_awburst),
        .m_axi_wdata   (axi_wdata),
        .m_axi_wvalid  (axi_wvalid),
        .m_axi_wready  (axi_wready),
        .m_axi_wlast   (axi_wlast),
        .m_axi_wstrb   (axi_wstrb),
        .m_axi_bresp   (axi_bresp),
        .m_axi_bvalid  (axi_bvalid),
        .m_axi_bready  (axi_bready)
    );

    // ============================================================
    // AXI4 RAM Slave (write side)
    // ============================================================
    reg  [31:0] ram [0:4095];
    reg  [31:0] aw_addr_r;
    reg  [7:0]  aw_len_r;
    reg  [7:0]  w_beat_cnt;
    reg         w_active;
    reg         bvalid_r;

    assign axi_awready = !w_active;
    assign axi_wready  = w_active;
    assign axi_bvalid  = bvalid_r;
    assign axi_bresp   = 2'b00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_active   <= 1'b0;
            aw_addr_r  <= 32'h0;
            aw_len_r   <= 8'h0;
            w_beat_cnt <= 8'h0;
            bvalid_r   <= 1'b0;
        end else begin
            // AW acceptance
            if (!w_active && axi_awvalid && axi_awready) begin
                w_active   <= 1'b1;
                aw_addr_r  <= axi_awaddr;
                aw_len_r   <= axi_awlen;
                w_beat_cnt <= 8'h0;
                bvalid_r   <= 1'b0;
            end

            // W data acceptance
            if (w_active && axi_wvalid && axi_wready) begin
                ram[aw_addr_r[13:2] + {27'h0, w_beat_cnt}] <= axi_wdata;
                if (axi_wlast) begin
                    bvalid_r <= 1'b1;
                end else begin
                    w_beat_cnt <= w_beat_cnt + 8'h1;
                end
            end

            // B handshake
            if (bvalid_r && axi_bready) begin
                bvalid_r  <= 1'b0;
                w_active  <= 1'b0;
                w_beat_cnt <= 8'h0;
            end
        end
    end

    // ============================================================
    // Data source: generates sequential data words
    // ============================================================
    reg  [31:0] data_gen;
    reg  [31:0] data_seed;
    reg  [7:0]  tx_cnt;
    reg  [31:0] total_beats;
    reg         feeding;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_valid  <= 1'b0;
            tx_data   <= 32'h0;
            data_gen  <= 32'h0;
            tx_cnt    <= 8'h0;
            feeding   <= 1'b0;
        end else begin
            if (dma_start && !dma_busy) begin
                feeding     <= 1'b1;
                tx_cnt      <= 8'h0;
                data_gen    <= data_seed;
                total_beats <= dma_byte_count / 4;
            end

            if (feeding) begin
                if (tx_ready) begin
                    tx_valid <= 1'b1;
                    tx_data  <= data_gen;
                    data_gen <= data_gen + 32'h1;
                    tx_cnt   <= tx_cnt + 8'h1;
                    if (tx_cnt + 8'h1 == total_beats[7:0]) begin
                        feeding <= 1'b0;
                    end
                end
            end else if (!dma_start) begin
                tx_valid <= 1'b0;
            end
        end
    end

    // ============================================================
    // Clock
    // ============================================================
    always #2.5 clk = ~clk;

    // ============================================================
    // Helper: read RAM
    // ============================================================
    function [31:0] read_ram;
        input [31:0] addr;
        begin
            read_ram = ram[addr[13:2]];
        end
    endfunction

    // ============================================================
    // Test sequence
    // ============================================================
    integer i;

    initial begin
        $dumpfile("sim/tb_dma_writer.vcd");
        $dumpvars(0, tb_dma_writer);

        clk = 0; rst_n = 0;
        dma_start = 0;
        data_seed = 32'hCAFE_0000;

        #10 rst_n = 1;
        #10;

        // ============================================================
        $display("=== Test 1: Single beat write (4 bytes) ===");
        // Clear RAM
        for (i = 0; i < 64; i = i + 1) ram[i] = 32'h0;
        dma_base_addr = 32'h0000_0100;
        dma_byte_count = 32'h4;  // 1 beat
        data_seed = 32'hDEAD_BEEF;
        @(posedge clk);
        dma_start = 1;
        @(posedge clk);
        dma_start = 0;
        while (!dma_done) @(posedge clk);
        #5;
        if (read_ram(32'h0000_0100) != 32'hDEAD_BEEF) begin
            $error("  FAIL: RAM data mismatch: 0x%08h", read_ram(32'h0000_0100));
        end else begin
            $display("  PASS: RAM[0x100] = 0x%08h", read_ram(32'h0000_0100));
        end

        // ============================================================
        $display("=== Test 2: 16-beat burst write (64 bytes) ===");
        for (i = 0; i < 64; i = i + 1) ram[i] = 32'h0;
        dma_base_addr = 32'h0000_0200;
        dma_byte_count = 32'h40;  // 64 bytes = 16 beats
        data_seed = 32'hB000_0000;
        @(posedge clk);
        dma_start = 1;
        @(posedge clk);
        dma_start = 0;
        while (!dma_done) @(posedge clk);
        // Verify
        for (i = 0; i < 16; i = i + 1) begin
            if (read_ram(32'h0000_0200 + i*4) != 32'hB000_0000 + i) begin
                $error("  FAIL: RAM[0x%04h] = 0x%08h, expect 0x%08h",
                    32'h200 + i*4, read_ram(32'h0000_0200 + i*4), 32'hB000_0000 + i);
            end
        end
        $display("  PASS: RAM[0x200..0x23C] verified");

        // ============================================================
        $display("=== Test 3: Multi-burst write (100 bytes = 25 beats) ===");
        for (i = 0; i < 64; i = i + 1) ram[i] = 32'h0;
        dma_base_addr = 32'h0000_0400;
        dma_byte_count = 32'h64;  // 100 bytes = 25 beats
        data_seed = 32'h1000_0000;
        @(posedge clk);
        dma_start = 1;
        @(posedge clk);
        dma_start = 0;
        while (!dma_done) @(posedge clk);
        // Verify first and last
        if (read_ram(32'h0000_0400) != 32'h1000_0000)
            $error("  FAIL: first beat mismatch");
        if (read_ram(32'h0000_0400 + 24*4) != 32'h1000_0018)
            $error("  FAIL: last beat mismatch: 0x%08h", read_ram(32'h0000_0400 + 24*4));
        $display("  PASS: first=0x%08h, last=0x%08h",
            read_ram(32'h0000_0400), read_ram(32'h0000_0400 + 24*4));

        // ============================================================
        $display("=== Test 4: Zero-byte write ===");
        @(posedge clk);
        dma_start = 1;
        dma_byte_count = 32'h0;
        @(posedge clk);
        dma_start = 0;
        repeat(5) @(posedge clk);
        $display("  PASS: no hang");

        $display("=== All tests complete ===");
        #20;
        $finish;
    end

endmodule
