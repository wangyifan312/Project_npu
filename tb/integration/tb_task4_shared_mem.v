// tb_task4_shared_mem: verify CPU and NPU share the same physical memory
// CPU writes input data → NPU reads same address → NPU writes result → CPU reads result
`timescale 1ns / 1ps

module tb_task4_shared_mem;
    reg clk, rst_n;

    // CPU AXI-Lite (direct stimulus to shared_ram)
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

    // NPU AXI4 (256-bit DMA port — matches shared_ram NPU port width)
    reg         npu_awvalid, npu_wvalid, npu_bready;
    wire        npu_awready, npu_wready, npu_bvalid;
    reg  [31:0] npu_awaddr;
    reg  [255:0] npu_wdata;
    reg  [7:0]  npu_awlen;
    reg  [2:0]  npu_awsize;
    reg  [1:0]  npu_awburst;
    reg         npu_wlast;
    reg  [31:0] npu_wstrb;
    wire [1:0]  npu_bresp;
    reg         npu_arvalid, npu_rready;
    wire        npu_arready, npu_rvalid;
    reg  [31:0] npu_araddr;
    reg  [7:0]  npu_arlen;
    reg  [2:0]  npu_arsize;
    reg  [1:0]  npu_arburst;
    wire [255:0] npu_rdata;
    wire        npu_rlast;
    wire [1:0]  npu_rresp;

    shared_ram #(.RAM_DEPTH(16384)) u_ram (
        .clk(clk), .rst_n(rst_n),
        .cpu_awvalid(cpu_awvalid), .cpu_awready(cpu_awready),
        .cpu_awaddr(cpu_awaddr),   .cpu_wvalid(cpu_wvalid),
        .cpu_wready(cpu_wready),   .cpu_wdata(cpu_wdata),
        .cpu_wstrb(cpu_wstrb),     .cpu_bvalid(cpu_bvalid),
        .cpu_bready(cpu_bready),   .cpu_bresp(cpu_bresp),
        .cpu_arvalid(cpu_arvalid), .cpu_arready(cpu_arready),
        .cpu_araddr(cpu_araddr),   .cpu_rvalid(cpu_rvalid),
        .cpu_rready(cpu_rready),   .cpu_rdata(cpu_rdata),
        .cpu_rresp(cpu_rresp),
        .npu_awvalid(npu_awvalid), .npu_awready(npu_awready),
        .npu_awaddr(npu_awaddr),   .npu_awlen(npu_awlen),
        .npu_awsize(npu_awsize),   .npu_awburst(npu_awburst),
        .npu_wvalid(npu_wvalid),   .npu_wready(npu_wready),
        .npu_wdata(npu_wdata),     .npu_wlast(npu_wlast),
        .npu_wstrb(npu_wstrb),     .npu_bvalid(npu_bvalid),
        .npu_bready(npu_bready),   .npu_bresp(npu_bresp),
        .npu_arvalid(npu_arvalid), .npu_arready(npu_arready),
        .npu_araddr(npu_araddr),   .npu_arlen(npu_arlen),
        .npu_arsize(npu_arsize),   .npu_arburst(npu_arburst),
        .npu_rvalid(npu_rvalid),   .npu_rready(npu_rready),
        .npu_rdata(npu_rdata),     .npu_rlast(npu_rlast),
        .npu_rresp(npu_rresp)
    );

    always #2.5 clk = ~clk;

    task cpu_write;
        input [31:0] addr, data;
        begin
            // AW
            @(posedge clk);
            cpu_awvalid = 1; cpu_awaddr = addr;
            @(posedge clk);
            cpu_awvalid = 0;
            // W (next cycle)
            @(posedge clk);
            cpu_wvalid  = 1; cpu_wdata  = data; cpu_wstrb = 4'hF;
            @(posedge clk);
            cpu_wvalid = 0;
            // B
            @(posedge clk); cpu_bready = 1;
            @(posedge clk); cpu_bready = 0;
        end
    endtask

    task cpu_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            cpu_arvalid = 1; cpu_araddr = addr;
            @(posedge clk); cpu_arvalid = 0;
            // Data available one cycle after AR
            @(posedge clk); data = cpu_rdata; cpu_rready = 1;
            @(posedge clk); cpu_rready = 0;
        end
    endtask

    task npu_write_single;
        input [31:0] addr, data;
        begin
            // AW phase
            @(posedge clk);
            npu_awvalid = 1; npu_awaddr = addr; npu_awlen = 0;
            npu_awsize = 5; npu_awburst = 2'b01;
            @(posedge clk);  // AW handshake
            npu_awvalid = 0;
            // W phase (next cycle — WREADY becomes 1 after AW)
            npu_wvalid  = 1; npu_wdata  = {224'h0, data};
            npu_wlast  = 1; npu_wstrb = {28'h0, 4'hF};
            @(posedge clk);  // W handshake
            npu_wvalid = 0;
            // B phase
            @(posedge clk); npu_bready = 1;
            @(posedge clk); npu_bready = 0;
        end
    endtask

    reg [31:0] rd_val;
    reg [31:0] errors;

    initial begin
        $dumpfile("sim/tb_task4_shared_mem.vcd");
        $dumpvars(0, tb_task4_shared_mem);
        clk = 0; rst_n = 0;
        cpu_awvalid = 0; cpu_wvalid = 0; cpu_bready = 0;
        cpu_arvalid = 0; cpu_rready = 0;
        npu_awvalid = 0; npu_wvalid = 0; npu_bready = 0;
        npu_arvalid = 0; npu_rready = 0;
        errors = 0;

        #20 rst_n = 1; #20;

        // ============================================================
        // Test A: CPU writes to addr 0x100, NPU reads same addr
        // ============================================================
        $display("=== Test A: CPU write, NPU read back ===");
        cpu_write(32'h0000_0100, 32'hDEAD_BEEF);

        // NPU reads same address (256-bit burst, extract lower 32 bits)
        @(posedge clk);
        npu_arvalid = 1; npu_araddr = 32'h0000_0100; npu_arlen = 0;
        npu_arsize = 5; npu_arburst = 2'b01;
        @(posedge clk); npu_arvalid = 0;
        @(posedge clk);  // data appears
        if (npu_rdata[31:0] === 32'hDEAD_BEEF) $display("  PASS: NPU read 0x%08h from CPU-written addr", npu_rdata[31:0]);
        else begin $display("  FAIL: NPU read 0x%08h, expected 0xDEAD_BEEF", npu_rdata[31:0]); errors = errors + 1; end
        npu_rready = 1;
        @(posedge clk); npu_rready = 0;

        // ============================================================
        // Test B: NPU writes to addr 0x200, CPU reads same addr
        // ============================================================
        $display("=== Test B: NPU write, CPU read back ===");
        npu_write_single(32'h0000_0200, 32'hCAFE_F00D);

        // CPU reads same address
        cpu_read(32'h0000_0200, rd_val);
        if (rd_val === 32'hCAFE_F00D) $display("  PASS: CPU read 0x%08h from NPU-written addr", rd_val);
        else begin $display("  FAIL: CPU read 0x%08h, expected 0xCAFE_F00D", rd_val); errors = errors + 1; end

        // ============================================================
        // Test C: Multiple addresses written by CPU, verified by CPU
        // ============================================================
        $display("=== Test C: Multiple addresses ===");
        cpu_write(32'h0000_0300, 32'h1111_1111);
        cpu_write(32'h0000_0304, 32'h2222_2222);
        cpu_write(32'h0000_0308, 32'h3333_3333);

        cpu_read(32'h0000_0300, rd_val);
        if (rd_val !== 32'h1111_1111) begin $display("  FAIL: addr 0x300"); errors = errors + 1; end
        cpu_read(32'h0000_0304, rd_val);
        if (rd_val !== 32'h2222_2222) begin $display("  FAIL: addr 0x304"); errors = errors + 1; end
        cpu_read(32'h0000_0308, rd_val);
        if (rd_val !== 32'h3333_3333) begin $display("  FAIL: addr 0x308"); errors = errors + 1; end
        if (errors == 0) $display("  PASS: All multi-address writes verified");

        // ============================================================
        $display("=== Final: %0d errors ===", errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== FAIL ===");
        #20 $finish;
    end

endmodule
