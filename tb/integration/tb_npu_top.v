// tb_npu_top: end-to-end NPU accelerator testbench (256-bit data-plane)
// Pre-loads RAM via 256-bit AXI4 write, then runs NPU Conv task
`timescale 1ns / 1ps

module tb_npu_top;

    reg clk, rst_n;

    // === AXI4-Lite (CPU → NPU registers) ===
    reg         s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    wire        s_axi_awready, s_axi_wready, s_axi_bvalid;
    reg  [31:0] s_axi_awaddr, s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    wire [1:0]  s_axi_bresp;
    reg         s_axi_arvalid, s_axi_rready;
    wire        s_axi_arready, s_axi_rvalid;
    reg  [31:0] s_axi_araddr;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;

    // === NPU AXI4 DMA ports (256-bit data-plane) ===
    wire        npu_arvalid, npu_awvalid;
    wire [31:0] npu_araddr,  npu_awaddr;
    wire [7:0]  npu_arlen,   npu_awlen;
    wire [2:0]  npu_arsize,  npu_awsize;
    wire [1:0]  npu_arburst, npu_awburst;
    wire        npu_wvalid,  npu_wlast;
    wire [255:0] npu_wdata;
    wire [31:0] npu_wstrb;
    wire        npu_rready,  npu_bready;
    wire        npu_busy, npu_done, npu_error;
    wire [7:0]  npu_error_code;

    // === Preload control ===
    reg         preload;
    reg         tb_awvalid, tb_wvalid;
    reg  [31:0] tb_awaddr;
    reg  [255:0] tb_wdata;
    reg  [31:0] tb_wstrb;

    // === RAM interface (muxed) — all 256-bit ===
    wire        ram_awvalid = preload ? tb_awvalid : npu_awvalid;
    wire [31:0] ram_awaddr  = preload ? tb_awaddr  : npu_awaddr;
    wire [7:0]  ram_awlen   = preload ? 8'h0       : npu_awlen;
    wire [2:0]  ram_awsize  = preload ? 3'd5       : npu_awsize;
    wire [1:0]  ram_awburst = preload ? 2'b01      : npu_awburst;
    wire        ram_wvalid  = preload ? tb_wvalid  : npu_wvalid;
    wire [255:0] ram_wdata  = preload ? tb_wdata   : npu_wdata;
    wire [31:0] ram_wstrb   = preload ? tb_wstrb   : npu_wstrb;
    wire        ram_wlast   = preload ? 1'b1       : npu_wlast;
    wire        ram_bready  = preload ? 1'b1       : npu_bready;
    wire        ram_arvalid = preload ? 1'b0       : npu_arvalid;
    wire [31:0] ram_araddr  = preload ? 32'h0      : npu_araddr;
    wire [7:0]  ram_arlen   = preload ? 8'h0       : npu_arlen;
    wire [2:0]  ram_arsize  = preload ? 3'd5       : npu_arsize;
    wire [1:0]  ram_arburst = preload ? 2'b01      : npu_arburst;
    wire        ram_rready  = preload ? 1'b0       : npu_rready;

    wire        ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0]  ram_bresp, ram_rresp;
    wire        ram_rvalid, ram_rlast;
    wire [255:0] ram_rdata;

    wire        npu_arready = preload ? 1'b0 : ram_arready;
    wire        npu_awready = preload ? 1'b0 : ram_awready;
    wire        npu_wready  = preload ? 1'b0 : ram_wready;
    wire        npu_rvalid  = preload ? 1'b0 : ram_rvalid;
    wire        npu_bvalid  = preload ? 1'b0 : ram_bvalid;
    wire [255:0] npu_rdata  = ram_rdata;
    wire        npu_rlast   = ram_rlast;
    wire [1:0]  npu_rresp   = preload ? 2'b0 : ram_rresp;
    wire [1:0]  npu_bresp   = preload ? 2'b0 : ram_bresp;

    // ============================================================
    // NPU Top instance
    // ============================================================
    npu_top #(.TILE_ROWS(7), .TILE_COLS(2), .BUF_ENTRIES(256), .BUF_ADDR_W(8)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr),   .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),   .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),     .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),   .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_araddr(s_axi_araddr),   .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),   .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .m_axi_arvalid(npu_arvalid),   .m_axi_arready(npu_arready),
        .m_axi_araddr(npu_araddr),     .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize),     .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(npu_rvalid),     .m_axi_rready(npu_rready),
        .m_axi_rdata(npu_rdata),       .m_axi_rlast(npu_rlast),
        .m_axi_rresp(npu_rresp),
        .m_axi_awvalid(npu_awvalid),   .m_axi_awready(npu_awready),
        .m_axi_awaddr(npu_awaddr),     .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize),     .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid),     .m_axi_wready(npu_wready),
        .m_axi_wdata(npu_wdata),       .m_axi_wlast(npu_wlast),
        .m_axi_wstrb(npu_wstrb),       .m_axi_bvalid(npu_bvalid),
        .m_axi_bready(npu_bready),     .m_axi_bresp(npu_bresp),
        .npu_busy(npu_busy),           .npu_done(npu_done),
        .npu_error(npu_error),         .npu_error_code(npu_error_code)
    );

    // ============================================================
    // AXI4 RAM instance (256-bit)
    // ============================================================
    axi4_ram #(.RAM_DEPTH(16384)) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(ram_awvalid), .s_axi_awready(ram_awready),
        .s_axi_awaddr(ram_awaddr),   .s_axi_awlen(ram_awlen),
        .s_axi_awsize(ram_awsize),   .s_axi_awburst(ram_awburst),
        .s_axi_wvalid(ram_wvalid),   .s_axi_wready(ram_wready),
        .s_axi_wdata(ram_wdata),     .s_axi_wstrb(ram_wstrb),
        .s_axi_wlast(ram_wlast),     .s_axi_bvalid(ram_bvalid),
        .s_axi_bready(ram_bready),   .s_axi_bresp(ram_bresp),
        .s_axi_arvalid(ram_arvalid), .s_axi_arready(ram_arready),
        .s_axi_araddr(ram_araddr),   .s_axi_arlen(ram_arlen),
        .s_axi_arsize(ram_arsize),   .s_axi_arburst(ram_arburst),
        .s_axi_rvalid(ram_rvalid),   .s_axi_rready(ram_rready),
        .s_axi_rdata(ram_rdata),     .s_axi_rlast(ram_rlast),
        .s_axi_rresp(ram_rresp)
    );

    always #2.5 clk = ~clk;

    // ============================================================
    // AXI-Lite helpers
    // ============================================================
    task axi_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            s_axi_awvalid = 1; s_axi_awaddr = addr;
            s_axi_wvalid  = 1; s_axi_wdata  = data; s_axi_wstrb = 4'hF;
            @(posedge clk);
            s_axi_awvalid = 0; s_axi_wvalid = 0;
            @(posedge clk);
            s_axi_bready = 1;
            @(posedge clk);
            s_axi_bready = 0;
        end
    endtask

    task axi_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            s_axi_arvalid = 1; s_axi_araddr = addr;
            @(posedge clk);
            s_axi_arvalid = 0;
            @(posedge clk);
            data = s_axi_rdata;
            s_axi_rready = 1;
            @(posedge clk);
            s_axi_rready = 0;
        end
    endtask

    // Pre-load helper: write one 256-bit beat to RAM via AXI4
    task preload_beat;
        input [31:0] addr;
        input [255:0] data;
        input [31:0] strb;
        begin
            // AW phase
            @(posedge clk);
            tb_awvalid = 1; tb_awaddr = addr;
            @(posedge clk);  // AW handshake
            tb_awvalid = 0;
            // W phase (wready now high after AW)
            tb_wvalid  = 1; tb_wdata  = data; tb_wstrb = strb;
            @(posedge clk);  // W handshake
            tb_wvalid = 0;
            // Wait for BVALID (asserted automatically after WLAST)
            @(posedge clk);  // bready=1 from mux ensures B consumed
        end
    endtask

    reg [31:0] rd_val;
    integer i;

    initial begin
        $dumpfile("sim/tb_npu_top.vcd");
        $dumpvars(0, tb_npu_top);

        clk = 0; rst_n = 0; preload = 1;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_arvalid = 0; s_axi_rready = 0;
        tb_awvalid = 0; tb_wvalid = 0;

        #20 rst_n = 1;
        #20;

        // === Pre-load activations: 25 bytes of value 1 at addr 0x100 ===
        $display("=== Pre-load activations (5x5, all 1s) at 0x100 ===");
        // 25 bytes of 0x01 + 7 zero-pad: bytes 0-24=0x01, bytes 25-31=0x00
        preload_beat(32'h0000_0100,
            256'h00000000_00000001_01010101_01010101_01010101_01010101_01010101_01010101,
            32'hFFFFFFFF);
        $display("  Done (25 bytes + 7 zero-pad)");

        // === Pre-load weights: 25 bytes of value 2 at addr 0x200 ===
        $display("=== Pre-load weights (5x5, all 2s) at 0x200 ===");
        preload_beat(32'h0000_0200,
            256'h00000000_00000002_02020202_02020202_02020202_02020202_02020202_02020202,
            32'hFFFFFFFF);
        $display("  Done (25 bytes + 7 zero-pad)");

        // === Release RAM to NPU ===
        preload = 0;

        // === Configure NPU registers ===
        $display("=== Configure NPU ===");
        axi_write(32'h1000_0008, 32'h0000_0000);  // TASK_TYPE=Conv
        axi_write(32'h1000_000C, 32'h0000_0100);  // input_addr
        axi_write(32'h1000_0010, 32'h0000_0200);  // weight_addr
        axi_write(32'h1000_0014, 32'h0000_0300);  // output_addr
        axi_write(32'h1000_0018, 32'h0000_0019);  // input_bytes=25
        axi_write(32'h1000_001C, 32'h0000_0019);  // weight_bytes=25
        axi_write(32'h1000_0020, 32'h0000_0004);  // output_bytes=4
        axi_write(32'h1000_0024, 32'h0005_0005);  // H=5,W=5
        axi_write(32'h1000_0028, 32'h0001_0001);  // C_IN=1,C_OUT=1
        axi_write(32'h1000_002C, 32'h0000_0000);  // relu=0,pool=0
        $display("  Done");

        // === Start task ===
        $display("=== Start task ===");
        axi_write(32'h1000_0000, 32'h0000_0001);  // start=1

        // === Wait for completion ===
        repeat(5000) @(posedge clk);

        $display("FSM state = %0d", u_npu.fsm_state);
        $display("wgt_dma_busy=%b wgt_dma_done=%b", u_npu.wgt_dma_busy, u_npu.wgt_dma_done);
        $display("act_dma_busy=%b act_dma_done=%b", u_npu.act_dma_busy, u_npu.act_dma_done);

        // Read RAM at beat addresses (addr >> 5)
        $display("RAM[0x100 beat]=0x%064h", u_ram.ram[32'h100 >> 5]);
        $display("RAM[0x200 beat]=0x%064h", u_ram.ram[32'h200 >> 5]);
        // Output at 0x300: lower 32 bits of beat at 0x300
        $display("RAM[0x300 beat][31:0]=0x%08h (expected 50=0x32)",
                 u_ram.ram[32'h300 >> 5][31:0]);

        axi_read(32'h1000_0000, rd_val);
        $display("CTRL=0x%08h busy=%b done=%b error=%b", rd_val, rd_val[1], rd_val[2], rd_val[3]);

        if (rd_val[2]) begin
            $display("PASS: done=1");
            if (u_ram.ram[32'h300 >> 5][31:0] == 32'd50)
                $display("PASS: Conv result correct (50)");
            else
                $error("FAIL: expected 50, got %0d", $signed(u_ram.ram[32'h300 >> 5][31:0]));

            // === Read perf counters ===
            $display("=== Perf Counters ===");
            axi_read(32'h1000_003C, rd_val);
            $display("write_beats       = %0d", rd_val);
            axi_read(32'h1000_0044, rd_val);
            $display("write_active_cyc  = %0d", rd_val);
            axi_read(32'h1000_0088, rd_val);
            $display("write_data_cycles = %0d", rd_val);
            axi_read(32'h1000_008C, rd_val);
            $display("write_txn_cycles  = %0d", rd_val);
            // Read read-side perf for comparison
            axi_read(32'h1000_0038, rd_val);
            $display("read_beats        = %0d", rd_val);
            axi_read(32'h1000_0040, rd_val);
            $display("read_active_cyc   = %0d", rd_val);
            axi_read(32'h1000_0030, rd_val);
            $display("total_cycle_lo    = %0d", rd_val);
        end else if (rd_val[3]) begin
            axi_read(32'h1000_0004, rd_val);
            $display("FAIL: error_code=0x%02h", rd_val[7:0]);
        end else if (rd_val[1]) $display("NOTE: Still busy after 5000 cycles");
        else $display("NOTE: Idle — nothing happened");

        $display("=== Done ===");
        #20; $finish;
    end

endmodule
