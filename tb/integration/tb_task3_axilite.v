// tb_task3_axilite: legacy Task3 AXI-Lite target-latch micro-test.
// This test predates AXI-2 compliance and still encodes the old project-subset
// assumption that W-before-AW is blocked by the interconnect. It is retained as
// a legacy/debug asset and is not AXI-2 standard AXI-Lite compliance evidence.
// AXI-2 interconnect compliance is covered by tb_axil_interconnect_protocol.
`timescale 1ns / 1ps

module tb_task3_axilite;
    reg clk, rst_n;

    // CPU side (AXI-Lite master stimulus)
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

    // NPU side (simple responder)
    wire        npu_awvalid, npu_wvalid, npu_bready, npu_arvalid, npu_rready;
    wire [31:0] npu_awaddr, npu_wdata, npu_araddr;
    wire [3:0]  npu_wstrb;
    reg         npu_awready, npu_wready, npu_bvalid, npu_arready, npu_rvalid;
    reg  [1:0]  npu_bresp, npu_rresp;
    reg  [31:0] npu_rdata;

    // Memory side (simple responder)
    wire        mem_awvalid, mem_wvalid, mem_bready, mem_arvalid, mem_rready;
    wire [31:0] mem_awaddr, mem_wdata, mem_araddr;
    wire [3:0]  mem_wstrb;
    reg         mem_awready, mem_wready, mem_bvalid, mem_arready, mem_rvalid;
    reg  [1:0]  mem_bresp, mem_rresp;
    reg  [31:0] mem_rdata;

    // DMA side (tied off)
    wire        mem4_awvalid, mem4_wvalid, mem4_arvalid;
    wire [31:0] mem4_awaddr, mem4_wdata, mem4_araddr;
    wire [7:0]  mem4_awlen, mem4_arlen;
    wire [2:0]  mem4_awsize, mem4_arsize;
    wire [1:0]  mem4_awburst, mem4_arburst;
    wire        mem4_wlast, mem4_bready, mem4_rready;
    wire [3:0]  mem4_wstrb;
    reg         mem4_awready, mem4_wready;

    axi_interconnect u_interconnect (
        .clk(clk), .rst_n(rst_n),
        .cpu_awvalid(cpu_awvalid), .cpu_awready(cpu_awready),
        .cpu_awaddr(cpu_awaddr),   .cpu_awprot(cpu_awprot),
        .cpu_wvalid(cpu_wvalid),   .cpu_wready(cpu_wready),
        .cpu_wdata(cpu_wdata),     .cpu_wstrb(cpu_wstrb),
        .cpu_bvalid(cpu_bvalid),   .cpu_bready(cpu_bready),
        .cpu_bresp(cpu_bresp),
        .cpu_arvalid(cpu_arvalid), .cpu_arready(cpu_arready),
        .cpu_araddr(cpu_araddr),   .cpu_arprot(cpu_arprot),
        .cpu_rvalid(cpu_rvalid),   .cpu_rready(cpu_rready),
        .cpu_rdata(cpu_rdata),     .cpu_rresp(cpu_rresp),
        .npu_awvalid(npu_awvalid), .npu_awready(npu_awready),
        .npu_awaddr(npu_awaddr),   .npu_wvalid(npu_wvalid),
        .npu_wready(npu_wready),   .npu_wdata(npu_wdata),
        .npu_wstrb(npu_wstrb),     .npu_bvalid(npu_bvalid),
        .npu_bready(npu_bready),   .npu_bresp(npu_bresp),
        .npu_arvalid(npu_arvalid), .npu_arready(npu_arready),
        .npu_araddr(npu_araddr),   .npu_rvalid(npu_rvalid),
        .npu_rready(npu_rready),   .npu_rdata(npu_rdata),
        .npu_rresp(npu_rresp),
        .mem_awvalid(mem_awvalid), .mem_awready(mem_awready),
        .mem_awaddr(mem_awaddr),   .mem_wvalid(mem_wvalid),
        .mem_wready(mem_wready),   .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),     .mem_bvalid(mem_bvalid),
        .mem_bready(mem_bready),   .mem_bresp(mem_bresp),
        .mem_arvalid(mem_arvalid), .mem_arready(mem_arready),
        .mem_araddr(mem_araddr),   .mem_rvalid(mem_rvalid),
        .mem_rready(mem_rready),   .mem_rdata(mem_rdata),
        .mem_rresp(mem_rresp),
        .dma_arvalid(1'b0), .dma_araddr(32'h0), .dma_arlen(8'h0), .dma_arsize(3'h0), .dma_arburst(2'h0),
        .dma_rready(1'b0),
        .dma_awvalid(1'b0), .dma_awaddr(32'h0), .dma_awlen(8'h0), .dma_awsize(3'h0), .dma_awburst(2'h0),
        .dma_wvalid(1'b0),  .dma_wdata(32'h0),  .dma_wlast(1'b0),  .dma_wstrb(4'h0),
        .dma_bready(1'b0),
        .dma_arready(), .dma_rvalid(), .dma_rdata(), .dma_rlast(), .dma_rresp(),
        .dma_awready(), .dma_wready(), .dma_bvalid(), .dma_bresp(),
        .mem4_awvalid(), .mem4_awaddr(), .mem4_awlen(), .mem4_awsize(), .mem4_awburst(),
        .mem4_wvalid(),  .mem4_wdata(),  .mem4_wlast(),  .mem4_wstrb(),
        .mem4_bready(),  .mem4_arvalid(),.mem4_araddr(), .mem4_arlen(),
        .mem4_arsize(),  .mem4_arburst(),.mem4_rready(),
        .mem4_awready(1'b1), .mem4_wready(1'b1),
        .mem4_bvalid(1'b0),  .mem4_bresp(2'h0),
        .mem4_arready(1'b0), .mem4_rvalid(1'b0), .mem4_rdata(32'h0), .mem4_rlast(1'b0), .mem4_rresp(2'h0)
    );

    always #2.5 clk = ~clk;

    reg [31:0] errors;

    initial begin
        $dumpfile("sim/tb_task3_axilite.vcd");
        $dumpvars(0, tb_task3_axilite);
        clk = 0; rst_n = 0;
        cpu_awvalid = 0; cpu_wvalid = 0; cpu_bready = 0;
        cpu_arvalid = 0; cpu_rready = 0;
        cpu_awaddr  = 0; cpu_wdata  = 0; cpu_wstrb = 0;
        cpu_araddr  = 0; cpu_awprot = 0; cpu_arprot = 0;
        npu_awready = 0; npu_wready = 0; npu_bvalid = 0; npu_bresp = 0;
        npu_arready = 0; npu_rvalid = 0; npu_rresp = 0; npu_rdata = 0;
        mem_awready = 0; mem_wready = 0; mem_bvalid = 0; mem_bresp = 0;
        mem_arready = 0; mem_rvalid = 0; mem_rresp = 0; mem_rdata = 0;
        errors = 0;

        #20 rst_n = 1;
        #20;

        // ============================================================
        // Test A: Decoupled AW + W write to NPU
        // AW → NPU register. Then change cpu_awaddr to Memory addr.
        // W must still go to NPU (latched target from AW).
        // ============================================================
        $display("=== Test A: AW/W decoupled write to NPU ===");
        @(posedge clk);
        // Send AW to NPU (0x1000_0000)
        cpu_awvalid = 1; cpu_awaddr = 32'h1000_0000;
        @(posedge clk);  // AW accepted
        npu_awready = 1;
        @(posedge clk);
        cpu_awvalid = 0;
        npu_awready = 0;

        // Now change cpu_awaddr to memory address (0x0000_0100)
        cpu_awaddr = 32'h0000_0100;

        // Delay W by 2 cycles (AW/W decoupled)
        repeat(2) @(posedge clk);

        // Send W data
        cpu_wvalid = 1; cpu_wdata = 32'hCAFE_BABE; cpu_wstrb = 4'hF;
        npu_wready = 1;
        @(posedge clk);  // W accepted
        cpu_wvalid = 0;
        npu_wready = 0;
        @(posedge clk);

        // Check W went to NPU
        if (npu_wdata !== 32'hCAFE_BABE) begin
            $display("  FAIL: W data went to wrong target (NPU wdata=0x%08h)", npu_wdata);
            errors = errors + 1;
        end else $display("  PASS: W correctly routed to NPU (0x%08h)", npu_wdata);

        // Send B response from NPU
        @(posedge clk);
        npu_bvalid = 1; npu_bresp = 2'b00;
        cpu_bready = 1;
        @(posedge clk);
        npu_bvalid = 0;
        cpu_bready = 0;

        if (cpu_bvalid && cpu_bresp == 2'b00) $display("  PASS: B correctly returned from NPU");
        else begin $display("  FAIL: B routing wrong"); errors = errors + 1; end

        // ============================================================
        // Test B: Decoupled AW + W write to Memory
        // AW → Memory. Then change cpu_awaddr to NPU addr.
        // W must still go to Memory.
        // ============================================================
        $display("=== Test B: AW/W decoupled write to Memory ===");
        @(posedge clk);
        cpu_awvalid = 1; cpu_awaddr = 32'h0000_0100;
        @(posedge clk);
        mem_awready = 1;
        @(posedge clk);
        cpu_awvalid = 0;
        mem_awready = 0;

        // Change address to NPU
        cpu_awaddr = 32'h1000_0000;

        repeat(2) @(posedge clk);

        cpu_wvalid = 1; cpu_wdata = 32'hDEAD_BEEF; cpu_wstrb = 4'hF;
        mem_wready = 1;
        @(posedge clk);
        cpu_wvalid = 0;
        mem_wready = 0;
        @(posedge clk);

        if (mem_wdata !== 32'hDEAD_BEEF) begin
            $display("  FAIL: W went to NPU instead of Mem (mem_wdata=0x%08h)", mem_wdata);
            errors = errors + 1;
        end else $display("  PASS: W correctly routed to Memory (0x%08h)", mem_wdata);

        // Send B from Memory
        @(posedge clk);
        mem_bvalid = 1; mem_bresp = 2'b00;
        cpu_bready = 1;
        @(posedge clk);
        mem_bvalid = 0;
        cpu_bready = 0;

        if (cpu_bvalid && cpu_bresp == 2'b00) $display("  PASS: B correctly returned from Memory");
        else begin $display("  FAIL: B routing wrong"); errors = errors + 1; end

        // ============================================================
        // Test C: AR/R decoupled read from NPU
        // AR → NPU. Change cpu_araddr to Memory. R must come from NPU.
        // ============================================================
        $display("=== Test C: AR/R decoupled read from NPU ===");
        @(posedge clk);
        cpu_arvalid = 1; cpu_araddr = 32'h1000_0000;
        @(posedge clk);
        npu_arready = 1;
        @(posedge clk);
        cpu_arvalid = 0;
        npu_arready = 0;

        // Change address
        cpu_araddr = 32'h0000_0200;

        repeat(3) @(posedge clk);

        // NPU sends R data
        npu_rvalid = 1; npu_rdata = 32'h1234_5678; npu_rresp = 2'b00;
        cpu_rready = 1;
        @(posedge clk);
        npu_rvalid = 0;
        cpu_rready = 0;

        if (cpu_rvalid && cpu_rdata === 32'h1234_5678)
            $display("  PASS: R correctly returned from NPU (0x%08h)", cpu_rdata);
        else begin
            $display("  FAIL: R routing wrong (cpu_rdata=0x%08h)", cpu_rdata);
            errors = errors + 1;
        end

        // ============================================================
        // Test D: AR/R decoupled read from Memory
        // ============================================================
        $display("=== Test D: AR/R decoupled read from Memory ===");
        @(posedge clk);
        cpu_arvalid = 1; cpu_araddr = 32'h0000_0100;
        @(posedge clk);
        mem_arready = 1;
        @(posedge clk);
        cpu_arvalid = 0;
        mem_arready = 0;

        // Change address to NPU
        cpu_araddr = 32'h1000_0004;

        repeat(3) @(posedge clk);

        // Memory sends R
        mem_rvalid = 1; mem_rdata = 32'hAABB_CCDD; mem_rresp = 2'b00;
        cpu_rready = 1;
        @(posedge clk);
        mem_rvalid = 0;
        cpu_rready = 0;

        if (cpu_rvalid && cpu_rdata === 32'hAABB_CCDD)
            $display("  PASS: R correctly returned from Memory (0x%08h)", cpu_rdata);
        else begin
            $display("  FAIL: R routing wrong (cpu_rdata=0x%08h)", cpu_rdata);
            errors = errors + 1;
        end

        // ============================================================
        // Test E: W-before-AW, target NPU (slave ready, interconnect must block)
        // ============================================================
        $display("=== Test E: W-before-AW, target NPU (slave wready=1) ===");
        @(posedge clk);
        // Slave ready BEFORE AW — interconnect must still reject W (aw_seen=0)
        npu_wready = 1;
        @(posedge clk);
        cpu_wvalid = 1; cpu_wdata = 32'hBEEF_0001; cpu_wstrb = 4'hF;
        @(posedge clk);
        if (cpu_wready) begin
            $display("  FAIL: W accepted before AW despite aw_seen=0");
            errors = errors + 1;
        end else if (npu_wvalid) begin
            $display("  FAIL: W forwarded to NPU before AW");
            errors = errors + 1;
        end else $display("  PASS: W blocked (wready=0, wvalid=0) even with slave ready");
        npu_wready = 0;

        // Now send AW to NPU — W should now be accepted
        @(posedge clk);
        cpu_awvalid = 1; cpu_awaddr = 32'h1000_000C;
        @(posedge clk); cpu_awvalid = 0;
        // AW latched, wready should go high
        npu_wready = 1;
        @(posedge clk); // W handshake
        if (npu_wdata !== 32'hBEEF_0001) begin
            $display("  FAIL: W data 0x%08h after AW", npu_wdata);
            errors = errors + 1;
        end else $display("  PASS: W correctly routed to NPU after AW");
        npu_wready = 0; cpu_wvalid = 0;
        // B from NPU
        @(posedge clk); @(posedge clk);
        npu_bvalid = 1; cpu_bready = 1;
        @(posedge clk); npu_bvalid = 0; cpu_bready = 0;

        // ============================================================
        // Test F: W-before-AW, target Memory (slave ready, interconnect must block)
        // ============================================================
        $display("=== Test F: W-before-AW, target Memory (slave wready=1) ===");
        @(posedge clk);
        // Slave ready BEFORE AW — interconnect must reject
        mem_wready = 1;
        @(posedge clk);
        cpu_wvalid = 1; cpu_wdata = 32'hC001_F00D; cpu_wstrb = 4'hF;
        @(posedge clk);
        if (cpu_wready || mem_wvalid) begin
            $display("  FAIL: W accepted/forwarded before AW to Memory");
            errors = errors + 1;
        end else $display("  PASS: W blocked even with mem_wready=1");
        mem_wready = 0;

        // Send AW to Memory
        @(posedge clk);
        cpu_awvalid = 1; cpu_awaddr = 32'h0000_0500;
        @(posedge clk); cpu_awvalid = 0;
        // Now W should go to Memory
        mem_wready = 1;
        @(posedge clk);
        if (mem_wdata !== 32'hC001_F00D) begin
            $display("  FAIL: W not routed to Mem after AW");
            errors = errors + 1;
        end else $display("  PASS: W correctly routed to Memory after AW");
        mem_wready = 0; cpu_wvalid = 0;
        @(posedge clk); @(posedge clk);
        mem_bvalid = 1; cpu_bready = 1;
        @(posedge clk); mem_bvalid = 0; cpu_bready = 0;

        // ============================================================
        $display("=== Final: %0d errors ===", errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== FAIL ===");
        #20 $finish;
    end

endmodule
