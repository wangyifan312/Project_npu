// tb_fc_reject: verify FC tasks are rejected by task_checker (Task 5 Plan B)
`timescale 1ns / 1ps

module tb_fc_reject;
    reg clk, rst_n;
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
    wire npu_arvalid, npu_awvalid, npu_wvalid, npu_wlast;
    wire [31:0] npu_araddr, npu_awaddr, npu_wdata;
    wire [7:0] npu_arlen, npu_awlen;
    wire [2:0] npu_arsize, npu_awsize;
    wire [1:0] npu_arburst, npu_awburst;
    wire [3:0] npu_wstrb;
    wire npu_rready, npu_bready, npu_busy, npu_done, npu_error;
    wire [7:0] npu_error_code;
    wire npu_arready, npu_awready, npu_wready, npu_rvalid, npu_bvalid;
    wire [31:0] npu_rdata; wire npu_rlast; wire [1:0] npu_rresp, npu_bresp;
    reg  preload, tb_awvalid, tb_wvalid;
    reg  [31:0] tb_awaddr, tb_wdata;

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
        .m_axi_arvalid(npu_arvalid), .m_axi_arready(1'b0),
        .m_axi_araddr(npu_araddr), .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize), .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(1'b0), .m_axi_rready(npu_rready),
        .m_axi_rdata(32'h0), .m_axi_rlast(1'b0), .m_axi_rresp(2'b0),
        .m_axi_awvalid(npu_awvalid), .m_axi_awready(1'b0),
        .m_axi_awaddr(npu_awaddr), .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize), .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid), .m_axi_wready(1'b0),
        .m_axi_wdata(npu_wdata), .m_axi_wlast(npu_wlast),
        .m_axi_wstrb(npu_wstrb), .m_axi_bvalid(1'b0),
        .m_axi_bready(npu_bready), .m_axi_bresp(2'b0),
        .npu_busy(npu_busy), .npu_done(npu_done),
        .npu_error(npu_error), .npu_error_code(npu_error_code)
    );

    always #2.5 clk = ~clk;

    task axi_write;
        input [31:0] addr, data;
        begin @(posedge clk); s_axi_awvalid=1; s_axi_awaddr=addr; s_axi_wvalid=1; s_axi_wdata=data; s_axi_wstrb=4'hF;
        @(posedge clk); s_axi_awvalid=0; s_axi_wvalid=0;
        @(posedge clk); s_axi_bready=1; @(posedge clk); s_axi_bready=0; end
    endtask

    task axi_read;
        input [31:0] addr; output [31:0] data;
        begin @(posedge clk); s_axi_arvalid=1; s_axi_araddr=addr;
        @(posedge clk); s_axi_arvalid=0; @(posedge clk); data=s_axi_rdata; s_axi_rready=1;
        @(posedge clk); s_axi_rready=0; end
    endtask

    reg [31:0] rd_val;
    reg        errors;

    initial begin
        $dumpfile("sim/tb_fc_reject.vcd");
        $dumpvars(0, tb_fc_reject);
        clk=0; rst_n=0; errors=0;
        s_axi_awvalid=0; s_axi_wvalid=0; s_axi_bready=0;
        s_axi_arvalid=0; s_axi_rready=0;

        #20 rst_n=1; #20;

        // Configure FC task with valid parameters
        $display("=== FC rejection test ===");
        axi_write(32'h1000_0008, 32'h0000_0001);  // FC task_type=1
        axi_write(32'h1000_000C, 32'h0000_0100);
        axi_write(32'h1000_0010, 32'h0000_0200);
        axi_write(32'h1000_0014, 32'h0000_0300);
        axi_write(32'h1000_0018, 32'h0000_0064);
        axi_write(32'h1000_001C, 32'h0000_0064);
        axi_write(32'h1000_0020, 32'h0000_0064);
        axi_write(32'h1000_0024, 32'h0001_0001);
        axi_write(32'h1000_0028, 32'h0001_0001);
        axi_write(32'h1000_002C, 32'h0);
        axi_write(32'h1000_0000, 32'h0000_0001);  // start

        repeat(100) @(posedge clk);

        axi_read(32'h1000_0000, rd_val);
        $display("CTRL=0x%08h busy=%b done=%b error=%b", rd_val, rd_val[1], rd_val[2], rd_val[3]);

        if (!rd_val[3]) begin
            $display("FAIL: FC task not rejected (error=0)");
            errors = errors + 1;
        end else begin
            $display("PASS: FC task rejected (error=1)");
        end

        // Also verify no DMA activity
        if (npu_arvalid || npu_awvalid) begin
            $display("FAIL: DMA activity detected on FC rejection");
            errors = errors + 1;
        end

        $display("=== Final: %0d errors ===", errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== FAIL ===");
        #20 $finish;
    end

endmodule
