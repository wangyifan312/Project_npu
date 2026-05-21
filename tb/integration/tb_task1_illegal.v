// tb_task1_illegal: verify that illegal tasks are rejected BEFORE any DMA activity
// Task 1 acceptance test — parameter check must complete before execution starts
`timescale 1ns / 1ps

module tb_task1_illegal;
    reg clk, rst_n;

    // AXI-Lite
    reg  s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    wire s_axi_awready, s_axi_wready, s_axi_bvalid;
    reg  [31:0] s_axi_awaddr, s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    wire [1:0]  s_axi_bresp;
    reg  s_axi_arvalid, s_axi_rready;
    wire s_axi_arready, s_axi_rvalid;
    reg  [31:0] s_axi_araddr;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;

    // AXI4 DMA
    wire        npu_arvalid, npu_arready;
    wire [31:0] npu_araddr;
    wire [7:0]  npu_arlen;
    wire [2:0]  npu_arsize;
    wire [1:0]  npu_arburst;
    wire        npu_rvalid, npu_rready;
    wire [31:0] npu_rdata;
    wire        npu_rlast;
    wire [1:0]  npu_rresp;
    wire        npu_awvalid, npu_awready;
    wire [31:0] npu_awaddr;
    wire [7:0]  npu_awlen;
    wire [2:0]  npu_awsize;
    wire [1:0]  npu_awburst;
    wire        npu_wvalid, npu_wready;
    wire [31:0] npu_wdata;
    wire        npu_wlast;
    wire [3:0]  npu_wstrb;
    wire        npu_bvalid, npu_bready;
    wire [1:0]  npu_bresp;
    wire        npu_busy, npu_done, npu_error;
    wire [7:0]  npu_error_code;

    reg  preload;

    // RAM signals
    wire ram_awvalid = preload ? 1'b0 : npu_awvalid;
    wire [31:0] ram_awaddr = npu_awaddr;
    wire [7:0]  ram_awlen = npu_awlen;
    wire [2:0]  ram_awsize = npu_awsize;
    wire [1:0]  ram_awburst = npu_awburst;
    wire ram_wvalid = preload ? 1'b0 : npu_wvalid;
    wire [31:0] ram_wdata = npu_wdata;
    wire [3:0]  ram_wstrb = npu_wstrb;
    wire ram_wlast = npu_wlast;
    wire ram_bready = npu_bready;
    wire ram_arvalid = preload ? 1'b0 : npu_arvalid;
    wire [31:0] ram_araddr = npu_araddr;
    wire [7:0]  ram_arlen = npu_arlen;
    wire [2:0]  ram_arsize = npu_arsize;
    wire [1:0]  ram_arburst = npu_arburst;
    wire ram_rready = npu_rready;
    wire ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0] ram_bresp, ram_rresp;
    wire ram_rvalid, ram_rlast;
    wire [31:0] ram_rdata;

    assign npu_arready = preload ? 1'b0 : ram_arready;
    assign npu_awready = preload ? 1'b0 : ram_awready;
    assign npu_wready  = preload ? 1'b0 : ram_wready;
    assign npu_rvalid  = preload ? 1'b0 : ram_rvalid;
    assign npu_bvalid  = preload ? 1'b0 : ram_bvalid;
    assign npu_rdata   = ram_rdata;
    assign npu_rlast   = ram_rlast;
    assign npu_rresp   = preload ? 2'b0 : ram_rresp;
    assign npu_bresp   = preload ? 2'b0 : ram_bresp;

    // NPU
    npu_top #(.TILE_ROWS(7), .TILE_COLS(2), .BUF_ENTRIES(256), .BUF_ADDR_W(8)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr),   .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),   .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),     .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),   .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_araddr(s_axi_araddr),   .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),   .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .m_axi_arvalid(npu_arvalid),   .m_axi_arready(npu_arready),
        .m_axi_araddr(npu_araddr),     .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize),     .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(npu_rvalid),     .m_axi_rready(npu_rready),
        .m_axi_rdata(npu_rdata),       .m_axi_rlast(npu_rlast),
        .m_axi_rresp(npu_rresp),
        .m_axi_awvalid(npu_awvalid),   .m_axi_awready(npu_awready),
        .m_axi_awaddr(npu_awaddr),     .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize),     .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid),     .m_axi_wready(npu_wready),
        .m_axi_wdata(npu_wdata),       .m_axi_wlast(npu_wlast),
        .m_axi_wstrb(npu_wstrb),       .m_axi_bvalid(npu_bvalid),
        .m_axi_bready(npu_bready),     .m_axi_bresp(npu_bresp),
        .npu_busy(npu_busy),           .npu_done(npu_done),
        .npu_error(npu_error),         .npu_error_code(npu_error_code)
    );

    axi4_ram #(.RAM_DEPTH(16384)) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(ram_awvalid), .s_axi_awready(ram_awready),
        .s_axi_awaddr(ram_awaddr),   .s_axi_awlen(ram_awlen),
        .s_axi_awsize(ram_awsize),   .s_axi_awburst(ram_awburst),
        .s_axi_wvalid(ram_wvalid),   .s_axi_wready(ram_wready),
        .s_axi_wdata(ram_wdata),     .s_axi_wstrb(ram_wstrb),
        .s_axi_wlast(ram_wlast),     .s_axi_bvalid(ram_bvalid),
        .s_axi_bready(ram_bready),   .s_axi_bresp(ram_bresp),
        .s_axi_arvalid(ram_arvalid), .s_axi_arready(ram_arready),
        .s_axi_araddr(ram_araddr),   .s_axi_arlen(ram_arlen),
        .s_axi_arsize(ram_arsize),   .s_axi_arburst(ram_arburst),
        .s_axi_rvalid(ram_rvalid),   .s_axi_rready(ram_rready),
        .s_axi_rdata(ram_rdata),     .s_axi_rlast(ram_rlast),
        .s_axi_rresp(ram_rresp)
    );

    always #2.5 clk = ~clk;

    // Track if any AXI transaction occurred
    reg any_ar, any_aw;
    always @(posedge clk) begin
        if (npu_arvalid && npu_arready) any_ar <= 1'b1;
        if (npu_awvalid && npu_awready) any_aw <= 1'b1;
    end

    task axi_write;
        input [31:0] addr, data;
        begin
            @(posedge clk);
            s_axi_awvalid=1; s_axi_awaddr=addr; s_axi_wvalid=1; s_axi_wdata=data; s_axi_wstrb=4'hF;
            @(posedge clk); s_axi_awvalid=0; s_axi_wvalid=0;
            @(posedge clk); s_axi_bready=1;
            @(posedge clk); s_axi_bready=0;
        end
    endtask

    task axi_read;
        input [31:0] addr; output [31:0] data;
        begin
            @(posedge clk); s_axi_arvalid=1; s_axi_araddr=addr;
            @(posedge clk); s_axi_arvalid=0;
            @(posedge clk); data=s_axi_rdata; s_axi_rready=1;
            @(posedge clk); s_axi_rready=0;
        end
    endtask

    reg [31:0] rd_val;
    reg        test_pass;

    initial begin
        $dumpfile("sim/tb_task1_illegal.vcd");
        $dumpvars(0, tb_task1_illegal);

        clk=0; rst_n=0; preload=0;
        s_axi_awvalid=0; s_axi_wvalid=0; s_axi_bready=0;
        s_axi_arvalid=0; s_axi_rready=0;
        any_ar=0; any_aw=0; test_pass=1;

        #20 rst_n=1;
        #20;

        // ============================================================
        // Test A: Invalid task_type (3 is undefined)
        // ============================================================
        $display("=== Test A: invalid task_type=3 ===");
        any_ar = 0; any_aw = 0;
        axi_write(32'h1000_0008, 32'h0000_0003);  // TASK_TYPE=3 (invalid)
        axi_write(32'h1000_000C, 32'h0000_0100);  // input_addr
        axi_write(32'h1000_0010, 32'h0000_0200);  // weight_addr
        axi_write(32'h1000_0014, 32'h0000_0300);  // output_addr
        axi_write(32'h1000_0018, 32'h0000_0019);  // input_bytes=25
        axi_write(32'h1000_001C, 32'h0000_0019);  // weight_bytes=25
        axi_write(32'h1000_0020, 32'h0000_0004);  // output_bytes=4
        axi_write(32'h1000_0024, 32'h0005_0005);  // H=5,W=5
        axi_write(32'h1000_0028, 32'h0001_0001);
        axi_write(32'h1000_002C, 32'h0);
        axi_write(32'h1000_0000, 32'h0000_0001);  // start=1

        repeat(200) @(posedge clk);
        axi_read(32'h1000_0000, rd_val);
        $display("  CTRL=0x%08h busy=%b done=%b error=%b", rd_val, rd_val[1], rd_val[2], rd_val[3]);

        if (rd_val[3] && !rd_val[2] && !any_ar && !any_aw) begin
            $display("  PASS: error=1, done=0, no DMA activity");
        end else begin
            $display("  FAIL: error=%b done=%b any_ar=%b any_aw=%b", rd_val[3], rd_val[2], any_ar, any_aw);
            test_pass = 0;
        end

        // Clear error
        axi_write(32'h1000_0000, 32'h0000_0010);  // clear error

        // ============================================================
        // Test B: Zero input_bytes
        // ============================================================
        $display("=== Test B: zero input_bytes ===");
        any_ar = 0; any_aw = 0;
        axi_write(32'h1000_0008, 32'h0000_0000);  // Conv
        axi_write(32'h1000_0018, 32'h0000_0000);  // input_bytes=0
        axi_write(32'h1000_0000, 32'h0000_0001);  // start=1

        repeat(200) @(posedge clk);
        axi_read(32'h1000_0000, rd_val);
        $display("  CTRL=0x%08h busy=%b done=%b error=%b", rd_val, rd_val[1], rd_val[2], rd_val[3]);

        if (rd_val[3] && !rd_val[2] && !any_ar && !any_aw) begin
            $display("  PASS: error=1, done=0, no DMA activity");
        end else begin
            $display("  FAIL: error=%b done=%b any_ar=%b any_aw=%b", rd_val[3], rd_val[2], any_ar, any_aw);
            test_pass = 0;
        end

        // ============================================================
        $display("=== Final: %s ===", test_pass ? "ALL PASS" : "SOME FAILED");
        #20 $finish;
    end
endmodule
