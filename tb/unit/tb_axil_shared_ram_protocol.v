`timescale 1ns / 1ps

module tb_axil_shared_ram_protocol;
    reg clk;
    reg rst_n;

    reg         awvalid;
    wire        awready;
    reg  [31:0] awaddr;
    reg         wvalid;
    wire        wready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    wire        bvalid;
    reg         bready;
    wire [1:0]  bresp;
    reg         arvalid;
    wire        arready;
    reg  [31:0] araddr;
    wire        rvalid;
    reg         rready;
    wire [31:0] rdata;
    wire [1:0]  rresp;

    shared_ram #(.RAM_DEPTH(32768)) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_awvalid(awvalid),
        .cpu_awready(awready),
        .cpu_awaddr(awaddr),
        .cpu_wvalid(wvalid),
        .cpu_wready(wready),
        .cpu_wdata(wdata),
        .cpu_wstrb(wstrb),
        .cpu_bvalid(bvalid),
        .cpu_bready(bready),
        .cpu_bresp(bresp),
        .cpu_arvalid(arvalid),
        .cpu_arready(arready),
        .cpu_araddr(araddr),
        .cpu_rvalid(rvalid),
        .cpu_rready(rready),
        .cpu_rdata(rdata),
        .cpu_rresp(rresp),
        .npu_awvalid(1'b0),
        .npu_awready(),
        .npu_awaddr(32'h0),
        .npu_awlen(8'h0),
        .npu_awsize(3'h0),
        .npu_awburst(2'h0),
        .npu_wvalid(1'b0),
        .npu_wready(),
        .npu_wdata(256'h0),
        .npu_wlast(1'b0),
        .npu_wstrb(32'h0),
        .npu_bvalid(),
        .npu_bready(1'b0),
        .npu_bresp(),
        .npu_arvalid(1'b0),
        .npu_arready(),
        .npu_araddr(32'h0),
        .npu_arlen(8'h0),
        .npu_arsize(3'h0),
        .npu_arburst(2'h0),
        .npu_rvalid(),
        .npu_rready(1'b0),
        .npu_rdata(),
        .npu_rlast(),
        .npu_rresp()
    );

    always #5 clk = ~clk;

    task fail;
        input [255:0] msg;
        begin
            $display("tb_axil_shared_ram_protocol FAIL: %0s", msg);
            $finish;
        end
    endtask

    task init_bus;
        begin
            awvalid = 1'b0;
            awaddr  = 32'h0;
            wvalid  = 1'b0;
            wdata   = 32'h0;
            wstrb   = 4'h0;
            bready  = 1'b0;
            arvalid = 1'b0;
            araddr  = 32'h0;
            rready  = 1'b0;
        end
    endtask

    task accept_aw;
        input [31:0] addr;
        begin
            awaddr  <= addr;
            awvalid <= 1'b1;
            while (!awready) @(posedge clk);
            @(posedge clk);
            awvalid <= 1'b0;
        end
    endtask

    task accept_w;
        input [31:0] data;
        input [3:0]  strb;
        begin
            wdata  <= data;
            wstrb  <= strb;
            wvalid <= 1'b1;
            while (!wready) @(posedge clk);
            @(posedge clk);
            wvalid <= 1'b0;
        end
    endtask

    task check_b_stall;
        reg [1:0] held_resp;
        begin
            bready <= 1'b0;
            while (!bvalid) @(posedge clk);
            held_resp = bresp;
            repeat (3) begin
                @(posedge clk);
                if (!bvalid) fail("BVALID dropped while BREADY=0");
                if (bresp !== held_resp) fail("BRESP changed while BREADY=0");
            end
            bready <= 1'b1;
            @(posedge clk);
            bready <= 1'b0;
            if (held_resp !== 2'b00) fail("unexpected BRESP");
        end
    endtask

    task write_aw_first;
        input [31:0] addr;
        input [31:0] data;
        begin
            accept_aw(addr);
            repeat (2) @(posedge clk);
            accept_w(data, 4'hF);
            check_b_stall();
        end
    endtask

    task write_w_first;
        input [31:0] addr;
        input [31:0] data;
        begin
            accept_w(data, 4'hF);
            repeat (2) @(posedge clk);
            accept_aw(addr);
            check_b_stall();
        end
    endtask

    task write_same_cycle;
        input [31:0] addr;
        input [31:0] data;
        begin
            awaddr  <= addr;
            wdata   <= data;
            wstrb   <= 4'hF;
            awvalid <= 1'b1;
            wvalid  <= 1'b1;
            while (!(awready && wready)) @(posedge clk);
            @(posedge clk);
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            check_b_stall();
        end
    endtask

    task read_check;
        input [31:0] addr;
        input [31:0] expected;
        reg [31:0] held_data;
        reg [1:0]  held_resp;
        begin
            araddr  <= addr;
            arvalid <= 1'b1;
            while (!arready) @(posedge clk);
            @(posedge clk);
            arvalid <= 1'b0;
            rready  <= 1'b0;
            while (!rvalid) @(posedge clk);
            held_data = rdata;
            held_resp = rresp;
            repeat (3) begin
                @(posedge clk);
                if (!rvalid) fail("RVALID dropped while RREADY=0");
                if (rdata !== held_data) fail("RDATA changed while RREADY=0");
                if (rresp !== held_resp) fail("RRESP changed while RREADY=0");
            end
            if (held_resp !== 2'b00) fail("unexpected RRESP");
            if (held_data !== expected) begin
                $display("read addr=0x%08x got=0x%08x expected=0x%08x", addr, held_data, expected);
                fail("read data mismatch");
            end
            rready <= 1'b1;
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        init_bus();
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        write_aw_first(32'h0000_0100, 32'h1122_3344);
        write_w_first(32'h0000_0104, 32'h5566_7788);
        write_same_cycle(32'h0000_0108, 32'h99aa_bbcc);

        read_check(32'h0000_0100, 32'h1122_3344);
        read_check(32'h0000_0104, 32'h5566_7788);
        read_check(32'h0000_0108, 32'h99aa_bbcc);

        $display("tb_axil_shared_ram_protocol PASS");
        $finish;
    end
endmodule
