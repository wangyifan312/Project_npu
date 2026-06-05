// tb_task4_system: legacy Task4 system-level shared memory closed-loop test.
// This entry still carries historical 32-bit padded wiring/semantics and is
// retained as a legacy/debug micro-test, not AXI-2 standard AXI-Lite compliance
// evidence. AXI-2 closure uses tb_axil_*_protocol plus top/subsystem smoke.
`timescale 1ns / 1ps

module tb_task4_system;
    reg clk, rst_n;

    // === CPU side AXI-Lite stimulus ===
    reg         cpu_awvalid, cpu_wvalid, cpu_bready;
    wire        cpu_awready, cpu_wready, cpu_bvalid;
    reg  [31:0] cpu_awaddr, cpu_wdata;
    reg  [3:0]  cpu_wstrb;
    wire [1:0]  cpu_bresp;
    reg         cpu_arvalid, cpu_rready;
    wire        cpu_arready, cpu_rvalid;
    reg  [31:0] cpu_araddr;
    wire [31:0] cpu_rdata;
    wire [1:0]  cpu_rresp;
    reg  [2:0]  cpu_awprot, cpu_arprot;

    // === Interconnect -> NPU (AXI-Lite) ===
    wire        npu_awvalid, npu_awready;
    wire [31:0] npu_awaddr;
    wire        npu_wvalid, npu_wready;
    wire [31:0] npu_wdata;
    wire [3:0]  npu_wstrb;
    wire        npu_bvalid, npu_bready;
    wire [1:0]  npu_bresp;
    wire        npu_arvalid, npu_arready;
    wire [31:0] npu_araddr;
    wire        npu_rvalid, npu_rready;
    wire [31:0] npu_rdata;
    wire [1:0]  npu_rresp;

    // === Interconnect -> Memory (CPU AXI-Lite path) ===
    wire        mem_awvalid, mem_wvalid, mem_bready, mem_arvalid, mem_rready;
    wire [31:0] mem_awaddr, mem_wdata, mem_araddr;
    wire [3:0]  mem_wstrb;
    wire        mem_awready, mem_wready, mem_bvalid, mem_arready;
    wire [1:0]  mem_bresp;
    wire        mem_rvalid;
    wire [31:0] mem_rdata;
    wire [1:0]  mem_rresp;

    // === NPU DMA AXI4 signals ===
    wire        npu_m_arvalid, npu_m_arready;
    wire [31:0] npu_m_araddr;
    wire [7:0]  npu_m_arlen;
    wire [2:0]  npu_m_arsize;
    wire [1:0]  npu_m_arburst;
    wire        npu_m_rvalid, npu_m_rready;
    wire [31:0] npu_m_rdata;
    wire        npu_m_rlast;
    wire [1:0]  npu_m_rresp;
    wire        npu_m_awvalid, npu_m_awready;
    wire [31:0] npu_m_awaddr;
    wire [7:0]  npu_m_awlen;
    wire [2:0]  npu_m_awsize;
    wire [1:0]  npu_m_awburst;
    wire        npu_m_wvalid, npu_m_wready;
    wire [31:0] npu_m_wdata;
    wire        npu_m_wlast;
    wire [3:0]  npu_m_wstrb;
    wire        npu_m_bvalid, npu_m_bready;
    wire [1:0]  npu_m_bresp;

    // === Memory AXI4 signals (NPU DMA path) ===
    wire        mem4_awvalid, mem4_wvalid, mem4_arvalid, mem4_rready, mem4_bready;
    wire [31:0] mem4_awaddr, mem4_wdata, mem4_araddr;
    wire [7:0]  mem4_awlen, mem4_arlen;
    wire [2:0]  mem4_awsize, mem4_arsize;
    wire [1:0]  mem4_awburst, mem4_arburst;
    wire        mem4_wlast;
    wire [3:0]  mem4_wstrb;
    wire        mem4_awready, mem4_wready, mem4_bvalid, mem4_arready;
    wire [1:0]  mem4_bresp;
    wire        mem4_rvalid;
    wire [31:0] mem4_rdata;
    wire        mem4_rlast;
    wire [1:0]  mem4_rresp;

    // ============================================================
    // AXI Interconnect
    // ============================================================
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
        .dma_arvalid(npu_m_arvalid), .dma_arready(npu_m_arready),
        .dma_araddr(npu_m_araddr),   .dma_arlen(npu_m_arlen),
        .dma_arsize(npu_m_arsize),   .dma_arburst(npu_m_arburst),
        .dma_rready(npu_m_rready),   .dma_rvalid(npu_m_rvalid),
        .dma_rdata(npu_m_rdata),     .dma_rlast(npu_m_rlast),
        .dma_rresp(npu_m_rresp),
        .dma_awvalid(npu_m_awvalid), .dma_awready(npu_m_awready),
        .dma_awaddr(npu_m_awaddr),   .dma_awlen(npu_m_awlen),
        .dma_awsize(npu_m_awsize),   .dma_awburst(npu_m_awburst),
        .dma_wvalid(npu_m_wvalid),   .dma_wready(npu_m_wready),
        .dma_wdata(npu_m_wdata),     .dma_wlast(npu_m_wlast),
        .dma_wstrb(npu_m_wstrb),     .dma_bready(npu_m_bready),
        .dma_bvalid(npu_m_bvalid),   .dma_bresp(npu_m_bresp),
        .mem4_awvalid(mem4_awvalid), .mem4_awready(mem4_awready),
        .mem4_awaddr(mem4_awaddr),   .mem4_awlen(mem4_awlen),
        .mem4_awsize(mem4_awsize),   .mem4_awburst(mem4_awburst),
        .mem4_wvalid(mem4_wvalid),   .mem4_wready(mem4_wready),
        .mem4_wdata(mem4_wdata),     .mem4_wlast(mem4_wlast),
        .mem4_wstrb(mem4_wstrb),     .mem4_bready(mem4_bready),
        .mem4_bvalid(mem4_bvalid),   .mem4_bresp(mem4_bresp),
        .mem4_arvalid(mem4_arvalid), .mem4_arready(mem4_arready),
        .mem4_araddr(mem4_araddr),   .mem4_arlen(mem4_arlen),
        .mem4_arsize(mem4_arsize),   .mem4_arburst(mem4_arburst),
        .mem4_rready(mem4_rready),   .mem4_rvalid(mem4_rvalid),
        .mem4_rdata(mem4_rdata),     .mem4_rlast(mem4_rlast),
        .mem4_rresp(mem4_rresp)
    );

    // ============================================================
    // Unified Shared Memory
    // ============================================================
    shared_ram #(.RAM_DEPTH(16384)) u_shared_ram (
        .clk(clk), .rst_n(rst_n),
        .cpu_awvalid(mem_awvalid), .cpu_awready(mem_awready),
        .cpu_awaddr(mem_awaddr),   .cpu_wvalid(mem_wvalid),
        .cpu_wready(mem_wready),   .cpu_wdata(mem_wdata),
        .cpu_wstrb(mem_wstrb),     .cpu_bvalid(mem_bvalid),
        .cpu_bready(mem_bready),   .cpu_bresp(mem_bresp),
        .cpu_arvalid(mem_arvalid), .cpu_arready(mem_arready),
        .cpu_araddr(mem_araddr),   .cpu_rvalid(mem_rvalid),
        .cpu_rready(mem_rready),   .cpu_rdata(mem_rdata),
        .cpu_rresp(mem_rresp),
        .npu_awvalid(mem4_awvalid), .npu_awready(mem4_awready),
        .npu_awaddr(mem4_awaddr),   .npu_awlen(mem4_awlen),
        .npu_awsize(mem4_awsize),   .npu_awburst(mem4_awburst),
        .npu_wvalid(mem4_wvalid),   .npu_wready(mem4_wready),
        .npu_wdata(mem4_wdata),     .npu_wlast(mem4_wlast),
        .npu_wstrb(mem4_wstrb),     .npu_bvalid(mem4_bvalid),
        .npu_bready(mem4_bready),   .npu_bresp(mem4_bresp),
        .npu_arvalid(mem4_arvalid), .npu_arready(mem4_arready),
        .npu_araddr(mem4_araddr),   .npu_arlen(mem4_arlen),
        .npu_arsize(mem4_arsize),   .npu_arburst(mem4_arburst),
        .npu_rvalid(mem4_rvalid),   .npu_rready(mem4_rready),
        .npu_rdata(mem4_rdata),     .npu_rlast(mem4_rlast),
        .npu_rresp(mem4_rresp)
    );

    // ============================================================
    // NPU Top
    // ============================================================
    wire npu_busy, npu_done, npu_error;
    wire [7:0] npu_error_code;
    npu_top #(.TILE_ROWS(7), .TILE_COLS(2), .BUF_ENTRIES(256), .BUF_ADDR_W(8)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(npu_awvalid), .s_axi_awready(npu_awready),
        .s_axi_awaddr(npu_awaddr),   .s_axi_wvalid(npu_wvalid),
        .s_axi_wready(npu_wready),   .s_axi_wdata(npu_wdata),
        .s_axi_wstrb(npu_wstrb),     .s_axi_bvalid(npu_bvalid),
        .s_axi_bready(npu_bready),   .s_axi_bresp(npu_bresp),
        .s_axi_arvalid(npu_arvalid), .s_axi_arready(npu_arready),
        .s_axi_araddr(npu_araddr),   .s_axi_rvalid(npu_rvalid),
        .s_axi_rready(npu_rready),   .s_axi_rdata(npu_rdata),
        .s_axi_rresp(npu_rresp),
        .m_axi_arvalid(npu_m_arvalid), .m_axi_arready(npu_m_arready),
        .m_axi_araddr(npu_m_araddr),   .m_axi_arlen(npu_m_arlen),
        .m_axi_arsize(npu_m_arsize),   .m_axi_arburst(npu_m_arburst),
        .m_axi_rvalid(npu_m_rvalid),   .m_axi_rready(npu_m_rready),
        .m_axi_rdata(npu_m_rdata),     .m_axi_rlast(npu_m_rlast),
        .m_axi_rresp(npu_m_rresp),
        .m_axi_awvalid(npu_m_awvalid), .m_axi_awready(npu_m_awready),
        .m_axi_awaddr(npu_m_awaddr),   .m_axi_awlen(npu_m_awlen),
        .m_axi_awsize(npu_m_awsize),   .m_axi_awburst(npu_m_awburst),
        .m_axi_wvalid(npu_m_wvalid),   .m_axi_wready(npu_m_wready),
        .m_axi_wdata(npu_m_wdata),     .m_axi_wlast(npu_m_wlast),
        .m_axi_wstrb(npu_m_wstrb),     .m_axi_bvalid(npu_m_bvalid),
        .m_axi_bready(npu_m_bready),   .m_axi_bresp(npu_m_bresp),
        .npu_busy(npu_busy),           .npu_done(npu_done),
        .npu_error(npu_error),         .npu_error_code(npu_error_code)
    );

    always #2.5 clk = ~clk;

    // === CPU-side tasks ===
    task cpu_axi_write;
        input [31:0] addr, data;
        begin
            @(posedge clk);
            cpu_awvalid = 1; cpu_awaddr = addr; cpu_awprot = 0;
            while (!cpu_awready) @(posedge clk);
            @(posedge clk); cpu_awvalid = 0;
            cpu_wvalid  = 1; cpu_wdata  = data; cpu_wstrb = 4'hF;
            while (!cpu_wready) @(posedge clk);
            @(posedge clk); cpu_wvalid = 0;
            cpu_bready = 1;
            while (!cpu_bvalid) @(posedge clk);
            @(posedge clk); cpu_bready = 0;
        end
    endtask

    task cpu_axi_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            cpu_arvalid = 1; cpu_araddr = addr; cpu_arprot = 0;
            while (!cpu_arready) @(posedge clk);
            @(posedge clk); cpu_arvalid = 0;
            cpu_rready = 1;
            while (!cpu_rvalid) @(posedge clk);
            data = cpu_rdata;
            @(posedge clk); cpu_rready = 0;
        end
    endtask

    reg [31:0] rd_val, errors;
    integer i;

    initial begin
        $dumpfile("sim/tb_task4_system.vcd");
        $dumpvars(0, tb_task4_system);
        clk = 0; rst_n = 0;
        cpu_awvalid = 0; cpu_wvalid = 0; cpu_bready = 0;
        cpu_arvalid = 0; cpu_rready = 0;
        cpu_awaddr  = 0; cpu_wdata  = 0; cpu_wstrb = 0;
        cpu_awprot  = 0; cpu_arprot  = 0;
        errors = 0;

        #20 rst_n = 1; #20;

        // ============================================================
        // Step 1: CPU writes input data to shared memory at 0x100
        // 5x5 input, all 1s (INT8)
        // ============================================================
        $display("=== Step 1: CPU preloads activations ===");
        for (i = 0; i < 7; i = i + 1)
            cpu_axi_write(32'h0000_0100 + i*4, 32'h01010101);

        // Write weights (all 2s) at 0x200
        $display("=== Step 1b: CPU preloads weights ===");
        for (i = 0; i < 7; i = i + 1)
            cpu_axi_write(32'h0000_0200 + i*4, 32'h02020202);

        // ============================================================
        // Step 2: CPU configures NPU registers
        // ============================================================
        $display("=== Step 2: CPU configures NPU ===");
        // NPU register base = 0x1000_0000
        cpu_axi_write(32'h1000_0008, 32'h0000_0000);  // Conv
        cpu_axi_write(32'h1000_000C, 32'h0000_0100);  // input_addr
        cpu_axi_write(32'h1000_0010, 32'h0000_0200);  // weight_addr
        cpu_axi_write(32'h1000_0014, 32'h0000_0300);  // output_addr
        cpu_axi_write(32'h1000_0018, 32'h0000_0019);  // input_bytes=25
        cpu_axi_write(32'h1000_001C, 32'h0000_0019);  // weight_bytes=25
        cpu_axi_write(32'h1000_0020, 32'h0000_0004);  // output_bytes=4
        cpu_axi_write(32'h1000_0024, 32'h0005_0005);  // H=5,W=5
        cpu_axi_write(32'h1000_0028, 32'h0001_0001);  // C_IN=1,C_OUT=1
        cpu_axi_write(32'h1000_002C, 32'h0);

        // ============================================================
        // Step 3: CPU starts NPU
        // ============================================================
        $display("=== Step 3: Start NPU ===");
        cpu_axi_write(32'h1000_0000, 32'h0000_0001);

        // ============================================================
        // Step 4: Wait for NPU to finish
        // ============================================================
        repeat(30000) @(posedge clk);
        cpu_axi_read(32'h1000_0000, rd_val);
        $display("NPU CTRL: 0x%08h (done=%b error=%b)", rd_val, rd_val[2], rd_val[3]);

        if (!rd_val[2]) begin
            $display("FAIL: NPU did not complete");
            errors = errors + 1;
        end else begin
            // ============================================================
            // Step 5: CPU reads result from shared memory at 0x300
            // ============================================================
            $display("=== Step 5: CPU reads NPU output from shared memory ===");
            cpu_axi_read(32'h0000_0300, rd_val);
            $display("  output[0]=%0d (expect 50)", $signed(rd_val));
            if ($signed(rd_val) !== 50) begin
                $display("  FAIL: output mismatch");
                errors = errors + 1;
            end else
                $display("  PASS: CPU sees NPU result correctly");
        end

        // ============================================================
        // Step 6: Verify end-to-end: CPU writes new test data, NPU re-processes
        // ============================================================
        $display("=== Step 6: Verify shared memory back-to-back ===");
        // Write different data pattern to shared memory
        cpu_axi_write(32'h0000_0400, 32'hCAFE_BABE);
        // Read it back
        cpu_axi_read(32'h0000_0400, rd_val);
        if (rd_val === 32'hCAFE_BABE) $display("  PASS: CPU round-trip to shared memory OK");
        else begin $display("  FAIL: round-trip 0x%08h", rd_val); errors = errors + 1; end

        $display("=== Final: %0d errors ===", errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== FAIL ===");
        #20 $finish;
    end

endmodule
