`timescale 1ns / 1ps

module tb_dma_axi_reader_protocol;
    reg clk;
    reg rst_n;
    integer errors;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        #200000;
        $display("FAIL tb_dma_axi_reader_protocol timeout");
        $fatal(1);
    end

    reg         start;
    reg  [31:0] base_addr;
    reg  [31:0] byte_count;
    wire        done;
    wire        error;
    wire [7:0]  error_code;
    wire        busy;
    wire [255:0] data_out;
    wire        data_valid;
    reg         data_ready;
    wire [31:0] araddr;
    wire        arvalid;
    reg         arready;
    wire [7:0]  arlen;
    wire [2:0]  arsize;
    wire [1:0]  arburst;
    reg  [255:0] rdata;
    reg          rvalid;
    wire         rready;
    reg          rlast;
    reg  [1:0]   rresp;

    dma_axi_reader #(.AXI_DATA_WIDTH(256), .MAX_BURST_LEN(2)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .base_addr(base_addr), .byte_count(byte_count),
        .done(done), .error(error), .error_code(error_code), .busy(busy),
        .data_out(data_out), .data_valid(data_valid), .data_ready(data_ready),
        .m_axi_araddr(araddr), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_rdata(rdata), .m_axi_rvalid(rvalid), .m_axi_rready(rready),
        .m_axi_rlast(rlast), .m_axi_rresp(rresp)
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
            data_ready = 1'b1;
            arready = 1'b0;
            rdata = 256'h0;
            rvalid = 1'b0;
            rlast = 1'b0;
            rresp = 2'b00;
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task start_read;
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

    task accept_ar;
        input [31:0] exp_addr;
        input [7:0]  exp_len;
        begin
            arready = 1'b1;
            while (!arvalid) @(posedge clk);
            #1;
            check(araddr == exp_addr, "ARADDR mismatch");
            check(arlen == exp_len, "ARLEN mismatch");
            check(arsize == 3'd5, "ARSIZE should be 256-bit");
            check(arburst == 2'b01, "ARBURST should be INCR");
            @(posedge clk);
            #1;
            arready = 1'b0;
        end
    endtask

    task send_r_beat;
        input [255:0] data;
        input         last;
        input [1:0]   resp;
        begin
            rdata = data;
            rlast = last;
            rresp = resp;
            rvalid = 1'b1;
            while (!rready) @(posedge clk);
            @(posedge clk);
            #1;
            rvalid = 1'b0;
            rlast = 1'b0;
            rresp = 2'b00;
        end
    endtask

    initial begin
        errors = 0;

        reset_dut();
        start_read(32'h0000_0004, 32'd32);
        check(error && error_code == 8'h21, "unaligned read should raise ERR_ALIGN");

        reset_dut();
        start_read(32'h0000_0000, 32'd96);
        accept_ar(32'h0000_0000, 8'd1);
        data_ready = 1'b0;
        rdata = 256'h1111;
        rlast = 1'b0;
        rresp = 2'b00;
        rvalid = 1'b1;
        repeat (2) begin
            @(posedge clk);
            #1;
            check(!rready, "RREADY should follow data backpressure");
            check(rvalid && rdata == 256'h1111 && !rlast && rresp == 2'b00,
                  "test slave holds R channel stable during backpressure");
        end
        data_ready = 1'b1;
        while (!rready) @(posedge clk);
        @(posedge clk);
        #1;
        rvalid = 1'b0;
        send_r_beat(256'h2222, 1'b1, 2'b00);
        accept_ar(32'h0000_0040, 8'd0);
        send_r_beat(256'h3333, 1'b1, 2'b00);
        while (!done && !error) @(posedge clk);
        check(!error, "split burst read should complete without error");

        reset_dut();
        start_read(32'h0000_0000, 32'd32);
        accept_ar(32'h0000_0000, 8'd0);
        send_r_beat(256'h4444, 1'b1, 2'b10);
        check(error && error_code == 8'h20, "RRESP error should raise ERR_RRESP");

        reset_dut();
        start_read(32'h0000_0000, 32'd64);
        accept_ar(32'h0000_0000, 8'd1);
        send_r_beat(256'h5555, 1'b1, 2'b00);
        check(error && error_code == 8'h22, "early RLAST should raise internal protocol error");

        if (errors == 0) begin
            $display("PASS tb_dma_axi_reader_protocol");
            $finish;
        end
        $display("FAIL tb_dma_axi_reader_protocol errors=%0d", errors);
        $fatal(1);
    end
endmodule
