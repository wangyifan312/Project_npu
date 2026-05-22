`timescale 1ns / 1ps

module tb_top_lenet;

    reg         clk;
    reg         rst_n;
    reg         tb_axil_enable;
    reg         tb_awvalid;
    wire        tb_awready;
    reg  [31:0] tb_awaddr;
    reg         tb_wvalid;
    wire        tb_wready;
    reg  [31:0] tb_wdata;
    reg  [3:0]  tb_wstrb;
    wire        tb_bvalid;
    reg         tb_bready;
    wire [1:0]  tb_bresp;
    reg         tb_arvalid;
    wire        tb_arready;
    reg  [31:0] tb_araddr;
    wire        tb_rvalid;
    reg         tb_rready;
    wire [31:0] tb_rdata;
    wire [1:0]  tb_rresp;
    wire        cpu_trap;
    wire [31:0] npu_status;

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
    localparam NPU_BASE       = 32'h1000_0000;
    localparam MAX_FILE_WORDS = 131072;
    localparam PERF_CYCLE_LO       = NPU_BASE + 32'h30;
    localparam PERF_CYCLE_HI       = NPU_BASE + 32'h34;
    localparam PERF_READ_BEATS     = NPU_BASE + 32'h38;
    localparam PERF_WRITE_BEATS    = NPU_BASE + 32'h3C;
    localparam PERF_READ_ACTIVE    = NPU_BASE + 32'h40;
    localparam PERF_WRITE_ACTIVE   = NPU_BASE + 32'h44;
    localparam PERF_ARRAY_ACTIVE   = NPU_BASE + 32'h48;
    localparam PERF_ARRAY_STALL    = NPU_BASE + 32'h4C;
    localparam PERF_MAC_LO         = NPU_BASE + 32'h50;
    localparam PERF_MAC_HI         = NPU_BASE + 32'h54;
    localparam PERF_CLUSTER_ACTIVE = NPU_BASE + 32'h58;
    localparam PERF_CLUSTER_STALL  = NPU_BASE + 32'h5C;
    localparam PERF_CLUSTER_CFG    = NPU_BASE + 32'h60;

    reg [31:0] file_words [0:MAX_FILE_WORDS-1];
    string fixture_dir, sample_name, sample_dir, weights_dir;
    string path_input, path_conv1_w, path_conv2_w, path_fc1_w, path_fc2_w;
    string path_conv1_g, path_pool1_g, path_conv2_input_g, path_conv2_g;
    string path_pool2_g, path_fc1_g, path_fc2_g, path_argmax;
    integer show_progress;

    top u_top (
        .clk(clk),
        .rst_n(rst_n),
        .tb_axil_enable(tb_axil_enable),
        .tb_awvalid(tb_awvalid),
        .tb_awready(tb_awready),
        .tb_awaddr(tb_awaddr),
        .tb_wvalid(tb_wvalid),
        .tb_wready(tb_wready),
        .tb_wdata(tb_wdata),
        .tb_wstrb(tb_wstrb),
        .tb_bvalid(tb_bvalid),
        .tb_bready(tb_bready),
        .tb_bresp(tb_bresp),
        .tb_arvalid(tb_arvalid),
        .tb_arready(tb_arready),
        .tb_araddr(tb_araddr),
        .tb_rvalid(tb_rvalid),
        .tb_rready(tb_rready),
        .tb_rdata(tb_rdata),
        .tb_rresp(tb_rresp),
        .cpu_trap(cpu_trap),
        .npu_status(npu_status)
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

    function [63:0] expected_mac_count;
        input [1:0] ttype;
        input [31:0] in_bytes;
        input [15:0] iw;
        input [15:0] ih;
        input [15:0] ic;
        input [15:0] oc;
        reg [63:0] conv_windows;
        begin
            if (ttype == 2'd0) begin
                conv_windows = ((ih >= 16'd5) && (iw >= 16'd5)) ? ((ih - 16'd4) * (iw - 16'd4)) : 64'd0;
                expected_mac_count = conv_windows * ic * oc * 64'd25;
            end else if (ttype == 2'd1) begin
                expected_mac_count = (in_bytes >> 2) * oc;
            end else begin
                expected_mac_count = 64'd0;
            end
        end
    endfunction

    task axil_write;
        input [31:0] addr;
        input [31:0] data;
        reg aw_done;
        reg w_done;
        begin
            aw_done = 1'b0;
            w_done = 1'b0;
            tb_awvalid <= 1'b1;
            tb_awaddr  <= addr;
            tb_wvalid  <= 1'b1;
            tb_wdata   <= data;
            tb_wstrb   <= 4'hF;
            while (!(aw_done && w_done)) begin
                @(posedge clk);
                if (tb_awvalid && tb_awready) begin
                    tb_awvalid <= 1'b0;
                    aw_done = 1'b1;
                end
                if (tb_wvalid && tb_wready) begin
                    tb_wvalid <= 1'b0;
                    w_done = 1'b1;
                end
            end
            tb_bready  <= 1'b1;
            wait (tb_bvalid);
            @(posedge clk);
            tb_bready  <= 1'b0;
        end
    endtask

    task axil_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            tb_arvalid <= 1'b1;
            tb_araddr  <= addr;
            @(posedge clk);
            while (!tb_arready)
                @(posedge clk);
            tb_arvalid <= 1'b0;
            tb_rready  <= 1'b1;
            wait (tb_rvalid);
            data = tb_rdata;
            @(posedge clk);
            tb_rready  <= 1'b0;
        end
    endtask

    task wait_done;
        input integer maxc;
        integer c;
        begin
            c = 0;
            while (!npu_status[2] && !npu_status[3] && c < maxc) begin
                @(posedge clk);
                c = c + 1;
                if (show_progress != 0 && (c % 1000) == 0)
                    $display("  progress cycles=%0d status=0x%08x fsm=%0d sub=%0d", c, npu_status, u_top.u_npu.fsm_state, u_top.u_npu.comp_sub_state);
            end
            if (npu_status[3])
                $fatal(1, "top_lenet NPU error");
            if (!npu_status[2])
                $fatal(1, "top_lenet timeout");
            while (npu_status[1] && c < maxc) begin
                @(posedge clk);
                c = c + 1;
            end
            if (npu_status[1])
                $fatal(1, "top_lenet busy stuck after done");
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
                u_top.u_shared_ram.ram[(base_addr >> 2) + i] = file_words[i];
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
                actual = u_top.u_shared_ram.ram[(base_addr >> 2) + i];
                if (actual !== file_words[i]) begin
                    local_errs = local_errs + 1;
                    if (local_errs <= 8)
                        $display("  %0s mismatch[%0d]: got %0d exp %0d", name, i, $signed(actual), $signed(file_words[i]));
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
                src_val = u_top.u_shared_ram.ram[(src_addr >> 2) + i];
                qv = sat_i8(src_val);
                byte_idx = i[1:0];
                pack_word[byte_idx*8 +: 8] = qv[7:0];
                if (byte_idx == 3) begin
                    u_top.u_shared_ram.ram[(dst_addr >> 2) + word_idx] = pack_word;
                    pack_word = 32'd0;
                    word_idx = word_idx + 1;
                end
            end
            if (elem_count % 4 != 0)
                u_top.u_shared_ram.ram[(dst_addr >> 2) + word_idx] = pack_word;
        end
    endtask

    task report_perf;
        input [127:0] layer_name;
        input [63:0] expected_mac;
        reg [31:0] cycle_lo;
        reg [31:0] cycle_hi;
        reg [31:0] read_beats;
        reg [31:0] write_beats;
        reg [31:0] read_active;
        reg [31:0] write_active;
        reg [31:0] array_active;
        reg [31:0] array_stall;
        reg [31:0] mac_lo;
        reg [31:0] mac_hi;
        reg [31:0] cluster_active;
        reg [31:0] cluster_stall;
        reg [31:0] cluster_cfg;
        real read_bw_util;
        real write_bw_util;
        real array_util;
        begin
            axil_read(PERF_CYCLE_LO, cycle_lo);
            axil_read(PERF_CYCLE_HI, cycle_hi);
            axil_read(PERF_READ_BEATS, read_beats);
            axil_read(PERF_WRITE_BEATS, write_beats);
            axil_read(PERF_READ_ACTIVE, read_active);
            axil_read(PERF_WRITE_ACTIVE, write_active);
            axil_read(PERF_ARRAY_ACTIVE, array_active);
            axil_read(PERF_ARRAY_STALL, array_stall);
            axil_read(PERF_MAC_LO, mac_lo);
            axil_read(PERF_MAC_HI, mac_hi);
            axil_read(PERF_CLUSTER_ACTIVE, cluster_active);
            axil_read(PERF_CLUSTER_STALL, cluster_stall);
            axil_read(PERF_CLUSTER_CFG, cluster_cfg);

            if ({mac_hi, mac_lo} !== expected_mac)
                $fatal(1, "%0s perf mac mismatch got 0x%08x_%08x expect 0x%08x_%08x",
                       layer_name, mac_hi, mac_lo, expected_mac[63:32], expected_mac[31:0]);
            if (cycle_lo == 32'd0)
                $fatal(1, "%0s perf cycles should be non-zero", layer_name);
            if (cluster_cfg[7:0] !== 8'h01)
                $fatal(1, "%0s cluster cfg mismatch: 0x%08x", layer_name, cluster_cfg);

            read_bw_util = (read_active != 0) ? (read_beats * 1.0 / read_active) : 0.0;
            write_bw_util = (write_active != 0) ? (write_beats * 1.0 / write_active) : 0.0;
            array_util = (cycle_lo != 0) ? (array_active * 1.0 / cycle_lo) : 0.0;

            $display("PERF %0s cycles=%0d read_beats=%0d write_beats=%0d read_bw_util=%0.4f write_bw_util=%0.4f array_active=%0d array_stall=%0d cluster_active=%0d cluster_stall=%0d mac=%0d cluster_cfg=0x%08x array_util=%0.4f",
                     layer_name, cycle_lo, read_beats, write_beats, read_bw_util, write_bw_util,
                     array_active, array_stall, cluster_active, cluster_stall, mac_lo, cluster_cfg, array_util);
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
        reg [63:0] expected_mac;
        begin
            $display("=== %0s ===", layer_name);
            if (npu_status[2] || npu_status[3])
                axil_write(NPU_BASE + 32'h00, 32'h10);
            repeat (2) @(posedge clk);
            axil_write(NPU_BASE + 32'h08, {30'd0, ttype});
            axil_write(NPU_BASE + 32'h0C, in_addr);
            axil_write(NPU_BASE + 32'h10, wgt_addr);
            axil_write(NPU_BASE + 32'h14, out_addr);
            axil_write(NPU_BASE + 32'h18, in_bytes);
            axil_write(NPU_BASE + 32'h1C, wgt_bytes);
            axil_write(NPU_BASE + 32'h20, out_bytes);
            axil_write(NPU_BASE + 32'h24, {iw[15:0], ih[15:0]});
            axil_write(NPU_BASE + 32'h28, {oc[15:0], ic[15:0]});
            axil_write(NPU_BASE + 32'h2C, {30'd0, pool, relu});
            axil_write(NPU_BASE + 32'h00, 32'h1);
            wait_done(maxc);
            expected_mac = expected_mac_count(ttype, in_bytes, iw, ih, ic, oc);
            report_perf(layer_name, expected_mac);
        end
    endtask

    integer errs;
    integer expected_class;
    integer pred_class;
    integer i;
    reg signed [31:0] best_val;
    reg [31:0] logits_word;
    reg [31:0] cpu_logits [0:9];

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        tb_axil_enable = 1'b1;
        tb_awvalid = 1'b0;
        tb_awaddr  = 32'h0;
        tb_wvalid  = 1'b0;
        tb_wdata   = 32'h0;
        tb_wstrb   = 4'h0;
        tb_bready  = 1'b0;
        tb_arvalid = 1'b0;
        tb_araddr  = 32'h0;
        tb_rready  = 1'b0;
        errs = 0;

        fixture_dir = "datasets/mnist/lenet_fixture";
        sample_name = "sample_00000_label_7";
        show_progress = 0;
        void'($value$plusargs("fixture_dir=%s", fixture_dir));
        void'($value$plusargs("sample_name=%s", sample_name));
        void'($value$plusargs("progress=%d", show_progress));

        sample_dir = {fixture_dir, "/", sample_name};
        weights_dir = {fixture_dir, "/weights"};
        path_input         = {sample_dir, "/input.memh"};
        path_conv1_w       = {weights_dir, "/conv1_weights.memh"};
        path_conv2_w       = {weights_dir, "/conv2_weights.memh"};
        path_fc1_w         = {weights_dir, "/fc1_weights.memh"};
        path_fc2_w         = {weights_dir, "/fc2_weights.memh"};
        path_conv1_g       = {sample_dir, "/conv1_out.memh"};
        path_pool1_g       = {sample_dir, "/pool1_out.memh"};
        path_conv2_input_g = {sample_dir, "/conv2_input.memh"};
        path_conv2_g       = {sample_dir, "/conv2_out.memh"};
        path_pool2_g       = {sample_dir, "/pool2_out.memh"};
        path_fc1_g         = {sample_dir, "/fc1_out.memh"};
        path_fc2_g         = {sample_dir, "/fc2_logits.memh"};
        path_argmax        = {sample_dir, "/argmax.txt"};

        #20 rst_n = 1'b1;
        #20;

        load_memh_to_ram(path_input, INPUT_ADDR, 196);
        load_memh_to_ram(path_conv1_w, CONV1_WGT_ADDR, 125);
        load_memh_to_ram(path_conv2_w, CONV2_WGT_ADDR, 12500);
        load_memh_to_ram(path_fc1_w, FC1_WGT_ADDR, 100000);
        load_memh_to_ram(path_fc2_w, FC2_WGT_ADDR, 1250);

        run_layer(2'd0, INPUT_ADDR, CONV1_WGT_ADDR, CONV1_OUT_ADDR, 32'd784, 32'd500, 32'd46080, 16'd28, 16'd28, 16'd1, 16'd20, 1'b0, 1'b0, 3000000, "Conv1");
        compare_region_memh(path_conv1_g, CONV1_OUT_ADDR, 24*24*20, "Conv1 golden", errs);

        run_layer(2'd2, CONV1_OUT_ADDR, 32'h0, POOL1_OUT_ADDR, 32'd46080, 32'd0, 32'd11520, 16'd24, 16'd24, 16'd20, 16'd20, 1'b0, 1'b1, 1000000, "Pool1");
        compare_region_memh(path_pool1_g, POOL1_OUT_ADDR, 12*12*20, "Pool1 golden", errs);

        requantize_i32_to_i8_region(POOL1_OUT_ADDR, CONV2_IN_ADDR, 12*12*20);
        compare_region_memh(path_conv2_input_g, CONV2_IN_ADDR, (12*12*20 + 3) / 4, "Pool1->Conv2 requant", errs);

        run_layer(2'd0, CONV2_IN_ADDR, CONV2_WGT_ADDR, CONV2_OUT_ADDR, 32'd2880, 32'd25000, 32'd12800, 16'd12, 16'd12, 16'd20, 16'd50, 1'b0, 1'b0, 6000000, "Conv2");
        compare_region_memh(path_conv2_g, CONV2_OUT_ADDR, 8*8*50, "Conv2 golden", errs);

        run_layer(2'd2, CONV2_OUT_ADDR, 32'h0, POOL2_OUT_ADDR, 32'd12800, 32'd0, 32'd3200, 16'd8, 16'd8, 16'd50, 16'd50, 1'b0, 1'b1, 1000000, "Pool2");
        compare_region_memh(path_pool2_g, POOL2_OUT_ADDR, 4*4*50, "Pool2 golden", errs);

        run_layer(2'd1, POOL2_OUT_ADDR, FC1_WGT_ADDR, FC1_OUT_ADDR, 32'd3200, 32'd400000, 32'd2000, 16'd1, 16'd1, 16'd800, 16'd500, 1'b1, 1'b0, 10000000, "FC1");
        compare_region_memh(path_fc1_g, FC1_OUT_ADDR, 500, "FC1 golden", errs);

        run_layer(2'd1, FC1_OUT_ADDR, FC2_WGT_ADDR, FC2_OUT_ADDR, 32'd2000, 32'd5000, 32'd40, 16'd1, 16'd1, 16'd500, 16'd10, 1'b0, 1'b0, 3000000, "FC2");
        compare_region_memh(path_fc2_g, FC2_OUT_ADDR, 10, "FC2 golden", errs);

        expected_class = read_argmax_file(path_argmax);
        pred_class = 0;
        best_val = -32'sd2147483648;
        for (i = 0; i < 10; i = i + 1) begin
            axil_read(FC2_OUT_ADDR + i*4, logits_word);
            cpu_logits[i] = logits_word;
            if ($signed(logits_word) > best_val) begin
                best_val = $signed(logits_word);
                pred_class = i;
            end
        end

        $display("Predicted class=%0d expected=%0d", pred_class, expected_class);
        if (pred_class != expected_class) begin
            errs = errs + 1;
            $display("Classification mismatch");
        end

        if (errs != 0)
            $fatal(1, "tb_top_lenet FAILED with %0d mismatches", errs);

        $display("tb_top_lenet PASS for %0s", sample_name);
        $finish;
    end

endmodule
