`timescale 1ns / 1ps

module tb_axil_interconnect_protocol;
    reg clk;
    reg rst_n;

    reg         cpu_awvalid;
    wire        cpu_awready;
    reg  [31:0] cpu_awaddr;
    reg  [2:0]  cpu_awprot;
    reg         cpu_wvalid;
    wire        cpu_wready;
    reg  [31:0] cpu_wdata;
    reg  [3:0]  cpu_wstrb;
    wire        cpu_bvalid;
    reg         cpu_bready;
    wire [1:0]  cpu_bresp;
    reg         cpu_arvalid;
    wire        cpu_arready;
    reg  [31:0] cpu_araddr;
    reg  [2:0]  cpu_arprot;
    wire        cpu_rvalid;
    reg         cpu_rready;
    wire [31:0] cpu_rdata;
    wire [1:0]  cpu_rresp;

    wire        npu_awvalid;
    reg         npu_awready;
    wire [31:0] npu_awaddr;
    wire        npu_wvalid;
    reg         npu_wready;
    wire [31:0] npu_wdata;
    wire [3:0]  npu_wstrb;
    reg         npu_bvalid;
    wire        npu_bready;
    reg  [1:0]  npu_bresp;
    wire        npu_arvalid;
    reg         npu_arready;
    wire [31:0] npu_araddr;
    reg         npu_rvalid;
    wire        npu_rready;
    reg  [31:0] npu_rdata;
    reg  [1:0]  npu_rresp;

    wire        mem_awvalid;
    reg         mem_awready;
    wire [31:0] mem_awaddr;
    wire        mem_wvalid;
    reg         mem_wready;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg         mem_bvalid;
    wire        mem_bready;
    reg  [1:0]  mem_bresp;
    wire        mem_arvalid;
    reg         mem_arready;
    wire [31:0] mem_araddr;
    reg         mem_rvalid;
    wire        mem_rready;
    reg  [31:0] mem_rdata;
    reg  [1:0]  mem_rresp;

    axi_interconnect u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_awvalid(cpu_awvalid),
        .cpu_awready(cpu_awready),
        .cpu_awaddr(cpu_awaddr),
        .cpu_awprot(cpu_awprot),
        .cpu_wvalid(cpu_wvalid),
        .cpu_wready(cpu_wready),
        .cpu_wdata(cpu_wdata),
        .cpu_wstrb(cpu_wstrb),
        .cpu_bvalid(cpu_bvalid),
        .cpu_bready(cpu_bready),
        .cpu_bresp(cpu_bresp),
        .cpu_arvalid(cpu_arvalid),
        .cpu_arready(cpu_arready),
        .cpu_araddr(cpu_araddr),
        .cpu_arprot(cpu_arprot),
        .cpu_rvalid(cpu_rvalid),
        .cpu_rready(cpu_rready),
        .cpu_rdata(cpu_rdata),
        .cpu_rresp(cpu_rresp),
        .npu_awvalid(npu_awvalid),
        .npu_awready(npu_awready),
        .npu_awaddr(npu_awaddr),
        .npu_wvalid(npu_wvalid),
        .npu_wready(npu_wready),
        .npu_wdata(npu_wdata),
        .npu_wstrb(npu_wstrb),
        .npu_bvalid(npu_bvalid),
        .npu_bready(npu_bready),
        .npu_bresp(npu_bresp),
        .npu_arvalid(npu_arvalid),
        .npu_arready(npu_arready),
        .npu_araddr(npu_araddr),
        .npu_rvalid(npu_rvalid),
        .npu_rready(npu_rready),
        .npu_rdata(npu_rdata),
        .npu_rresp(npu_rresp),
        .mem_awvalid(mem_awvalid),
        .mem_awready(mem_awready),
        .mem_awaddr(mem_awaddr),
        .mem_wvalid(mem_wvalid),
        .mem_wready(mem_wready),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_bvalid(mem_bvalid),
        .mem_bready(mem_bready),
        .mem_bresp(mem_bresp),
        .mem_arvalid(mem_arvalid),
        .mem_arready(mem_arready),
        .mem_araddr(mem_araddr),
        .mem_rvalid(mem_rvalid),
        .mem_rready(mem_rready),
        .mem_rdata(mem_rdata),
        .mem_rresp(mem_rresp),
        .dma_arvalid(1'b0),
        .dma_arready(),
        .dma_araddr(32'h0),
        .dma_arlen(8'h0),
        .dma_arsize(3'h0),
        .dma_arburst(2'h0),
        .dma_rvalid(),
        .dma_rready(1'b0),
        .dma_rdata(),
        .dma_rlast(),
        .dma_rresp(),
        .dma_awvalid(1'b0),
        .dma_awready(),
        .dma_awaddr(32'h0),
        .dma_awlen(8'h0),
        .dma_awsize(3'h0),
        .dma_awburst(2'h0),
        .dma_wvalid(1'b0),
        .dma_wready(),
        .dma_wdata(256'h0),
        .dma_wlast(1'b0),
        .dma_wstrb(32'h0),
        .dma_bvalid(),
        .dma_bready(1'b0),
        .dma_bresp(),
        .mem4_awvalid(),
        .mem4_awready(1'b0),
        .mem4_awaddr(),
        .mem4_awlen(),
        .mem4_awsize(),
        .mem4_awburst(),
        .mem4_wvalid(),
        .mem4_wready(1'b0),
        .mem4_wdata(),
        .mem4_wlast(),
        .mem4_wstrb(),
        .mem4_bvalid(1'b0),
        .mem4_bready(),
        .mem4_bresp(2'b00),
        .mem4_arvalid(),
        .mem4_arready(1'b0),
        .mem4_araddr(),
        .mem4_arlen(),
        .mem4_arsize(),
        .mem4_arburst(),
        .mem4_rvalid(1'b0),
        .mem4_rready(),
        .mem4_rdata(256'h0),
        .mem4_rlast(1'b0),
        .mem4_rresp(2'b00)
    );

    always #5 clk = ~clk;

    task fail;
        input [255:0] msg;
        begin
            $display("tb_axil_interconnect_protocol FAIL: %0s", msg);
            $finish;
        end
    endtask

    task init_bus;
        begin
            cpu_awvalid = 1'b0;
            cpu_awaddr  = 32'h0;
            cpu_awprot  = 3'h0;
            cpu_wvalid  = 1'b0;
            cpu_wdata   = 32'h0;
            cpu_wstrb   = 4'h0;
            cpu_bready  = 1'b0;
            cpu_arvalid = 1'b0;
            cpu_araddr  = 32'h0;
            cpu_arprot  = 3'h0;
            cpu_rready  = 1'b0;
            npu_awready = 1'b1;
            npu_wready  = 1'b1;
            npu_bvalid  = 1'b0;
            npu_bresp   = 2'b00;
            npu_arready = 1'b1;
            npu_rvalid  = 1'b0;
            npu_rdata   = 32'h0;
            npu_rresp   = 2'b00;
            mem_awready = 1'b1;
            mem_wready  = 1'b1;
            mem_bvalid  = 1'b0;
            mem_bresp   = 2'b00;
            mem_arready = 1'b1;
            mem_rvalid  = 1'b0;
            mem_rdata   = 32'h0;
            mem_rresp   = 2'b00;
        end
    endtask

    task wait_b;
        input [1:0] expected_resp;
        begin
            cpu_bready <= 1'b0;
            while (!cpu_bvalid) @(posedge clk);
            if (cpu_bresp !== expected_resp) fail("unexpected BRESP");
            repeat (2) begin
                @(posedge clk);
                if (!cpu_bvalid) fail("BVALID changed while BREADY=0");
                if (cpu_bresp !== expected_resp) fail("BRESP changed while BREADY=0");
            end
            cpu_bready <= 1'b1;
            @(posedge clk);
            cpu_bready <= 1'b0;
        end
    endtask

    task test_w_before_aw_npu;
        begin
            cpu_wdata  <= 32'hcafe_beef;
            cpu_wstrb  <= 4'hF;
            cpu_wvalid <= 1'b1;
            while (!cpu_wready) @(posedge clk);
            @(posedge clk);
            cpu_wvalid <= 1'b0;
            repeat (2) @(posedge clk);

            cpu_awaddr  <= 32'h1000_0008;
            cpu_awvalid <= 1'b1;
            while (!cpu_awready) @(posedge clk);
            @(posedge clk);
            cpu_awvalid <= 1'b0;

            while (!(npu_awvalid && npu_wvalid)) begin
                if (mem_awvalid || mem_wvalid) fail("NPU write routed to memory");
                @(posedge clk);
            end
            if (npu_awaddr !== 32'h1000_0008) fail("NPU AWADDR mismatch");
            if (npu_wdata !== 32'hcafe_beef) fail("NPU WDATA mismatch");
            @(posedge clk);
            npu_bvalid <= 1'b1;
            @(posedge clk);
            npu_bvalid <= 1'b0;
            wait_b(2'b00);
        end
    endtask

    task test_decode_miss_write;
        begin
            cpu_awaddr  <= 32'h2000_0000;
            cpu_wdata   <= 32'h1234_5678;
            cpu_wstrb   <= 4'hF;
            cpu_awvalid <= 1'b1;
            cpu_wvalid  <= 1'b1;
            while (!(cpu_awready && cpu_wready)) @(posedge clk);
            @(posedge clk);
            cpu_awvalid <= 1'b0;
            cpu_wvalid  <= 1'b0;
            if (npu_awvalid || npu_wvalid || mem_awvalid || mem_wvalid)
                fail("decode miss write forwarded to a slave");
            wait_b(2'b11);
        end
    endtask

    task test_decode_miss_read;
        begin
            cpu_araddr  <= 32'h2000_0000;
            cpu_arvalid <= 1'b1;
            while (!cpu_arready) @(posedge clk);
            @(posedge clk);
            cpu_arvalid <= 1'b0;
            cpu_rready  <= 1'b0;
            while (!cpu_rvalid) @(posedge clk);
            if (cpu_rresp !== 2'b11) fail("decode miss read did not return DECERR");
            if (cpu_rdata !== 32'h0) fail("decode miss read data not zero");
            repeat (2) begin
                @(posedge clk);
                if (!cpu_rvalid) fail("RVALID changed while RREADY=0");
                if (cpu_rresp !== 2'b11) fail("RRESP changed while RREADY=0");
                if (cpu_rdata !== 32'h0) fail("RDATA changed while RREADY=0");
            end
            cpu_rready <= 1'b1;
            @(posedge clk);
            cpu_rready <= 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        init_bus();
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        test_w_before_aw_npu();
        test_decode_miss_write();
        test_decode_miss_read();

        $display("tb_axil_interconnect_protocol PASS");
        $finish;
    end
endmodule
