// tb_lenet_network: full LeNet(MNIST) network-level integration test
`timescale 1ns / 1ps

module tb_lenet_network;
    reg clk, rst_n;
    reg s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    reg s_axi_arvalid, s_axi_rready;
    reg [31:0] s_axi_awaddr, s_axi_wdata;
    reg [31:0] s_axi_araddr;
    reg [3:0] s_axi_wstrb;

    wire s_axi_awready, s_axi_wready, s_axi_bvalid;
    wire s_axi_arready, s_axi_rvalid;
    wire [1:0] s_axi_bresp;
    wire [31:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire npu_busy, npu_done, npu_error;
    wire [7:0] npu_error_code;
    wire npu_arvalid, npu_awvalid, npu_wvalid, npu_wlast;
    wire [31:0] npu_araddr, npu_awaddr;
    wire [255:0] npu_wdata;
    wire [7:0] npu_arlen, npu_awlen;
    wire [2:0] npu_arsize, npu_awsize;
    wire [1:0] npu_arburst, npu_awburst;
    wire [31:0] npu_wstrb;
    wire npu_rready, npu_bready;
    wire ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0] ram_bresp, ram_rresp;
    wire ram_rvalid, ram_rlast;
    wire [255:0] ram_rdata;

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
    localparam REQUANT_SEL         = NPU_BASE + 32'h64;
    localparam REQUANT0_MULT       = NPU_BASE + 32'h68;
    localparam REQUANT0_SHIFT      = NPU_BASE + 32'h6C;
    localparam REQUANT1_MULT       = NPU_BASE + 32'h70;
    localparam REQUANT1_SHIFT      = NPU_BASE + 32'h74;
    localparam REQUANT2_MULT       = NPU_BASE + 32'h78;
    localparam REQUANT2_SHIFT      = NPU_BASE + 32'h7C;

    localparam CONV1_OUT_WORDS = 24*24*20;
    localparam POOL1_OUT_WORDS = 12*12*20;
    localparam CONV2_OUT_WORDS = 8*8*50;
    localparam POOL2_OUT_WORDS = 4*4*50;
    localparam FC1_OUT_WORDS   = 500;
    localparam FC2_OUT_WORDS   = 10;
    localparam MAX_FILE_WORDS  = 131072;

    reg [31:0] file_words [0:MAX_FILE_WORDS-1];
    string fixture_dir, sample_name, sample_dir, weights_dir, sample_root_dir, weights_root_dir;
    string path_input, path_conv1_w, path_conv2_w, path_fc1_w, path_fc2_w;
    string path_conv1_g, path_pool1_g, path_conv2_input_g, path_conv2_g;
    string path_pool2_g, path_fc1_g, path_fc2_g, path_expected, stop_after_layer;
    string input_memh_name, expected_file_name;
    integer show_progress, eval_mode, sample_ordinal, verbose_limit, verbose_this_sample, skip_perf_reads;
    integer rq_conv2_mult, rq_conv2_shift;
    integer rq_fc1_mult, rq_fc1_shift;
    integer rq_fc2_mult, rq_fc2_shift;
    integer errs, pred, expected_pred;
    reg [63:0] sample_total_cycles, sample_total_mac;
    reg [63:0] sample_total_read_beats, sample_total_write_beats;
    reg [63:0] sample_total_read_active, sample_total_write_active;
    reg [63:0] sample_total_array_active, sample_total_array_stall;
    reg [63:0] sample_total_cluster_active, sample_total_cluster_stall;

    npu_top #(.TILE_ROWS(16), .TILE_COLS(16), .BUF_ENTRIES(16384), .BUF_ADDR_W(14)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready), .s_axi_araddr(s_axi_araddr),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
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

    // Formal HB data plane RAM model: 1 MB = 32768 x 256-bit beats.
    axi4_ram #(.RAM_DEPTH(32768)) u_ram (
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

    function integer read_int_file;
        input string path;
        integer fd, value;
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("ERROR: failed to open %0s", path);
                read_int_file = -1;
            end else begin
                value = -1;
                if ($fscanf(fd, "%d", value) != 1)
                    value = -1;
                $fclose(fd);
                read_int_file = value;
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
                expected_mac_count = in_bytes * oc;
            end else begin
                expected_mac_count = 64'd0;
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

    task program_requant_slots;
        begin
            axi_write(REQUANT0_MULT, rq_conv2_mult[31:0]);
            axi_write(REQUANT0_SHIFT, rq_conv2_shift[31:0]);
            axi_write(REQUANT1_MULT, rq_fc1_mult[31:0]);
            axi_write(REQUANT1_SHIFT, rq_fc1_shift[31:0]);
            axi_write(REQUANT2_MULT, rq_fc2_mult[31:0]);
            axi_write(REQUANT2_SHIFT, rq_fc2_shift[31:0]);
        end
    endtask

    task axi_read;
        input  [31:0] addr;
        output [31:0] data;
        integer guard;
        begin
            s_axi_arvalid = 1'b0;
            s_axi_rready  = 1'b1;
            repeat (2) @(posedge clk);
            s_axi_rready  = 1'b0;

            s_axi_arvalid = 1'b1;
            s_axi_araddr  = addr;
            guard = 0;
            @(posedge clk);
            while (!s_axi_arready && !s_axi_rvalid) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 1000)
                    $fatal(1, "AXI read address timeout addr=0x%08x arready=%b arvalid=%b rready=%b",
                           addr, s_axi_arready, s_axi_arvalid, s_axi_rready);
            end
            s_axi_arvalid = 1'b0;
            guard = 0;
            while (!s_axi_rvalid) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 1000)
                    $fatal(1, "AXI read data timeout addr=0x%08x arready=%b arvalid=%b rready=%b",
                           addr, s_axi_arready, s_axi_arvalid, s_axi_rready);
            end
            data = s_axi_rdata;
            s_axi_rready  = 1'b1;
            @(posedge clk);
            s_axi_rready  = 1'b0;
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
                ram_write_word(base_addr + (i * 4), file_words[i]);
        end
    endtask

    task ram_write_word;
        input [31:0] byte_addr;
        input [31:0] data;
        integer beat_idx;
        integer word_idx;
        begin
            // Hierarchical preload uses the same 256-bit beat address split as shared_ram:
            // beat_addr=addr[19:5], word_in_beat=addr[4:2].
            beat_idx = byte_addr[19:5];
            word_idx = byte_addr[4:2];
            u_ram.ram[beat_idx][word_idx*32 +: 32] = data;
        end
    endtask

    function [31:0] ram_read_word;
        input [31:0] byte_addr;
        integer beat_idx;
        integer word_idx;
        begin
            // Hierarchical readback mirrors the formal 256-bit beat organization.
            beat_idx = byte_addr[19:5];
            word_idx = byte_addr[4:2];
            ram_read_word = u_ram.ram[beat_idx][word_idx*32 +: 32];
        end
    endfunction

    function [7:0] file_memh_byte;
        input integer byte_idx;
        integer word_idx;
        integer byte_in_word;
        begin
            word_idx = byte_idx >> 2;
            byte_in_word = byte_idx & 3;
            file_memh_byte = file_words[word_idx][byte_in_word*8 +: 8];
        end
    endfunction

    function [7:0] act_buffer_byte;
        input integer byte_idx;
        integer beat_idx;
        integer byte_in_beat;
        reg [255:0] beat_data;
        begin
            beat_idx = byte_idx >> 5;
            byte_in_beat = byte_idx & 31;
            if (u_npu.act_comp_bank == 1'b0)
                beat_data = u_npu.u_act_buffer.bank_a[beat_idx];
            else
                beat_data = u_npu.u_act_buffer.bank_b[beat_idx];
            act_buffer_byte = beat_data[byte_in_beat*8 +: 8];
        end
    endfunction

    function [7:0] wgt_buffer_byte;
        input integer byte_idx;
        integer beat_idx;
        integer byte_in_beat;
        reg [255:0] beat_data;
        begin
            beat_idx = byte_idx >> 5;
            byte_in_beat = byte_idx & 31;
            if (u_npu.wgt_load_bank == 1'b0)
                beat_data = u_npu.u_wgt_buffer.bank_a[beat_idx];
            else
                beat_data = u_npu.u_wgt_buffer.bank_b[beat_idx];
            wgt_buffer_byte = beat_data[byte_in_beat*8 +: 8];
        end
    endfunction

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
                actual = ram_read_word(base_addr + (i * 4));
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

    task compare_act_buffer_memh;
        input string path;
        input integer word_count;
        input [127:0] name;
        inout integer total_errs;
        integer i, local_errs;
        integer byte_count;
        reg [7:0] actual, expected;
        begin
            local_errs = 0;
            byte_count = word_count * 4;
            $readmemh(path, file_words);
            for (i = 0; i < byte_count; i = i + 1) begin
                actual = act_buffer_byte(i);
                expected = file_memh_byte(i);
                if (actual !== expected) begin
                    local_errs = local_errs + 1;
                    if (local_errs <= 8)
                        $display("  %0s byte mismatch[%0d]: got 0x%02x exp 0x%02x",
                                 name, i, actual, expected);
                end
            end
            if (local_errs == 0)
                $display("  %0s PASS", name);
            else
                $display("  %0s FAIL: %0d mismatches", name, local_errs);
            total_errs = total_errs + local_errs;
        end
    endtask

    task compare_wgt_buffer_memh_slice;
        input string path;
        input integer word_offset;
        input integer word_count;
        input [127:0] name;
        inout integer total_errs;
        integer i, local_errs;
        integer start_byte;
        integer byte_count;
        reg [7:0] actual, expected;
        begin
            local_errs = 0;
            start_byte = word_offset * 4;
            byte_count = word_count * 4;
            $readmemh(path, file_words);
            for (i = 0; i < byte_count; i = i + 1) begin
                actual = wgt_buffer_byte(i);
                expected = file_memh_byte(start_byte + i);
                if (actual !== expected) begin
                    local_errs = local_errs + 1;
                    if (local_errs <= 8)
                        $display("  %0s byte mismatch[%0d]: got 0x%02x exp 0x%02x",
                                 name, i, actual, expected);
                end
            end
            if (local_errs == 0)
                $display("  %0s PASS", name);
            else
                $display("  %0s FAIL: %0d mismatches", name, local_errs);
            total_errs = total_errs + local_errs;
        end
    endtask

    task report_perf;
        input [127:0] layer_name;
        input [63:0] expected_mac;
        reg [31:0] cycle_lo, cycle_hi;
        reg [31:0] read_beats, write_beats;
        reg [31:0] read_active, write_active;
        reg [31:0] array_active, array_stall;
        reg [31:0] mac_lo, mac_hi;
        reg [31:0] cluster_active, cluster_stall;
        reg [31:0] cluster_cfg;
        real read_bw_util;
        real write_bw_util;
        real array_util;
        begin
            axi_read(PERF_CYCLE_LO, cycle_lo);
            axi_read(PERF_CYCLE_HI, cycle_hi);
            axi_read(PERF_READ_BEATS, read_beats);
            axi_read(PERF_WRITE_BEATS, write_beats);
            axi_read(PERF_READ_ACTIVE, read_active);
            axi_read(PERF_WRITE_ACTIVE, write_active);
            axi_read(PERF_ARRAY_ACTIVE, array_active);
            axi_read(PERF_ARRAY_STALL, array_stall);
            axi_read(PERF_MAC_LO, mac_lo);
            axi_read(PERF_MAC_HI, mac_hi);
            axi_read(PERF_CLUSTER_ACTIVE, cluster_active);
            axi_read(PERF_CLUSTER_STALL, cluster_stall);
            axi_read(PERF_CLUSTER_CFG, cluster_cfg);

            if ({mac_hi, mac_lo} !== expected_mac)
                $fatal(1, "%0s perf mac mismatch got 0x%08x_%08x expect 0x%08x_%08x",
                       layer_name, mac_hi, mac_lo, expected_mac[63:32], expected_mac[31:0]);
            if (cycle_lo == 32'd0)
                $fatal(1, "%0s perf cycles should be non-zero", layer_name);
            if (cluster_cfg[7:0] !== 8'h01)
                $fatal(1, "%0s cluster cfg mismatch: 0x%08x", layer_name, cluster_cfg);

            sample_total_cycles         = sample_total_cycles + {cycle_hi, cycle_lo};
            sample_total_mac            = sample_total_mac + {mac_hi, mac_lo};
            sample_total_read_beats     = sample_total_read_beats + read_beats;
            sample_total_write_beats    = sample_total_write_beats + write_beats;
            sample_total_read_active    = sample_total_read_active + read_active;
            sample_total_write_active   = sample_total_write_active + write_active;
            sample_total_array_active   = sample_total_array_active + array_active;
            sample_total_array_stall    = sample_total_array_stall + array_stall;
            sample_total_cluster_active = sample_total_cluster_active + cluster_active;
            sample_total_cluster_stall  = sample_total_cluster_stall + cluster_stall;

            if (verbose_this_sample != 0) begin
                read_bw_util = (read_active != 0) ? (read_beats * 1.0 / read_active) : 0.0;
                write_bw_util = (write_active != 0) ? (write_beats * 1.0 / write_active) : 0.0;
                array_util = (cycle_lo != 0) ? (array_active * 1.0 / cycle_lo) : 0.0;
                $display("PERF %0s cycles=%0d read_beats=%0d write_beats=%0d read_bw_util=%0.4f write_bw_util=%0.4f array_active=%0d array_stall=%0d cluster_active=%0d cluster_stall=%0d mac=%0d cluster_cfg=0x%08x array_util=%0.4f",
                         layer_name, cycle_lo, read_beats, write_beats, read_bw_util, write_bw_util,
                         array_active, array_stall, cluster_active, cluster_stall, mac_lo, cluster_cfg, array_util);
            end
        end
    endtask

    task requantize_i32_to_i8_region;
        input [31:0] src_addr;
        input [31:0] dst_addr;
        input integer elem_count;
        input [1:0] slot_sel;
        input integer multiplier;
        input integer shift;
        integer rq_cycles;
        begin
            axi_write(REQUANT_SEL, {30'd0, slot_sel});
            case (slot_sel)
                2'd0: begin
                    axi_write(REQUANT0_MULT, multiplier[31:0]);
                    axi_write(REQUANT0_SHIFT, shift[31:0]);
                end
                2'd1: begin
                    axi_write(REQUANT1_MULT, multiplier[31:0]);
                    axi_write(REQUANT1_SHIFT, shift[31:0]);
                end
                default: begin
                    axi_write(REQUANT2_MULT, multiplier[31:0]);
                    axi_write(REQUANT2_SHIFT, shift[31:0]);
                end
            endcase
            run_layer(2'd3, src_addr, 32'h0, dst_addr, elem_count * 4, 0, elem_count,
                      1, 1, 1, 1, 1'b0, 1'b0, 3000000, "Requant");
        end
    endtask

    task maybe_stop_after_layer;
        input string layer_key;
        begin
            if ((stop_after_layer != "") && (stop_after_layer == layer_key)) begin
                $display("STOP_AFTER sample=%0s layer=%0s total_cycles=%0d total_mac=%0d total_read_beats=%0d total_write_beats=%0d total_array_active=%0d total_array_stall=%0d total_cluster_active=%0d total_cluster_stall=%0d",
                         sample_name, layer_key,
                         sample_total_cycles, sample_total_mac, sample_total_read_beats, sample_total_write_beats,
                         sample_total_array_active, sample_total_array_stall, sample_total_cluster_active, sample_total_cluster_stall);
                #20 $finish;
            end
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
        integer done_cycle;
        integer busy_clear_cycle;
        integer conv2_act_debug_done;
        integer conv2_wgt_debug_done;
        reg [63:0] expected_mac;
        begin
            if (verbose_this_sample != 0)
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
            done_cycle = -1;
            busy_clear_cycle = -1;
            conv2_act_debug_done = 0;
            conv2_wgt_debug_done = 0;
            while (!npu_done && !npu_error && c < maxc) begin
                @(posedge clk);
                c = c + 1;
                if (!eval_mode && (ttype == 2'd0) && (iw == 16'd12) && (ih == 16'd12) && (ic == 16'd20) && (oc == 16'd50)) begin
                    if (!conv2_act_debug_done && (u_npu.fsm_state == 5'd2)) begin
                        $display("  Conv2 debug bytes: blk_in_bytes=%0d act_dma_bytes=%0d blk_input_rows=%0d blk_output_rows=%0d",
                                 u_npu.blk_in_bytes, u_npu.act_dma_bytes, u_npu.blk_in_rows, u_npu.blk_out_rows);
                        compare_act_buffer_memh(path_conv2_input_g, 720, "Conv2 act_buffer", errs);
                        conv2_act_debug_done = 1;
                    end
                    if (!conv2_wgt_debug_done && (u_npu.fsm_state == 5'd8)) begin
                        $display("  Conv2 debug weights: blk_wgt_per_cin=%0d wgt_per_cin=%0d wgt_dma_bytes=%0d cin_idx=%0d",
                                 u_npu.blk_wgt_per_cin, u_npu.wgt_per_cin, u_npu.wgt_dma_bytes, u_npu.cin_idx);
                        compare_wgt_buffer_memh_slice(path_conv2_w, 0, 313, "Conv2 wgt_buffer cin0", errs);
                        conv2_wgt_debug_done = 1;
                    end
                end
                if (show_progress != 0 && (c % 1000) == 0) begin
                    $display("  %0s progress: cycles=%0d fsm=%0d sub=%0d block_row=%0d cin=%0d win=%0d feed=%0d dma_ptr=%0d dma_state=%0d awv=%0b awr=%0b wv=%0b wr=%0b bv=%0b br=%0b",
                             layer_name, c, u_npu.fsm_state, u_npu.comp_sub_state,
                             u_npu.u_block_sched.curr_out_row, u_npu.cin_idx,
                             u_npu.comp_win_idx, u_npu.act_feed_done_cnt,
                             u_npu.dma_rd_ptr, u_npu.u_dma_writer.state,
                             u_npu.m_axi_awvalid, u_npu.m_axi_awready,
                             u_npu.m_axi_wvalid, u_npu.m_axi_wready,
                             u_npu.m_axi_bvalid, u_npu.m_axi_bready);
                end
            end
            if (npu_error)
                $fatal(1, "%0s NPU error code=0x%02h", layer_name, npu_error_code);
            if (!npu_done)
                $fatal(1, "%0s TIMEOUT", layer_name);
            done_cycle = c;
            while (npu_busy && c < maxc) begin
                @(posedge clk);
                c = c + 1;
            end
            if (npu_busy)
                $fatal(1, "%0s BUSY-STUCK after done", layer_name);
            busy_clear_cycle = c;
            if (verbose_this_sample != 0)
                $display("LAYER_PHASE layer=%0s done_cycle=%0d busy_clear_cycle=%0d post_done_cycles=%0d",
                         layer_name, done_cycle, busy_clear_cycle, busy_clear_cycle - done_cycle);
            repeat (4) @(posedge clk);
            expected_mac = expected_mac_count(ttype, in_bytes, iw, ih, ic, oc);
            if (!skip_perf_reads) begin
                report_perf(layer_name, expected_mac);
            end else begin
                sample_total_cycles = sample_total_cycles + busy_clear_cycle;
                sample_total_mac = sample_total_mac + expected_mac;
            end
        end
    endtask

    function integer argmax_region;
        input [31:0] base_addr;
        input integer count;
        integer i, best_i;
        reg signed [31:0] best_v, cur_v;
        begin
            best_i = 0;
            best_v = ram_read_word(base_addr);
            for (i = 1; i < count; i = i + 1) begin
                cur_v = ram_read_word(base_addr + (i * 4));
                if (cur_v > best_v) begin
                    best_v = cur_v;
                    best_i = i;
                end
            end
            argmax_region = best_i;
        end
    endfunction

    initial begin
        clk = 0; rst_n = 0; errs = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0; s_axi_wstrb = 4'hF;
        s_axi_arvalid = 0; s_axi_rready = 0; s_axi_araddr = 32'h0;
        sample_total_cycles = 64'd0;
        sample_total_mac = 64'd0;
        sample_total_read_beats = 64'd0;
        sample_total_write_beats = 64'd0;
        sample_total_read_active = 64'd0;
        sample_total_write_active = 64'd0;
        sample_total_array_active = 64'd0;
        sample_total_array_stall = 64'd0;
        sample_total_cluster_active = 64'd0;
        sample_total_cluster_stall = 64'd0;

        fixture_dir = "datasets/mnist/lenet_fixture";
        sample_name = "sample_00000_label_7";
        sample_root_dir = "";
        weights_root_dir = "";
        input_memh_name = "input.memh";
        expected_file_name = "argmax.txt";
        stop_after_layer = "";
        show_progress = 0;
        eval_mode = 0;
        sample_ordinal = 0;
        verbose_limit = 16;
        skip_perf_reads = 0;
        rq_conv2_mult = 1;
        rq_conv2_shift = 0;
        rq_fc1_mult = 1;
        rq_fc1_shift = 0;
        rq_fc2_mult = 1;
        rq_fc2_shift = 0;
        void'($value$plusargs("fixture_dir=%s", fixture_dir));
        void'($value$plusargs("sample_name=%s", sample_name));
        void'($value$plusargs("sample_root_dir=%s", sample_root_dir));
        void'($value$plusargs("weights_root_dir=%s", weights_root_dir));
        void'($value$plusargs("input_memh_name=%s", input_memh_name));
        void'($value$plusargs("expected_file_name=%s", expected_file_name));
        void'($value$plusargs("stop_after_layer=%s", stop_after_layer));
        void'($value$plusargs("progress=%d", show_progress));
        void'($value$plusargs("eval_mode=%d", eval_mode));
        void'($value$plusargs("sample_ordinal=%d", sample_ordinal));
        void'($value$plusargs("verbose_limit=%d", verbose_limit));
        void'($value$plusargs("skip_perf_reads=%d", skip_perf_reads));
        void'($value$plusargs("rq_conv2_mult=%d", rq_conv2_mult));
        void'($value$plusargs("rq_conv2_shift=%d", rq_conv2_shift));
        void'($value$plusargs("rq_fc1_mult=%d", rq_fc1_mult));
        void'($value$plusargs("rq_fc1_shift=%d", rq_fc1_shift));
        void'($value$plusargs("rq_fc2_mult=%d", rq_fc2_mult));
        void'($value$plusargs("rq_fc2_shift=%d", rq_fc2_shift));
        if (sample_root_dir == "")
            sample_root_dir = fixture_dir;
        if (weights_root_dir == "")
            weights_root_dir = {fixture_dir, "/weights"};
        verbose_this_sample = (!eval_mode) || (sample_ordinal < verbose_limit);

        sample_dir = {sample_root_dir, "/", sample_name};
        weights_dir = weights_root_dir;

        path_input        = {sample_dir, "/", input_memh_name};
        path_conv1_w      = {weights_dir, "/conv1_weights.memh"};
        path_conv2_w      = {weights_dir, "/conv2_weights.memh"};
        path_fc1_w        = {weights_dir, "/fc1_weights.memh"};
        path_fc2_w        = {weights_dir, "/fc2_weights.memh"};
        path_conv1_g      = {fixture_dir, "/", sample_name, "/conv1_out.memh"};
        path_pool1_g      = {fixture_dir, "/", sample_name, "/pool1_out.memh"};
        path_conv2_input_g= {fixture_dir, "/", sample_name, "/conv2_input.memh"};
        path_conv2_g      = {fixture_dir, "/", sample_name, "/conv2_out.memh"};
        path_pool2_g      = {fixture_dir, "/", sample_name, "/pool2_out.memh"};
        path_fc1_g        = {fixture_dir, "/", sample_name, "/fc1_out.memh"};
        path_fc2_g        = {fixture_dir, "/", sample_name, "/fc2_logits.memh"};
        path_expected     = {sample_dir, "/", expected_file_name};

        #20 rst_n = 1; #20;

        load_memh_to_ram(path_input,   INPUT_ADDR,     196);
        load_memh_to_ram(path_conv1_w, CONV1_WGT_ADDR, 125);
        load_memh_to_ram(path_conv2_w, CONV2_WGT_ADDR, 6260);
        load_memh_to_ram(path_fc1_w,   FC1_WGT_ADDR,   100000);
        load_memh_to_ram(path_fc2_w,   FC2_WGT_ADDR,   1250);
        program_requant_slots();

        run_layer(2'd0, INPUT_ADDR, CONV1_WGT_ADDR, CONV1_OUT_ADDR, 784, 500, 24*24*20*4,
                  28, 28, 1, 20, 1'b0, 1'b0, 5000000, "Conv1");
        if (!eval_mode)
            compare_region_memh(path_conv1_g, CONV1_OUT_ADDR, CONV1_OUT_WORDS, "Conv1 golden", errs);
        maybe_stop_after_layer("conv1");

        run_layer(2'd2, CONV1_OUT_ADDR, 32'h0, POOL1_OUT_ADDR, 24*24*20*4, 0, 12*12*20*4,
                  24, 24, 20, 20, 1'b0, 1'b1, 5000000, "Pool1");
        if (!eval_mode)
            compare_region_memh(path_pool1_g, POOL1_OUT_ADDR, POOL1_OUT_WORDS, "Pool1 golden", errs);
        maybe_stop_after_layer("pool1");

        requantize_i32_to_i8_region(POOL1_OUT_ADDR, CONV2_IN_ADDR, POOL1_OUT_WORDS, 2'd0, rq_conv2_mult, rq_conv2_shift);
        if (!eval_mode)
            compare_region_memh(path_conv2_input_g, CONV2_IN_ADDR, 720, "Pool1->Conv2 requant", errs);

        run_layer(2'd0, CONV2_IN_ADDR, CONV2_WGT_ADDR, CONV2_OUT_ADDR, 12*12*20, 25040, 8*8*50*4,
                  12, 12, 20, 50, 1'b0, 1'b0, 8000000, "Conv2");
        if (!eval_mode)
            compare_region_memh(path_conv2_g, CONV2_OUT_ADDR, CONV2_OUT_WORDS, "Conv2 golden", errs);
        maybe_stop_after_layer("conv2");

        run_layer(2'd2, CONV2_OUT_ADDR, 32'h0, POOL2_OUT_ADDR, 8*8*50*4, 0, 4*4*50*4,
                  8, 8, 50, 50, 1'b0, 1'b1, 4000000, "Pool2");
        if (!eval_mode)
            compare_region_memh(path_pool2_g, POOL2_OUT_ADDR, POOL2_OUT_WORDS, "Pool2 golden", errs);
        maybe_stop_after_layer("pool2");

        requantize_i32_to_i8_region(POOL2_OUT_ADDR, POOL2_OUT_ADDR, POOL2_OUT_WORDS, 2'd1, rq_fc1_mult, rq_fc1_shift);

        run_layer(2'd1, POOL2_OUT_ADDR, FC1_WGT_ADDR, FC1_OUT_ADDR, 800, 400000, 2000,
                  1, 1, 800, 500, 1'b1, 1'b0, 12000000, "FC1");
        if (!eval_mode)
            compare_region_memh(path_fc1_g, FC1_OUT_ADDR, FC1_OUT_WORDS, "FC1 golden", errs);
        maybe_stop_after_layer("fc1");

        requantize_i32_to_i8_region(FC1_OUT_ADDR, FC1_OUT_ADDR, FC1_OUT_WORDS, 2'd2, rq_fc2_mult, rq_fc2_shift);

        run_layer(2'd1, FC1_OUT_ADDR, FC2_WGT_ADDR, FC2_OUT_ADDR, 500, 5000, 40,
                  1, 1, 500, 10, 1'b0, 1'b0, 2000000, "FC2");
        if (!eval_mode)
            compare_region_memh(path_fc2_g, FC2_OUT_ADDR, FC2_OUT_WORDS, "FC2 golden", errs);
        maybe_stop_after_layer("fc2");

        pred = argmax_region(FC2_OUT_ADDR, 10);
        expected_pred = read_int_file(path_expected);
        if (verbose_this_sample != 0)
            $display("Predicted class=%0d expected=%0d", pred, expected_pred);
        if (pred != expected_pred) begin
            if (verbose_this_sample != 0)
                $display("  Argmax mismatch");
            errs = errs + 1;
        end

        if (errs != 0) begin
            $display("SUBSYS_RESULT sample=%0s predicted=%0d expected=%0d status=FAIL total_cycles=%0d total_mac=%0d total_read_beats=%0d total_write_beats=%0d total_read_active=%0d total_write_active=%0d total_array_active=%0d total_array_stall=%0d total_cluster_active=%0d total_cluster_stall=%0d",
                     sample_name, pred, expected_pred,
                     sample_total_cycles, sample_total_mac, sample_total_read_beats, sample_total_write_beats,
                     sample_total_read_active, sample_total_write_active,
                     sample_total_array_active, sample_total_array_stall, sample_total_cluster_active, sample_total_cluster_stall);
            $fatal(1, "LeNet network FAILED with %0d total mismatches", errs);
        end else begin
            $display("SUBSYS_RESULT sample=%0s predicted=%0d expected=%0d status=PASS total_cycles=%0d total_mac=%0d total_read_beats=%0d total_write_beats=%0d total_read_active=%0d total_write_active=%0d total_array_active=%0d total_array_stall=%0d total_cluster_active=%0d total_cluster_stall=%0d",
                     sample_name, pred, expected_pred,
                     sample_total_cycles, sample_total_mac, sample_total_read_beats, sample_total_write_beats,
                     sample_total_read_active, sample_total_write_active,
                     sample_total_array_active, sample_total_array_stall, sample_total_cluster_active, sample_total_cluster_stall);
            $display("LeNet network PASSED for %0s", sample_name);
        end

        #20 $finish;
    end
endmodule
