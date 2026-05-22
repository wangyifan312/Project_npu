// tb_task4_fc_tiled_signed: strict signed FC regression across tile boundaries
`timescale 1ns / 1ps

module tb_task4_fc_tiled_signed;
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

    localparam IN_ADDR  = 32'h0000_1000;
    localparam WGT_ADDR = 32'h0001_0000;
    localparam OUT_ADDR = 32'h0004_0000;
    localparam IN_C = 16'd800;
    localparam OUT_C = 16'd100;

    npu_top #(.TILE_ROWS(7), .TILE_COLS(13), .BUF_ENTRIES(16384), .BUF_ADDR_W(14)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(1'b0), .s_axi_arready(), .s_axi_araddr(32'h0),
        .s_axi_rvalid(), .s_axi_rready(1'b0), .s_axi_rdata(), .s_axi_rresp(),
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

    function signed [7:0] sat_i8;
        input signed [31:0] val;
        begin
            if (val > 32'sd127) sat_i8 = 8'sd127;
            else if (val < -32'sd128) sat_i8 = -8'sd128;
            else sat_i8 = val[7:0];
        end
    endfunction

    function signed [31:0] in_val;
        input integer idx;
        integer raw;
        begin
            raw = idx * 37 - 255;
            in_val = raw;
        end
    endfunction

    function signed [7:0] wgt_val;
        input integer out_idx, in_idx;
        integer raw;
        begin
            raw = out_idx * 11 - in_idx * 3 + 17;
            wgt_val = raw[7:0];
        end
    endfunction

    function signed [31:0] golden_out;
        input integer out_idx;
        integer i;
        reg signed [31:0] acc;
        begin
            acc = 0;
            for (i = 0; i < IN_C; i = i + 1)
                acc = acc + sat_i8(in_val(i)) * wgt_val(out_idx, i);
            golden_out = acc;
        end
    endfunction

    integer i, o, errs;
    reg [31:0] packed_word;
    reg signed [31:0] actual;

    initial begin
        clk = 0; rst_n = 0; errs = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0; s_axi_wstrb = 4'hF;
        #20 rst_n = 1; #20;

        for (i = 0; i < IN_C; i = i + 1)
            ram_write_word(IN_ADDR + i*4, in_val(i));

        for (o = 0; o < OUT_C; o = o + 1) begin
            for (i = 0; i < IN_C; i = i + 4) begin
                packed_word = {wgt_val(o, i+3), wgt_val(o, i+2), wgt_val(o, i+1), wgt_val(o, i+0)};
                ram_write_word(WGT_ADDR + o*IN_C + i, packed_word);
            end
        end

        axi_write(32'h1000_0008, 32'h1);
        axi_write(32'h1000_000C, IN_ADDR);
        axi_write(32'h1000_0010, WGT_ADDR);
        axi_write(32'h1000_0014, OUT_ADDR);
        axi_write(32'h1000_0018, IN_C * 4);
        axi_write(32'h1000_001C, OUT_C * IN_C);
        axi_write(32'h1000_0020, OUT_C * 4);
        axi_write(32'h1000_0024, {16'd1, 16'd1});
        axi_write(32'h1000_0028, {OUT_C[15:0], IN_C[15:0]});
        axi_write(32'h1000_002C, 32'd0);
        axi_write(32'h1000_0000, 32'h1);
        wait_done(5000000);

        if (npu_error) $fatal(1, "NPU error 0x%02h", npu_error_code);
        if (!npu_done) $fatal(1, "TIMEOUT");

        for (o = 0; o < OUT_C; o = o + 1) begin
            actual = u_ram.ram[(OUT_ADDR >> 2) + o];
            if (actual !== golden_out(o)) begin
                errs = errs + 1;
                if (errs <= 12)
                    $display("mismatch out%0d got=%0d exp=%0d", o, actual, golden_out(o));
            end
        end

        if (errs != 0)
            $fatal(1, "tb_task4_fc_tiled_signed FAILED with %0d mismatches", errs);
        else
            $display("tb_task4_fc_tiled_signed PASS");

        #20 $finish;
    end
endmodule
