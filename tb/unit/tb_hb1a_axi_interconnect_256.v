`timescale 1ns / 1ps

module tb_hb1a_axi_interconnect_256;
    reg clk;
    reg rst_n;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    reg         cpu_awvalid;
    wire        cpu_awready;
    reg  [31:0] cpu_awaddr;
    reg         cpu_wvalid;
    wire        cpu_wready;
    reg  [31:0] cpu_wdata;
    reg  [3:0]  cpu_wstrb;
    wire        cpu_bvalid;
    reg         cpu_bready;
    reg         cpu_arvalid;
    wire        cpu_arready;
    reg  [31:0] cpu_araddr;
    wire        cpu_rvalid;
    reg         cpu_rready;
    wire [31:0] cpu_rdata;

    wire        npu_awvalid;
    reg         npu_awready;
    wire [31:0] npu_awaddr;
    wire        npu_wvalid;
    reg         npu_wready;
    wire [31:0] npu_wdata;
    wire [3:0]  npu_wstrb;
    reg         npu_bvalid;
    wire        npu_bready;
    wire        npu_arvalid;
    reg         npu_arready;
    wire [31:0] npu_araddr;
    reg         npu_rvalid;
    wire        npu_rready;
    reg  [31:0] npu_rdata;

    wire        mem_awvalid;
    reg         mem_awready;
    wire [31:0] mem_awaddr;
    wire        mem_wvalid;
    reg         mem_wready;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg         mem_bvalid;
    wire        mem_bready;
    wire        mem_arvalid;
    reg         mem_arready;
    wire [31:0] mem_araddr;
    reg         mem_rvalid;
    wire        mem_rready;
    reg  [31:0] mem_rdata;

    reg          dma_arvalid;
    wire         dma_arready;
    reg  [31:0] dma_araddr;
    reg  [7:0]  dma_arlen;
    reg  [2:0]  dma_arsize;
    reg  [1:0]  dma_arburst;
    wire         dma_rvalid;
    reg          dma_rready;
    wire [255:0] dma_rdata;
    wire         dma_rlast;
    wire [1:0]   dma_rresp;
    reg          dma_awvalid;
    wire         dma_awready;
    reg  [31:0] dma_awaddr;
    reg  [7:0]  dma_awlen;
    reg  [2:0]  dma_awsize;
    reg  [1:0]  dma_awburst;
    reg          dma_wvalid;
    wire         dma_wready;
    reg  [255:0] dma_wdata;
    reg          dma_wlast;
    reg  [31:0]  dma_wstrb;
    wire         dma_bvalid;
    reg          dma_bready;
    wire [1:0]   dma_bresp;

    wire         mem4_awvalid;
    reg          mem4_awready;
    wire [31:0]  mem4_awaddr;
    wire [7:0]   mem4_awlen;
    wire [2:0]   mem4_awsize;
    wire [1:0]   mem4_awburst;
    wire         mem4_wvalid;
    reg          mem4_wready;
    wire [255:0] mem4_wdata;
    wire         mem4_wlast;
    wire [31:0]  mem4_wstrb;
    reg          mem4_bvalid;
    wire         mem4_bready;
    reg  [1:0]   mem4_bresp;
    wire         mem4_arvalid;
    reg          mem4_arready;
    wire [31:0]  mem4_araddr;
    wire [7:0]   mem4_arlen;
    wire [2:0]   mem4_arsize;
    wire [1:0]   mem4_arburst;
    reg          mem4_rvalid;
    wire         mem4_rready;
    reg  [255:0] mem4_rdata;
    reg          mem4_rlast;
    reg  [1:0]   mem4_rresp;

    axi_interconnect #(.CPU_AXI_DATA_W(32), .DMA_AXI_DATA_W(256)) u_interconnect (
        .clk(clk), .rst_n(rst_n),
        .cpu_awvalid(cpu_awvalid), .cpu_awready(cpu_awready), .cpu_awaddr(cpu_awaddr),
        .cpu_awprot(3'b000), .cpu_wvalid(cpu_wvalid), .cpu_wready(cpu_wready),
        .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb), .cpu_bvalid(cpu_bvalid),
        .cpu_bready(cpu_bready), .cpu_bresp(), .cpu_arvalid(cpu_arvalid),
        .cpu_arready(cpu_arready), .cpu_araddr(cpu_araddr), .cpu_arprot(3'b000),
        .cpu_rvalid(cpu_rvalid), .cpu_rready(cpu_rready), .cpu_rdata(cpu_rdata), .cpu_rresp(),
        .npu_awvalid(npu_awvalid), .npu_awready(npu_awready), .npu_awaddr(npu_awaddr),
        .npu_wvalid(npu_wvalid), .npu_wready(npu_wready), .npu_wdata(npu_wdata),
        .npu_wstrb(npu_wstrb), .npu_bvalid(npu_bvalid), .npu_bready(npu_bready),
        .npu_bresp(2'b00), .npu_arvalid(npu_arvalid), .npu_arready(npu_arready),
        .npu_araddr(npu_araddr), .npu_rvalid(npu_rvalid), .npu_rready(npu_rready),
        .npu_rdata(npu_rdata), .npu_rresp(2'b00),
        .mem_awvalid(mem_awvalid), .mem_awready(mem_awready), .mem_awaddr(mem_awaddr),
        .mem_wvalid(mem_wvalid), .mem_wready(mem_wready), .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb), .mem_bvalid(mem_bvalid), .mem_bready(mem_bready),
        .mem_bresp(2'b00), .mem_arvalid(mem_arvalid), .mem_arready(mem_arready),
        .mem_araddr(mem_araddr), .mem_rvalid(mem_rvalid), .mem_rready(mem_rready),
        .mem_rdata(mem_rdata), .mem_rresp(2'b00),
        .dma_arvalid(dma_arvalid), .dma_arready(dma_arready), .dma_araddr(dma_araddr),
        .dma_arlen(dma_arlen), .dma_arsize(dma_arsize), .dma_arburst(dma_arburst),
        .dma_rvalid(dma_rvalid), .dma_rready(dma_rready), .dma_rdata(dma_rdata),
        .dma_rlast(dma_rlast), .dma_rresp(dma_rresp),
        .dma_awvalid(dma_awvalid), .dma_awready(dma_awready), .dma_awaddr(dma_awaddr),
        .dma_awlen(dma_awlen), .dma_awsize(dma_awsize), .dma_awburst(dma_awburst),
        .dma_wvalid(dma_wvalid), .dma_wready(dma_wready), .dma_wdata(dma_wdata),
        .dma_wlast(dma_wlast), .dma_wstrb(dma_wstrb), .dma_bvalid(dma_bvalid),
        .dma_bready(dma_bready), .dma_bresp(dma_bresp),
        .mem4_awvalid(mem4_awvalid), .mem4_awready(mem4_awready), .mem4_awaddr(mem4_awaddr),
        .mem4_awlen(mem4_awlen), .mem4_awsize(mem4_awsize), .mem4_awburst(mem4_awburst),
        .mem4_wvalid(mem4_wvalid), .mem4_wready(mem4_wready), .mem4_wdata(mem4_wdata),
        .mem4_wlast(mem4_wlast), .mem4_wstrb(mem4_wstrb), .mem4_bvalid(mem4_bvalid),
        .mem4_bready(mem4_bready), .mem4_bresp(mem4_bresp), .mem4_arvalid(mem4_arvalid),
        .mem4_arready(mem4_arready), .mem4_araddr(mem4_araddr), .mem4_arlen(mem4_arlen),
        .mem4_arsize(mem4_arsize), .mem4_arburst(mem4_arburst), .mem4_rvalid(mem4_rvalid),
        .mem4_rready(mem4_rready), .mem4_rdata(mem4_rdata), .mem4_rlast(mem4_rlast),
        .mem4_rresp(mem4_rresp)
    );

    initial begin
        rst_n = 1'b0;
        cpu_awvalid = 0; cpu_awaddr = 0; cpu_wvalid = 0; cpu_wdata = 0; cpu_wstrb = 0;
        cpu_bready = 0; cpu_arvalid = 0; cpu_araddr = 0; cpu_rready = 0;
        npu_awready = 0; npu_wready = 0; npu_bvalid = 0; npu_arready = 0; npu_rvalid = 0; npu_rdata = 0;
        mem_awready = 1; mem_wready = 1; mem_bvalid = 0; mem_arready = 1; mem_rvalid = 0; mem_rdata = 0;
        dma_arvalid = 0; dma_araddr = 0; dma_arlen = 0; dma_arsize = 0; dma_arburst = 0; dma_rready = 0;
        dma_awvalid = 0; dma_awaddr = 0; dma_awlen = 0; dma_awsize = 0; dma_awburst = 0;
        dma_wvalid = 0; dma_wdata = 0; dma_wlast = 0; dma_wstrb = 0; dma_bready = 0;
        mem4_awready = 1; mem4_wready = 1; mem4_bvalid = 1; mem4_bresp = 2'b00;
        mem4_arready = 1; mem4_rvalid = 1; mem4_rdata = 256'h0123_4567_89ab_cdef_0011_2233_4455_6677_8899_aabb_ccdd_eeff_dead_beef_cafe_f00d;
        mem4_rlast = 1; mem4_rresp = 2'b00;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        dma_awaddr = 32'h0000_0120;
        dma_awlen = 8'd3;
        dma_awsize = 3'd5;
        dma_awburst = 2'b01;
        dma_awvalid = 1'b1;
        dma_wdata = 256'hffeeddccbbaa9988_7766554433221100_0102030405060708_1112131415161718;
        dma_wstrb = 32'h00ff_ffff;
        dma_wlast = 1'b1;
        dma_wvalid = 1'b1;
        dma_bready = 1'b1;
        #1;
        if (mem4_awaddr !== dma_awaddr || mem4_awlen !== dma_awlen || mem4_awsize !== 3'd5 ||
            mem4_wdata !== dma_wdata || mem4_wstrb !== dma_wstrb || mem4_wlast !== dma_wlast ||
            !dma_awready || !dma_wready || !dma_bvalid) begin
            $display("tb_hb1a_axi_interconnect_256 FAIL DMA write pass-through");
            $fatal(1);
        end

        dma_araddr = 32'h0000_0200;
        dma_arlen = 8'd1;
        dma_arsize = 3'd5;
        dma_arburst = 2'b01;
        dma_arvalid = 1'b1;
        dma_rready = 1'b1;
        #1;
        if (mem4_araddr !== dma_araddr || mem4_arlen !== dma_arlen || mem4_arsize !== 3'd5 ||
            !dma_arready || !dma_rvalid || dma_rdata !== mem4_rdata || !dma_rlast || dma_rresp !== 2'b00) begin
            $display("tb_hb1a_axi_interconnect_256 FAIL DMA read pass-through");
            $fatal(1);
        end

        // CPU AXI-Lite data width remains 32-bit.
        cpu_awaddr = 32'h0000_0040;
        cpu_wdata = 32'h1234_5678;
        cpu_wstrb = 4'hF;
        cpu_awvalid = 1'b1;
        @(posedge clk);
        if (mem_wdata !== 32'h1234_5678 || mem_wstrb !== 4'hF || mem4_wdata !== dma_wdata) begin
            $display("tb_hb1a_axi_interconnect_256 FAIL CPU 32-bit side changed");
            $fatal(1);
        end

        $display("tb_hb1a_axi_interconnect_256 PASS");
        $finish;
    end
endmodule
