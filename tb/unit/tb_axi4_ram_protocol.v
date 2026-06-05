`timescale 1ns / 1ps

module tb_axi4_ram_protocol;
    reg clk;
    reg rst_n;
    integer errors;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        #200000;
        $display("FAIL tb_axi4_ram_protocol timeout");
        $fatal(1);
    end

    reg         awvalid;
    wire        awready;
    reg  [31:0] awaddr;
    reg  [7:0]  awlen;
    reg  [2:0]  awsize;
    reg  [1:0]  awburst;
    reg         wvalid;
    wire        wready;
    reg  [255:0] wdata;
    reg  [31:0]  wstrb;
    reg          wlast;
    wire         bvalid;
    reg          bready;
    wire [1:0]   bresp;
    reg          arvalid;
    wire         arready;
    reg  [31:0]  araddr;
    reg  [7:0]   arlen;
    reg  [2:0]   arsize;
    reg  [1:0]   arburst;
    wire         rvalid;
    reg          rready;
    wire [255:0] rdata;
    wire         rlast;
    wire [1:0]   rresp;

    axi4_ram #(.RAM_DEPTH(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_awaddr(awaddr),
        .s_axi_awlen(awlen), .s_axi_awsize(awsize), .s_axi_awburst(awburst),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_bresp(bresp),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready), .s_axi_araddr(araddr),
        .s_axi_arlen(arlen), .s_axi_arsize(arsize), .s_axi_arburst(arburst),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready), .s_axi_rdata(rdata),
        .s_axi_rlast(rlast), .s_axi_rresp(rresp)
    );

    function [255:0] beat_pattern;
        input [7:0] base;
        integer i;
        begin
            beat_pattern = 256'h0;
            for (i = 0; i < 32; i = i + 1)
                beat_pattern[i*8 +: 8] = base + i[7:0];
        end
    endfunction

    task check;
        input cond;
        input [255:0] msg;
        begin
            if (!cond) begin
                $display("FAIL %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    task reset_bus;
        begin
            awvalid = 1'b0; awaddr = 32'h0; awlen = 8'h0; awsize = 3'd5; awburst = 2'b01;
            wvalid = 1'b0; wdata = 256'h0; wstrb = 32'h0; wlast = 1'b0; bready = 1'b0;
            arvalid = 1'b0; araddr = 32'h0; arlen = 8'h0; arsize = 3'd5; arburst = 2'b01;
            rready = 1'b0;
        end
    endtask

    task axi_write;
        input [31:0] addr;
        input [7:0]  len;
        input [2:0]  size;
        input [1:0]  burst;
        input        suppress_final_wlast;
        output [1:0] resp;
        integer i;
        begin
            @(posedge clk);
            awaddr = addr; awlen = len; awsize = size; awburst = burst; awvalid = 1'b1;
            while (!awready) @(posedge clk);
            @(posedge clk);
            awvalid = 1'b0;
            for (i = 0; i <= len; i = i + 1) begin
                wdata = beat_pattern(8'h40 + i);
                wstrb = 32'hffff_ffff;
                wlast = (i == len) && !suppress_final_wlast;
                wvalid = 1'b1;
                while (!wready) @(posedge clk);
                @(posedge clk);
                wvalid = 1'b0;
                wlast = 1'b0;
            end
            bready = 1'b0;
            while (!bvalid) @(posedge clk);
            resp = bresp;
            @(posedge clk);
            check(bvalid && (bresp == resp), "BVALID/BRESP should hold while BREADY is low");
            bready = 1'b1;
            @(posedge clk);
            bready = 1'b0;
        end
    endtask

    task axi_read;
        input [31:0] addr;
        input [7:0]  len;
        input [2:0]  size;
        input [1:0]  burst;
        input        stall_first;
        output [1:0] last_resp;
        integer i;
        reg [255:0] hold_data;
        reg [1:0] hold_resp;
        reg hold_last;
        begin
            @(posedge clk);
            araddr = addr; arlen = len; arsize = size; arburst = burst; arvalid = 1'b1;
            while (!arready) @(posedge clk);
            @(posedge clk);
            arvalid = 1'b0;
            rready = 1'b0;
            for (i = 0; i <= len; i = i + 1) begin
                while (!rvalid) @(posedge clk);
                #1;
                if (stall_first && i == 0) begin
                    hold_data = rdata;
                    hold_resp = rresp;
                    hold_last = rlast;
                    @(posedge clk);
                    #1;
                    check(rvalid && rdata == hold_data && rresp == hold_resp && rlast == hold_last,
                          "R channel should hold stable while RREADY is low");
                end
                check(rlast == (i == len), "RLAST should match ARLEN");
                last_resp = rresp;
                rready = 1'b1;
                @(posedge clk);
                #1;
                rready = 1'b0;
            end
        end
    endtask

    reg [1:0] resp;

    initial begin
        errors = 0;
        reset_bus();
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        wvalid <= 1'b1;
        wdata <= beat_pattern(8'h10);
        wstrb <= 32'hffff_ffff;
        wlast <= 1'b1;
        repeat (2) begin
            @(posedge clk);
            check(!wready, "WREADY should stay low before a write address is active");
        end
        wvalid <= 1'b0;
        wlast <= 1'b0;

        axi_write(32'h0000_0000, 8'd1, 3'd5, 2'b01, 1'b0, resp);
        check(resp == 2'b00, "INCR write should return OKAY");
        axi_read(32'h0000_0000, 8'd1, 3'd5, 2'b01, 1'b1, resp);
        check(resp == 2'b00, "INCR read should return OKAY");

        axi_write(32'h0000_0040, 8'd0, 3'd5, 2'b00, 1'b0, resp);
        check(resp == 2'b10, "FIXED write should return SLVERR");
        axi_read(32'h0000_0040, 8'd0, 3'd5, 2'b10, 1'b0, resp);
        check(resp == 2'b10, "WRAP read should return SLVERR");

        axi_write(32'h0000_0060, 8'd0, 3'd4, 2'b01, 1'b0, resp);
        check(resp == 2'b10, "wrong AWSIZE should return SLVERR");
        axi_read(32'h0000_0060, 8'd0, 3'd4, 2'b01, 1'b0, resp);
        check(resp == 2'b10, "wrong ARSIZE should return SLVERR");

        axi_write(32'h0000_0020, 8'd1, 3'd5, 2'b01, 1'b1, resp);
        check(resp == 2'b10, "missing final WLAST should return SLVERR");

        axi_write(32'h0000_0200, 8'd0, 3'd5, 2'b01, 1'b0, resp);
        check(resp == 2'b10, "out-of-range write should return SLVERR");
        axi_read(32'h0000_0200, 8'd0, 3'd5, 2'b01, 1'b0, resp);
        check(resp == 2'b10, "out-of-range read should return SLVERR");

        if (errors == 0) begin
            $display("PASS tb_axi4_ram_protocol");
            $finish;
        end
        $display("FAIL tb_axi4_ram_protocol errors=%0d", errors);
        $fatal(1);
    end
endmodule
