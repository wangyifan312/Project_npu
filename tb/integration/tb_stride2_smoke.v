// tb_stride2_smoke: minimal 3x3 stride2 same-padding smoke test
// 16 input channels x 32x32 -> 16 output channels x 16x16
// Uses MODE_SINGLE (1 cluster) to isolate conv_frontend stride2 path.
`timescale 1ns / 1ps

module tb_stride2_smoke;
    reg clk;
    reg rst_n;

    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg  [31:0] s_axi_awaddr;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    wire        s_axi_bvalid;
    reg         s_axi_bready;
    wire [1:0]  s_axi_bresp;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    reg  [31:0] s_axi_araddr;
    wire        s_axi_rvalid;
    reg         s_axi_rready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;

    wire        npu_arvalid;
    wire        npu_arready;
    wire [31:0] npu_araddr;
    wire [7:0]  npu_arlen;
    wire [2:0]  npu_arsize;
    wire [1:0]  npu_arburst;
    wire        npu_rvalid;
    wire        npu_rready;
    wire [255:0] npu_rdata;
    wire        npu_rlast;
    wire [1:0]  npu_rresp;
    wire        npu_awvalid;
    wire        npu_awready;
    wire [31:0] npu_awaddr;
    wire [7:0]  npu_awlen;
    wire [2:0]  npu_awsize;
    wire [1:0]  npu_awburst;
    wire        npu_wvalid;
    wire        npu_wready;
    wire [255:0] npu_wdata;
    wire        npu_wlast;
    wire [31:0] npu_wstrb;
    wire        npu_bvalid;
    wire        npu_bready;
    wire [1:0]  npu_bresp;

    wire        npu_busy;
    wire        npu_done;
    wire        npu_error;
    wire [7:0]  npu_error_code;

    // ---- AXI-Lite register address map (from npu_ctrl) ----
    localparam [31:0] ADDR_CTRL          = 32'h0000_0000;
    localparam [31:0] ADDR_TASK_TYPE     = 32'h0000_0008;
    localparam [31:0] ADDR_INPUT_ADDR    = 32'h0000_000c;
    localparam [31:0] ADDR_WEIGHT_ADDR   = 32'h0000_0010;
    localparam [31:0] ADDR_OUTPUT_ADDR   = 32'h0000_0014;
    localparam [31:0] ADDR_INPUT_BYTES   = 32'h0000_0018;
    localparam [31:0] ADDR_WEIGHT_BYTES  = 32'h0000_001c;
    localparam [31:0] ADDR_OUTPUT_BYTES  = 32'h0000_0020;
    localparam [31:0] ADDR_DIM_IN        = 32'h0000_0024;
    localparam [31:0] ADDR_DIM_OUT       = 32'h0000_0028;
    localparam [31:0] ADDR_POSTPROC      = 32'h0000_002c;
    localparam [31:0] ADDR_REQUANT_SEL   = 32'h0000_0064;
    localparam [31:0] ADDR_RQ0_MULT      = 32'h0000_0068;
    localparam [31:0] ADDR_RQ0_SHIFT     = 32'h0000_006c;
    localparam [31:0] ADDR_CONV_CFG      = 32'h0000_0098;
    localparam [31:0] ADDR_BIAS_ADDR     = 32'h0000_009c;
    localparam [31:0] ADDR_BIAS_BYTES    = 32'h0000_00a0;
    localparam [31:0] ADDR_SRC1_ADDR     = 32'h0000_00a4;
    localparam [31:0] ADDR_SRC1_BYTES    = 32'h0000_00a8;
    localparam [31:0] ADDR_ADD_CFG       = 32'h0000_00ac;
    localparam [31:0] ADDR_CLUSTER_MODE  = 32'h0000_0088;
    localparam [31:0] ADDR_CLUSTER_MASK  = 32'h0000_008c;

    // ---- NPU instantiation (16 output channels -> MODE_SINGLE ok) ----
    npu_top #(
        .TILE_ROWS(4),
        .TILE_COLS(4),
        .BUF_ENTRIES(16384),
        .BUF_ADDR_W(14)
    ) u_npu (
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
        .m_axi_arvalid(npu_arvalid), .m_axi_arready(npu_arready),
        .m_axi_araddr(npu_araddr), .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize), .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(npu_rvalid), .m_axi_rready(npu_rready),
        .m_axi_rdata(npu_rdata), .m_axi_rlast(npu_rlast),
        .m_axi_rresp(npu_rresp),
        .m_axi_awvalid(npu_awvalid), .m_axi_awready(npu_awready),
        .m_axi_awaddr(npu_awaddr), .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize), .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid), .m_axi_wready(npu_wready),
        .m_axi_wdata(npu_wdata), .m_axi_wlast(npu_wlast),
        .m_axi_wstrb(npu_wstrb), .m_axi_bvalid(npu_bvalid),
        .m_axi_bready(npu_bready), .m_axi_bresp(npu_bresp),
        .npu_busy(npu_busy), .npu_done(npu_done),
        .npu_error(npu_error), .npu_error_code(npu_error_code)
    );

    axi4_ram #(
        .RAM_DEPTH(32768)
    ) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(npu_awvalid), .s_axi_awready(npu_awready),
        .s_axi_awaddr(npu_awaddr), .s_axi_awlen(npu_awlen),
        .s_axi_awsize(npu_awsize), .s_axi_awburst(npu_awburst),
        .s_axi_wvalid(npu_wvalid), .s_axi_wready(npu_wready),
        .s_axi_wdata(npu_wdata), .s_axi_wstrb(npu_wstrb),
        .s_axi_wlast(npu_wlast), .s_axi_bvalid(npu_bvalid),
        .s_axi_bready(npu_bready), .s_axi_bresp(npu_bresp),
        .s_axi_arvalid(npu_arvalid), .s_axi_arready(npu_arready),
        .s_axi_araddr(npu_araddr), .s_axi_arlen(npu_arlen),
        .s_axi_arsize(npu_arsize), .s_axi_arburst(npu_arburst),
        .s_axi_rvalid(npu_rvalid), .s_axi_rready(npu_rready),
        .s_axi_rdata(npu_rdata), .s_axi_rlast(npu_rlast),
        .s_axi_rresp(npu_rresp)
    );

    always #2.5 clk = ~clk;

    // ============================================================
    // Task helpers
    // ============================================================

    task fail;
        input [1023:0] msg;
        begin
            $display("STRIDE2_SMOKE FAIL: %0s", msg);
            $finish;
        end
    endtask

    task init_bus;
        begin
            s_axi_awvalid = 1'b0;
            s_axi_awaddr = 32'd0;
            s_axi_wvalid = 1'b0;
            s_axi_wdata = 32'd0;
            s_axi_wstrb = 4'hf;
            s_axi_bready = 1'b0;
            s_axi_arvalid = 1'b0;
            s_axi_araddr = 32'd0;
            s_axi_rready = 1'b0;
        end
    endtask

    task axi_write;
        input [31:0] addr;
        input [31:0] data;
        reg aw_done, w_done;
        integer timeout_cycles;
        begin
            @(posedge clk);
            s_axi_awvalid = 1'b1;
            s_axi_awaddr = addr;
            s_axi_wvalid = 1'b1;
            s_axi_wdata = data;
            s_axi_wstrb = 4'hf;
            aw_done = 1'b0;
            w_done = 1'b0;
            timeout_cycles = 0;
            while ((!aw_done || !w_done) && timeout_cycles < 1000) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
                if (s_axi_awvalid && s_axi_awready) begin
                    aw_done = 1'b1;
                    s_axi_awvalid = 1'b0;
                end
                if (s_axi_wvalid && s_axi_wready) begin
                    w_done = 1'b1;
                    s_axi_wvalid = 1'b0;
                end
            end
            if (!aw_done || !w_done) fail("AXI write timeout");
            s_axi_bready = 1'b1;
            @(posedge clk);
            timeout_cycles = 0;
            while (!s_axi_bvalid && timeout_cycles < 1000) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (!s_axi_bvalid) fail("AXI write response timeout");
            if (s_axi_bresp !== 2'b00) fail("AXI write error response");
            @(posedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task ram_write_byte;
        input [31:0] addr;
        input [7:0]  data;
        integer beat, lane;
        begin
            beat = addr >> 5;
            lane = addr[4:0];
            u_ram.ram[beat][lane*8 +: 8] = data;
        end
    endtask

    function [7:0] ram_read_byte;
        input [31:0] addr;
        integer beat, lane;
        begin
            beat = addr >> 5;
            lane = addr[4:0];
            ram_read_byte = u_ram.ram[beat][lane*8 +: 8];
        end
    endfunction

    function integer is_unknown_byte;
        input [31:0] addr;
        reg [7:0] b;
        begin
            b = ram_read_byte(addr);
            is_unknown_byte = ($isunknown(b)) ? 1 : 0;
        end
    endfunction

    // ============================================================
    // Load memh files
    // ============================================================
    reg [7:0] load_byte [0:16383];
    integer i;

    task load_memh_to_ram;
        input [1023:0] filename;
        input [31:0]   base_addr;
        input [31:0]   byte_count;
        integer j;
        begin
            $readmemh(filename, load_byte);
            for (j = 0; j < byte_count; j = j + 1)
                ram_write_byte(base_addr + j, load_byte[j]);
        end
    endtask

    // ============================================================
    // Program a single Conv task
    // ============================================================
    task program_conv_task;
        input [31:0] in_addr, wgt_addr, out_addr, bias_addr;
        input [31:0] in_bytes, wgt_bytes, out_bytes, bias_bytes;
        input [15:0] in_h, in_w, in_c, out_c;
        input [31:0] conv_cfg;
        input [31:0] rq_mult, rq_shift;
        begin
            axi_write(ADDR_TASK_TYPE,     32'd0);      // Conv
            axi_write(ADDR_INPUT_ADDR,    in_addr);
            axi_write(ADDR_WEIGHT_ADDR,   wgt_addr);
            axi_write(ADDR_OUTPUT_ADDR,   out_addr);
            axi_write(ADDR_INPUT_BYTES,   in_bytes);
            axi_write(ADDR_WEIGHT_BYTES,  wgt_bytes);
            axi_write(ADDR_OUTPUT_BYTES,  out_bytes);
            axi_write(ADDR_DIM_IN,        {in_w[15:0], in_h[15:0]});
            axi_write(ADDR_DIM_OUT,       {out_c[15:0], in_c[15:0]});
            axi_write(ADDR_POSTPROC,      32'd1);  // bit0=relu_en
            axi_write(ADDR_REQUANT_SEL,   32'd0);
            axi_write(ADDR_RQ0_MULT,      rq_mult);
            axi_write(ADDR_RQ0_SHIFT,     rq_shift);
            axi_write(ADDR_CONV_CFG,      conv_cfg);
            axi_write(ADDR_BIAS_ADDR,     bias_addr);
            axi_write(ADDR_BIAS_BYTES,    bias_bytes);
            axi_write(ADDR_SRC1_ADDR,     32'd0);
            axi_write(ADDR_SRC1_BYTES,    32'd0);
            axi_write(ADDR_ADD_CFG,       32'd0);
        end
    endtask

    task wait_done;
        input integer max_cycles;
        integer cnt;
        begin
            cnt = 0;
            while (!npu_done && !npu_error && cnt < max_cycles) begin
                @(posedge clk);
                cnt = cnt + 1;
                if ((cnt % 200000) == 0)
                    $display("STRIDE2_SMOKE_PROGRESS cycles=%0d busy=%0b done=%0b",
                             cnt, npu_busy, npu_done);
            end
            if (npu_error) begin
                $display("STRIDE2_SMOKE_ERROR code=0x%02h", npu_error_code);
                fail("npu_top task error");
            end
            if (!npu_done)
                fail("npu_top task timeout");
        end
    endtask

    // ============================================================
    // Main test
    // ============================================================
    integer total_compared, total_mismatch, total_unknown;
    integer first_mismatch_idx, first_unknown_idx;
    reg [7:0] first_expected, first_actual;
    integer first_unknown;
    reg [31:0] actual_masked_checksum;
    reg [31:0] expected_checksum_val;
    integer j;
    reg [7:0] expected_byte_val;
    reg [7:0] actual_byte_val;
    reg actual_unknown;
    integer oh, ow, oc;

    // task parameters from summary
    localparam [31:0] INPUT_ADDR   = 32'd64;
    localparam [31:0] WEIGHT_ADDR  = 32'd524288;
    localparam [31:0] BIAS_ADDR    = 32'd528384;
    localparam [31:0] OUTPUT_ADDR  = 32'd3136;
    localparam [31:0] INPUT_BYTES  = 32'd16384;
    localparam [31:0] WEIGHT_BYTES = 32'd2304;
    localparam [31:0] BIAS_BYTES   = 32'd64;
    localparam [31:0] OUTPUT_BYTES = 32'd4096;
    localparam [15:0] IN_H = 16'd32, IN_W = 16'd32, IN_C = 16'd16, OUT_C = 16'd16;
    localparam [31:0] CONV_CFG_VAL = 32'd30;  // 0x1E
    localparam [31:0] RQ_MULT = 32'd1234567;
    localparam [31:0] RQ_SHIFT = 32'd27;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        init_bus;
        total_compared = 0;
        total_mismatch = 0;
        total_unknown = 0;
        first_mismatch_idx = -1;
        first_unknown_idx = -1;
        first_expected = 8'd0;
        first_actual = 8'd0;
        first_unknown = 0;

        // ---- Reset RAM ----
        for (i = 0; i < 32768; i = i + 1)
            u_ram.ram[i] = 256'd0;

        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (6) @(posedge clk);

        $display("=== stride2 3x3 same-padding smoke test ===");
        $display("STRIDE2_SCOPE kernel=3x3 stride=2 padding=same in=16x32x32 out=16x16x16 mode=SINGLE");

        // ---- Load data ----
        load_memh_to_ram("tb/generated/stride2_smoke/input.memh",   INPUT_ADDR,  INPUT_BYTES);
        load_memh_to_ram("tb/generated/stride2_smoke/weights.memh", WEIGHT_ADDR, WEIGHT_BYTES);
        load_memh_to_ram("tb/generated/stride2_smoke/bias_bytes.memh", BIAS_ADDR, BIAS_BYTES);
        $display("STRIDE2_SMOKE loaded input=%0d weight=%0d bias=%0d",
                 INPUT_BYTES, WEIGHT_BYTES, BIAS_BYTES);

        // ---- Load expected reference ----
        $readmemh("tb/generated/stride2_smoke/expected.memh", load_byte);

        // ---- Keep CLUSTER_MODE = SINGLE (default), confirm mask ----
        axi_write(ADDR_CLUSTER_MODE, 32'd0);  // MODE_SINGLE
        axi_write(ADDR_CLUSTER_MASK, 32'h0000_003f);

        // ---- Program task ----
        program_conv_task(
            INPUT_ADDR, WEIGHT_ADDR, OUTPUT_ADDR, BIAS_ADDR,
            INPUT_BYTES, WEIGHT_BYTES, OUTPUT_BYTES, BIAS_BYTES,
            IN_H, IN_W, IN_C, OUT_C,
            CONV_CFG_VAL, RQ_MULT, RQ_SHIFT
        );

        // ---- Start ----
        $display("STRIDE2_SMOKE_START");
        axi_write(ADDR_CTRL, 32'h0000_0001);

        // ---- Wait ----
        wait_done(8000000);

        $display("STRIDE2_SMOKE_DONE done=%0b error=%0b", npu_done, npu_error);

        // ---- Read and compare output ----
        actual_masked_checksum = 32'd0;
        expected_checksum_val = 32'h1002919e;  // from fixture script

        // Dump actual output for debugging
        begin
            integer dump_fd, dump_j;
            dump_fd = $fopen("tb/generated/stride2_smoke/rtl_actual.memh", "w");
            for (dump_j = 0; dump_j < OUTPUT_BYTES; dump_j = dump_j + 1) begin
                $fdisplay(dump_fd, "%02x", ram_read_byte(OUTPUT_ADDR + dump_j));
            end
            $fclose(dump_fd);
        end

        for (j = 0; j < OUTPUT_BYTES; j = j + 1) begin
            expected_byte_val = load_byte[j];
            actual_byte_val = ram_read_byte(OUTPUT_ADDR + j);
            actual_unknown = ($isunknown(actual_byte_val)) ? 1 : 0;

            // Checksum: treat unknown as 0
            actual_masked_checksum = (actual_masked_checksum +
                ({24'd0, actual_unknown ? 8'd0 : actual_byte_val} * (j + 1))) & 32'hffff_ffff;

            if (actual_unknown) begin
                total_unknown = total_unknown + 1;
                if (first_unknown_idx < 0)
                    first_unknown_idx = j;
            end else if (actual_byte_val !== expected_byte_val) begin
                total_mismatch = total_mismatch + 1;
                if (first_mismatch_idx < 0) begin
                    first_mismatch_idx = j;
                    first_expected = expected_byte_val;
                    first_actual = actual_byte_val;
                    first_unknown = 0;
                end
            end
            total_compared = total_compared + 1;
        end

        // ---- Report ----
        $display("STRIDE2_SMOKE_RESULT compared=%0d mismatch=%0d unknown=%0d first_mismatch_idx=%0d first_unknown_idx=%0d expected_checksum=0x%08h actual_masked_checksum=0x%08h",
                 total_compared, total_mismatch, total_unknown,
                 first_mismatch_idx, first_unknown_idx,
                 expected_checksum_val, actual_masked_checksum);

        if (first_mismatch_idx >= 0) begin
            j = first_mismatch_idx;
            oh = (j / (OUT_C * 16)) / 16;
            ow = (j / OUT_C) % 16;
            oc = j % OUT_C;
            $display("STRIDE2_SMOKE_FIRST_MISMATCH byte_idx=%0d (oh=%0d ow=%0d oc=%0d) expected=0x%02h actual=0x%02h",
                     j, oh, ow, oc, first_expected, first_actual);
        end

        if (first_unknown_idx >= 0) begin
            j = first_unknown_idx;
            oh = (j / (OUT_C * 16)) / 16;
            ow = (j / OUT_C) % 16;
            oc = j % OUT_C;
            $display("STRIDE2_SMOKE_FIRST_UNKNOWN byte_idx=%0d (oh=%0d ow=%0d oc=%0d)",
                     j, oh, ow, oc);
            $display("STRIDE2_SMOKE_X_RANGE unknown_count=%0d first=%0d last_unknown_offset=%0d",
                     total_unknown, first_unknown_idx,
                     total_unknown > 0 ? (first_unknown_idx + total_unknown - 1) : -1);
        end

        if (total_mismatch == 0 && total_unknown == 0) begin
            $display("STRIDE2_SMOKE PASS: stride2 3x3 same path exact match");
        end else if (total_unknown > 0) begin
            $display("STRIDE2_SMOKE FAIL: conv_frontend stride2 path produces X (%0d unknown bytes)", total_unknown);
        end else begin
            $display("STRIDE2_SMOKE FAIL: stride2 arithmetic mismatch (%0d errors, no X)", total_mismatch);
        end

        // ---- Write result JSON ----
        begin
            integer fd;
            fd = $fopen("tb/generated/stride2_smoke/rtl_result.json", "w");
            if (fd != 0) begin
                $fdisplay(fd, "{");
                $fdisplay(fd, "  \"scope\": \"stride2_3x3_same_smoke\",");
                $fdisplay(fd, "  \"kernel\": [3,3], \"stride\": 2, \"padding\": \"same\",");
                $fdisplay(fd, "  \"input_shape\": [16,32,32], \"output_shape\": [16,16,16],");
                $fdisplay(fd, "  \"cluster_mode\": \"SINGLE\",");
                $fdisplay(fd, "  \"compared_bytes\": %0d,", total_compared);
                $fdisplay(fd, "  \"mismatch_count\": %0d,", total_mismatch);
                $fdisplay(fd, "  \"unknown_count\": %0d,", total_unknown);
                $fdisplay(fd, "  \"first_mismatch_idx\": %0d,", first_mismatch_idx);
                $fdisplay(fd, "  \"first_unknown_idx\": %0d,", first_unknown_idx);
                $fdisplay(fd, "  \"expected_checksum\": \"0x%08h\",", expected_checksum_val);
                $fdisplay(fd, "  \"actual_masked_checksum\": \"0x%08h\",", actual_masked_checksum);
                $fdisplay(fd, "  \"x_propagates\": %0d,", (total_unknown > 0) ? 1 : 0);
                $fdisplay(fd, "  \"verdict\": \"%0s\"",
                         (total_unknown == 0 && total_mismatch == 0) ? "exact_match" :
                         (total_unknown > 0) ? "x_detected" : "arithmetic_mismatch");
                $fdisplay(fd, "}");
                $fclose(fd);
            end
        end

        $display("tb_stride2_smoke FINISH x_detected=%0d mismatch=%0d",
                 (total_unknown > 0) ? 1 : 0, total_mismatch);
        $finish;
    end
endmodule
