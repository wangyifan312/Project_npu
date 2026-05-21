// tb_task2_strict: strict multi-block Conv test with unique-per-window outputs
// Input: 30x5 signed-safe ramp (each activation byte = row*3+col+1)
// Weights: all 1s
// Each 5x5 window has a unique sum → detects drop/dup/misorder
`timescale 1ns / 1ps

module tb_task2_strict;
    reg clk, rst_n;

    reg  s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    wire s_axi_awready, s_axi_wready, s_axi_bvalid;
    reg  [31:0] s_axi_awaddr, s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    wire [1:0]  s_axi_bresp;
    reg  s_axi_arvalid, s_axi_rready;
    wire s_axi_arready, s_axi_rvalid;
    reg  [31:0] s_axi_araddr;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;

    wire npu_arvalid, npu_awvalid, npu_wvalid, npu_wlast;
    wire [31:0] npu_araddr, npu_awaddr, npu_wdata;
    wire [7:0] npu_arlen, npu_awlen;
    wire [2:0] npu_arsize, npu_awsize;
    wire [1:0] npu_arburst, npu_awburst;
    wire [3:0] npu_wstrb;
    wire npu_rready, npu_bready, npu_busy, npu_done, npu_error;
    wire [7:0] npu_error_code;
    wire npu_arready, npu_awready, npu_wready;
    wire npu_rvalid, npu_bvalid;
    wire [31:0] npu_rdata;
    wire npu_rlast;
    wire [1:0] npu_rresp, npu_bresp;

    reg  preload, tb_awvalid, tb_wvalid;
    reg  [31:0] tb_awaddr, tb_wdata;
    reg  [31:0] tb_araddr;
    reg         tb_arvalid, tb_rready;
    wire        tb_arready, tb_rvalid;
    wire [31:0] tb_rdata;
    wire        tb_rlast;
    wire [1:0]  tb_rresp;

    wire ram_awvalid = preload ? tb_awvalid : npu_awvalid;
    wire [31:0] ram_awaddr = preload ? tb_awaddr : npu_awaddr;
    wire [7:0] ram_awlen = preload ? 8'h0 : npu_awlen;
    wire [2:0] ram_awsize = preload ? 3'd2 : npu_awsize;
    wire [1:0] ram_awburst = preload ? 2'd1 : npu_awburst;
    wire ram_wvalid = preload ? tb_wvalid : npu_wvalid;
    wire [31:0] ram_wdata = preload ? tb_wdata : npu_wdata;
    wire [3:0] ram_wstrb = preload ? 4'hF : npu_wstrb;
    wire ram_wlast = preload ? 1'b1 : npu_wlast;
    wire ram_bready = preload ? 1'b1 : npu_bready;
    wire ram_arvalid = preload ? tb_arvalid : npu_arvalid;
    wire [31:0] ram_araddr = preload ? tb_araddr : npu_araddr;
    wire [7:0] ram_arlen = preload ? 8'h0 : npu_arlen;
    wire [2:0] ram_arsize = preload ? 3'd2 : npu_arsize;
    wire [1:0] ram_arburst = preload ? 2'd1 : npu_arburst;
    wire ram_rready = preload ? tb_rready : npu_rready;
    wire ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0] ram_bresp, ram_rresp;
    wire ram_rvalid, ram_rlast;
    wire [31:0] ram_rdata;

    assign npu_arready = preload ? 1'b0 : ram_arready;
    assign npu_awready = preload ? 1'b0 : ram_awready;
    assign npu_wready  = preload ? 1'b0 : ram_wready;
    assign npu_rvalid  = preload ? 1'b0 : ram_rvalid;
    assign npu_bvalid  = preload ? 1'b0 : ram_bvalid;
    assign npu_rdata   = ram_rdata;
    assign npu_rlast   = ram_rlast;
    assign npu_rresp   = preload ? 2'b0 : ram_rresp;
    assign npu_bresp   = preload ? 2'b0 : ram_bresp;
    assign tb_arready  = preload ? ram_arready : 1'b0;
    assign tb_rvalid   = preload ? ram_rvalid : 1'b0;
    assign tb_rdata    = preload ? ram_rdata : 32'h0;
    assign tb_rlast    = preload ? ram_rlast : 1'b0;
    assign tb_rresp    = preload ? ram_rresp : 2'b0;

    // 128 entries = 2 blocks (20+6)
    npu_top #(.TILE_ROWS(7), .TILE_COLS(2), .BUF_ENTRIES(128), .BUF_ADDR_W(7)) u_npu (
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

    task axi_write;
        input [31:0] addr, data;
        begin @(posedge clk); s_axi_awvalid=1; s_axi_awaddr=addr; s_axi_wvalid=1; s_axi_wdata=data; s_axi_wstrb=4'hF;
        @(posedge clk); s_axi_awvalid=0; s_axi_wvalid=0;
        @(posedge clk); s_axi_bready=1; @(posedge clk); s_axi_bready=0; end
    endtask

    task axi_read;
        input [31:0] addr; output [31:0] data;
        begin @(posedge clk); s_axi_arvalid=1; s_axi_araddr=addr;
        @(posedge clk); s_axi_arvalid=0; @(posedge clk); data=s_axi_rdata; s_axi_rready=1;
        @(posedge clk); s_axi_rready=0; end
    endtask

    task preload_word;
        input [31:0] addr, data;
        begin @(posedge clk); tb_awvalid=1; tb_awaddr=addr; tb_wvalid=1; tb_wdata=data;
        @(posedge clk); tb_awvalid=0; @(posedge clk); tb_wvalid=0; @(posedge clk); end
    endtask

    task axi4_read;
        input [31:0] addr; output [31:0] data;
        begin
            @(posedge clk);
            preload = 1;
            @(posedge clk);
            tb_arvalid = 1; tb_araddr = addr;
            @(posedge clk);
            tb_arvalid = 0;
            @(posedge clk);
            data = tb_rdata;
            tb_rready = 1;
            @(posedge clk);
            tb_rready = 0;
            preload = 0;
        end
    endtask

    // Expected output: window at out_row sums 5 rows of input starting at out_row.
    // Activation pattern is act[r][c] = 3*r + c + 1, which stays within signed INT8.
    // Each row sum = 15*r + 15 (for r = out_row .. out_row+4)
    // Total = 75*out_row + 225
    function [31:0] expected_out;
        input [15:0] out_row;
        begin
            expected_out = 75 * out_row + 225;
        end
    endfunction

    reg [31:0] rd_val, rd_data;
    integer i;
    reg [31:0] errors, missing_cnt, mismatch_cnt;

`ifdef DEBUG_TASK2
    always @(posedge clk) begin
        if (u_npu.pp_data_valid_o) begin
            $display("DBG pp_write: blk_row=%0d acc_wr_ptr=%0d pp_out=%0d cf_row=%0d cf_col=%0d comp_idx=%0d",
                     u_npu.u_block_sched.curr_out_row,
                     u_npu.acc_wr_ptr,
                     $signed(u_npu.pp_data_out),
                     u_npu.cf_cur_row,
                     u_npu.cf_cur_col,
                     u_npu.comp_win_idx);
        end
    end
`endif

    initial begin
`ifndef NO_DUMP
        $dumpfile("sim/tb_task2_strict.vcd");
        $dumpvars(0, tb_task2_strict);
`endif
        clk=0; rst_n=0; preload=1;
        s_axi_awvalid=0; s_axi_wvalid=0; s_axi_bready=0;
        s_axi_arvalid=0; s_axi_rready=0;
        tb_awvalid=0; tb_wvalid=0; tb_arvalid=0; tb_rready=0;
        errors = 0; missing_cnt = 0; mismatch_cnt = 0;

        #20 rst_n=1; #20;

        // Pre-load activations: 30x5 signed-safe ramp
        // Row r, col c: value = r*3 + c + 1 (r 0..29, c 0..4)
        // 4 bytes per 32-bit word, little-endian (b0=LSB)
        // 150 bytes = 38 words (last word has 2 pad bytes)
        $display("=== Pre-load activations (30x5 signed-safe ramp) ===");
        for (i = 0; i < 38; i = i + 1) begin
            reg [31:0] word_val;
            reg [7:0] b0, b1, b2, b3;
            reg [7:0] bi0, bi1, bi2, bi3;
            bi0 = 4*i + 0;
            bi1 = 4*i + 1;
            bi2 = 4*i + 2;
            bi3 = 4*i + 3;
            b0 = (bi0 < 150) ? ((bi0/5)*3 + (bi0%5) + 1) : 8'h00;
            b1 = (bi1 < 150) ? ((bi1/5)*3 + (bi1%5) + 1) : 8'h00;
            b2 = (bi2 < 150) ? ((bi2/5)*3 + (bi2%5) + 1) : 8'h00;
            b3 = (bi3 < 150) ? ((bi3/5)*3 + (bi3%5) + 1) : 8'h00;
            word_val = {b3, b2, b1, b0};
            preload_word(32'h100 + i*4, word_val);
        end

        // weights: all 1s
        $display("=== Pre-load weights (all 1s) ===");
        for (i = 0; i < 7; i = i + 1)
            preload_word(32'h200 + i*4, 32'h01010101);

        preload = 0;

        // Configure NPU
        $display("=== Configure Conv: 30x5 input, 5x5 kernel -> 26x1 output ===");
        axi_write(32'h1000_0008, 32'h0000_0000);  // Conv
        axi_write(32'h1000_000C, 32'h0000_0100);  // input_addr
        axi_write(32'h1000_0010, 32'h0000_0200);  // weight_addr
        axi_write(32'h1000_0014, 32'h0000_0300);  // output_addr
        axi_write(32'h1000_0018, 32'h0000_0096);  // input_bytes=150
        axi_write(32'h1000_001C, 32'h0000_0019);  // weight_bytes=25
        axi_write(32'h1000_0020, 32'h0000_0068);  // output_bytes=104
        axi_write(32'h1000_0024, 32'h0005_001E);  // H=30,W=5
        axi_write(32'h1000_0028, 32'h0001_0001);
        axi_write(32'h1000_002C, 32'h0);

        $display("=== Start ===");
        axi_write(32'h1000_0000, 32'h1);

        repeat(500000) @(posedge clk);
        preload = 0;
        axi_read(32'h1000_0000, rd_val);
        $display("CTRL=0x%08h done=%b error=%b", rd_val, rd_val[2], rd_val[3]);

        if (rd_val[2]) begin
            $display("Task completed.");
            // Check ALL 26 output positions
            for (i = 0; i < 26; i = i + 1) begin
                axi4_read(32'h300 + i*4, rd_data);
                if ($signed(rd_data) !== expected_out(i[15:0])) begin
                    if (rd_data === 32'hxxxxxxxx) begin
                        $display("  MISSING: output[%0d] expected %0d, got x", i, expected_out(i[15:0]));
                        missing_cnt = missing_cnt + 1;
                    end else begin
                        $display("  MISMATCH: output[%0d] expected %0d, got %0d", i, expected_out(i[15:0]), $signed(rd_data));
                        mismatch_cnt = mismatch_cnt + 1;
                    end
                    errors = errors + 1;
                end
            end
            if (errors == 0) begin
                $display("=== STRICT TEST: ALL 26 OUTPUTS CORRECT ===");
                $display("=== FINAL: PASS ===");
            end else begin
                $display("=== STRICT TEST: %0d errors (%0d missing, %0d mismatch) ===", errors, missing_cnt, mismatch_cnt);
                $display("=== FINAL: FAIL ===");
            end
        end else if (rd_val[3]) begin
            axi_read(32'h1000_0004, rd_val);
            $display("FAIL: error_code=0x%02h", rd_val[7:0]);
        end else begin
            $display("FAIL: Still busy, FSM=%0d", u_npu.fsm_state);
        end

        #20 $finish;
    end

endmodule
