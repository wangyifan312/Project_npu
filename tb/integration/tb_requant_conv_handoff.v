`timescale 1ns / 1ps

module tb_requant_conv_handoff;
    reg clk, rst_n;
    reg s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    reg s_axi_arvalid, s_axi_rready;
    reg [31:0] s_axi_awaddr, s_axi_wdata;
    reg [31:0] s_axi_araddr;
    reg [3:0] s_axi_wstrb;

    wire s_axi_awready, s_axi_wready, s_axi_bvalid;
    wire s_axi_arready, s_axi_rvalid;
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
    wire ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0] ram_bresp, ram_rresp;
    wire ram_rvalid, ram_rlast;
    wire [31:0] ram_rdata;

    localparam REQ_IN_ADDR   = 32'h0001_8000;
    localparam REQ_OUT_ADDR  = 32'h0001_C000;
    localparam CONV_WGT_ADDR = 32'h0002_0000;
    localparam CONV_OUT_ADDR = 32'h0006_0000;

    npu_top #(.TILE_ROWS(7), .TILE_COLS(13), .BUF_ENTRIES(16384), .BUF_ADDR_W(14)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready), .s_axi_araddr(s_axi_araddr),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .m_axi_arvalid(npu_arvalid), .m_axi_arready(ram_arready),
        .m_axi_araddr(npu_araddr), .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize), .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(ram_rvalid), .m_axi_rready(npu_rready),
        .m_axi_rdata(ram_rdata), .m_axi_rlast(ram_rlast), .m_axi_rresp(ram_rresp),
        .m_axi_awvalid(npu_awvalid), .m_axi_awready(ram_awready),
        .m_axi_awaddr(npu_awaddr), .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize), .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid), .m_axi_wready(ram_wready),
        .m_axi_wdata(npu_wdata), .m_axi_wlast(npu_wlast), .m_axi_wstrb(npu_wstrb),
        .m_axi_bvalid(ram_bvalid), .m_axi_bready(npu_bready), .m_axi_bresp(ram_bresp),
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
        .s_axi_rdata(ram_rdata), .s_axi_rlast(ram_rlast), .s_axi_rresp(ram_rresp)
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

    task clear_done;
        begin
            axi_write(32'h1000_0000, 32'h10);
        end
    endtask

    task start_requant;
        begin
            axi_write(32'h1000_0008, 32'd3);
            axi_write(32'h1000_000C, REQ_IN_ADDR);
            axi_write(32'h1000_0010, 32'd0);
            axi_write(32'h1000_0014, REQ_OUT_ADDR);
            axi_write(32'h1000_0018, 32'd2880);
            axi_write(32'h1000_001C, 32'd0);
            axi_write(32'h1000_0020, 32'd720);
            axi_write(32'h1000_0024, 32'h0001_0001);
            axi_write(32'h1000_0028, 32'h0001_0001);
            axi_write(32'h1000_002C, 32'd0);
            axi_write(32'h1000_0064, 32'd0);
            axi_write(32'h1000_0068, 32'd1);
            axi_write(32'h1000_006C, 32'd4);
            axi_write(32'h1000_0000, 32'd1);
        end
    endtask

    task start_conv2;
        begin
            axi_write(32'h1000_0008, 32'd0);
            axi_write(32'h1000_000C, REQ_OUT_ADDR);
            axi_write(32'h1000_0010, CONV_WGT_ADDR);
            axi_write(32'h1000_0014, CONV_OUT_ADDR);
            axi_write(32'h1000_0018, 32'd2880);
            axi_write(32'h1000_001C, 32'd25040);
            axi_write(32'h1000_0020, 32'd12800);
            axi_write(32'h1000_0024, {16'd12, 16'd12});
            axi_write(32'h1000_0028, {16'd50, 16'd20});
            axi_write(32'h1000_002C, 32'd0);
            axi_write(32'h1000_0000, 32'd1);
        end
    endtask

    integer i;
    integer cycles;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        s_axi_awvalid = 1'b0;
        s_axi_wvalid = 1'b0;
        s_axi_bready = 1'b0;
        s_axi_arvalid = 1'b0;
        s_axi_rready = 1'b0;
        s_axi_awaddr = 32'd0;
        s_axi_wdata = 32'd0;
        s_axi_araddr = 32'd0;
        s_axi_wstrb = 4'hF;

        #20 rst_n = 1'b1;
        #20;

        for (i = 0; i < 720; i = i + 1)
            u_ram.ram[(REQ_IN_ADDR >> 2) + i] = i;
        for (i = 0; i < 6260; i = i + 1)
            u_ram.ram[(CONV_WGT_ADDR >> 2) + i] = i;

        start_requant();
        cycles = 0;
        while (!npu_done && !npu_error && cycles < 200000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!npu_done)
            $fatal(1, "requant task did not complete");
        clear_done();

        start_conv2();
        cycles = 0;
        while ((u_npu.fsm_state != 5'd2) && !npu_error && cycles < 200000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (u_npu.fsm_state != 5'd2)
            $fatal(1, "conv2 did not reach CF_START");

        $display("HANDOFF_DEBUG blk_in_bytes=%0d act_dma_bytes=%0d blk_input_rows=%0d blk_output_rows=%0d blk_wgt_per_cin=%0d wgt_per_cin=%0d wgt_words_per_cin=%0d",
                 u_npu.blk_in_bytes, u_npu.act_dma_bytes, u_npu.blk_in_rows, u_npu.blk_out_rows,
                 u_npu.blk_wgt_per_cin, u_npu.wgt_per_cin, u_npu.wgt_words_per_cin);

        if (u_npu.blk_in_bytes !== 32'd2880)
            $fatal(1, "blk_in_bytes wrong: %0d", u_npu.blk_in_bytes);
        if (u_npu.act_dma_bytes !== 32'd2880)
            $fatal(1, "act_dma_bytes wrong: %0d", u_npu.act_dma_bytes);
        if (u_npu.blk_in_rows !== 16'd12)
            $fatal(1, "blk_in_rows wrong: %0d", u_npu.blk_in_rows);
        if (u_npu.blk_out_rows !== 16'd8)
            $fatal(1, "blk_out_rows wrong: %0d", u_npu.blk_out_rows);
        if (u_npu.blk_wgt_per_cin !== 32'd1252)
            $fatal(1, "blk_wgt_per_cin wrong: %0d", u_npu.blk_wgt_per_cin);
        if (u_npu.wgt_per_cin !== 32'd1252)
            $fatal(1, "wgt_per_cin wrong: %0d", u_npu.wgt_per_cin);
        if (u_npu.wgt_words_per_cin !== 32'd313)
            $fatal(1, "wgt_words_per_cin wrong: %0d", u_npu.wgt_words_per_cin);

        $display("tb_requant_conv_handoff PASS");
        #20 $finish;
    end
endmodule
