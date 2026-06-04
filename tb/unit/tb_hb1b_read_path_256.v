`timescale 1ns / 1ps

module tb_hb1b_read_path_256;
    localparam AXI_ADDR_W = 32;
    localparam AXI_DATA_W = 256;
    localparam BUF_ADDR_W = 4;

    reg clk;
    reg rst_n;

    reg act_start, wgt_start;
    wire act_done, act_error, act_busy;
    wire wgt_done, wgt_error, wgt_busy;
    wire [7:0] act_error_code, wgt_error_code;
    wire [BUF_ADDR_W-1:0] act_buf_wr_addr, wgt_buf_wr_addr;
    wire [AXI_DATA_W-1:0] act_buf_wr_data, wgt_buf_wr_data;
    wire act_buf_wr_en, wgt_buf_wr_en;

    wire [AXI_ADDR_W-1:0] act_araddr, wgt_araddr;
    wire act_arvalid, wgt_arvalid;
    reg act_arready, wgt_arready;
    wire [7:0] act_arlen, wgt_arlen;
    wire [2:0] act_arsize, wgt_arsize;
    wire [1:0] act_arburst, wgt_arburst;
    reg [AXI_DATA_W-1:0] act_rdata, wgt_rdata;
    reg act_rvalid, wgt_rvalid;
    wire act_rready, wgt_rready;
    reg act_rlast, wgt_rlast;
    reg [1:0] act_rresp, wgt_rresp;

    reg [AXI_DATA_W-1:0] exp_act [0:1];
    reg [AXI_DATA_W-1:0] exp_wgt [0:1];
    integer act_seen, wgt_seen;

    act_read_path #(
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_DATA_W(AXI_DATA_W),
        .BUF_DATA_W(AXI_DATA_W),
        .BUF_ADDR_W(BUF_ADDR_W)
    ) u_act (
        .clk(clk), .rst_n(rst_n),
        .start(act_start), .base_addr(32'h1000), .byte_count(32'd64),
        .done(act_done), .error(act_error), .error_code(act_error_code), .busy(act_busy),
        .buf_wr_addr(act_buf_wr_addr), .buf_wr_data(act_buf_wr_data), .buf_wr_en(act_buf_wr_en),
        .m_axi_araddr(act_araddr), .m_axi_arvalid(act_arvalid), .m_axi_arready(act_arready),
        .m_axi_arlen(act_arlen), .m_axi_arsize(act_arsize), .m_axi_arburst(act_arburst),
        .m_axi_rdata(act_rdata), .m_axi_rvalid(act_rvalid), .m_axi_rready(act_rready),
        .m_axi_rlast(act_rlast), .m_axi_rresp(act_rresp)
    );

    weight_read_path #(
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_DATA_W(AXI_DATA_W),
        .BUF_DATA_W(AXI_DATA_W),
        .BUF_ADDR_W(BUF_ADDR_W)
    ) u_wgt (
        .clk(clk), .rst_n(rst_n),
        .start(wgt_start), .base_addr(32'h2000), .byte_count(32'd64),
        .done(wgt_done), .error(wgt_error), .error_code(wgt_error_code), .busy(wgt_busy),
        .buf_wr_addr(wgt_buf_wr_addr), .buf_wr_data(wgt_buf_wr_data), .buf_wr_en(wgt_buf_wr_en),
        .m_axi_araddr(wgt_araddr), .m_axi_arvalid(wgt_arvalid), .m_axi_arready(wgt_arready),
        .m_axi_arlen(wgt_arlen), .m_axi_arsize(wgt_arsize), .m_axi_arburst(wgt_arburst),
        .m_axi_rdata(wgt_rdata), .m_axi_rvalid(wgt_rvalid), .m_axi_rready(wgt_rready),
        .m_axi_rlast(wgt_rlast), .m_axi_rresp(wgt_rresp)
    );

    always #5 clk = ~clk;

    task init_beats;
        integer i;
        begin
            exp_act[0] = {AXI_DATA_W{1'b0}};
            exp_act[1] = {AXI_DATA_W{1'b0}};
            exp_wgt[0] = {AXI_DATA_W{1'b0}};
            exp_wgt[1] = {AXI_DATA_W{1'b0}};
            for (i = 0; i < 32; i = i + 1) begin
                exp_act[0][i*8 +: 8] = 8'h10 + i[7:0];
                exp_act[1][i*8 +: 8] = 8'h40 + i[7:0];
                exp_wgt[0][i*8 +: 8] = 8'h80 + i[7:0];
                exp_wgt[1][i*8 +: 8] = 8'hc0 + i[7:0];
            end
        end
    endtask

    task drive_act_read;
        begin
            @(posedge clk);
            act_start <= 1'b1;
            @(posedge clk);
            act_start <= 1'b0;
            wait (act_arvalid);
            if (act_araddr !== 32'h1000 || act_arlen !== 8'd1 || act_arsize !== 3'd5) begin
                $display("FAIL act AR addr/len/size addr=%h len=%0d size=%0d", act_araddr, act_arlen, act_arsize);
                $finish;
            end
            @(posedge clk);
            act_rdata <= exp_act[0];
            act_rvalid <= 1'b1;
            act_rlast <= 1'b0;
            @(posedge clk);
            act_rdata <= exp_act[1];
            act_rlast <= 1'b1;
            @(posedge clk);
            act_rvalid <= 1'b0;
            act_rlast <= 1'b0;
            wait (act_done);
            repeat (2) @(posedge clk);
        end
    endtask

    task drive_wgt_read;
        begin
            @(posedge clk);
            wgt_start <= 1'b1;
            @(posedge clk);
            wgt_start <= 1'b0;
            wait (wgt_arvalid);
            if (wgt_araddr !== 32'h2000 || wgt_arlen !== 8'd1 || wgt_arsize !== 3'd5) begin
                $display("FAIL wgt AR addr/len/size addr=%h len=%0d size=%0d", wgt_araddr, wgt_arlen, wgt_arsize);
                $finish;
            end
            @(posedge clk);
            wgt_rdata <= exp_wgt[0];
            wgt_rvalid <= 1'b1;
            wgt_rlast <= 1'b0;
            @(posedge clk);
            wgt_rdata <= exp_wgt[1];
            wgt_rlast <= 1'b1;
            @(posedge clk);
            wgt_rvalid <= 1'b0;
            wgt_rlast <= 1'b0;
            wait (wgt_done);
            repeat (2) @(posedge clk);
        end
    endtask

    always @(posedge clk) begin
        if (act_buf_wr_en) begin
            if (act_buf_wr_addr !== act_seen[BUF_ADDR_W-1:0] || act_buf_wr_data !== exp_act[act_seen]) begin
                $display("FAIL act buf write addr=%0d seen=%0d", act_buf_wr_addr, act_seen);
                $finish;
            end
            act_seen <= act_seen + 1;
        end
        if (wgt_buf_wr_en) begin
            if (wgt_buf_wr_addr !== wgt_seen[BUF_ADDR_W-1:0] || wgt_buf_wr_data !== exp_wgt[wgt_seen]) begin
                $display("FAIL wgt buf write addr=%0d seen=%0d", wgt_buf_wr_addr, wgt_seen);
                $finish;
            end
            wgt_seen <= wgt_seen + 1;
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        act_start = 0;
        wgt_start = 0;
        act_arready = 1;
        wgt_arready = 1;
        act_rdata = 0;
        wgt_rdata = 0;
        act_rvalid = 0;
        wgt_rvalid = 0;
        act_rlast = 0;
        wgt_rlast = 0;
        act_rresp = 0;
        wgt_rresp = 0;
        act_seen = 0;
        wgt_seen = 0;
        init_beats();

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        drive_act_read();
        if (act_seen != 2 || act_error) begin
            $display("FAIL act path seen=%0d error=%b code=%h", act_seen, act_error, act_error_code);
            $finish;
        end
        $display("HB1B_ACT_READ_PATH_256_PASS");

        drive_wgt_read();
        if (wgt_seen != 2 || wgt_error) begin
            $display("FAIL wgt path seen=%0d error=%b code=%h", wgt_seen, wgt_error, wgt_error_code);
            $finish;
        end
        $display("HB1B_WEIGHT_READ_PATH_256_PASS");
        $display("HB1B_READ_PATH_256_PASS");
        $finish;
    end
endmodule
