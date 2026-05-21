// tb_lenet_network: full LeNet(MNIST) network-level integration test
`timescale 1ns / 1ps

module tb_lenet_network;
    reg clk, rst_n;
    reg s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    reg [31:0] s_axi_awaddr, s_axi_wdata;
    reg [3:0] s_axi_wstrb;

    wire s_axi_awready, s_axi_wready, s_axi_bvalid;
    wire [1:0] s_axi_bresp;
    wire npu_busy, npu_done, npu_error;
    wire [7:0] npu_error_code;
    wire npu_arvalid, npu_awvalid, npu_wvalid, npu_wlast;
    wire [31:0] npu_araddr, npu_awaddr, npu_wdata;
    wire [7:0] npu_arlen, npu_awlen;
    wire [2:0] npu_arsize, npu_awsize;
    wire [1:0] npu_arburst, npu_awburst;
    wire [3:0] npu_wstrb;
    wire npu_rready, npu_bready;
    wire ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0] ram_bresp, ram_rresp;
    wire ram_rvalid, ram_rlast;
    wire [31:0] ram_rdata;

    localparam INPUT_ADDR     = 32'h0000_0100;
    localparam CONV1_WGT_ADDR = 32'h0000_1000;
    localparam CONV1_OUT_ADDR = 32'h0000_4000;
    localparam POOL1_OUT_ADDR = 32'h0001_8000;
    localparam CONV2_IN_ADDR  = 32'h0001_C000;
    localparam CONV2_WGT_ADDR = 32'h0002_0000;
    localparam CONV2_OUT_ADDR = 32'h0006_0000;
    localparam POOL2_OUT_ADDR = 32'h0008_0000;
    localparam FC1_WGT_ADDR   = 32'h0009_0000;
    localparam FC1_OUT_ADDR   = 32'h000F_2000;
    localparam FC2_WGT_ADDR   = 32'h000F_3000;
    localparam FC2_OUT_ADDR   = 32'h000F_5000;

    localparam CONV1_OUT_WORDS = 24*24*20;
    localparam POOL1_OUT_WORDS = 12*12*20;
    localparam CONV2_OUT_WORDS = 8*8*50;
    localparam POOL2_OUT_WORDS = 4*4*50;
    localparam FC1_OUT_WORDS   = 500;
    localparam FC2_OUT_WORDS   = 10;
    localparam MAX_FILE_WORDS  = 131072;

    reg [31:0] file_words [0:MAX_FILE_WORDS-1];
    string fixture_dir, sample_name, sample_dir, weights_dir;
    string path_input, path_conv1_w, path_conv2_w, path_fc1_w, path_fc2_w;
    string path_conv1_g, path_pool1_g, path_conv2_input_g, path_conv2_g;
    string path_pool2_g, path_fc1_g, path_fc2_g, path_argmax;
    integer show_progress;

    npu_top #(.TILE_ROWS(7), .TILE_COLS(13), .BUF_ENTRIES(16384), .BUF_ADDR_W(14)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(1'b0), .s_axi_arready(), .s_axi_araddr(32'h0),
        .s_axi_rvalid(), .s_axi_rready(1'b0), .s_axi_rdata(), .s_axi_rresp(),
        .m_axi_arvalid(npu_arvalid), .m_axi_arready(ram_arready),
        .m_axi_araddr(npu_araddr), .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize), .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(ram_rvalid), .m_axi_rready(npu_rready),
        .m_axi_rdata(ram_rdata), .m_axi_rlast(ram_rlast), .m_axi_rresp(ram_rresp),
        .m_axi_awvalid(npu_awvalid), .m_axi_awready(ram_awready),
        .m_axi_awaddr(npu_awaddr), .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize), .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid), .m_axi_wready(ram_wready),
        .m_axi_wdata(npu_wdata), .m_axi_wlast(npu_wlast), .m_axi_wstrb(npu_wstrb),
        .m_axi_bvalid(ram_bvalid), .m_axi_bready(npu_bready), .m_axi_bresp(ram_bresp),
        .npu_busy(npu_busy), .npu_done(npu_done), .npu_error(npu_error), .npu_error_code(npu_error_code)
    );

    axi4_ram #(.RAM_DEPTH(262144)) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(npu_awvalid), .s_axi_awready(ram_awready),
        .s_axi_awaddr(npu_awaddr), .s_axi_awlen(npu_awlen),
        .s_axi_awsize(npu_awsize), .s_axi_awburst(npu_awburst),
        .s_axi_wvalid(npu_wvalid), .s_axi_wready(ram_wready),
        .s_axi_wdata(npu_wdata), .s_axi_wstrb(npu_wstrb),
        .s_axi_wlast(npu_wlast), .s_axi_bvalid(ram_bvalid),
        .s_axi_bready(npu_bready), .s_axi_bresp(ram_bresp),
        .s_axi_arvalid(npu_arvalid), .s_axi_arready(ram_arready),
        .s_axi_araddr(npu_araddr), .s_axi_arlen(npu_arlen),
        .s_axi_arsize(npu_arsize), .s_axi_arburst(npu_arburst),
        .s_axi_rvalid(ram_rvalid), .s_axi_rready(npu_rready),
        .s_axi_rdata(ram_rdata), .s_axi_rlast(ram_rlast), .s_axi_rresp(ram_rresp)
    );

    always #2.5 clk = ~clk;

    function signed [7:0] sat_i8;
        input signed [31:0] val;
        begin
            if (val > 32'sd127) sat_i8 = 8'sd127;
            else if (val < -32'sd128) sat_i8 = -8'sd128;
            else sat_i8 = val[7:0];
        end
    endfunction

    function integer read_argmax_file;
        input string path;
        integer fd, value;
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("ERROR: failed to open %0s", path);
                read_argmax_file = -1;
            end else begin
                value = -1;
                if ($fscanf(fd, "%d", value) != 1)
                    value = -1;
                $fclose(fd);
                read_argmax_file = value;
            end
        end
    endfunction

    task axi_write;
        input [31:0] addr, data;
        begin
            @(posedge clk);
            s_axi_awvalid = 1'b1; s_axi_awaddr = addr;
            s_axi_wvalid  = 1'b1; s_axi_wdata  = data; s_axi_wstrb = 4'hF;
            @(posedge clk);
            s_axi_awvalid = 1'b0; s_axi_wvalid = 1'b0;
            @(posedge clk);
            s_axi_bready = 1'b1;
            @(posedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task wait_done;
        input integer maxc;
        integer c;
        begin
            c = 0;
            while (!npu_done && !npu_error && c < maxc) begin
                @(posedge clk);
                c = c + 1;
            end
        end
    endtask

    task load_memh_to_ram;
        input string path;
        input [31:0] base_addr;
        input integer word_count;
        integer i;
        begin
            $readmemh(path, file_words);
            for (i = 0; i < word_count; i = i + 1)
                u_ram.ram[(base_addr >> 2) + i] = file_words[i];
        end
    endtask

    task compare_region_memh;
        input string path;
        input [31:0] base_addr;
        input integer word_count;
        input [127:0] name;
        inout integer total_errs;
        integer i, local_errs;
        reg [31:0] actual;
        begin
            local_errs = 0;
            $readmemh(path, file_words);
            for (i = 0; i < word_count; i = i + 1) begin
                actual = u_ram.ram[(base_addr >> 2) + i];
                if (actual !== file_words[i]) begin
                    local_errs = local_errs + 1;
                    if (local_errs <= 8)
                        $display("  %0s mismatch[%0d]: got %0d exp %0d",
                                 name, i, $signed(actual), $signed(file_words[i]));
                end
            end
            if (local_errs == 0)
                $display("  %0s PASS", name);
            else
                $display("  %0s FAIL: %0d mismatches", name, local_errs);
            total_errs = total_errs + local_errs;
        end
    endtask

    task requantize_i32_to_i8_region;
        input [31:0] src_addr;
        input [31:0] dst_addr;
        input integer elem_count;
        integer i, word_idx, byte_idx;
        reg signed [31:0] src_val;
        reg [31:0] pack_word;
        reg signed [7:0] qv;
        begin
            pack_word = 32'd0;
            word_idx = 0;
            for (i = 0; i < elem_count; i = i + 1) begin
                src_val = u_ram.ram[(src_addr >> 2) + i];
                qv = sat_i8(src_val);
                byte_idx = i[1:0];
                pack_word[byte_idx*8 +: 8] = qv[7:0];
                if (byte_idx == 3) begin
                    u_ram.ram[(dst_addr >> 2) + word_idx] = pack_word;
                    pack_word = 32'd0;
                    word_idx = word_idx + 1;
                end
            end
            if (elem_count % 4 != 0)
                u_ram.ram[(dst_addr >> 2) + word_idx] = pack_word;
        end
    endtask

    task run_layer;
        input [1:0] ttype;
        input [31:0] in_addr, wgt_addr, out_addr;
        input [31:0] in_bytes, wgt_bytes, out_bytes;
        input [15:0] iw, ih, ic, oc;
        input relu, pool;
        input integer maxc;
        input [127:0] layer_name;
        integer c;
        begin
            $display("=== %0s ===", layer_name);
            if (npu_done || npu_error)
                axi_write(32'h1000_0000, 32'h10);
            repeat (2) @(posedge clk);
            axi_write(32'h1000_0008, {30'd0, ttype});
            axi_write(32'h1000_000C, in_addr);
            axi_write(32'h1000_0010, wgt_addr);
            axi_write(32'h1000_0014, out_addr);
            axi_write(32'h1000_0018, in_bytes);
            axi_write(32'h1000_001C, wgt_bytes);
            axi_write(32'h1000_0020, out_bytes);
            axi_write(32'h1000_0024, {iw[15:0], ih[15:0]});
            axi_write(32'h1000_0028, {oc[15:0], ic[15:0]});
            axi_write(32'h1000_002C, {30'd0, pool, relu});
            axi_write(32'h1000_0000, 32'h1);
            c = 0;
            while (!npu_done && !npu_error && c < maxc) begin
                @(posedge clk);
                c = c + 1;
                if (show_progress != 0 && (c % 1000) == 0) begin
                    $display("  %0s progress: cycles=%0d fsm=%0d sub=%0d block_row=%0d cin=%0d win=%0d feed=%0d",
                             layer_name, c, u_npu.fsm_state, u_npu.comp_sub_state,
                             u_npu.u_block_sched.curr_out_row, u_npu.cin_idx,
                             u_npu.comp_win_idx, u_npu.act_feed_done_cnt);
                end
            end
            if (npu_error)
                $fatal(1, "%0s NPU error code=0x%02h", layer_name, npu_error_code);
            if (!npu_done)
                $fatal(1, "%0s TIMEOUT", layer_name);
            while (npu_busy && c < maxc) begin
                @(posedge clk);
                c = c + 1;
            end
            if (npu_busy)
                $fatal(1, "%0s BUSY-STUCK after done", layer_name);
            repeat (4) @(posedge clk);
        end
    endtask

    function integer argmax_region;
        input [31:0] base_addr;
        input integer count;
        integer i, best_i;
        reg signed [31:0] best_v, cur_v;
        begin
            best_i = 0;
            best_v = u_ram.ram[(base_addr >> 2)];
            for (i = 1; i < count; i = i + 1) begin
                cur_v = u_ram.ram[(base_addr >> 2) + i];
                if (cur_v > best_v) begin
                    best_v = cur_v;
                    best_i = i;
                end
            end
            argmax_region = best_i;
        end
    endfunction

    integer errs, pred, expected_pred;

    initial begin
        clk = 0; rst_n = 0; errs = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0; s_axi_wstrb = 4'hF;

        fixture_dir = "datasets/mnist/lenet_fixture";
        sample_name = "sample_00000_label_7";
        show_progress = 0;
        void'($value$plusargs("fixture_dir=%s", fixture_dir));
        void'($value$plusargs("sample_name=%s", sample_name));
        void'($value$plusargs("progress=%d", show_progress));
        sample_dir = {fixture_dir, "/", sample_name};
        weights_dir = {fixture_dir, "/weights"};

        path_input        = {sample_dir, "/input.memh"};
        path_conv1_w      = {weights_dir, "/conv1_weights.memh"};
        path_conv2_w      = {weights_dir, "/conv2_weights.memh"};
        path_fc1_w        = {weights_dir, "/fc1_weights.memh"};
        path_fc2_w        = {weights_dir, "/fc2_weights.memh"};
        path_conv1_g      = {sample_dir, "/conv1_out.memh"};
        path_pool1_g      = {sample_dir, "/pool1_out.memh"};
        path_conv2_input_g= {sample_dir, "/conv2_input.memh"};
        path_conv2_g      = {sample_dir, "/conv2_out.memh"};
        path_pool2_g      = {sample_dir, "/pool2_out.memh"};
        path_fc1_g        = {sample_dir, "/fc1_out.memh"};
        path_fc2_g        = {sample_dir, "/fc2_logits.memh"};
        path_argmax       = {sample_dir, "/argmax.txt"};

        #20 rst_n = 1; #20;

        load_memh_to_ram(path_input,   INPUT_ADDR,     196);
        load_memh_to_ram(path_conv1_w, CONV1_WGT_ADDR, 125);
        load_memh_to_ram(path_conv2_w, CONV2_WGT_ADDR, 6260);
        load_memh_to_ram(path_fc1_w,   FC1_WGT_ADDR,   100000);
        load_memh_to_ram(path_fc2_w,   FC2_WGT_ADDR,   1250);

        run_layer(2'd0, INPUT_ADDR, CONV1_WGT_ADDR, CONV1_OUT_ADDR, 784, 500, 24*24*20*4,
                  28, 28, 1, 20, 1'b0, 1'b0, 5000000, "Conv1");
        compare_region_memh(path_conv1_g, CONV1_OUT_ADDR, CONV1_OUT_WORDS, "Conv1 golden", errs);

        run_layer(2'd2, CONV1_OUT_ADDR, 32'h0, POOL1_OUT_ADDR, 24*24*20*4, 0, 12*12*20*4,
                  24, 24, 20, 20, 1'b0, 1'b1, 5000000, "Pool1");
        compare_region_memh(path_pool1_g, POOL1_OUT_ADDR, POOL1_OUT_WORDS, "Pool1 golden", errs);

        requantize_i32_to_i8_region(POOL1_OUT_ADDR, CONV2_IN_ADDR, POOL1_OUT_WORDS);
        compare_region_memh(path_conv2_input_g, CONV2_IN_ADDR, 720, "Pool1->Conv2 requant", errs);

        run_layer(2'd0, CONV2_IN_ADDR, CONV2_WGT_ADDR, CONV2_OUT_ADDR, 12*12*20, 25040, 8*8*50*4,
                  12, 12, 20, 50, 1'b0, 1'b0, 8000000, "Conv2");
        compare_region_memh(path_conv2_g, CONV2_OUT_ADDR, CONV2_OUT_WORDS, "Conv2 golden", errs);

        run_layer(2'd2, CONV2_OUT_ADDR, 32'h0, POOL2_OUT_ADDR, 8*8*50*4, 0, 4*4*50*4,
                  8, 8, 50, 50, 1'b0, 1'b1, 4000000, "Pool2");
        compare_region_memh(path_pool2_g, POOL2_OUT_ADDR, POOL2_OUT_WORDS, "Pool2 golden", errs);

        run_layer(2'd1, POOL2_OUT_ADDR, FC1_WGT_ADDR, FC1_OUT_ADDR, 3200, 400000, 2000,
                  1, 1, 800, 500, 1'b1, 1'b0, 12000000, "FC1");
        compare_region_memh(path_fc1_g, FC1_OUT_ADDR, FC1_OUT_WORDS, "FC1 golden", errs);

        run_layer(2'd1, FC1_OUT_ADDR, FC2_WGT_ADDR, FC2_OUT_ADDR, 2000, 5000, 40,
                  1, 1, 500, 10, 1'b0, 1'b0, 2000000, "FC2");
        compare_region_memh(path_fc2_g, FC2_OUT_ADDR, FC2_OUT_WORDS, "FC2 golden", errs);

        pred = argmax_region(FC2_OUT_ADDR, 10);
        expected_pred = read_argmax_file(path_argmax);
        $display("Predicted class=%0d expected=%0d", pred, expected_pred);
        if (pred != expected_pred) begin
            $display("  Argmax mismatch");
            errs = errs + 1;
        end

        if (errs != 0)
            $fatal(1, "LeNet network FAILED with %0d total mismatches", errs);
        else
            $display("LeNet network PASSED for %0s", sample_name);

        #20 $finish;
    end
endmodule
