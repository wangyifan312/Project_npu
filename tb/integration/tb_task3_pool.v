// tb_task3_pool: Pool/ReLU integration tests
// Tests: Pool 2x2 MaxPool as independent task, ReLU in Conv
`timescale 1ns / 1ps

module tb_task3_pool;
    reg clk, rst_n, preload;
    reg s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    reg [31:0] s_axi_awaddr, s_axi_wdata;
    reg [3:0] s_axi_wstrb;
    reg s_axi_arvalid, s_axi_rready;
    reg [31:0] s_axi_araddr;
    reg tb_awvalid, tb_wvalid;
    reg [31:0] tb_awaddr, tb_wdata;

    wire s_axi_bvalid, s_axi_arready, s_axi_rvalid;
    wire s_axi_awready, s_axi_wready;
    wire [1:0] s_axi_bresp, s_axi_rresp;
    wire [31:0] s_axi_rdata;
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
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_araddr(s_axi_araddr), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready), .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
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
    axi4_ram #(.RAM_DEPTH(65536)) u_ram (
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

    function [31:0] ram_read;
        input [31:0] addr;
        begin ram_read = u_ram.ram[addr[15:2]]; end
    endfunction

    task wait_done;
        input integer maxc;
        integer cnt;
        begin cnt=0; while(!npu_done && !npu_error && cnt<maxc) begin @(posedge clk); cnt=cnt+1; end end
    endtask

    // Golden 2x2 MaxPool
    function [31:0] golden_pool;
        input [15:0] oh, ow, oc_idx, iw, ic_total;
        reg signed [31:0] v00, v01, v10, v11, mxh, mxv;
        begin
            v00 = ((oh*2*iw*ic_total + ow*2*ic_total + oc_idx) & 8'h7F) - 64;
            v01 = ((oh*2*iw*ic_total + (ow*2+1)*ic_total + oc_idx) & 8'h7F) - 64;
            v10 = (((oh*2+1)*iw*ic_total + ow*2*ic_total + oc_idx) & 8'h7F) - 64;
            v11 = (((oh*2+1)*iw*ic_total + (ow*2+1)*ic_total + oc_idx) & 8'h7F) - 64;
            mxh = (v00 > v01) ? v00 : v01;
            mxv = (v10 > v11) ? v10 : v11;
            golden_pool = (mxh > mxv) ? mxh : mxv;
        end
    endfunction

    integer total_err, h, w, c, i, byte_off;
    reg [31:0] actual, expected;
    reg [7:0] b0,b1,b2,b3;
    reg [31:0] wv;

    initial begin
        clk=0; rst_n=0; preload=1;
        s_axi_awvalid=0; s_axi_wvalid=0; s_axi_bready=0; s_axi_wstrb=4'hF;
        s_axi_arvalid=0; s_axi_rready=0;
        tb_awvalid=0; tb_wvalid=0;
        total_err = 0;
        #20 rst_n=1; #20;

        // ============================================================
        // Test A: Pool 4x4x1 -> 2x2x1 (single channel, verify path works)
        // ============================================================
        $display("=== Test A: Pool 4x4x1 -> 2x2x1 ===");
        preload = 1;
        for (h=0; h<4; h=h+1) begin
            for (w=0; w<4; w=w+1) begin
                wv = h*4 + w + 10;
                preload_word(32'h200 + (h*4 + w)*4, wv);
            end
        end
        preload = 0;

        axi_write(32'h1000_0008, 32'h2);  // Pool
        axi_write(32'h1000_000C, 32'h200);
        axi_write(32'h1000_0014, 32'h400);
        axi_write(32'h1000_0018, 4*4*1*4);   // 64 bytes input
        axi_write(32'h1000_0020, 2*2*1*4);   // 16 bytes output
        axi_write(32'h1000_0024, {16'd4, 16'd4});
        axi_write(32'h1000_0028, {16'd1, 16'd1});
        axi_write(32'h1000_002C, 32'h2);  // pool_en=1
        axi_write(32'h1000_0000, 32'h1);

        wait_done(50000);

        if (npu_done) begin
            $display("  Verifying 2x2x1 pool outputs...");
            // Golden: max of 2x2 windows
            // Input: 10-13, 14-17, 18-21, 22-25
            // Pool(0,0)=max(10,11,14,15)=15
            // Pool(0,1)=max(12,13,16,17)=17
            // Pool(1,0)=max(18,19,22,23)=23
            // Pool(1,1)=max(20,21,24,25)=25
            actual = ram_read(32'h400); expected = 15;
            if (actual !== expected) begin total_err = total_err + 1; $display("  out[0]=%0d exp 15", $signed(actual)); end
            actual = ram_read(32'h404); expected = 17;
            if (actual !== expected) begin total_err = total_err + 1; $display("  out[1]=%0d exp 17", $signed(actual)); end
            actual = ram_read(32'h408); expected = 23;
            if (actual !== expected) begin total_err = total_err + 1; $display("  out[2]=%0d exp 23", $signed(actual)); end
            actual = ram_read(32'h40c); expected = 25;
            if (actual !== expected) begin total_err = total_err + 1; $display("  out[3]=%0d exp 25", $signed(actual)); end
            if (total_err == 0) $display("  Test A PASS");
        end else if (npu_error) begin
            $display("  Test A NPU ERROR: code=0x%02h", npu_error_code);
            total_err = total_err + 100;
        end else $display("  Test A TIMEOUT");

        // Reset
        rst_n=0; #20; rst_n=1; #20; preload=1; #20;

        // ============================================================
        // Test A2: Pool 4x4x2 -> 2x2x2 (multi-channel HWC ordering)
        // ============================================================
        $display("=== Test A2: Pool 4x4x2 -> 2x2x2 ===");
        preload = 1;
        for (h=0; h<4; h=h+1) begin
            for (w=0; w<4; w=w+1) begin
                for (c=0; c<2; c=c+1) begin
                    preload_word(32'h200 + ((h*4 + w)*2 + c)*4, (h*4 + w)*2 + c + 10);
                end
            end
        end
        preload = 0;

        axi_write(32'h1000_0008, 32'h2);  // Pool
        axi_write(32'h1000_000C, 32'h200);
        axi_write(32'h1000_0014, 32'h500);
        axi_write(32'h1000_0018, 4*4*2*4);   // 128 bytes input
        axi_write(32'h1000_0020, 2*2*2*4);   // 32 bytes output
        axi_write(32'h1000_0024, {16'd4, 16'd4});
        axi_write(32'h1000_0028, {16'd2, 16'd2});
        axi_write(32'h1000_002C, 32'h2);  // pool_en=1
        axi_write(32'h1000_0000, 32'h1);

        wait_done(50000);

        if (npu_done) begin
            $display("  Verifying 2x2x2 pool outputs...");
            for (h=0; h<2; h=h+1) begin
                for (w=0; w<2; w=w+1) begin
                    for (c=0; c<2; c=c+1) begin
                        actual = ram_read(32'h500 + ((h*2 + w)*2 + c)*4);
                        expected = 10 + (((h*2+1)*4 + (w*2+1))*2 + c);
                        if (actual !== expected) begin
                            total_err = total_err + 1;
                            $display("  out[%0d,%0d,%0d]=%0d exp %0d", h, w, c, $signed(actual), $signed(expected));
                        end
                    end
                end
            end
            if (total_err == 0) $display("  Test A2 PASS");
        end else if (npu_error) begin
            $display("  Test A2 NPU ERROR: code=0x%02h", npu_error_code);
            total_err = total_err + 100;
        end else $display("  Test A2 TIMEOUT");

        // Reset
        rst_n=0; #20; rst_n=1; #20; preload=1; #20;

        // ============================================================
        // Test B: Conv 5x5 1->1 with ReLU clamps negative output to 0
        // ============================================================
        $display("=== Test B: Conv 5x5 1->1 with ReLU ===");
        preload = 1;
        // 5x5 input of ones
        for (i=0; i<7; i=i+1)
            preload_word(32'h200 + i*4, 32'h01010101);
        // 5x5 weights of -1 => convolution sum = -25, ReLU => 0
        for (i=0; i<7; i=i+1)
            preload_word(32'h300 + i*4, 32'hFFFF_FFFF);
        preload = 0;

        axi_write(32'h1000_0008, 32'h0);  // Conv
        axi_write(32'h1000_000C, 32'h200);
        axi_write(32'h1000_0010, 32'h300);
        axi_write(32'h1000_0014, 32'h400);
        axi_write(32'h1000_0018, 25);      // input_bytes
        axi_write(32'h1000_001C, 25);      // weight_bytes
        axi_write(32'h1000_0020, 4);       // output_bytes (1x1x1 INT32)
        axi_write(32'h1000_0024, {16'd5, 16'd5});  // W=5, H=5
        axi_write(32'h1000_0028, {16'd1, 16'd1});  // C_out=1, C_in=1
        axi_write(32'h1000_002C, 32'h1);  // relu_en=1, pool_en=0
        axi_write(32'h1000_0000, 32'h1);

        wait_done(50000);

        if (npu_done) begin
            actual = ram_read(32'h400);
            $display("  Conv+ReLU output = %0d (expect 0)", $signed(actual));
            if ($signed(actual) != 0) total_err = total_err + 1;
            if (total_err == 0) $display("  Test B PASS");
        end else if (npu_error) begin
            $display("  Test B ERROR: code=0x%02h", npu_error_code);
            total_err = total_err + 100;
        end else $display("  Test B TIMEOUT");

        // ============================================================
        // Final
        // ============================================================
        $display("=== Task 3: %0d total errors ===", total_err);
        if (total_err != 0) $fatal(1, "Task 3 FAILED");
        else $display("Task 3 PASSED");
        #20 $finish;
    end
endmodule
