// tb_task2_weight_layout: strict multi-channel conv with spatially varying weights
`timescale 1ns / 1ps

module tb_task2_weight_layout #(
    parameter integer IN_W_P  = 7,
    parameter integer IN_H_P  = 7,
    parameter integer IN_C_P  = 2,
    parameter integer OUT_C_P = 5,
    parameter integer BUF_ENTRIES_P = 1024,
    parameter integer BUF_ADDR_W_P = 10
) ();
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

    localparam ACT_BASE = 32'h0000_0100;
    localparam WGT_BASE = 32'h0000_1000;
    localparam OUT_BASE = 32'h0000_2000;

    localparam IN_W = IN_W_P[15:0];
    localparam IN_H = IN_H_P[15:0];
    localparam IN_C = IN_C_P[15:0];
    localparam OUT_C = OUT_C_P[15:0];
    localparam OUT_W = IN_W_P - 4;
    localparam OUT_H = IN_H_P - 4;
    localparam OUT_WORDS = OUT_W * OUT_H * OUT_C;

    npu_top #(.TILE_ROWS(7), .TILE_COLS(13), .BUF_ENTRIES(BUF_ENTRIES_P), .BUF_ADDR_W(BUF_ADDR_W_P)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(1'b0), .s_axi_arready(), .s_axi_araddr(32'h0),
        .s_axi_rvalid(), .s_axi_rready(1'b0), .s_axi_rdata(), .s_axi_rresp(),
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
        .m_axi_wdata(npu_wdata), .m_axi_wlast(npu_wlast), .m_axi_wstrb(npu_wstrb),
        .m_axi_bvalid(preload ? 1'b0 : ram_bvalid), .m_axi_bready(npu_bready), .m_axi_bresp(ram_bresp),
        .npu_busy(npu_busy), .npu_done(npu_done), .npu_error(npu_error), .npu_error_code(npu_error_code)
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

    task preload_word;
        input [31:0] addr, data;
        begin
            @(posedge clk);
            tb_awvalid = 1'b1; tb_awaddr = addr; tb_wvalid = 1'b1; tb_wdata = data;
            @(posedge clk);
            tb_awvalid = 1'b0;
            @(posedge clk);
            tb_wvalid = 1'b0;
            @(posedge clk);
        end
    endtask

    function signed [7:0] act_val;
        input integer h, w, c;
        integer raw;
        begin
            raw = (h * 7 + w * 3 + c * 5) - 20;
            act_val = raw[7:0];
        end
    endfunction

    function signed [7:0] wgt_val;
        input integer ci, kh, kw, oc;
        integer raw;
        begin
            raw = (ci * 11) - (kh * 3) + (kw * 2) + (oc * 5) - 7;
            wgt_val = raw[7:0];
        end
    endfunction

    task preload_activations;
        integer h, w, c, byte_idx;
        reg [7:0] bytes [0:3];
        reg [31:0] word_val;
        begin
            byte_idx = 0;
            word_val = 32'd0;
            for (h = 0; h < IN_H; h = h + 1) begin
                for (w = 0; w < IN_W; w = w + 1) begin
                    for (c = 0; c < IN_C; c = c + 1) begin
                        bytes[byte_idx[1:0]] = act_val(h, w, c);
                        if (byte_idx[1:0] == 3) begin
                            word_val = {bytes[3], bytes[2], bytes[1], bytes[0]};
                            preload_word(ACT_BASE + (byte_idx - 3), word_val);
                        end
                        byte_idx = byte_idx + 1;
                    end
                end
            end
            if ((byte_idx & 3) != 0) begin
                if ((byte_idx & 3) == 1) begin bytes[1]=0; bytes[2]=0; bytes[3]=0; end
                if ((byte_idx & 3) == 2) begin bytes[2]=0; bytes[3]=0; end
                if ((byte_idx & 3) == 3) begin bytes[3]=0; end
                word_val = {bytes[3], bytes[2], bytes[1], bytes[0]};
                preload_word(ACT_BASE + (byte_idx & ~3), word_val);
            end
        end
    endtask

    task preload_weights;
        integer ci, kh, kw, oc, byte_idx;
        integer valid_bytes_per_ci, bytes_per_ci;
        reg [7:0] bytes [0:3];
        reg [31:0] word_val;
        begin
            valid_bytes_per_ci = 25 * OUT_C;
            bytes_per_ci = ((valid_bytes_per_ci + 3) / 4) * 4;
            for (ci = 0; ci < IN_C; ci = ci + 1) begin
                byte_idx = 0;
                for (kh = 0; kh < 5; kh = kh + 1) begin
                    for (kw = 0; kw < 5; kw = kw + 1) begin
                        for (oc = 0; oc < OUT_C; oc = oc + 1) begin
                            bytes[byte_idx[1:0]] = wgt_val(ci, kh, kw, oc);
                            if (byte_idx[1:0] == 3) begin
                                word_val = {bytes[3], bytes[2], bytes[1], bytes[0]};
                                preload_word(WGT_BASE + ci * bytes_per_ci + (byte_idx - 3), word_val);
                            end
                            byte_idx = byte_idx + 1;
                        end
                    end
                end
                while ((byte_idx & 3) != 0) begin
                    bytes[byte_idx[1:0]] = 8'd0;
                    if (byte_idx[1:0] == 3) begin
                        word_val = {bytes[3], bytes[2], bytes[1], bytes[0]};
                        preload_word(WGT_BASE + ci * bytes_per_ci + (byte_idx - 3), word_val);
                    end
                    byte_idx = byte_idx + 1;
                end
            end
        end
    endtask

    function signed [31:0] golden_conv;
        input integer oh, ow, oc;
        integer ci, kh, kw;
        reg signed [31:0] acc;
        begin
            acc = 0;
            for (ci = 0; ci < IN_C; ci = ci + 1)
                for (kh = 0; kh < 5; kh = kh + 1)
                    for (kw = 0; kw < 5; kw = kw + 1)
                        acc = acc + act_val(oh + kh, ow + kw, ci) * wgt_val(ci, kh, kw, oc);
            golden_conv = acc;
        end
    endfunction

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

    integer errors;
    integer h, w, c;
    integer idx;
    reg signed [31:0] actual, expected;

    initial begin
        clk = 0; rst_n = 0; preload = 0; errors = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0; s_axi_wstrb = 4'hF;
        tb_awvalid = 0; tb_wvalid = 0; tb_awaddr = 0; tb_wdata = 0;

        #20 rst_n = 1;
        #20 preload = 1;
        preload_activations();
        preload_weights();
        preload = 0;

        axi_write(32'h1000_0008, 32'd0);
        axi_write(32'h1000_000C, ACT_BASE);
        axi_write(32'h1000_0010, WGT_BASE);
        axi_write(32'h1000_0014, OUT_BASE);
        axi_write(32'h1000_0018, IN_W * IN_H * IN_C);
        axi_write(32'h1000_001C, IN_C * (((25 * OUT_C) + 3) & 32'hFFFF_FFFC));
        axi_write(32'h1000_0020, OUT_WORDS * 4);
        axi_write(32'h1000_0024, {IN_W[15:0], IN_H[15:0]});
        axi_write(32'h1000_0028, {OUT_C[15:0], IN_C[15:0]});
        axi_write(32'h1000_002C, 32'd0);
        axi_write(32'h1000_0000, 32'h1);

        wait_done(2000000);
        if (npu_error) $fatal(1, "NPU error 0x%02h", npu_error_code);
        if (!npu_done) $fatal(1, "TIMEOUT");

        idx = 0;
        for (h = 0; h < OUT_H; h = h + 1) begin
            for (w = 0; w < OUT_W; w = w + 1) begin
                for (c = 0; c < OUT_C; c = c + 1) begin
                    actual = u_ram.ram[(OUT_BASE >> 2) + idx];
                    expected = golden_conv(h, w, c);
                    if (actual !== expected) begin
                        errors = errors + 1;
                        if (errors <= 12)
                            $display("mismatch idx=%0d h=%0d w=%0d c=%0d got=%0d exp=%0d", idx, h, w, c, actual, expected);
                    end
                    idx = idx + 1;
                end
            end
        end

        if (errors != 0)
            $fatal(1, "tb_task2_weight_layout FAILED with %0d mismatches", errors);
        else
            $display("tb_task2_weight_layout PASS");

        #20 $finish;
    end
endmodule
