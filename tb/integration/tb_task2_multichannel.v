// tb_task2_multichannel: Strict multi-channel Conv acceptance tests
// Tests: 1->4, 3->5 (small), 1->20, 20->50 (LeNet scale)
// Uses $fatal on failure for automatic flow detection
`timescale 1ns / 1ps

module tb_task2_multichannel;
    reg clk, rst_n, preload;
    reg s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    reg [31:0] s_axi_awaddr, s_axi_wdata;
    reg [3:0] s_axi_wstrb;
    reg s_axi_arvalid, s_axi_rready;
    reg [31:0] s_axi_araddr;
    reg tb_awvalid, tb_wvalid;
    reg [31:0] tb_awaddr, tb_wdata;

    wire s_axi_bvalid, s_axi_arready, s_axi_rvalid;
    wire s_axi_awready, s_axi_wready;
    wire [1:0] s_axi_bresp, s_axi_rresp;
    wire [31:0] s_axi_rdata;

    wire npu_busy, npu_done, npu_error;
    wire [7:0] npu_error_code;
    wire npu_arvalid, npu_awvalid, npu_wvalid, npu_wlast;
    wire [31:0] npu_araddr, npu_awaddr, npu_wdata;
    wire [7:0] npu_arlen, npu_awlen;
    wire [2:0] npu_arsize, npu_awsize;
    wire [1:0] npu_arburst, npu_awburst;
    wire [3:0] npu_wstrb;
    wire npu_rready, npu_bready;

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
    wire ram_arvalid = preload ? 1'b0 : npu_arvalid;
    wire [31:0] ram_araddr = preload ? 32'h0 : npu_araddr;
    wire [7:0] ram_arlen = preload ? 8'h0 : npu_arlen;
    wire [2:0] ram_arsize = preload ? 3'd2 : npu_arsize;
    wire [1:0] ram_arburst = preload ? 2'd1 : npu_arburst;
    wire ram_rready = preload ? 1'b0 : npu_rready;

    wire ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0] ram_bresp, ram_rresp;
    wire ram_rvalid, ram_rlast;
    wire [31:0] ram_rdata;

    // TILE_COLS=13 gives 52 PE columns, enough for 50 output channels (LeNet Conv2)
    npu_top #(.TILE_ROWS(7), .TILE_COLS(13), .BUF_ENTRIES(1024), .BUF_ADDR_W(10)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_araddr(s_axi_araddr), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready), .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .m_axi_arvalid(npu_arvalid), .m_axi_arready(preload ? 1'b0 : ram_arready),
        .m_axi_araddr(npu_araddr), .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize), .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(preload ? 1'b0 : ram_rvalid),
        .m_axi_rready(npu_rready), .m_axi_rdata(ram_rdata),
        .m_axi_rlast(preload ? 1'b0 : ram_rlast), .m_axi_rresp(ram_rresp),
        .m_axi_awvalid(npu_awvalid), .m_axi_awready(preload ? 1'b0 : ram_awready),
        .m_axi_awaddr(npu_awaddr), .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize), .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid), .m_axi_wready(preload ? 1'b0 : ram_wready),
        .m_axi_wdata(npu_wdata), .m_axi_wlast(npu_wlast),
        .m_axi_wstrb(npu_wstrb), .m_axi_bvalid(preload ? 1'b0 : ram_bvalid),
        .m_axi_bready(npu_bready), .m_axi_bresp(ram_bresp),
        .npu_busy(npu_busy), .npu_done(npu_done),
        .npu_error(npu_error), .npu_error_code(npu_error_code)
    );

    axi4_ram #(.RAM_DEPTH(65536)) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(ram_awvalid), .s_axi_awready(ram_awready),
        .s_axi_awaddr(ram_awaddr), .s_axi_awlen(ram_awlen),
        .s_axi_awsize(ram_awsize), .s_axi_awburst(ram_awburst),
        .s_axi_wvalid(ram_wvalid), .s_axi_wready(ram_wready),
        .s_axi_wdata(ram_wdata), .s_axi_wstrb(ram_wstrb),
        .s_axi_wlast(ram_wlast), .s_axi_bvalid(ram_bvalid),
        .s_axi_bready(ram_bready), .s_axi_bresp(ram_bresp),
        .s_axi_arvalid(ram_arvalid), .s_axi_arready(ram_arready),
        .s_axi_araddr(ram_araddr), .s_axi_arlen(ram_arlen),
        .s_axi_arsize(ram_arsize), .s_axi_arburst(ram_arburst),
        .s_axi_rvalid(ram_rvalid), .s_axi_rready(ram_rready),
        .s_axi_rdata(ram_rdata), .s_axi_rlast(ram_rlast),
        .s_axi_rresp(ram_rresp)
    );

    always #2.5 clk = ~clk;

    task axi_write;
        input [31:0] addr, data;
        begin @(posedge clk); s_axi_awvalid=1; s_axi_awaddr=addr; s_axi_wvalid=1; s_axi_wdata=data; s_axi_wstrb=4'hF;
        @(posedge clk); s_axi_awvalid=0; s_axi_wvalid=0;
        @(posedge clk); s_axi_bready=1; @(posedge clk); s_axi_bready=0; end
    endtask

    task preload_word;
        input [31:0] addr, data;
        begin @(posedge clk); tb_awvalid=1; tb_awaddr=addr; tb_wvalid=1; tb_wdata=data;
        @(posedge clk); tb_awvalid=0; @(posedge clk); tb_wvalid=0; @(posedge clk); end
    endtask

    function [31:0] ram_read;
        input [31:0] addr;
        begin ram_read = u_ram.ram[addr[15:2]]; end
    endfunction

    task wait_done;
        input integer max_cycles;
        integer cnt;
        begin cnt = 0;
            while (!npu_done && !npu_error && cnt < max_cycles) begin
                @(posedge clk); cnt = cnt + 1;
            end
        end
    endtask

    // ============================================================
    // Preload helpers
    // ============================================================
    task preload_activations;
        input [31:0] base;
        input [15:0] iw, ih, ic;
        reg [31:0] word_val;
        reg [7:0] b0, b1, b2, b3;
        integer byte_idx, total_bytes;
        begin
            total_bytes = iw * ih * ic;
            for (byte_idx = 0; byte_idx < total_bytes; byte_idx = byte_idx + 4) begin
                b0 = (byte_idx+0 < total_bytes) ? ((byte_idx+0) & 8'h7F) : 8'h00;
                b1 = (byte_idx+1 < total_bytes) ? ((byte_idx+1) & 8'h7F) : 8'h00;
                b2 = (byte_idx+2 < total_bytes) ? ((byte_idx+2) & 8'h7F) : 8'h00;
                b3 = (byte_idx+3 < total_bytes) ? ((byte_idx+3) & 8'h7F) : 8'h00;
                word_val = {b3, b2, b1, b0};
                preload_word(base + byte_idx, word_val);
            end
        end
    endtask

    task preload_weights;
        input [31:0] base;
        input [15:0] ic, oc;
        reg [31:0] word_val;
        reg [7:0] b0, b1, b2, b3;
        integer ci, byte_idx, bytes_per_ci, valid_bytes_per_ci;
        begin
            valid_bytes_per_ci = 25 * oc;                  // actual weights
            bytes_per_ci = ((valid_bytes_per_ci + 3) / 4) * 4;  // 32-bit aligned stride per C_in
            for (ci = 0; ci < ic; ci = ci + 1) begin
                for (byte_idx = 0; byte_idx < bytes_per_ci; byte_idx = byte_idx + 4) begin
                    b0 = (byte_idx+0 < valid_bytes_per_ci) ? (((byte_idx+0) % oc + 1) * (ci + 1)) & 8'h7F : 8'h00;
                    b1 = (byte_idx+1 < valid_bytes_per_ci) ? (((byte_idx+1) % oc + 1) * (ci + 1)) & 8'h7F : 8'h00;
                    b2 = (byte_idx+2 < valid_bytes_per_ci) ? (((byte_idx+2) % oc + 1) * (ci + 1)) & 8'h7F : 8'h00;
                    b3 = (byte_idx+3 < valid_bytes_per_ci) ? (((byte_idx+3) % oc + 1) * (ci + 1)) & 8'h7F : 8'h00;
                    word_val = {b3, b2, b1, b0};
                    preload_word(base + ci * bytes_per_ci + byte_idx, word_val);
                end
            end
        end
    endtask

    // ============================================================
    // Golden conv: computes expected output value
    // ============================================================
    function [31:0] golden_conv;
        input [15:0] oh, ow, oc_idx;  // output position (row, col, channel)
        input [15:0] iw, ic_total, oc_total;
        reg [31:0] acc;
        integer ci, kh, kw, act_byte;
        reg signed [7:0] act_val, wgt_val;
        begin
            acc = 0;
            for (ci = 0; ci < ic_total; ci = ci + 1) begin
                for (kh = 0; kh < 5; kh = kh + 1) begin
                    for (kw = 0; kw < 5; kw = kw + 1) begin
                        act_byte = (oh + kh) * iw * ic_total + (ow + kw) * ic_total + ci;
                        act_val = act_byte & 8'h7F;
                        wgt_val = ((oc_idx + 1) * (ci + 1)) & 8'h7F;
                        acc = acc + act_val * wgt_val;
                    end
                end
            end
            golden_conv = acc;
        end
    endfunction

    // ============================================================
    // Run and verify a single Conv test
    // ============================================================
    integer total_errors;
    task run_conv_test;
        input [15:0] iw, ih, ic, oc;
        input [31:0] act_base, wgt_base, out_base;
        input integer max_cycles;
        input [255:0] test_name;
        reg [15:0] ow, oh;
        reg [31:0] rd_val;
        integer i, h, w, c;
        reg [31:0] expected_val;
        begin
            oh = ih - 4;  // valid padding
            ow = iw - 4;
            $display("=== %0s: Conv %0d->%0d  %0dx%0d -> %0dx%0dx%0d ===",
                test_name, ic, oc, iw, ih, ow, oh, oc);

            preload = 1;

            // Preload activations (HWC layout, ramp pattern)
            preload_activations(act_base, iw, ih, ic);

            // Preload weights: [in_c][kh][kw][out_c]
            preload_weights(wgt_base, ic, oc);

            preload = 0;

            // Configure NPU
            axi_write(32'h1000_0008, 32'h0);  // Conv
            axi_write(32'h1000_000C, act_base);
            axi_write(32'h1000_0010, wgt_base);
            axi_write(32'h1000_0014, out_base);
            axi_write(32'h1000_0018, iw * ih * ic);            // input_bytes
            axi_write(32'h1000_001C, (((25 * oc + 3) / 4) * 4) * ic);  // padded weight_bytes
            axi_write(32'h1000_0020, ow * oh * oc * 4);        // output_bytes
            axi_write(32'h1000_0024, {iw[15:0], ih[15:0]});    // W,H
            axi_write(32'h1000_0028, {oc[15:0], ic[15:0]});    // C_OUT, C_IN
            axi_write(32'h1000_002C, 32'h0);                    // relu=0,pool=0
            axi_write(32'h1000_0000, 32'h1);                    // start

            wait_done(max_cycles);

            if (!npu_done && !npu_error) begin
                $display("  TIMEOUT after %0d cycles", max_cycles);
                $fatal(1, "Test timed out");
            end

            if (npu_error) begin
                axi_write(32'h0, 32'h0);  // dummy
                $display("  NPU ERROR: code=0x%02h", npu_error_code);
                total_errors = total_errors + 1000;  // mark as failed
            end else begin
                // Verify all output positions
                for (h = 0; h < oh; h = h + 1) begin
                    for (w = 0; w < ow; w = w + 1) begin
                        for (c = 0; c < oc; c = c + 1) begin
                            integer byte_offset;
                            byte_offset = (h * ow * oc + w * oc + c) * 4;
                            rd_val = ram_read(out_base + byte_offset);
                            expected_val = golden_conv(h[15:0], w[15:0], c[15:0], iw, ic, oc);
                            if ($signed(rd_val) !== expected_val) begin
                                if (total_errors < 8)
                                    $display("  MISMATCH out[%0d][%0d][%0d]: got %0d exp %0d",
                                        h, w, c, $signed(rd_val), expected_val);
                                total_errors = total_errors + 1;
                            end
                        end
                    end
                end
                if (total_errors == 0)
                    $display("  PASS: all %0d outputs correct", oh * ow * oc);
            end
        end
    endtask

    // ============================================================
    // Main test sequence
    // ============================================================
    initial begin
`ifndef NO_DUMP
        $dumpfile("sim/tb_task2_multichannel.vcd");
        $dumpvars(0, tb_task2_multichannel);
`endif
        clk = 0; rst_n = 0; preload = 1;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0; s_axi_wstrb = 4'hF;
        s_axi_arvalid = 0; s_axi_rready = 0;
        tb_awvalid = 0; tb_wvalid = 0;
        total_errors = 0;

        #20 rst_n = 1; #20;

        // ============================================================
        // Test 1: Conv 1->4, 5x5 input (1 window x 4 channels = 4 outputs)
        // ============================================================
        run_conv_test(5, 5, 1, 4, 32'h200, 32'h400, 32'h800, 5000, "Test 1: 1->4");

        // Reset between tests
        rst_n = 0; #20; rst_n = 1; #20; preload = 1; #20;

        // ============================================================
        // Test 2: Conv 3->5, 5x5 input (1 window x 5 channels = 5 outputs)
        // ============================================================
        run_conv_test(5, 5, 3, 5, 32'h200, 32'h400, 32'h800, 8000, "Test 2: 3->5");

        // Reset between tests
        rst_n = 0; #20; rst_n = 1; #20; preload = 1; #20;

        // ============================================================
        // Test 3: Conv 1->20, 5x5 input (1 window x 20 channels = 20 outputs)
        // Proves LeNet Conv1 scale channel count
        // ============================================================
        run_conv_test(5, 5, 1, 20, 32'h200, 32'h2000, 32'h3000, 10000, "Test 3: 1->20");

        // Reset between tests
        rst_n = 0; #20; rst_n = 1; #20; preload = 1; #20;

        // ============================================================
        // Test 4: Conv 20->50, 5x5 input (1 window x 50 channels = 50 outputs)
        // Full LeNet Conv2 coverage: C_in=20, C_out=50
        // ============================================================
        run_conv_test(5, 5, 20, 50, 32'h200, 32'h2000, 32'h3000, 60000, "Test 4: 20->50");

        // ============================================================
        // Final result
        // ============================================================
        $display("=== Task 2 Results: %0d total errors ===", total_errors);
        if (total_errors != 0) begin
            $display("FAIL: Task 2 multi-channel Conv verification failed with %0d errors", total_errors);
            $fatal(1, "Task 2 FAILED");
        end else begin
            $display("PASS: Task 2 multi-channel Conv verification passed all tests");
        end

        #20 $finish;
    end
endmodule
