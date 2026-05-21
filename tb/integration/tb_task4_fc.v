// tb_task4_fc: FC functional tests
`timescale 1ns / 1ps

module tb_task4_fc;
    reg clk, rst_n;
    reg s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    reg [31:0] s_axi_awaddr, s_axi_wdata;
    reg [3:0] s_axi_wstrb;

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
    wire ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0] ram_bresp, ram_rresp;
    wire ram_rvalid, ram_rlast;
    wire [31:0] ram_rdata;

    npu_top #(.TILE_ROWS(7), .TILE_COLS(2), .BUF_ENTRIES(1024), .BUF_ADDR_W(10)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(1'b0), .s_axi_arready(),
        .s_axi_araddr(32'h0), .s_axi_rvalid(), .s_axi_rready(1'b0), .s_axi_rdata(), .s_axi_rresp(),
        .m_axi_arvalid(npu_arvalid), .m_axi_arready(ram_arready),
        .m_axi_araddr(npu_araddr), .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize), .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(ram_rvalid), .m_axi_rready(npu_rready),
        .m_axi_rdata(ram_rdata), .m_axi_rlast(ram_rlast), .m_axi_rresp(ram_rresp),
        .m_axi_awvalid(npu_awvalid), .m_axi_awready(ram_awready),
        .m_axi_awaddr(npu_awaddr), .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize), .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid), .m_axi_wready(ram_wready),
        .m_axi_wdata(npu_wdata), .m_axi_wlast(npu_wlast),
        .m_axi_wstrb(npu_wstrb), .m_axi_bvalid(ram_bvalid),
        .m_axi_bready(npu_bready), .m_axi_bresp(ram_bresp),
        .npu_busy(npu_busy), .npu_done(npu_done), .npu_error(npu_error), .npu_error_code(npu_error_code)
    );

    axi4_ram #(.RAM_DEPTH(262144)) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(npu_awvalid), .s_axi_awready(ram_awready),
        .s_axi_awaddr(npu_awaddr), .s_axi_awlen(npu_awlen),
        .s_axi_awsize(npu_awsize), .s_axi_awburst(npu_awburst),
        .s_axi_wvalid(npu_wvalid), .s_axi_wready(ram_wready),
        .s_axi_wdata(npu_wdata), .s_axi_wstrb(npu_wstrb),
        .s_axi_wlast(npu_wlast), .s_axi_bvalid(ram_bvalid),
        .s_axi_bready(npu_bready), .s_axi_bresp(ram_bresp),
        .s_axi_arvalid(npu_arvalid), .s_axi_arready(ram_arready),
        .s_axi_araddr(npu_araddr), .s_axi_arlen(npu_arlen),
        .s_axi_arsize(npu_arsize), .s_axi_arburst(npu_arburst),
        .s_axi_rvalid(ram_rvalid), .s_axi_rready(npu_rready),
        .s_axi_rdata(ram_rdata), .s_axi_rlast(ram_rlast),
        .s_axi_rresp(ram_rresp)
    );

    always #2.5 clk = ~clk;

    task axi_write;
        input [31:0] addr, data;
        begin
            @(posedge clk);
            s_axi_awvalid = 1'b1; s_axi_awaddr = addr;
            s_axi_wvalid  = 1'b1; s_axi_wdata  = data; s_axi_wstrb = 4'hF;
            @(posedge clk);
            s_axi_awvalid = 1'b0; s_axi_wvalid = 1'b0;
            @(posedge clk);
            s_axi_bready = 1'b1;
            @(posedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task wait_done;
        input integer max_cycles;
        integer cnt;
        begin
            cnt = 0;
            while (!npu_done && !npu_error && cnt < max_cycles) begin
                @(posedge clk);
                cnt = cnt + 1;
            end
        end
    endtask

    task ram_write_word;
        input [31:0] addr, data;
        begin
            u_ram.ram[addr >> 2] = data;
        end
    endtask

    function [31:0] ram_read_word;
        input [31:0] addr;
        begin
            ram_read_word = u_ram.ram[addr >> 2];
        end
    endfunction

    integer i, errs;
    reg [31:0] actual;
    localparam SMALL_IN_ADDR  = 32'h0000_0100;
    localparam SMALL_WGT_ADDR = 32'h0000_0200;
    localparam SMALL_OUT_ADDR = 32'h0000_0300;
    localparam FC1_IN_ADDR    = 32'h0000_1000;
    localparam FC1_WGT_ADDR   = 32'h0001_0000;
    localparam FC1_OUT_ADDR   = 32'h0009_0000;
    localparam FC2_IN_ADDR    = 32'h0009_1000;
    localparam FC2_WGT_ADDR   = 32'h0009_2000;
    localparam FC2_OUT_ADDR   = 32'h0009_4000;

    initial begin
        clk = 0; rst_n = 0; errs = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0; s_axi_wstrb = 4'hF;
        #20 rst_n = 1; #20;

        $display("=== Test A: FC 4->2 functional ===");
        ram_write_word(SMALL_IN_ADDR + 32'd0,  32'sd5);
        ram_write_word(SMALL_IN_ADDR + 32'd4, -32'sd3);
        ram_write_word(SMALL_IN_ADDR + 32'd8,  32'sd2);
        ram_write_word(SMALL_IN_ADDR + 32'd12, 32'sd7);
        ram_write_word(SMALL_WGT_ADDR + 32'd0, 32'h01010101); // neuron0 weights = 1,1,1,1
        ram_write_word(SMALL_WGT_ADDR + 32'd4, 32'h02020202); // neuron1 weights = 2,2,2,2
        ram_write_word(SMALL_OUT_ADDR + 32'd0, 32'd0);
        ram_write_word(SMALL_OUT_ADDR + 32'd4, 32'd0);

        axi_write(32'h1000_0008, 32'h1);
        axi_write(32'h1000_000C, SMALL_IN_ADDR);
        axi_write(32'h1000_0010, SMALL_WGT_ADDR);
        axi_write(32'h1000_0014, SMALL_OUT_ADDR);
        axi_write(32'h1000_0018, 16);
        axi_write(32'h1000_001C, 8);
        axi_write(32'h1000_0020, 8);
        axi_write(32'h1000_0024, {16'd1, 16'd1});
        axi_write(32'h1000_0028, {16'd2, 16'd4});
        axi_write(32'h1000_002C, 32'h0);
        axi_write(32'h1000_0000, 32'h1);
        wait_done(200000);
        if (!npu_done) begin
            $display("  Test A failed to complete"); errs = errs + 1;
        end else begin
            actual = ram_read_word(SMALL_OUT_ADDR + 32'd0);
            if ($signed(actual) != 11) begin $display("  out0=%0d exp 11", $signed(actual)); errs = errs + 1; end
            actual = ram_read_word(SMALL_OUT_ADDR + 32'd4);
            if ($signed(actual) != 22) begin $display("  out1=%0d exp 22", $signed(actual)); errs = errs + 1; end
            if (errs == 0) $display("  Test A PASS");
        end

        rst_n = 0; #20; rst_n = 1; #20;

        $display("=== Test B: FC 800->500 all ones ===");
        for (i = 0; i < 800; i = i + 1)
            ram_write_word(FC1_IN_ADDR + i*4, 32'sd1);
        for (i = 0; i < 100000; i = i + 1)
            ram_write_word(FC1_WGT_ADDR + i*4, 32'h01010101);
        for (i = 0; i < 500; i = i + 1)
            ram_write_word(FC1_OUT_ADDR + i*4, 32'd0);

        axi_write(32'h1000_0008, 32'h1);
        axi_write(32'h1000_000C, FC1_IN_ADDR);
        axi_write(32'h1000_0010, FC1_WGT_ADDR);
        axi_write(32'h1000_0014, FC1_OUT_ADDR);
        axi_write(32'h1000_0018, 3200);
        axi_write(32'h1000_001C, 400000);
        axi_write(32'h1000_0020, 2000);
        axi_write(32'h1000_0024, {16'd1, 16'd1});
        axi_write(32'h1000_0028, {16'd500, 16'd800});
        axi_write(32'h1000_002C, 32'h0);
        axi_write(32'h1000_0000, 32'h1);
        wait_done(5000000);
        if (!npu_done) begin
            $display("  Test B failed to complete"); errs = errs + 1;
        end else begin
            actual = ram_read_word(FC1_OUT_ADDR + 32'd0);
            if ($signed(actual) != 800) begin $display("  out0=%0d exp 800", $signed(actual)); errs = errs + 1; end
            actual = ram_read_word(FC1_OUT_ADDR + 32'd996);
            if ($signed(actual) != 800) begin $display("  out249=%0d exp 800", $signed(actual)); errs = errs + 1; end
            actual = ram_read_word(FC1_OUT_ADDR + 32'd1996);
            if ($signed(actual) != 800) begin $display("  out499=%0d exp 800", $signed(actual)); errs = errs + 1; end
            if (errs == 0) $display("  Test B PASS");
        end

        rst_n = 0; #20; rst_n = 1; #20;

        $display("=== Test C: FC 500->10 all ones ===");
        for (i = 0; i < 500; i = i + 1)
            ram_write_word(FC2_IN_ADDR + i*4, 32'sd1);
        for (i = 0; i < 1250; i = i + 1)
            ram_write_word(FC2_WGT_ADDR + i*4, 32'h01010101);
        for (i = 0; i < 10; i = i + 1)
            ram_write_word(FC2_OUT_ADDR + i*4, 32'd0);

        axi_write(32'h1000_0008, 32'h1);
        axi_write(32'h1000_000C, FC2_IN_ADDR);
        axi_write(32'h1000_0010, FC2_WGT_ADDR);
        axi_write(32'h1000_0014, FC2_OUT_ADDR);
        axi_write(32'h1000_0018, 2000);
        axi_write(32'h1000_001C, 5000);
        axi_write(32'h1000_0020, 40);
        axi_write(32'h1000_0024, {16'd1, 16'd1});
        axi_write(32'h1000_0028, {16'd10, 16'd500});
        axi_write(32'h1000_002C, 32'h0);
        axi_write(32'h1000_0000, 32'h1);
        wait_done(1000000);
        if (!npu_done) begin
            $display("  Test C failed to complete"); errs = errs + 1;
        end else begin
            actual = ram_read_word(FC2_OUT_ADDR + 32'd0);
            if ($signed(actual) != 500) begin $display("  out0=%0d exp 500", $signed(actual)); errs = errs + 1; end
            actual = ram_read_word(FC2_OUT_ADDR + 32'd36);
            if ($signed(actual) != 500) begin $display("  out9=%0d exp 500", $signed(actual)); errs = errs + 1; end
            if (errs == 0) $display("  Test C PASS");
        end

        if (errs == 0) $display("=== Task 4 PASSED ===");
        else $fatal(1, "Task 4 FAILED with %0d errors", errs);
        #20 $finish;
    end
endmodule
