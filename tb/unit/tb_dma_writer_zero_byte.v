// tb_dma_writer_zero_byte: tests B9 — zero-byte and edge-case boundaries
`timescale 1ns / 1ps

module tb_dma_writer_zero_byte;

    reg clk, rst_n;
    reg start;
    reg [31:0] base_addr;
    reg [31:0] byte_count;
    wire done, error, busy, write_txn_active;
    wire [7:0] error_code;
    wire [4:0] fifo_level;
    wire [255:0] data_in;
    wire data_valid;
    wire data_ready;
    wire [31:0] m_axi_awaddr;
    wire m_axi_awvalid, m_axi_awready;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire [255:0] m_axi_wdata;
    wire m_axi_wvalid, m_axi_wready;
    wire m_axi_wlast;
    wire [31:0] m_axi_wstrb;
    wire [1:0] m_axi_bresp;
    wire m_axi_bvalid, m_axi_bready;

    reg [255:0] fifo_wr_data;
    reg [31:0] fifo_wr_strb;
    reg fifo_wr_last, fifo_wr_en;
    wire fifo_wr_full;
    wire [255:0] fifo_rd_data;
    wire [31:0] fifo_rd_strb;
    wire fifo_rd_last, fifo_rd_valid, fifo_rd_empty;
    reg  fifo_rd_en;
    wire [4:0] fifo_rd_level;

    dma_axi_writer #(.AXI_DATA_WIDTH(256), .AXI_ADDR_WIDTH(32), .MAX_BURST_LEN(16)) u_dut (
        .clk,.rst_n,.start,.base_addr,.byte_count,.done,.error,.error_code,.busy,
        .write_txn_active,.fifo_level(fifo_rd_level),
        .data_in(fifo_rd_data),.data_valid(fifo_rd_valid),.data_ready(data_ready),
        .m_axi_awaddr,.m_axi_awvalid,.m_axi_awready,.m_axi_awlen,.m_axi_awsize,.m_axi_awburst,
        .m_axi_wdata,.m_axi_wvalid,.m_axi_wready,.m_axi_wlast,.m_axi_wstrb,
        .m_axi_bresp,.m_axi_bvalid,.m_axi_bready
    );

    assign data_in = fifo_rd_data;
    assign data_valid = fifo_rd_valid;
    assign fifo_rd_en = data_ready && fifo_rd_valid;

    write_beat_fifo #(16) u_fifo (
        .clk,.rst_n,.wr_data(fifo_wr_data),.wr_strb(fifo_wr_strb),.wr_last(fifo_wr_last),
        .wr_en(fifo_wr_en),.wr_full(fifo_wr_full),
        .rd_data(fifo_rd_data),.rd_strb(fifo_rd_strb),.rd_last(fifo_rd_last),
        .rd_valid(fifo_rd_valid),.rd_en(fifo_rd_en),.rd_empty(fifo_rd_empty),
        .rd_level(fifo_rd_level)
    );

    reg slave_awready, slave_wready;
    reg [1:0] slave_bresp;
    reg slave_bvalid, wlast_seen;
    assign m_axi_awready = slave_awready;
    assign m_axi_wready = slave_wready;
    assign m_axi_bresp = slave_bresp;
    assign m_axi_bvalid = slave_bvalid;

    always #5 clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wlast_seen <= 0; slave_bvalid <= 0;
        end else begin
            if (m_axi_wvalid && m_axi_wready && m_axi_wlast) wlast_seen <= 1;
            if (wlast_seen && !slave_bvalid) slave_bvalid <= 1;
            if (m_axi_bvalid && m_axi_bready) begin slave_bvalid <= 0; wlast_seen <= 0; end
        end
    end

    integer pass, fail;
    initial begin
        clk = 0; rst_n = 0;
        start = 0; base_addr = 32'h1000;
        fifo_wr_en = 0; fifo_wr_data = 0; fifo_wr_strb = 32'hFFFFFFFF; fifo_wr_last = 0;
        slave_awready = 1; slave_wready = 1; slave_bresp = 2'b00;
        pass = 0; fail = 0;

        repeat(10) @(posedge clk); rst_n = 1; repeat(5) @(posedge clk);

        // Test 1: byte_count = 0 (zero-byte write)
        $display("[%0t] Test 1: byte_count=0", $time);
        byte_count = 32'h0;
        start <= 1; @(posedge clk); start <= 0;
        // Writer should go S_IDLE -> S_DONE immediately
        wait(done || error);
        @(posedge clk);
        if (done && !error && !m_axi_awvalid) begin
            $display("  PASS: zero-byte done without AW"); pass = pass + 1;
        end else begin
            $display("  FAIL: done=%b error=%b awvalid=%b", done, error, m_axi_awvalid);
            fail = fail + 1;
        end
        wait(!busy);

        // Test 2: 1 byte (smallest non-zero)
        $display("[%0t] Test 2: byte_count=1", $time);
        byte_count = 32'h1;
        start <= 1; @(posedge clk); start <= 0;
        // Fill 1 beat into FIFO
        @(posedge clk); fifo_wr_data = 256'h1; fifo_wr_en = 1;
        @(posedge clk); fifo_wr_en = 0;
        wait(done || error);
        @(posedge clk);
        if (done && !error) begin
            $display("  PASS: 1-byte write done"); pass = pass + 1;
        end else begin
            $display("  FAIL: 1-byte write failed"); fail = fail + 1;
        end
        wait(!busy);

        // Test 3: 32 bytes (exact 1 beat)
        $display("[%0t] Test 3: byte_count=32", $time);
        byte_count = 32'h20;
        start <= 1; @(posedge clk); start <= 0;
        @(posedge clk); fifo_wr_data = 256'h20; fifo_wr_en = 1;
        @(posedge clk); fifo_wr_en = 0;
        wait(done);
        @(posedge clk);
        if (!error) begin
            $display("  PASS: 32-byte write done"); pass = pass + 1;
        end else begin
            $display("  FAIL"); fail = fail + 1;
        end
        wait(!busy);

        // Test 4: misaligned address rejection
        $display("[%0t] Test 4: misaligned address", $time);
        // Ensure writer fully idle from previous test
        repeat(5) @(posedge clk);
        base_addr = 32'h1001;  // not 32B aligned
        byte_count = 32;
        start <= 1; @(posedge clk); start <= 0;
        // error_r pulses for 1 cycle; capture it before it auto-clears
        fork : wait_err
            begin
                wait(error);
                $display("  error detected: code=%h", error_code);
            end
            begin
                repeat(100) @(posedge clk);
                $display("  timeout waiting for error");
            end
        join_any
        disable fork;
        if (error && error_code == 8'h31) begin
            $display("  PASS: misaligned rejected with code 0x31"); pass = pass + 1;
        end else begin
            $display("  FAIL: error=%b code=%h", error, error_code); fail = fail + 1;
        end
        base_addr = 32'h1000;
        start = 0;
        repeat(5) @(posedge clk);  // let writer return to idle

        $display("[%0t] === %0d PASS, %0d FAIL ===", $time, pass, fail);
        if (fail > 0) $display("FAIL"); else $display("PASS");
        $finish;
    end

    initial begin #300000; $display("TIMEOUT"); $finish; end
endmodule
