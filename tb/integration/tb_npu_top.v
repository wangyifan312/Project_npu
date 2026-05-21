// tb_npu_top: end-to-end NPU accelerator testbench
// Pre-loads RAM via direct AXI4 write, then runs NPU Conv task
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

    // === NPU AXI4 DMA ports ===
    wire        npu_arvalid, npu_awvalid;
    wire [31:0] npu_araddr,  npu_awaddr;
    wire [7:0]  npu_arlen,   npu_awlen;
    wire [2:0]  npu_arsize,  npu_awsize;
    wire [1:0]  npu_arburst, npu_awburst;
    wire        npu_wvalid,  npu_wlast;
    wire [31:0] npu_wdata;
    wire [3:0]  npu_wstrb;
    wire        npu_rready,  npu_bready;
    wire        npu_busy, npu_done, npu_error;
    wire [7:0]  npu_error_code;

    // === Preload control ===
    reg         preload;
    reg         tb_awvalid, tb_wvalid;
    reg  [31:0] tb_awaddr, tb_wdata;

    // === RAM interface (muxed) ===
    wire        ram_awvalid = preload ? tb_awvalid : npu_awvalid;
    wire [31:0] ram_awaddr  = preload ? tb_awaddr  : npu_awaddr;
    wire [7:0]  ram_awlen   = preload ? 8'h0       : npu_awlen;
    wire [2:0]  ram_awsize  = preload ? 3'd2       : npu_awsize;
    wire [1:0]  ram_awburst = preload ? 2'd1       : npu_awburst;
    wire        ram_wvalid  = preload ? tb_wvalid  : npu_wvalid;
    wire [31:0] ram_wdata   = preload ? tb_wdata   : npu_wdata;
    wire [3:0]  ram_wstrb   = preload ? 4'hF       : npu_wstrb;
    wire        ram_wlast   = preload ? 1'b1       : npu_wlast;
    wire        ram_bready  = preload ? 1'b1       : npu_bready;
    wire        ram_arvalid = preload ? 1'b0       : npu_arvalid;
    wire [31:0] ram_araddr  = preload ? 32'h0      : npu_araddr;
    wire [7:0]  ram_arlen   = preload ? 8'h0       : npu_arlen;
    wire [2:0]  ram_arsize  = preload ? 3'd2       : npu_arsize;
    wire [1:0]  ram_arburst = preload ? 2'd1       : npu_arburst;
    wire        ram_rready  = preload ? 1'b0       : npu_rready;

    wire        ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0]  ram_bresp, ram_rresp;
    wire        ram_rvalid, ram_rlast;
    wire [31:0] ram_rdata;

    // NPU sees RAM responses only when not preloading
    wire        npu_arready = preload ? 1'b0 : ram_arready;
    wire        npu_awready = preload ? 1'b0 : ram_awready;
    wire        npu_wready  = preload ? 1'b0 : ram_wready;
    wire        npu_rvalid  = preload ? 1'b0 : ram_rvalid;
    wire        npu_bvalid  = preload ? 1'b0 : ram_bvalid;
    wire [31:0] npu_rdata   = ram_rdata;
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
    // AXI4 RAM instance
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

    // Pre-load helper: write one word to RAM via AXI4
    // RAM has 1-cycle pipeline: AW accepted immediately, W accepted next cycle
    task preload_word;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            tb_awvalid = 1; tb_awaddr = addr;
            tb_wvalid  = 1; tb_wdata  = data;
            @(posedge clk);  // AW handshake done; w_active=1 now, wready=1
            // Hold wvalid for this cycle too (wready now high → w_hs fires)
            tb_awvalid = 0;
            // tb_wvalid stays 1, tb_wdata stays
            @(posedge clk);  // W handshake done
            tb_wvalid = 0;
            @(posedge clk);  // wait for bvalid
        end
    endtask

    reg [31:0] rd_val;

    initial begin
        $dumpfile("sim/tb_npu_top.vcd");
        $dumpvars(0, tb_npu_top);

        clk = 0; rst_n = 0; preload = 1;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_arvalid = 0; s_axi_rready = 0;
        tb_awvalid = 0; tb_wvalid = 0;

        #20 rst_n = 1;
        #20;

        // === Pre-load test data ===
        $display("=== Pre-load activations (5x5, all 1s) at 0x100 ===");
        preload_word(32'h0000_0100, 32'h01010101);
        preload_word(32'h0000_0104, 32'h01010101);
        preload_word(32'h0000_0108, 32'h01010101);
        preload_word(32'h0000_010C, 32'h01010101);
        preload_word(32'h0000_0110, 32'h01010101);
        preload_word(32'h0000_0114, 32'h01010101);
        preload_word(32'h0000_0118, 32'h01010101);
        $display("  Done (25 bytes)");

        $display("=== Pre-load weights (5x5, all 2s) at 0x200 ===");
        preload_word(32'h0000_0200, 32'h02020202);
        preload_word(32'h0000_0204, 32'h02020202);
        preload_word(32'h0000_0208, 32'h02020202);
        preload_word(32'h0000_020C, 32'h02020202);
        preload_word(32'h0000_0210, 32'h02020202);
        preload_word(32'h0000_0214, 32'h02020202);
        preload_word(32'h0000_0218, 32'h02020202);
        $display("  Done (25 bytes)");

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
        // Debug
        $display("FSM state = %0d", tb_npu_top.u_npu.fsm_state);
        $display("wgt_dma_busy=%b wgt_dma_done=%b", tb_npu_top.u_npu.wgt_dma_busy, tb_npu_top.u_npu.wgt_dma_done);
        $display("act_dma_busy=%b act_dma_done=%b", tb_npu_top.u_npu.act_dma_busy, tb_npu_top.u_npu.act_dma_done);
        // Check RAM at act/weight addresses
        $display("RAM[0x100>>2]=0x%08h RAM[0x104>>2]=0x%08h", tb_npu_top.u_ram.ram[32'h100>>2], tb_npu_top.u_ram.ram[32'h104>>2]);
        $display("RAM[0x200>>2]=0x%08h RAM[0x204>>2]=0x%08h", tb_npu_top.u_ram.ram[32'h200>>2], tb_npu_top.u_ram.ram[32'h204>>2]);
        $display("RAM[0x300>>2]=0x%08h (expected 50=0x32)", tb_npu_top.u_ram.ram[32'h300>>2]);
        // Check wgt_load_reg values
        $display("wgt_load_reg[0]=%0d wgt_load_reg[1]=%0d wgt_load_reg[24]=%0d",
            tb_npu_top.u_npu.wgt_load_reg[0], tb_npu_top.u_npu.wgt_load_reg[1], tb_npu_top.u_npu.wgt_load_reg[24]);
        // Check array_weight flat vector
        // Check all 25 weight positions
        $write("array_weight[");
        for (integer ci = 0; ci < 25; ci = ci + 1) begin
            integer tr, ti, lr, fb;
            tr = ci / 4;
            ti = tr * 2; // TILE_COLS=2
            lr = ci % 4;
            fb = ti * 128 + lr * 32;
            $write("%0d ", tb_npu_top.u_npu.array_weight[fb+:8]);
        end
        $display("]");
        $display("cf_state=%0d cf_window_valid=%b cf_done=%b",
            tb_npu_top.u_npu.u_conv_fe.state, tb_npu_top.u_npu.cf_window_valid_i, tb_npu_top.u_npu.cf_done);
        // Check array_act_in driven values
        $display("array_act_in[0+:8]=%0d [8+:8]=%0d [24*8+:8]=%0d",
            tb_npu_top.u_npu.array_act_in[0+:8],
            tb_npu_top.u_npu.array_act_in[8+:8],
            tb_npu_top.u_npu.array_act_in[24*8+:8]);
        $display("act_feed_en=%b comp_feed_cnt=%0d comp_sub_state=%0d",
            tb_npu_top.u_npu.act_feed_en, tb_npu_top.u_npu.comp_feed_cnt,
            tb_npu_top.u_npu.comp_sub_state);

        axi_read(32'h1000_0000, rd_val);
        $display("CTRL=0x%08h busy=%b done=%b error=%b", rd_val, rd_val[1], rd_val[2], rd_val[3]);

        if (rd_val[2]) begin
            $display("PASS: done=1");
            // Verify output by reading back from RAM at output_addr (0x300)
            // Use AXI4 read: temporarily take over RAM port
            preload = 1;
            // Issue AXI4 read via testbench signals
            @(posedge clk);
            // Drive AR
            tb_awvalid = 0; tb_wvalid = 0;
            // Use TB-controlled AXI4 read path (add simple AR → R handshake)
            // Actually read from RAM hierarchy for simplicity
            $display("output[0x300] = %0d (expect 50)", $signed(tb_npu_top.u_ram.ram[32'h300 >> 2]));
            if ($signed(tb_npu_top.u_ram.ram[32'h300 >> 2]) == 50)
                $display("PASS: Conv result correct (50)");
            else
                $error("FAIL: expected 50, got %0d", $signed(tb_npu_top.u_ram.ram[32'h300 >> 2]));
            preload = 0;
        end else if (rd_val[3]) begin
            axi_read(32'h1000_0004, rd_val);
            $display("FAIL: error_code=0x%02h", rd_val[7:0]);
        end else if (rd_val[1]) $display("NOTE: Still busy after 5000 cycles");
        else $display("NOTE: Idle — nothing happened");

        $display("=== Done ===");
        #20; $finish;
    end

endmodule
