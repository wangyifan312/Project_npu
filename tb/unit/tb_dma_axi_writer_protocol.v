`timescale 1ns / 1ps

module tb_dma_axi_writer_protocol;
    reg clk;
    reg rst_n;
    integer errors;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        #200000;
        $display("FAIL tb_dma_axi_writer_protocol timeout");
        $fatal(1);
    end

    reg         start;
    reg  [31:0] base_addr;
    reg  [31:0] byte_count;
    wire        done;
    wire        error;
    wire [7:0]  error_code;
    wire        busy;
    reg  [255:0] data_in;
    reg          data_valid;
    wire         data_ready;
    wire [31:0] awaddr;
    wire        awvalid;
    reg         awready;
    wire [7:0]  awlen;
    wire [2:0]  awsize;
    wire [1:0]  awburst;
    wire [255:0] wdata;
    wire         wvalid;
    reg          wready;
    wire         wlast;
    wire [31:0]  wstrb;
    reg  [1:0]   bresp;
    reg          bvalid;
    wire         bready;

    dma_axi_writer #(.AXI_DATA_WIDTH(256), .MAX_BURST_LEN(2)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .base_addr(base_addr), .byte_count(byte_count),
        .done(done), .error(error), .error_code(error_code), .busy(busy),
        .data_in(data_in), .data_valid(data_valid), .data_ready(data_ready),
        .m_axi_awaddr(awaddr), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_wdata(wdata), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_wlast(wlast), .m_axi_wstrb(wstrb),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready)
    );

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

    task reset_dut;
        begin
            start = 1'b0;
            base_addr = 32'h0;
            byte_count = 32'h0;
            data_in = 256'h0;
            data_valid = 1'b0;
            awready = 1'b0;
            wready = 1'b0;
            bresp = 2'b00;
            bvalid = 1'b0;
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task start_write;
        input [31:0] addr;
        input [31:0] bytes;
        begin
            @(negedge clk);
            base_addr = addr;
            byte_count = bytes;
            start = 1'b1;
            @(posedge clk);
            #1;
            start = 1'b0;
        end
    endtask

    task accept_aw;
        input [31:0] exp_addr;
        input [7:0]  exp_len;
        begin
            awready = 1'b1;
            while (!awvalid) @(posedge clk);
            #1;
            check(awaddr == exp_addr, "AWADDR mismatch");
            check(awlen == exp_len, "AWLEN mismatch");
            check(awsize == 3'd5, "AWSIZE should be 256-bit");
            check(awburst == 2'b01, "AWBURST should be INCR");
            @(posedge clk);
            #1;
            awready = 1'b0;
        end
    endtask

    task provide_and_accept_w;
        input [255:0] exp_data;
        input [31:0]  exp_strb;
        input         exp_last;
        input integer stall_cycles;
        integer i;
        reg [255:0] hold_data;
        reg [31:0] hold_strb;
        reg hold_last;
        begin
            while (!data_ready) @(posedge clk);
            data_in = exp_data;
            data_valid = 1'b1;
            @(posedge clk);
            data_valid = 1'b0;
            while (!wvalid) @(posedge clk);
            check(wdata == exp_data, "WDATA mismatch");
            check(wstrb == exp_strb, "WSTRB mismatch");
            check(wlast == exp_last, "WLAST mismatch");
            hold_data = wdata;
            hold_strb = wstrb;
            hold_last = wlast;
            data_in = ~exp_data;
            data_valid = 1'b1;
            for (i = 0; i < stall_cycles; i = i + 1) begin
                @(posedge clk);
                check(wvalid && wdata == hold_data && wstrb == hold_strb && wlast == hold_last,
                      "W channel should hold stable while WREADY is low");
            end
            data_valid = 1'b0;
            wready = 1'b1;
            @(posedge clk);
            #1;
            wready = 1'b0;
        end
    endtask

    task send_b;
        input [1:0] resp;
        begin
            bresp = resp;
            bvalid = 1'b1;
            while (!bready) @(posedge clk);
            @(posedge clk);
            #1;
            bvalid = 1'b0;
            bresp = 2'b00;
        end
    endtask

    initial begin
        errors = 0;

        reset_dut();
        start_write(32'h0000_0004, 32'd32);
        check(error && error_code == 8'h31, "unaligned write should raise ERR_ALIGN");

        reset_dut();
        start_write(32'h0000_0000, 32'd96);
        accept_aw(32'h0000_0000, 8'd1);
        provide_and_accept_w(256'h0001, 32'hffff_ffff, 1'b0, 2);
        provide_and_accept_w(256'h0002, 32'hffff_ffff, 1'b1, 1);
        send_b(2'b00);
        accept_aw(32'h0000_0040, 8'd0);
        provide_and_accept_w(256'h0003, 32'hffff_ffff, 1'b1, 0);
        send_b(2'b00);
        while (!done) @(posedge clk);
        check(!error, "split burst write should complete without error");

        reset_dut();
        start_write(32'h0000_0100, 32'd50);
        accept_aw(32'h0000_0100, 8'd1);
        provide_and_accept_w(256'h0011, 32'hffff_ffff, 1'b0, 0);
        provide_and_accept_w(256'h0012, 32'h0003_ffff, 1'b1, 0);
        send_b(2'b00);
        while (!done) @(posedge clk);
        check(!error, "partial tail write should complete without error");

        reset_dut();
        start_write(32'h0000_0200, 32'd32);
        accept_aw(32'h0000_0200, 8'd0);
        provide_and_accept_w(256'h00aa, 32'hffff_ffff, 1'b1, 1);
        send_b(2'b10);
        check(error && error_code == 8'h30, "BRESP error should raise ERR_BRESP");

        if (errors == 0) begin
            $display("PASS tb_dma_axi_writer_protocol");
            $finish;
        end
        $display("FAIL tb_dma_axi_writer_protocol errors=%0d", errors);
        $fatal(1);
    end
endmodule
