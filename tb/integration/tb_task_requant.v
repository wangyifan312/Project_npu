`timescale 1ns / 1ps

module tb_task_requant;

    reg clk, rst_n;

    reg         s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    wire        s_axi_awready, s_axi_wready, s_axi_bvalid;
    reg  [31:0] s_axi_awaddr, s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    wire [1:0]  s_axi_bresp;
    reg         s_axi_arvalid, s_axi_rready;
    wire        s_axi_arready, s_axi_rvalid;
    reg  [31:0] s_axi_araddr;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;

    wire        npu_arvalid, npu_awvalid;
    wire [31:0] npu_araddr, npu_awaddr;
    wire [7:0]  npu_arlen, npu_awlen;
    wire [2:0]  npu_arsize, npu_awsize;
    wire [1:0]  npu_arburst, npu_awburst;
    wire        npu_wvalid, npu_wlast;
    wire [31:0] npu_wdata;
    wire [3:0]  npu_wstrb;
    wire        npu_rready, npu_bready;
    wire        npu_busy, npu_done, npu_error;
    wire [7:0]  npu_error_code;

    reg         preload;
    reg         tb_awvalid, tb_wvalid;
    reg  [31:0] tb_awaddr, tb_wdata;

    wire        ram_awvalid = preload ? tb_awvalid : npu_awvalid;
    wire [31:0] ram_awaddr  = preload ? tb_awaddr  : npu_awaddr;
    wire [7:0]  ram_awlen   = preload ? 8'h0       : npu_awlen;
    wire [2:0]  ram_awsize  = preload ? 3'd2       : npu_awsize;
    wire [1:0]  ram_awburst = preload ? 2'd1       : npu_awburst;
    wire        ram_wvalid  = preload ? tb_wvalid  : npu_wvalid;
    wire [31:0] ram_wdata   = preload ? tb_wdata   : npu_wdata;
    wire [3:0]  ram_wstrb   = preload ? 4'hF       : npu_wstrb;
    wire        ram_wlast   = preload ? 1'b1       : npu_wlast;
    wire        ram_bready  = preload ? 1'b1       : npu_bready;
    wire        ram_arvalid = preload ? 1'b0       : npu_arvalid;
    wire [31:0] ram_araddr  = preload ? 32'h0      : npu_araddr;
    wire [7:0]  ram_arlen   = preload ? 8'h0       : npu_arlen;
    wire [2:0]  ram_arsize  = preload ? 3'd2       : npu_arsize;
    wire [1:0]  ram_arburst = preload ? 2'd1       : npu_arburst;
    wire        ram_rready  = preload ? 1'b0       : npu_rready;

    wire        ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0]  ram_bresp, ram_rresp;
    wire        ram_rvalid, ram_rlast;
    wire [31:0] ram_rdata;

    wire        npu_arready = preload ? 1'b0 : ram_arready;
    wire        npu_awready = preload ? 1'b0 : ram_awready;
    wire        npu_wready  = preload ? 1'b0 : ram_wready;
    wire        npu_rvalid  = preload ? 1'b0 : ram_rvalid;
    wire        npu_bvalid  = preload ? 1'b0 : ram_bvalid;
    wire [31:0] npu_rdata   = ram_rdata;
    wire        npu_rlast   = ram_rlast;
    wire [1:0]  npu_rresp   = preload ? 2'b0 : ram_rresp;
    wire [1:0]  npu_bresp   = preload ? 2'b0 : ram_bresp;

    npu_top #(.TILE_ROWS(7), .TILE_COLS(2), .BUF_ENTRIES(256), .BUF_ADDR_W(8)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_araddr(s_axi_araddr), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready), .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .m_axi_arvalid(npu_arvalid), .m_axi_arready(npu_arready),
        .m_axi_araddr(npu_araddr), .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize), .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(npu_rvalid), .m_axi_rready(npu_rready),
        .m_axi_rdata(npu_rdata), .m_axi_rlast(npu_rlast),
        .m_axi_rresp(npu_rresp),
        .m_axi_awvalid(npu_awvalid), .m_axi_awready(npu_awready),
        .m_axi_awaddr(npu_awaddr), .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize), .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid), .m_axi_wready(npu_wready),
        .m_axi_wdata(npu_wdata), .m_axi_wlast(npu_wlast),
        .m_axi_wstrb(npu_wstrb), .m_axi_bvalid(npu_bvalid),
        .m_axi_bready(npu_bready), .m_axi_bresp(npu_bresp),
        .npu_busy(npu_busy), .npu_done(npu_done),
        .npu_error(npu_error), .npu_error_code(npu_error_code)
    );

    axi4_ram #(.RAM_DEPTH(16384)) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(ram_awvalid), .s_axi_awready(ram_awready),
        .s_axi_awaddr(ram_awaddr), .s_axi_awlen(ram_awlen),
        .s_axi_awsize(ram_awsize), .s_axi_awburst(ram_awburst),
        .s_axi_wvalid(ram_wvalid), .s_axi_wready(ram_wready),
        .s_axi_wdata(ram_wdata), .s_axi_wstrb(ram_wstrb),
        .s_axi_wlast(ram_wlast), .s_axi_bvalid(ram_bvalid),
        .s_axi_bready(ram_bready), .s_axi_bresp(ram_bresp),
        .s_axi_arvalid(ram_arvalid), .s_axi_arready(ram_arready),
        .s_axi_araddr(ram_araddr), .s_axi_arlen(ram_arlen),
        .s_axi_arsize(ram_arsize), .s_axi_arburst(ram_arburst),
        .s_axi_rvalid(ram_rvalid), .s_axi_rready(ram_rready),
        .s_axi_rdata(ram_rdata), .s_axi_rlast(ram_rlast),
        .s_axi_rresp(ram_rresp)
    );

    always #2.5 clk = ~clk;

    task axi_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            s_axi_awvalid = 1; s_axi_awaddr = addr;
            s_axi_wvalid  = 1; s_axi_wdata  = data; s_axi_wstrb = 4'hF;
            @(posedge clk);
            s_axi_awvalid = 0; s_axi_wvalid = 0;
            @(posedge clk);
            s_axi_bready = 1;
            @(posedge clk);
            s_axi_bready = 0;
        end
    endtask

    task preload_word;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            tb_awvalid = 1; tb_awaddr = addr;
            tb_wvalid  = 1; tb_wdata  = data;
            @(posedge clk);
            tb_awvalid = 0;
            @(posedge clk);
            tb_wvalid = 0;
            @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("sim/tb_task_requant.vcd");
        $dumpvars(0, tb_task_requant);

        clk = 0; rst_n = 0; preload = 1;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_arvalid = 0; s_axi_rready = 0;
        tb_awvalid = 0; tb_wvalid = 0;

        #20 rst_n = 1;
        #20;

        $display("=== Pre-load requant source INT32 words ===");
        preload_word(32'h0000_0100, 32'd100);
        preload_word(32'h0000_0104, 32'd101);
        preload_word(32'h0000_0108, -32'sd101);
        preload_word(32'h0000_010C, 32'd400);
        preload = 0;

        $display("=== Configure requant task ===");
        axi_write(32'h1000_0008, 32'h0000_0003);  // task_type=requant
        axi_write(32'h1000_000C, 32'h0000_0100);  // input addr
        axi_write(32'h1000_0010, 32'h0000_0000);  // weight addr unused
        axi_write(32'h1000_0014, 32'h0000_0200);  // output addr
        axi_write(32'h1000_0018, 32'd16);         // 4 x INT32
        axi_write(32'h1000_001C, 32'd0);          // no weights
        axi_write(32'h1000_0020, 32'd4);          // 4 x INT8
        axi_write(32'h1000_0024, 32'h0001_0001);
        axi_write(32'h1000_0028, 32'h0001_0001);
        axi_write(32'h1000_002C, 32'h0000_0000);
        axi_write(32'h1000_0064, 32'h0000_0000);  // slot 0
        axi_write(32'h1000_0068, 32'd1);          // multiplier
        axi_write(32'h1000_006C, 32'd1);          // shift

        $display("=== Start requant task ===");
        axi_write(32'h1000_0000, 32'h0000_0001);

        repeat (400) @(posedge clk);

        $display("CTRL done=%b error=%b code=0x%02h", npu_done, npu_error, npu_error_code);
        $display("Output word = 0x%08h (expect 0x7fcd3332)", tb_task_requant.u_ram.ram[32'h200 >> 2]);

        if (!npu_done) $error("FAIL: requant task did not complete");
        if (npu_error) $error("FAIL: requant task error code=0x%02h", npu_error_code);
        if (tb_task_requant.u_ram.ram[32'h200 >> 2] !== 32'h7FCD3332)
            $error("FAIL: requant output mismatch");
        else
            $display("PASS: requant task packed output matches expected");

        #20;
        $finish;
    end

endmodule
