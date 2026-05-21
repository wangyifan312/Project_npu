// tb_fc_accept: verify FC tasks are accepted and execute (Task 4)
`timescale 1ns / 1ps
module tb_fc_accept;
    reg clk, rst_n, preload;
    reg s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    reg [31:0] s_axi_awaddr, s_axi_wdata;
    reg [3:0] s_axi_wstrb;
    reg tb_awvalid, tb_wvalid;
    reg [31:0] tb_awaddr, tb_wdata;
    wire s_axi_awready, s_axi_wready, s_axi_bvalid;
    wire [1:0] s_axi_bresp;
    wire npu_busy, npu_done, npu_error;
    wire [7:0] npu_error_code;
    wire npu_arvalid, npu_awvalid, npu_wvalid, npu_wlast;
    wire [31:0] npu_araddr, npu_awaddr, npu_wdata;
    wire [7:0] npu_arlen, npu_awlen;
    wire [2:0] npu_arsize, npu_awsize;
    wire [1:0] npu_arburst, npu_awburst;
    wire [3:0] npu_wstrb;
    wire npu_rready, npu_bready;
    wire ram_awvalid = preload ? tb_awvalid : npu_awvalid;
    wire [31:0] ram_awaddr = preload ? tb_awaddr : npu_awaddr;
    wire [7:0] ram_awlen = preload ? 8'h0 : npu_awlen;
    wire [2:0] ram_awsize = preload ? 3'd2 : npu_awsize;
    wire [1:0] ram_awburst = preload ? 2'd1 : npu_awburst;
    wire ram_wvalid = preload ? tb_wvalid : npu_wvalid;
    wire [31:0] ram_wdata = preload ? tb_wdata : npu_wdata;
    wire [3:0] ram_wstrb = preload ? 4'hF : npu_wstrb;
    wire ram_wlast = preload ? 1'b1 : npu_wlast;
    wire ram_bready = preload ? 1'b1 : npu_bready;
    wire ram_arvalid = preload ? 1'b0 : npu_arvalid;
    wire [31:0] ram_araddr = preload ? 32'h0 : npu_araddr;
    wire [7:0] ram_arlen = preload ? 8'h0 : npu_arlen;
    wire [2:0] ram_arsize = preload ? 3'd2 : npu_arsize;
    wire [1:0] ram_arburst = preload ? 2'd1 : npu_arburst;
    wire ram_rready = preload ? 1'b0 : npu_rready;
    wire ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0] ram_bresp, ram_rresp;
    wire ram_rvalid, ram_rlast;
    wire [31:0] ram_rdata;

    npu_top #(.TILE_ROWS(7), .TILE_COLS(2), .BUF_ENTRIES(256), .BUF_ADDR_W(8)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(1'b0), .s_axi_arready(),
        .s_axi_araddr(32'h0), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(1'b0), .s_axi_rdata(), .s_axi_rresp(),
        .m_axi_arvalid(npu_arvalid), .m_axi_arready(preload ? 1'b0 : ram_arready),
        .m_axi_araddr(npu_araddr), .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize), .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(preload ? 1'b0 : ram_rvalid),
        .m_axi_rready(npu_rready), .m_axi_rdata(ram_rdata),
        .m_axi_rlast(preload ? 1'b0 : ram_rlast), .m_axi_rresp(ram_rresp),
        .m_axi_awvalid(npu_awvalid), .m_axi_awready(preload ? 1'b0 : ram_awready),
        .m_axi_awaddr(npu_awaddr), .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize), .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid), .m_axi_wready(preload ? 1'b0 : ram_wready),
        .m_axi_wdata(npu_wdata), .m_axi_wlast(npu_wlast),
        .m_axi_wstrb(npu_wstrb), .m_axi_bvalid(preload ? 1'b0 : ram_bvalid),
        .m_axi_bready(npu_bready), .m_axi_bresp(ram_bresp),
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
        input [31:0] addr, data;
        begin @(posedge clk); s_axi_awvalid=1; s_axi_awaddr=addr;
        s_axi_wvalid=1; s_axi_wdata=data; s_axi_wstrb=4'hF;
        @(posedge clk); s_axi_awvalid=0; s_axi_wvalid=0;
        @(posedge clk); s_axi_bready=1; @(posedge clk); s_axi_bready=0; end
    endtask

    task preload_word;
        input [31:0] addr, data;
        begin @(posedge clk); tb_awvalid=1; tb_awaddr=addr;
        tb_wvalid=1; tb_wdata=data;
        @(posedge clk); tb_awvalid=0; @(posedge clk); tb_wvalid=0; @(posedge clk); end
    endtask

    integer i, errs;
    reg [7:0] b0,b1,b2,b3;
    reg [31:0] wv;

    initial begin
        clk=0; rst_n=0; preload=1; errs=0;
        s_axi_awvalid=0; s_axi_wvalid=0; s_axi_bready=0; s_axi_wstrb=4'hF;
        tb_awvalid=0; tb_wvalid=0;
        #20 rst_n=1; #20;

        $display("=== FC acceptance test ===");
        preload_word(32'h200, 32'd5); preload_word(32'h204, -32'd3);
        preload_word(32'h208, 32'd2); preload_word(32'h20c, 32'd7);
        for (i=0; i<2; i=i+1) begin
            b0=(i==0)?1:2; b1=b0; b2=b0; b3=b0; wv={b3,b2,b1,b0};
            preload_word(32'h400+i*4, wv);
        end
        preload=0;

        axi_write(32'h1000_0008, 32'h1);  // FC
        axi_write(32'h1000_000C, 32'h200); axi_write(32'h1000_0010, 32'h400);
        axi_write(32'h1000_0014, 32'h600);
        axi_write(32'h1000_0018, 16); axi_write(32'h1000_001C, 8);
        axi_write(32'h1000_0020, 8);
        axi_write(32'h1000_0024, {16'd1, 16'd1}); axi_write(32'h1000_0028, {16'd2, 16'd4});
        axi_write(32'h1000_002C, 32'h0);
        axi_write(32'h1000_0000, 32'h1);

        repeat(5000) @(posedge clk);
        if (npu_done) begin
            $display("PASS: FC accepted and completed");
            $display("  out[0]=%0d out[1]=%0d", $signed(u_ram.ram[(32'h600)>>2]), $signed(u_ram.ram[(32'h604)>>2]));
        end else if (npu_error) begin
            $display("FC error code=0x%02h", npu_error_code); errs=errs+1;
        end else begin $display("FC timeout"); errs=errs+1; end

        if (errs==0) $display("=== ALL PASS ===");
        else $display("=== FAIL ===");
        #20 $finish;
    end
endmodule
