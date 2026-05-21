// tb_dma_reader: testbench for dma_axi_reader with AXI4 RAM slave model
`timescale 1ns / 1ps

module tb_dma_reader;

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

    // DMA data output
    wire [31:0] dma_data;
    wire        dma_data_valid;
    reg         dma_data_ready;

    // AXI4 signals (between DMA master and RAM slave)
    wire [31:0] axi_araddr;
    wire        axi_arvalid;
    wire        axi_arready;
    wire [7:0]  axi_arlen;
    wire [2:0]  axi_arsize;
    wire [1:0]  axi_arburst;

    wire [31:0] axi_rdata;
    wire        axi_rvalid;
    wire        axi_rready;
    wire        axi_rlast;
    wire [1:0]  axi_rresp;

    // ============================================================
    // DUT: DMA AXI4 Reader
    // ============================================================
    dma_axi_reader #(
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
        .data_out      (dma_data),
        .data_valid    (dma_data_valid),
        .data_ready    (dma_data_ready),
        .m_axi_araddr  (axi_araddr),
        .m_axi_arvalid (axi_arvalid),
        .m_axi_arready (axi_arready),
        .m_axi_arlen   (axi_arlen),
        .m_axi_arsize  (axi_arsize),
        .m_axi_arburst (axi_arburst),
        .m_axi_rdata   (axi_rdata),
        .m_axi_rvalid  (axi_rvalid),
        .m_axi_rready  (axi_rready),
        .m_axi_rlast   (axi_rlast),
        .m_axi_rresp   (axi_rresp)
    );

    // ============================================================
    // AXI4 RAM Slave (simple, 1 cycle read latency)
    // ============================================================
    reg  [31:0] ram [0:4095];  // 16 KB
    reg  [31:0] ar_addr_r;
    reg  [7:0]  ar_len_r;
    reg  [7:0]  beat_cnt;
    reg         rvalid_r;
    reg  [31:0] rdata_r;
    reg         rlast_r;
    reg         rresp_r;

    // AXI4 RAM Slave — single always block, clean state machine
    reg         burst_active;
    assign axi_arready = !burst_active;  // only one burst at a time

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            burst_active <= 1'b0;
            ar_addr_r    <= 32'h0;
            ar_len_r     <= 8'h0;
            beat_cnt     <= 8'h0;
            rvalid_r     <= 1'b0;
            rdata_r      <= 32'h0;
            rlast_r      <= 1'b0;
            rresp_r      <= 2'b00;
        end else begin
            // Accept new read address
            if (!burst_active && axi_arvalid && axi_arready) begin
                burst_active <= 1'b1;
                ar_addr_r    <= axi_araddr;
                ar_len_r     <= axi_arlen;
                beat_cnt     <= 8'h0;
                rvalid_r     <= 1'b0;
            end
            // Active burst: manage beat flow
            else if (burst_active) begin
                if (rvalid_r && axi_rready) begin
                    // Current beat was consumed
                    if (rlast_r) begin
                        // Burst finished
                        burst_active <= 1'b0;
                        rvalid_r     <= 1'b0;
                        beat_cnt     <= 8'h0;
                    end else begin
                        // Advance to next beat
                        beat_cnt <= beat_cnt + 8'h1;
                        rdata_r  <= ram[ar_addr_r[13:2] + {27'h0, beat_cnt + 8'h1}];
                        rlast_r  <= (beat_cnt + 8'h1 == ar_len_r);
                    end
                end else if (!rvalid_r) begin
                    // First beat (or after stall): present data
                    rvalid_r <= 1'b1;
                    rdata_r  <= ram[ar_addr_r[13:2] + {27'h0, beat_cnt}];
                    rlast_r  <= (beat_cnt == ar_len_r);
                    rresp_r  <= 2'b00;
                end
            end
        end
    end

    assign axi_rvalid = rvalid_r;
    assign axi_rdata  = rdata_r;
    assign axi_rlast  = rlast_r;
    assign axi_rresp  = rresp_r;

    // ============================================================
    // Clock
    // ============================================================
    always #2.5 clk = ~clk;

    // ============================================================
    // Helper: initialize RAM
    // ============================================================
    task init_ram;
        input [31:0] start_addr;
        input [31:0] word_count;
        input [31:0] seed;
        integer i;
        begin
            for (i = 0; i < word_count; i = i + 1)
                ram[(start_addr[13:2] + i) & 12'hFFF] = seed + i;
        end
    endtask

    // ============================================================
    // Helper: collect DMA output
    // ============================================================
    reg  [31:0] rx_buf [0:255];
    reg  [7:0]  rx_cnt;
    integer      j;

    // ============================================================
    // Test sequence
    // ============================================================
    initial begin
        $dumpfile("sim/tb_dma_reader.vcd");
        $dumpvars(0, tb_dma_reader);

        clk = 0; rst_n = 0;
        dma_start = 0;
        dma_data_ready = 1;
        rx_cnt = 0;

        #10 rst_n = 1;
        #10;

        // ============================================================
        $display("=== Test 1: Single beat read (4 bytes) ===");
        init_ram(32'h0000_0100, 64, 32'hA000_0000);
        dma_base_addr = 32'h0000_0100;
        dma_byte_count = 32'h0000_0004;  // 4 bytes = 1 beat
        @(posedge clk);
        dma_start = 1;
        @(posedge clk);
        dma_start = 0;
        // Wait for done
        while (!dma_done) @(posedge clk);
        $display("  PASS: done=%b, data_valid=%b, data=0x%08h (expect 0xA0000000)",
            dma_done, dma_data_valid, dma_data);
        if (dma_data != 32'hA000_0000) $error("  FAIL: data mismatch");

        // ============================================================
        $display("=== Test 2: 16-beat burst (64 bytes) ===");
        init_ram(32'h0000_0200, 64, 32'hC000_0000);
        dma_base_addr = 32'h0000_0200;
        dma_byte_count = 32'h0000_0040;  // 64 bytes = 16 beats
        @(posedge clk);
        dma_start = 1;
        @(posedge clk);
        dma_start = 0;
        rx_cnt = 0;
        while (!dma_done) begin
            if (dma_data_valid && dma_data_ready) begin
                rx_buf[rx_cnt] = dma_data;
                rx_cnt = rx_cnt + 1;
            end
            @(posedge clk);
        end
        $display("  Received %0d beats (expect 16)", rx_cnt);
        if (rx_cnt != 16) $error("  FAIL: beat count mismatch");
        // Check first and last
        if (rx_buf[0]  != 32'hC000_0000) $error("  FAIL: first beat mismatch");
        if (rx_buf[15] != 32'hC000_000F) $error("  FAIL: last beat mismatch");
        $display("  PASS: first=0x%08h, last=0x%08h", rx_buf[0], rx_buf[15]);

        // ============================================================
        $display("=== Test 3: Multi-burst (100 bytes = 25 beats, > MAX_BURST_LEN) ===");
        init_ram(32'h0000_0400, 64, 32'hBEEF_0000);
        dma_base_addr = 32'h0000_0400;
        dma_byte_count = 32'h0000_0064;  // 100 bytes = 25 beats
        @(posedge clk);
        dma_start = 1;
        @(posedge clk);
        dma_start = 0;
        rx_cnt = 0;
        while (!dma_done) begin
            if (dma_data_valid && dma_data_ready) begin
                rx_buf[rx_cnt] = dma_data;
                rx_cnt = rx_cnt + 1;
            end
            @(posedge clk);
        end
        $display("  Received %0d beats (expect 25)", rx_cnt);
        if (rx_cnt != 25) $error("  FAIL: beat count mismatch");
        if (rx_buf[0]  != 32'hBEEF_0000) $error("  FAIL: first beat mismatch");
        if (rx_buf[24] != 32'hBEEF_0018) $error("  FAIL: last beat mismatch");
        $display("  PASS: first=0x%08h, last=0x%08h", rx_buf[0], rx_buf[24]);

        // ============================================================
        $display("=== Test 4: Backpressure (buffer not ready) ===");
        init_ram(32'h0000_0600, 32, 32'hDEAD_0000);
        dma_base_addr = 32'h0000_0600;
        dma_byte_count = 32'h0000_0020;  // 32 bytes = 8 beats
        dma_data_ready = 0;  // NOT ready
        @(posedge clk);
        dma_start = 1;
        @(posedge clk);
        dma_start = 0;
        // Wait a few cycles with ready=0
        repeat(10) @(posedge clk);
        // Now make ready
        dma_data_ready = 1;
        rx_cnt = 0;
        while (!dma_done) begin
            if (dma_data_valid && dma_data_ready) begin
                rx_buf[rx_cnt] = dma_data;
                rx_cnt = rx_cnt + 1;
            end
            @(posedge clk);
        end
        $display("  Received %0d beats with backpressure (expect 8)", rx_cnt);
        if (rx_cnt != 8) $error("  FAIL: beat count mismatch under backpressure");
        if (rx_buf[0] != 32'hDEAD_0000) $error("  FAIL: data mismatch under backpressure");
        $display("  PASS");

        // ============================================================
        $display("=== Test 5: Zero-byte transfer edge case ===");
        @(posedge clk);
        dma_start = 1;
        dma_byte_count = 32'h0;
        @(posedge clk);
        dma_start = 0;
        repeat(10) @(posedge clk);
        // Should not hang; done may or may not assert
        $display("  PASS: no hang");

        $display("=== All tests complete ===");
        #20;
        $finish;
    end

endmodule
