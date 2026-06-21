// tb_resnet20_r1h_package_compare: package-faithful npu_top conv1 compare.
// This is an R1h small fixture for input.image -> conv1 only. It uses formal
// memory_map/task_sequence addresses and full tensor byte sizes, not compact
// alias/remap addresses. It is not full ResNet-20 RTL closure.
`timescale 1ns / 1ps

module tb_resnet20_r1h_package_compare;
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
    localparam [31:0] ADDR_GAP_CFG       = 32'h0000_00b0;
    localparam [31:0] ADDR_POSTPROC_EXT  = 32'h0000_00b4;

    reg [7:0] r1h_input_byte [0:4095];
    reg [7:0] r1h_weight_byte [0:2047];
    reg [7:0] r1h_bias_byte [0:255];
    reg [7:0] r1h_expected_byte [0:20000];
    integer r1h_ref_input_idx [0:26];
    integer r1h_ref_weight_idx [0:26];
    reg signed [31:0] r1h_ref_input_i8 [0:26];
    reg signed [31:0] r1h_ref_weight_i8 [0:26];
    reg signed [31:0] r1h_ref_product [0:26];

`include "resnet20_r1h_package_compare.vh"

    localparam [4:0] TRACE_FSM_COMPUTE = 5'd9;
    localparam [4:0] TRACE_FSM_REQUANT_COMPUTE = 5'd21;
    localparam [2:0] TRACE_CP_FEED_ACT = 3'd1;

    reg        trace_window_seen [0:2];
    reg [7:0]  trace_window_byte [0:26];
    reg [7:0]  trace_weight_byte [0:26];
    reg signed [31:0] trace_window_i8 [0:26];
    reg signed [31:0] trace_weight_i8 [0:26];
    reg signed [31:0] trace_product [0:26];
    reg        trace_requant_seen;
    reg signed [31:0] trace_mac_before_bias;
    reg signed [31:0] trace_bias_i32;
    reg signed [31:0] trace_acc_after_bias;
    reg signed [31:0] trace_requant_i8;
    integer feed_event_count;
    integer feed_event_cin [0:15];
    integer feed_event_win [0:15];
    integer feed_event_window_sum [0:15];
    integer feed_event_product_sum [0:15];
    reg signed [31:0] feed_event_window_i8 [0:15][0:8];
    reg signed [31:0] feed_event_weight_i8 [0:15][0:8];
    integer acc0_event_count;
    integer acc0_event_fsm [0:15];
    integer acc0_event_sub [0:15];
    integer acc0_event_cin [0:15];
    integer acc0_event_win [0:15];
    integer acc0_event_col [0:15];
    integer acc0_event_wr_addr [0:15];
    integer acc0_event_partial_addr [0:15];
    integer acc0_event_wr_ptr [0:15];
    reg signed [31:0] acc0_event_col_result [0:15];
    reg signed [31:0] acc0_event_col_result_selected [0:15];
    reg signed [31:0] acc0_event_rd_data [0:15];
    reg signed [31:0] acc0_event_wr_data [0:15];
    integer acc0_event_is_collect [0:15];
    integer acc0_event_is_requant [0:15];
    integer acc3_event_count;
    integer acc3_event_fsm [0:15];
    integer acc3_event_sub [0:15];
    integer acc3_event_cin [0:15];
    integer acc3_event_win [0:15];
    integer acc3_event_col [0:15];
    integer acc3_event_wr_addr [0:15];
    reg signed [31:0] acc3_event_wr_data [0:15];
    integer acc3_event_is_collect [0:15];
    integer acc3_event_is_requant [0:15];
    integer rq_read0_fsm;
    reg signed [31:0] rq_read0_acc_data;
    reg rq_read0_seen;
    integer rq_read3_fsm;
    reg signed [31:0] rq_read3_acc_data;
    reg signed [31:0] rq_read3_bias;
    reg signed [31:0] rq_read3_acc_after_bias;
    reg signed [31:0] rq_read3_q;
    reg rq_read3_word_store_mode;
    reg rq_read3_seen;
    integer collect_write_count;
    integer collect_bad_owner_count;
    integer collect_first_bad_actual;
    integer collect_first_bad_expected;
    integer collect_duplicate_count;
    integer collect_first_duplicate_cin;
    integer collect_first_duplicate_win;
    integer collect_first_duplicate_col;
    integer collect_prev_valid;
    integer collect_prev_cin;
    integer collect_prev_win;
    integer collect_prev_col;
    integer acc16_event_count;
    integer acc16_event_fsm [0:15];
    integer acc16_event_cin [0:15];
    integer acc16_event_win [0:15];
    integer acc16_event_col [0:15];
    reg signed [31:0] acc16_event_wr_data [0:15];
    integer acc16_event_unknown [0:15];
    reg signed [31:0] rq_read16_acc_data;
    reg signed [31:0] rq_read16_q;
    reg rq_read16_acc_unknown;
    reg rq_read16_q_unknown;
    reg rq_read16_seen;

    function signed [31:0] s8_to_i32;
        input [7:0] value;
        begin
            s8_to_i32 = value[7] ? $signed({24'hff_ffff, value}) : $signed({24'd0, value});
        end
    endfunction

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

    task fail;
        input [511:0] msg;
        begin
            $display("tb_resnet20_r1h_package_compare FAIL: %0s", msg);
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
        reg aw_done;
        reg w_done;
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
            if (!aw_done || !w_done)
                fail("AXI-Lite write address/data timeout");
            s_axi_bready = 1'b1;
            @(posedge clk);
            timeout_cycles = 0;
            while (!s_axi_bvalid && timeout_cycles < 1000) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (!s_axi_bvalid)
                fail("AXI-Lite write response timeout");
            if (s_axi_bresp !== 2'b00)
                fail("AXI-Lite write error response");
            @(posedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task ram_write_byte;
        input [31:0] addr;
        input [7:0] data;
        integer beat;
        integer lane;
        begin
            beat = addr >> 5;
            lane = addr[4:0];
            u_ram.ram[beat][lane*8 +: 8] = data;
        end
    endtask

    function [7:0] ram_read_byte;
        input [31:0] addr;
        integer beat;
        integer lane;
        begin
            beat = addr >> 5;
            lane = addr[4:0];
            ram_read_byte = u_ram.ram[beat][lane*8 +: 8];
        end
    endfunction

    function [31:0] checksum_region;
        input [31:0] base;
        input [31:0] bytes;
        integer i;
        reg [31:0] acc;
        reg [7:0] b;
        begin
            acc = 32'd0;
            for (i = 0; i < bytes; i = i + 1) begin
                b = ram_read_byte(base + i);
                if (^b === 1'bx)
                    b = 8'd0;
                acc = (acc + ({24'd0, b} * (i + 1))) & 32'hffff_ffff;
            end
            checksum_region = acc;
        end
    endfunction

    function integer unknown_byte_count;
        input [31:0] base;
        input [31:0] bytes;
        integer i;
        reg [7:0] b;
        begin
            unknown_byte_count = 0;
            for (i = 0; i < bytes; i = i + 1) begin
                b = ram_read_byte(base + i);
                if (^b === 1'bx)
                    unknown_byte_count = unknown_byte_count + 1;
            end
        end
    endfunction

    task preload_fixture;
        integer i;
        begin
            for (i = 0; i < R1H_INPUT_BYTES; i = i + 1)
                ram_write_byte(R1H_INPUT_ADDR + i, r1h_input_byte[i]);
            for (i = 0; i < R1H_WEIGHT_BYTES; i = i + 1)
                ram_write_byte(R1H_WEIGHT_ADDR + i, r1h_weight_byte[i]);
            for (i = 0; i < R1H_BIAS_BYTES; i = i + 1)
                ram_write_byte(R1H_BIAS_ADDR + i, r1h_bias_byte[i]);
            for (i = 0; i < R1H_COMPARE_BYTES; i = i + 1)
                ram_write_byte(R1H_OUTPUT_ADDR + i, 8'd0);
        end
    endtask

    task init_trace;
        integer ti;
        integer tj;
        begin
            for (ti = 0; ti < 3; ti = ti + 1)
                trace_window_seen[ti] = 1'b0;
            for (ti = 0; ti < 27; ti = ti + 1) begin
                trace_window_byte[ti] = 8'd0;
                trace_weight_byte[ti] = 8'd0;
                trace_window_i8[ti] = 32'sd0;
                trace_weight_i8[ti] = 32'sd0;
                trace_product[ti] = 32'sd0;
            end
            trace_requant_seen = 1'b0;
            trace_mac_before_bias = 32'sd0;
            trace_bias_i32 = 32'sd0;
            trace_acc_after_bias = 32'sd0;
            trace_requant_i8 = 32'sd0;
            feed_event_count = 0;
            acc0_event_count = 0;
            acc3_event_count = 0;
            rq_read0_fsm = 0;
            rq_read0_acc_data = 32'sd0;
            rq_read0_seen = 1'b0;
            rq_read3_fsm = 0;
            rq_read3_acc_data = 32'sd0;
            rq_read3_bias = 32'sd0;
            rq_read3_acc_after_bias = 32'sd0;
            rq_read3_q = 32'sd0;
            rq_read3_word_store_mode = 1'b0;
            rq_read3_seen = 1'b0;
            collect_write_count = 0;
            collect_bad_owner_count = 0;
            collect_first_bad_actual = -1;
            collect_first_bad_expected = -1;
            collect_duplicate_count = 0;
            collect_first_duplicate_cin = -1;
            collect_first_duplicate_win = -1;
            collect_first_duplicate_col = -1;
            collect_prev_valid = 0;
            collect_prev_cin = -1;
            collect_prev_win = -1;
            collect_prev_col = -1;
            acc16_event_count = 0;
            rq_read16_acc_data = 32'sd0;
            rq_read16_q = 32'sd0;
            rq_read16_acc_unknown = 1'b0;
            rq_read16_q_unknown = 1'b0;
            rq_read16_seen = 1'b0;
            for (ti = 0; ti < 16; ti = ti + 1) begin
                feed_event_cin[ti] = 0;
                feed_event_win[ti] = 0;
                feed_event_window_sum[ti] = 0;
                feed_event_product_sum[ti] = 0;
                acc0_event_fsm[ti] = 0;
                acc0_event_sub[ti] = 0;
                acc0_event_cin[ti] = 0;
                acc0_event_win[ti] = 0;
                acc0_event_col[ti] = 0;
                acc0_event_wr_addr[ti] = 0;
                acc0_event_partial_addr[ti] = 0;
                acc0_event_wr_ptr[ti] = 0;
                acc0_event_col_result[ti] = 32'sd0;
                acc0_event_col_result_selected[ti] = 32'sd0;
                acc0_event_rd_data[ti] = 32'sd0;
                acc0_event_wr_data[ti] = 32'sd0;
                acc0_event_is_collect[ti] = 0;
                acc0_event_is_requant[ti] = 0;
                acc3_event_fsm[ti] = 0;
                acc3_event_sub[ti] = 0;
                acc3_event_cin[ti] = 0;
                acc3_event_win[ti] = 0;
                acc3_event_col[ti] = 0;
                acc3_event_wr_addr[ti] = 0;
                acc3_event_wr_data[ti] = 32'sd0;
                acc3_event_is_collect[ti] = 0;
                acc3_event_is_requant[ti] = 0;
                acc16_event_fsm[ti] = 0;
                acc16_event_cin[ti] = 0;
                acc16_event_win[ti] = 0;
                acc16_event_col[ti] = 0;
                acc16_event_wr_data[ti] = 32'sd0;
                acc16_event_unknown[ti] = 0;
                for (tj = 0; tj < 9; tj = tj + 1) begin
                    feed_event_window_i8[ti][tj] = 32'sd0;
                    feed_event_weight_i8[ti][tj] = 32'sd0;
                end
            end
        end
    endtask

    integer trace_sp;
    integer trace_idx;
    integer feed_idx;
    integer acc0_idx;
    integer acc3_idx;
    integer acc16_idx;
    integer collect_expected_addr;
    integer feed_window_sum_tmp;
    integer feed_product_sum_tmp;
    always @(posedge clk) begin
        if (rst_n &&
            (u_npu.fsm_state == TRACE_FSM_COMPUTE) &&
            (u_npu.comp_sub_state == TRACE_CP_FEED_ACT) &&
            (u_npu.comp_win_idx == 16'd0) &&
            (u_npu.comp_feed_cnt == 7'd0) &&
            (u_npu.cin_idx < 16'd3) &&
            !trace_window_seen[u_npu.cin_idx]) begin
            trace_window_seen[u_npu.cin_idx] <= 1'b1;
            for (trace_sp = 0; trace_sp < 9; trace_sp = trace_sp + 1) begin
                trace_idx = trace_sp * 3 + u_npu.cin_idx;
                trace_window_byte[trace_idx] <= u_npu.cf_window[trace_sp];
                trace_weight_byte[trace_idx] <= u_npu.wgt_load_reg[(trace_sp * 16 + 0) * 8 +: 8];
                trace_window_i8[trace_idx] <= s8_to_i32(u_npu.cf_window[trace_sp]);
                trace_weight_i8[trace_idx] <= s8_to_i32(u_npu.wgt_load_reg[(trace_sp * 16 + 0) * 8 +: 8]);
                trace_product[trace_idx] <= s8_to_i32(u_npu.cf_window[trace_sp]) *
                                            s8_to_i32(u_npu.wgt_load_reg[(trace_sp * 16 + 0) * 8 +: 8]);
            end
        end

        if (rst_n &&
            (u_npu.fsm_state == TRACE_FSM_COMPUTE) &&
            (u_npu.comp_sub_state == TRACE_CP_FEED_ACT) &&
            (u_npu.comp_feed_cnt == 7'd0) &&
            (u_npu.cin_idx < 16'd3) &&
            (u_npu.comp_win_idx < 16'd4) &&
            (feed_event_count < 16)) begin
            feed_idx = feed_event_count;
            feed_window_sum_tmp = 0;
            feed_product_sum_tmp = 0;
            feed_event_count <= feed_event_count + 1;
            feed_event_cin[feed_idx] <= u_npu.cin_idx;
            feed_event_win[feed_idx] <= u_npu.comp_win_idx;
            for (trace_sp = 0; trace_sp < 9; trace_sp = trace_sp + 1) begin
                feed_event_window_i8[feed_idx][trace_sp] <= s8_to_i32(u_npu.cf_window[trace_sp]);
                feed_event_weight_i8[feed_idx][trace_sp] <= s8_to_i32(u_npu.wgt_load_reg[(trace_sp * 16 + 0) * 8 +: 8]);
                feed_window_sum_tmp = feed_window_sum_tmp + s8_to_i32(u_npu.cf_window[trace_sp]);
                feed_product_sum_tmp = feed_product_sum_tmp +
                    (s8_to_i32(u_npu.cf_window[trace_sp]) *
                     s8_to_i32(u_npu.wgt_load_reg[(trace_sp * 16 + 0) * 8 +: 8]));
            end
            feed_event_window_sum[feed_idx] <= feed_window_sum_tmp;
            feed_event_product_sum[feed_idx] <= feed_product_sum_tmp;
        end

        if (rst_n &&
            u_npu.acc_wr_en &&
            (u_npu.acc_wr_addr == {14{1'b0}}) &&
            (acc0_event_count < 16)) begin
            acc0_idx = acc0_event_count;
            acc0_event_count <= acc0_event_count + 1;
            acc0_event_fsm[acc0_idx] <= u_npu.fsm_state;
            acc0_event_sub[acc0_idx] <= u_npu.comp_sub_state;
            acc0_event_cin[acc0_idx] <= u_npu.cin_idx;
            acc0_event_win[acc0_idx] <= u_npu.comp_win_idx;
            acc0_event_col[acc0_idx] <= u_npu.acc_col_idx;
            acc0_event_wr_addr[acc0_idx] <= u_npu.acc_wr_addr;
            acc0_event_partial_addr[acc0_idx] <= u_npu.acc_partial_addr;
            acc0_event_wr_ptr[acc0_idx] <= u_npu.acc_wr_ptr;
            acc0_event_col_result[acc0_idx] <= $signed(u_npu.col_results[0]);
            acc0_event_col_result_selected[acc0_idx] <= $signed(u_npu.col_results[u_npu.acc_col_idx]);
            acc0_event_rd_data[acc0_idx] <= $signed(u_npu.acc_rd_data);
            acc0_event_wr_data[acc0_idx] <= $signed(u_npu.acc_wr_data);
            acc0_event_is_collect[acc0_idx] <=
                (u_npu.fsm_state == TRACE_FSM_COMPUTE) &&
                (u_npu.comp_sub_state == 3'd3);
            acc0_event_is_requant[acc0_idx] <= u_npu.rq_internal_write_phase;
        end

        if (rst_n &&
            u_npu.acc_wr_en &&
            (u_npu.acc_wr_addr == 14'd3) &&
            (acc3_event_count < 16)) begin
            acc3_idx = acc3_event_count;
            acc3_event_count <= acc3_event_count + 1;
            acc3_event_fsm[acc3_idx] <= u_npu.fsm_state;
            acc3_event_sub[acc3_idx] <= u_npu.comp_sub_state;
            acc3_event_cin[acc3_idx] <= u_npu.cin_idx;
            acc3_event_win[acc3_idx] <= u_npu.comp_win_idx;
            acc3_event_col[acc3_idx] <= u_npu.acc_col_idx;
            acc3_event_wr_addr[acc3_idx] <= u_npu.acc_wr_addr;
            acc3_event_wr_data[acc3_idx] <= $signed(u_npu.acc_wr_data);
            acc3_event_is_collect[acc3_idx] <=
                (u_npu.fsm_state == TRACE_FSM_COMPUTE) &&
                (u_npu.comp_sub_state == 3'd3);
            acc3_event_is_requant[acc3_idx] <= u_npu.rq_internal_write_phase;
        end

        if (rst_n &&
            u_npu.acc_wr_en &&
            (u_npu.fsm_state == TRACE_FSM_COMPUTE) &&
            (u_npu.comp_sub_state == 3'd3)) begin
            collect_expected_addr = u_npu.comp_win_idx * 16 + u_npu.acc_col_idx;
            collect_write_count <= collect_write_count + 1;
            if (collect_prev_valid &&
                (collect_prev_cin == u_npu.cin_idx) &&
                (collect_prev_win == u_npu.comp_win_idx) &&
                (collect_prev_col == u_npu.acc_col_idx)) begin
                collect_duplicate_count <= collect_duplicate_count + 1;
                if (collect_first_duplicate_cin < 0) begin
                    collect_first_duplicate_cin <= u_npu.cin_idx;
                    collect_first_duplicate_win <= u_npu.comp_win_idx;
                    collect_first_duplicate_col <= u_npu.acc_col_idx;
                end
            end
            collect_prev_valid <= 1;
            collect_prev_cin <= u_npu.cin_idx;
            collect_prev_win <= u_npu.comp_win_idx;
            collect_prev_col <= u_npu.acc_col_idx;
            if ((u_npu.comp_win_idx >= u_npu.comp_total_wins) ||
                (collect_expected_addr >= 16384) ||
                (u_npu.acc_wr_addr !== collect_expected_addr[13:0])) begin
                collect_bad_owner_count <= collect_bad_owner_count + 1;
                if (collect_first_bad_actual < 0) begin
                    collect_first_bad_actual <= u_npu.acc_wr_addr;
                    collect_first_bad_expected <= collect_expected_addr;
                end
            end
        end

        if (rst_n &&
            u_npu.acc_wr_en &&
            (u_npu.acc_wr_addr == 14'd16) &&
            (acc16_event_count < 16)) begin
            acc16_idx = acc16_event_count;
            acc16_event_count <= acc16_event_count + 1;
            acc16_event_fsm[acc16_idx] <= u_npu.fsm_state;
            acc16_event_cin[acc16_idx] <= u_npu.cin_idx;
            acc16_event_win[acc16_idx] <= u_npu.comp_win_idx;
            acc16_event_col[acc16_idx] <= u_npu.acc_col_idx;
            acc16_event_wr_data[acc16_idx] <= $signed(u_npu.acc_wr_data);
            acc16_event_unknown[acc16_idx] <= (^u_npu.acc_wr_data === 1'bx);
        end

        if (rst_n &&
            (u_npu.fsm_state == TRACE_FSM_REQUANT_COMPUTE) &&
            !u_npu.rq_src_wait &&
            (u_npu.rq_src_idx == 32'd0) &&
            !trace_requant_seen) begin
            trace_requant_seen <= 1'b1;
            trace_mac_before_bias <= $signed(u_npu.acc_rd_data);
            trace_bias_i32 <= $signed(u_npu.rq_bias_value);
            trace_acc_after_bias <= $signed(u_npu.rq_bias_acc);
            trace_requant_i8 <= $signed(u_npu.rq_q_selected);
        end

        if (rst_n &&
            (u_npu.fsm_state == TRACE_FSM_REQUANT_COMPUTE) &&
            !u_npu.rq_src_wait &&
            (u_npu.rq_src_idx == 32'd0) &&
            !rq_read0_seen) begin
            rq_read0_seen <= 1'b1;
            rq_read0_fsm <= u_npu.fsm_state;
            rq_read0_acc_data <= $signed(u_npu.acc_rd_data);
        end

        if (rst_n &&
            (u_npu.fsm_state == TRACE_FSM_REQUANT_COMPUTE) &&
            !u_npu.rq_src_wait &&
            (u_npu.rq_src_idx == 32'd3) &&
            !rq_read3_seen) begin
            rq_read3_seen <= 1'b1;
            rq_read3_fsm <= u_npu.fsm_state;
            rq_read3_acc_data <= $signed(u_npu.acc_rd_data);
            rq_read3_bias <= $signed(u_npu.rq_bias_value);
            rq_read3_acc_after_bias <= $signed(u_npu.rq_bias_acc);
            rq_read3_q <= $signed(u_npu.rq_q_selected);
            rq_read3_word_store_mode <= u_npu.rq_word_store_mode;
        end


        if (rst_n &&
            (u_npu.fsm_state == TRACE_FSM_REQUANT_COMPUTE) &&
            !u_npu.rq_src_wait &&
            (u_npu.rq_src_idx == 32'd16) &&
            !rq_read16_seen) begin
            rq_read16_seen <= 1'b1;
            rq_read16_acc_data <= $signed(u_npu.acc_rd_data);
            rq_read16_q <= $signed(u_npu.rq_q_selected);
            rq_read16_acc_unknown <= (^u_npu.acc_rd_data === 1'bx);
            rq_read16_q_unknown <= (^u_npu.rq_q_selected === 1'bx);
        end
    end

    task program_conv1;
        begin
            axi_write(ADDR_TASK_TYPE,    32'd0);
            axi_write(ADDR_INPUT_ADDR,   R1H_INPUT_ADDR);
            axi_write(ADDR_WEIGHT_ADDR,  R1H_WEIGHT_ADDR);
            axi_write(ADDR_OUTPUT_ADDR,  R1H_OUTPUT_ADDR);
            axi_write(ADDR_INPUT_BYTES,  R1H_INPUT_BYTES);
            axi_write(ADDR_WEIGHT_BYTES, R1H_WEIGHT_BYTES);
            axi_write(ADDR_OUTPUT_BYTES, R1H_COMPARE_BYTES);
            axi_write(ADDR_DIM_IN,       {16'd32, 16'd32});
            axi_write(ADDR_DIM_OUT,      {16'd16, 16'd3});
            axi_write(ADDR_POSTPROC,     32'd1);
            axi_write(ADDR_REQUANT_SEL,  32'd0);
            axi_write(ADDR_RQ0_MULT,     R1H_REQUANT_MULT);
            axi_write(ADDR_RQ0_SHIFT,    R1H_REQUANT_SHIFT);
            axi_write(ADDR_CONV_CFG,     R1H_CONV_CFG);
            axi_write(ADDR_BIAS_ADDR,    R1H_BIAS_ADDR);
            axi_write(ADDR_BIAS_BYTES,   R1H_BIAS_BYTES);
            axi_write(ADDR_SRC1_ADDR,    32'd0);
            axi_write(ADDR_SRC1_BYTES,   32'd0);
            axi_write(ADDR_ADD_CFG,      32'd0);
            axi_write(ADDR_GAP_CFG,      32'd0);
            axi_write(ADDR_POSTPROC_EXT, 32'd0);
        end
    endtask

    task wait_done;
        integer cnt;
        begin
            cnt = 0;
            while (!npu_done && !npu_error && cnt < 12000000) begin
                @(posedge clk);
                cnt = cnt + 1;
                if ((cnt % 500000) == 0)
                    $display("R1H_PROGRESS cycles=%0d state=%0d sub=%0d busy=%0b done=%0b",
                             cnt, u_npu.fsm_state, u_npu.comp_sub_state, npu_busy, npu_done);
            end
            if (npu_error) begin
                $display("R1H_ERROR code=0x%02h", npu_error_code);
                fail("npu_top task error");
            end
            if (!npu_done)
                fail("npu_top task timeout");
        end
    endtask

    integer compared_bytes;
    integer mismatch_count;
    integer unknown_bytes;
    integer first_mismatch;
    integer first_unknown_idx;
    reg [7:0] first_expected;
    reg [7:0] first_actual;
    reg [7:0] first_unknown_expected;
    reg first_unknown;
    reg [31:0] final_checksum;
    integer trace_fd;
    integer acc_source_fd;
    integer window_truth_fd;
    integer acc_truth_fd;
    integer byte3_trace_fd;
    integer debug_fd;
    integer result_fd;
    integer i;
    integer t;
    integer divergence_stage_code;
    integer trace_product_sum;
    integer first_unknown_oh;
    integer first_unknown_ow;
    integer first_unknown_oc;
    reg [7:0] actual;
    reg [7:0] expected;
    reg actual_unknown;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        init_bus;
        init_r1h_fixture;
        init_trace;
        compared_bytes = 0;
        mismatch_count = 0;
        unknown_bytes = 0;
        first_mismatch = -1;
        first_unknown_idx = -1;
        first_expected = 8'd0;
        first_actual = 8'd0;
        first_unknown_expected = 8'd0;
        first_unknown = 1'b0;
        divergence_stage_code = 0;
        trace_product_sum = 0;
        first_unknown_oh = -1;
        first_unknown_ow = -1;
        first_unknown_oc = -1;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        if (R1H_INPUT_ADDR == 32'd0)
            fail("R1h package-faithful input address is still zero");

        preload_fixture;
        program_conv1;
        axi_write(ADDR_CTRL, 32'h0000_0001);
        wait_done;

        compared_bytes = R1H_COMPARE_BYTES;
        for (i = 0; i < R1H_COMPARE_BYTES; i = i + 1) begin
            actual = ram_read_byte(R1H_OUTPUT_ADDR + i);
            expected = r1h_expected_byte[i];
            actual_unknown = (^actual === 1'bx);
            if (actual_unknown) begin
                unknown_bytes = unknown_bytes + 1;
                if (first_unknown_idx < 0) begin
                    first_unknown_idx = i;
                    first_unknown_expected = expected;
                end
            end
            if (actual_unknown || actual !== expected) begin
                mismatch_count = mismatch_count + 1;
                if (first_mismatch < 0) begin
                    first_mismatch = i;
                    first_expected = expected;
                    first_actual = actual_unknown ? 8'd0 : actual;
                    first_unknown = actual_unknown;
                end
            end
        end
        final_checksum = checksum_region(R1H_OUTPUT_ADDR, R1H_COMPARE_BYTES);
        if (first_unknown_idx >= 0) begin
            first_unknown_oh = first_unknown_idx / (32 * 16);
            first_unknown_ow = (first_unknown_idx % (32 * 16)) / 16;
            first_unknown_oc = first_unknown_idx % 16;
        end

        divergence_stage_code = 0;
        trace_product_sum = 0;
        for (t = 0; t < 27; t = t + 1) begin
            trace_product_sum = trace_product_sum + trace_product[t];
            if ((trace_window_i8[t] !== r1h_ref_input_i8[t]) ||
                (trace_weight_i8[t] !== r1h_ref_weight_i8[t]))
                divergence_stage_code = 1;
        end
        if (divergence_stage_code == 0 && trace_mac_before_bias !== R1H_REF_MAC_BEFORE_BIAS)
            divergence_stage_code = 2;
        if (divergence_stage_code == 0 &&
            ((trace_bias_i32 !== R1H_REF_BIAS_I32) ||
             (trace_acc_after_bias !== R1H_REF_ACC_AFTER_BIAS)))
            divergence_stage_code = 3;
        if (divergence_stage_code == 0 && trace_requant_i8 !== R1H_REF_OUTPUT_I8)
            divergence_stage_code = 4;
        if (divergence_stage_code == 0 && ram_read_byte(R1H_OUTPUT_ADDR) !== R1H_REF_OUTPUT_BYTE)
            divergence_stage_code = 5;

        $display("R1H_PACKAGE_COMPARE compared_bytes=%0d mismatch_count=%0d unknown_bytes=%0d first_mismatch=%0d expected=0x%02h actual=0x%02h actual_unknown=%0d checksum=0x%08h expected_checksum=0x%08h",
                 compared_bytes, mismatch_count, unknown_bytes, first_mismatch,
                 first_expected, first_actual, first_unknown, final_checksum, R1H_EXPECTED_CHECKSUM);

        result_fd = $fopen("tb/generated/resnet20_r1h_package_compare_rtl_result.json", "w");
        if (result_fd) begin
            $fdisplay(result_fd, "{");
            $fdisplay(result_fd, "  \"scope\": \"R1h package-faithful npu_top input.image_to_conv1 compare\",");
            $fdisplay(result_fd, "  \"task\": \"conv1\",");
            $fdisplay(result_fd, "  \"input_addr\": %0d,", R1H_INPUT_ADDR);
            $fdisplay(result_fd, "  \"output_addr\": %0d,", R1H_OUTPUT_ADDR);
            $fdisplay(result_fd, "  \"input_addr_nonzero\": true,");
            $fdisplay(result_fd, "  \"compared_bytes\": %0d,", compared_bytes);
            $fdisplay(result_fd, "  \"mismatch_count\": %0d,", mismatch_count);
            $fdisplay(result_fd, "  \"unknown_bytes\": %0d,", unknown_bytes);
            $fdisplay(result_fd, "  \"first_unknown_idx\": %0d,", first_unknown_idx);
            $fdisplay(result_fd, "  \"first_unknown_expected\": \"0x%02h\",", first_unknown_expected);
            $fdisplay(result_fd, "  \"first_mismatch\": %0d,", first_mismatch);
            $fdisplay(result_fd, "  \"first_expected\": \"0x%02h\",", first_expected);
            $fdisplay(result_fd, "  \"first_actual\": \"0x%02h\",", first_actual);
            $fdisplay(result_fd, "  \"first_actual_unknown\": %0d,", first_unknown);
            $fdisplay(result_fd, "  \"final_checksum\": \"0x%08h\",", final_checksum);
            $fdisplay(result_fd, "  \"expected_checksum\": \"0x%08h\",", R1H_EXPECTED_CHECKSUM);
            $fdisplay(result_fd, "  \"numeric_match\": %0d,", mismatch_count == 0);
            $fdisplay(result_fd, "  \"full_resnet20\": false");
            $fdisplay(result_fd, "}");
            $fclose(result_fd);
        end

        trace_fd = $fopen("tb/generated/resnet20_r1h_conv1_trace.json", "w");
        if (trace_fd) begin
            $fdisplay(trace_fd, "{");
            $fdisplay(trace_fd, "  \"scope\": \"R1h focused conv1 output(0,0,0) trace\",");
            $fdisplay(trace_fd, "  \"position\": {\"oh\": 0, \"ow\": 0, \"oc\": 0},");
            $fdisplay(trace_fd, "  \"reference\": {");
            $fdisplay(trace_fd, "    \"mac_before_bias\": %0d,", R1H_REF_MAC_BEFORE_BIAS);
            $fdisplay(trace_fd, "    \"bias_i32\": %0d,", R1H_REF_BIAS_I32);
            $fdisplay(trace_fd, "    \"acc_after_bias\": %0d,", R1H_REF_ACC_AFTER_BIAS);
            $fdisplay(trace_fd, "    \"acc_after_relu\": %0d,", R1H_REF_ACC_AFTER_RELU);
            $fdisplay(trace_fd, "    \"requant_multiplier\": %0d,", R1H_REQUANT_MULT);
            $fdisplay(trace_fd, "    \"requant_shift\": %0d,", R1H_REQUANT_SHIFT);
            $fdisplay(trace_fd, "    \"output_i8\": %0d,", R1H_REF_OUTPUT_I8);
            $fdisplay(trace_fd, "    \"output_byte\": \"0x%02h\",", R1H_REF_OUTPUT_BYTE);
            $fdisplay(trace_fd, "    \"taps\": [");
            for (t = 0; t < 27; t = t + 1) begin
                if (t == 26)
                    $fdisplay(trace_fd,
                              "      {\"tap\": %0d, \"input_idx\": %0d, \"weight_idx\": %0d, \"input_i8\": %0d, \"weight_i8\": %0d, \"product\": %0d}",
                              t, r1h_ref_input_idx[t], r1h_ref_weight_idx[t],
                              r1h_ref_input_i8[t], r1h_ref_weight_i8[t],
                              r1h_ref_product[t]);
                else
                    $fdisplay(trace_fd,
                              "      {\"tap\": %0d, \"input_idx\": %0d, \"weight_idx\": %0d, \"input_i8\": %0d, \"weight_i8\": %0d, \"product\": %0d},",
                              t, r1h_ref_input_idx[t], r1h_ref_weight_idx[t],
                              r1h_ref_input_i8[t], r1h_ref_weight_i8[t],
                              r1h_ref_product[t]);
            end
            $fdisplay(trace_fd, "    ]");
            $fdisplay(trace_fd, "  },");
            $fdisplay(trace_fd, "  \"rtl\": {");
            $fdisplay(trace_fd, "    \"window_seen_cin0\": %0d,", trace_window_seen[0]);
            $fdisplay(trace_fd, "    \"window_seen_cin1\": %0d,", trace_window_seen[1]);
            $fdisplay(trace_fd, "    \"window_seen_cin2\": %0d,", trace_window_seen[2]);
            $fdisplay(trace_fd, "    \"captured_tap_product_sum\": %0d,", trace_product_sum);
            $fdisplay(trace_fd, "    \"mac_before_bias\": %0d,", trace_mac_before_bias);
            $fdisplay(trace_fd, "    \"bias_i32\": %0d,", trace_bias_i32);
            $fdisplay(trace_fd, "    \"acc_after_bias\": %0d,", trace_acc_after_bias);
            $fdisplay(trace_fd, "    \"requant_i8\": %0d,", trace_requant_i8);
            $fdisplay(trace_fd, "    \"stored_output_bytes_0_3\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"],",
                      ram_read_byte(R1H_OUTPUT_ADDR + 0), ram_read_byte(R1H_OUTPUT_ADDR + 1),
                      ram_read_byte(R1H_OUTPUT_ADDR + 2), ram_read_byte(R1H_OUTPUT_ADDR + 3));
            $fdisplay(trace_fd, "    \"taps\": [");
            for (t = 0; t < 27; t = t + 1) begin
                if (t == 26)
                    $fdisplay(trace_fd,
                              "      {\"tap\": %0d, \"window_i8\": %0d, \"weight_i8\": %0d, \"product\": %0d, \"window_byte\": \"0x%02h\", \"weight_byte\": \"0x%02h\"}",
                              t, trace_window_i8[t], trace_weight_i8[t],
                              trace_product[t], trace_window_byte[t],
                              trace_weight_byte[t]);
                else
                    $fdisplay(trace_fd,
                              "      {\"tap\": %0d, \"window_i8\": %0d, \"weight_i8\": %0d, \"product\": %0d, \"window_byte\": \"0x%02h\", \"weight_byte\": \"0x%02h\"},",
                              t, trace_window_i8[t], trace_weight_i8[t],
                              trace_product[t], trace_window_byte[t],
                              trace_weight_byte[t]);
            end
            $fdisplay(trace_fd, "    ]");
            $fdisplay(trace_fd, "  },");
            $fdisplay(trace_fd, "  \"first_divergence_stage_code\": %0d,", divergence_stage_code);
            if (divergence_stage_code == 1)
                $fdisplay(trace_fd, "  \"first_divergence_stage\": \"input_window_or_weight_mapping_before_mac\",");
            else if (divergence_stage_code == 2)
                $fdisplay(trace_fd, "  \"first_divergence_stage\": \"mac_accumulation\",");
            else if (divergence_stage_code == 3)
                $fdisplay(trace_fd, "  \"first_divergence_stage\": \"bias_add\",");
            else if (divergence_stage_code == 4)
                $fdisplay(trace_fd, "  \"first_divergence_stage\": \"requant\",");
            else if (divergence_stage_code == 5)
                $fdisplay(trace_fd, "  \"first_divergence_stage\": \"store_packing\",");
            else
                $fdisplay(trace_fd, "  \"first_divergence_stage\": \"none_for_output_0_0_0\",");
            $fdisplay(trace_fd, "  \"not_full_resnet20\": true");
            $fdisplay(trace_fd, "}");
            $fclose(trace_fd);
        end

        acc_source_fd = $fopen("tb/generated/resnet20_r1h_conv1_acc_source_trace.json", "w");
        if (acc_source_fd) begin
            $fdisplay(acc_source_fd, "{");
            $fdisplay(acc_source_fd, "  \"scope\": \"R1h conv1 acc_buffer[0] source alignment trace\",");
            $fdisplay(acc_source_fd, "  \"target\": {\"output_byte\": 0, \"logical_output\": {\"oh\": 0, \"ow\": 0, \"oc\": 0}, \"acc_buffer_addr\": 0},");
            $fdisplay(acc_source_fd, "  \"reference\": {\"mac_before_bias\": %0d, \"bias_i32\": %0d, \"output_byte\": \"0x%02h\"},",
                      R1H_REF_MAC_BEFORE_BIAS, R1H_REF_BIAS_I32, R1H_REF_OUTPUT_BYTE);
            $fdisplay(acc_source_fd, "  \"requant_read0\": {\"seen\": %0d, \"fsm\": %0d, \"acc_data\": %0d},",
                      rq_read0_seen, rq_read0_fsm, rq_read0_acc_data);
            $fdisplay(acc_source_fd, "  \"feed_event_count\": %0d,", feed_event_count);
            $fdisplay(acc_source_fd, "  \"feed_events\": [");
            for (t = 0; t < feed_event_count; t = t + 1) begin
                if (t == feed_event_count - 1)
                    $fdisplay(acc_source_fd,
                              "    {\"event\": %0d, \"cin_idx\": %0d, \"comp_win_idx\": %0d, \"window_sum\": %0d, \"product_sum_oc0\": %0d}",
                              t, feed_event_cin[t], feed_event_win[t],
                              feed_event_window_sum[t], feed_event_product_sum[t]);
                else
                    $fdisplay(acc_source_fd,
                              "    {\"event\": %0d, \"cin_idx\": %0d, \"comp_win_idx\": %0d, \"window_sum\": %0d, \"product_sum_oc0\": %0d},",
                              t, feed_event_cin[t], feed_event_win[t],
                              feed_event_window_sum[t], feed_event_product_sum[t]);
            end
            $fdisplay(acc_source_fd, "  ],");
            $fdisplay(acc_source_fd, "  \"acc0_event_count\": %0d,", acc0_event_count);
            $fdisplay(acc_source_fd, "  \"acc0_write_events\": [");
            for (t = 0; t < acc0_event_count; t = t + 1) begin
                if (t == acc0_event_count - 1)
                    $fdisplay(acc_source_fd,
                              "    {\"event\": %0d, \"fsm\": %0d, \"sub\": %0d, \"cin_idx\": %0d, \"comp_win_idx\": %0d, \"acc_col_idx\": %0d, \"wr_addr\": %0d, \"acc_partial_addr\": %0d, \"acc_wr_ptr\": %0d, \"col_result0\": \"%0d\", \"col_result_selected\": \"%0d\", \"acc_rd_data\": \"%0d\", \"acc_wr_data\": \"%0d\"}",
                              t, acc0_event_fsm[t], acc0_event_sub[t], acc0_event_cin[t],
                              acc0_event_win[t], acc0_event_col[t], acc0_event_wr_addr[t],
                              acc0_event_partial_addr[t], acc0_event_wr_ptr[t],
                              acc0_event_col_result[t], acc0_event_col_result_selected[t],
                              acc0_event_rd_data[t],
                              acc0_event_wr_data[t]);
                else
                    $fdisplay(acc_source_fd,
                              "    {\"event\": %0d, \"fsm\": %0d, \"sub\": %0d, \"cin_idx\": %0d, \"comp_win_idx\": %0d, \"acc_col_idx\": %0d, \"wr_addr\": %0d, \"acc_partial_addr\": %0d, \"acc_wr_ptr\": %0d, \"col_result0\": \"%0d\", \"col_result_selected\": \"%0d\", \"acc_rd_data\": \"%0d\", \"acc_wr_data\": \"%0d\"},",
                              t, acc0_event_fsm[t], acc0_event_sub[t], acc0_event_cin[t],
                              acc0_event_win[t], acc0_event_col[t], acc0_event_wr_addr[t],
                              acc0_event_partial_addr[t], acc0_event_wr_ptr[t],
                              acc0_event_col_result[t], acc0_event_col_result_selected[t],
                              acc0_event_rd_data[t],
                              acc0_event_wr_data[t]);
            end
            $fdisplay(acc_source_fd, "  ],");
            if ((acc0_event_count > 0) && (rq_read0_acc_data == acc0_event_wr_data[acc0_event_count - 1]))
                $fdisplay(acc_source_fd, "  \"rq_read_matches_last_acc0_write\": true,");
            else
                $fdisplay(acc_source_fd, "  \"rq_read_matches_last_acc0_write\": false,");
            $fdisplay(acc_source_fd, "  \"not_full_resnet20\": true");
            $fdisplay(acc_source_fd, "}");
            $fclose(acc_source_fd);
        end

        window_truth_fd = $fopen("tb/generated/resnet20_r1h_conv1_window_truth.json", "w");
        if (window_truth_fd) begin
            $fdisplay(window_truth_fd, "{");
            $fdisplay(window_truth_fd, "  \"scope\": \"R1h conv1 same-padding window truth for output(0,0,0)\",");
            $fdisplay(window_truth_fd, "  \"expected_semantics\": \"3x3 same stride1: top row and left column are zero padding; input[0..5] map to taps 12..17; input[96..101] map to taps 21..26\",");
            $fdisplay(window_truth_fd, "  \"reference_mac_before_bias\": %0d,", R1H_REF_MAC_BEFORE_BIAS);
            $fdisplay(window_truth_fd, "  \"rtl_captured_tap_product_sum\": %0d,", trace_product_sum);
            $fdisplay(window_truth_fd, "  \"mapping_match_for_output_0_0_0\": %0d,", trace_product_sum == R1H_REF_MAC_BEFORE_BIAS);
            $fdisplay(window_truth_fd, "  \"rtl_taps\": [");
            for (t = 0; t < 27; t = t + 1) begin
                if (t == 26)
                    $fdisplay(window_truth_fd,
                              "    {\"tap\": %0d, \"window_i8\": %0d, \"weight_i8\": %0d, \"product\": %0d}",
                              t, trace_window_i8[t], trace_weight_i8[t], trace_product[t]);
                else
                    $fdisplay(window_truth_fd,
                              "    {\"tap\": %0d, \"window_i8\": %0d, \"weight_i8\": %0d, \"product\": %0d},",
                              t, trace_window_i8[t], trace_weight_i8[t], trace_product[t]);
            end
            $fdisplay(window_truth_fd, "  ],");
            $fdisplay(window_truth_fd, "  \"not_full_resnet20\": true");
            $fdisplay(window_truth_fd, "}");
            $fclose(window_truth_fd);
        end

        acc_truth_fd = $fopen("tb/generated/resnet20_r1h_conv1_acc_ownership_truth.json", "w");
        if (acc_truth_fd) begin
            $fdisplay(acc_truth_fd, "{");
            $fdisplay(acc_truth_fd, "  \"scope\": \"R1h conv1 acc ownership truth for output(0,0,0)\",");
            $fdisplay(acc_truth_fd, "  \"expected_owner\": {\"logical_output\": {\"oh\": 0, \"ow\": 0, \"oc\": 0}, \"acc_buffer_addr\": 0},");
            $fdisplay(acc_truth_fd, "  \"reference_mac_before_bias\": %0d,", R1H_REF_MAC_BEFORE_BIAS);
            $fdisplay(acc_truth_fd, "  \"rtl_requant_read0_acc_data\": %0d,", rq_read0_acc_data);
            $fdisplay(acc_truth_fd, "  \"ownership_match_for_output_0_0_0\": %0d,", rq_read0_acc_data == R1H_REF_MAC_BEFORE_BIAS);
            $fdisplay(acc_truth_fd, "  \"acc0_write_event_count\": %0d,", acc0_event_count);
            $fdisplay(acc_truth_fd, "  \"acc0_write_events\": [");
            for (t = 0; t < acc0_event_count; t = t + 1) begin
                if (t == acc0_event_count - 1)
                    $fdisplay(acc_truth_fd,
                              "    {\"event\": %0d, \"fsm\": %0d, \"cin_idx\": %0d, \"comp_win_idx\": %0d, \"acc_col_idx\": %0d, \"wr_addr\": %0d, \"acc_wr_data\": \"%0d\", \"is_collect\": %0d, \"is_internal_requant\": %0d}",
                              t, acc0_event_fsm[t], acc0_event_cin[t], acc0_event_win[t],
                              acc0_event_col[t], acc0_event_wr_addr[t], acc0_event_wr_data[t],
                              acc0_event_is_collect[t], acc0_event_is_requant[t]);
                else
                    $fdisplay(acc_truth_fd,
                              "    {\"event\": %0d, \"fsm\": %0d, \"cin_idx\": %0d, \"comp_win_idx\": %0d, \"acc_col_idx\": %0d, \"wr_addr\": %0d, \"acc_wr_data\": \"%0d\", \"is_collect\": %0d, \"is_internal_requant\": %0d},",
                              t, acc0_event_fsm[t], acc0_event_cin[t], acc0_event_win[t],
                              acc0_event_col[t], acc0_event_wr_addr[t], acc0_event_wr_data[t],
                              acc0_event_is_collect[t], acc0_event_is_requant[t]);
            end
            $fdisplay(acc_truth_fd, "  ],");
            $fdisplay(acc_truth_fd, "  \"ownership_model\": \"logical_index=(oh*32+ow)*16+oc; collect owner acc_buffer[logical_index]; dense INT8 store owner byte[logical_index]\",");
            $fdisplay(acc_truth_fd, "  \"late_addr0_write_classification\": \"fsm21 is the legal internal requant overwrite for logical output byte0, not an unrelated collect write\",");
            $fdisplay(acc_truth_fd, "  \"forbidden_collect_write\": \"any CP_COLLECT write whose logical_index is outside 0..16383 or whose address differs from logical_index\",");
            $fdisplay(acc_truth_fd, "  \"collect_write_count\": %0d,", collect_write_count);
            $fdisplay(acc_truth_fd, "  \"collect_bad_owner_count\": %0d,", collect_bad_owner_count);
            $fdisplay(acc_truth_fd, "  \"collect_first_bad_actual\": %0d,", collect_first_bad_actual);
            $fdisplay(acc_truth_fd, "  \"collect_first_bad_expected\": %0d,", collect_first_bad_expected);
            $fdisplay(acc_truth_fd, "  \"collect_duplicate_count\": %0d,", collect_duplicate_count);
            $fdisplay(acc_truth_fd, "  \"collect_first_duplicate\": {\"cin_idx\": %0d, \"comp_win_idx\": %0d, \"acc_col_idx\": %0d},",
                      collect_first_duplicate_cin, collect_first_duplicate_win,
                      collect_first_duplicate_col);
            $fdisplay(acc_truth_fd, "  \"logical16_trace\": {");
            $fdisplay(acc_truth_fd, "    \"expected_owner\": {\"logical_index\": 16, \"oh\": 0, \"ow\": 1, \"oc\": 0, \"acc_buffer_addr\": 16, \"dense_store_byte_offset\": 16},");
            $fdisplay(acc_truth_fd, "    \"acc16_write_event_count\": %0d,", acc16_event_count);
            $fdisplay(acc_truth_fd, "    \"acc16_write_events\": [");
            for (t = 0; t < acc16_event_count; t = t + 1) begin
                if (t == acc16_event_count - 1)
                    $fdisplay(acc_truth_fd,
                              "      {\"event\": %0d, \"fsm\": %0d, \"cin_idx\": %0d, \"comp_win_idx\": %0d, \"acc_col_idx\": %0d, \"wr_data\": \"%0d\", \"unknown\": %0d}",
                              t, acc16_event_fsm[t], acc16_event_cin[t], acc16_event_win[t],
                              acc16_event_col[t], acc16_event_wr_data[t], acc16_event_unknown[t]);
                else
                    $fdisplay(acc_truth_fd,
                              "      {\"event\": %0d, \"fsm\": %0d, \"cin_idx\": %0d, \"comp_win_idx\": %0d, \"acc_col_idx\": %0d, \"wr_data\": \"%0d\", \"unknown\": %0d},",
                              t, acc16_event_fsm[t], acc16_event_cin[t], acc16_event_win[t],
                              acc16_event_col[t], acc16_event_wr_data[t], acc16_event_unknown[t]);
            end
            $fdisplay(acc_truth_fd, "    ],");
            $fdisplay(acc_truth_fd, "    \"requant_read_acc_data\": \"%0d\",", rq_read16_acc_data);
            $fdisplay(acc_truth_fd, "    \"requant_read_acc_unknown\": %0d,", rq_read16_acc_unknown);
            $fdisplay(acc_truth_fd, "    \"requant_q\": \"%0d\",", rq_read16_q);
            $fdisplay(acc_truth_fd, "    \"requant_q_unknown\": %0d", rq_read16_q_unknown);
            $fdisplay(acc_truth_fd, "  },");
            $fdisplay(acc_truth_fd, "  \"not_full_resnet20\": true");
            $fdisplay(acc_truth_fd, "}");
            $fclose(acc_truth_fd);
        end

        byte3_trace_fd = $fopen("tb/generated/resnet20_r1h_conv1_byte3_trace.json", "w");
        if (byte3_trace_fd) begin
            $fdisplay(byte3_trace_fd, "{");
            $fdisplay(byte3_trace_fd, "  \"scope\": \"R1h conv1 byte3 ownership trace\",");
            $fdisplay(byte3_trace_fd, "  \"logical_output\": {\"index\": 3, \"oh\": 0, \"ow\": 0, \"oc\": 3},");
            $fdisplay(byte3_trace_fd, "  \"expected_owner\": {\"acc_buffer_addr\": 3, \"dense_store_byte_offset\": 3, \"expected_byte\": \"0x%02h\"},", r1h_expected_byte[3]);
            $fdisplay(byte3_trace_fd, "  \"requant_read\": {\"seen\": %0d, \"fsm\": %0d, \"acc_data\": %0d, \"bias\": %0d, \"acc_after_bias\": %0d, \"q_i8\": %0d, \"q_byte\": \"0x%02h\", \"word_store_mode\": %0d},",
                      rq_read3_seen, rq_read3_fsm, rq_read3_acc_data, rq_read3_bias,
                      rq_read3_acc_after_bias, rq_read3_q, rq_read3_q[7:0],
                      rq_read3_word_store_mode);
            $fdisplay(byte3_trace_fd, "  \"acc3_write_event_count\": %0d,", acc3_event_count);
            $fdisplay(byte3_trace_fd, "  \"acc3_write_events\": [");
            for (t = 0; t < acc3_event_count; t = t + 1) begin
                if (t == acc3_event_count - 1)
                    $fdisplay(byte3_trace_fd,
                              "    {\"event\": %0d, \"fsm\": %0d, \"sub\": %0d, \"cin_idx\": %0d, \"comp_win_idx\": %0d, \"acc_col_idx\": %0d, \"wr_addr\": %0d, \"wr_data\": \"%0d\", \"is_collect\": %0d, \"is_internal_requant\": %0d}",
                              t, acc3_event_fsm[t], acc3_event_sub[t], acc3_event_cin[t],
                              acc3_event_win[t], acc3_event_col[t], acc3_event_wr_addr[t],
                              acc3_event_wr_data[t], acc3_event_is_collect[t], acc3_event_is_requant[t]);
                else
                    $fdisplay(byte3_trace_fd,
                              "    {\"event\": %0d, \"fsm\": %0d, \"sub\": %0d, \"cin_idx\": %0d, \"comp_win_idx\": %0d, \"acc_col_idx\": %0d, \"wr_addr\": %0d, \"wr_data\": \"%0d\", \"is_collect\": %0d, \"is_internal_requant\": %0d},",
                              t, acc3_event_fsm[t], acc3_event_sub[t], acc3_event_cin[t],
                              acc3_event_win[t], acc3_event_col[t], acc3_event_wr_addr[t],
                              acc3_event_wr_data[t], acc3_event_is_collect[t], acc3_event_is_requant[t]);
            end
            $fdisplay(byte3_trace_fd, "  ],");
            $fdisplay(byte3_trace_fd, "  \"stored_bytes_0_15\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"],",
                      ram_read_byte(R1H_OUTPUT_ADDR + 0), ram_read_byte(R1H_OUTPUT_ADDR + 1),
                      ram_read_byte(R1H_OUTPUT_ADDR + 2), ram_read_byte(R1H_OUTPUT_ADDR + 3),
                      ram_read_byte(R1H_OUTPUT_ADDR + 4), ram_read_byte(R1H_OUTPUT_ADDR + 5),
                      ram_read_byte(R1H_OUTPUT_ADDR + 6), ram_read_byte(R1H_OUTPUT_ADDR + 7),
                      ram_read_byte(R1H_OUTPUT_ADDR + 8), ram_read_byte(R1H_OUTPUT_ADDR + 9),
                      ram_read_byte(R1H_OUTPUT_ADDR + 10), ram_read_byte(R1H_OUTPUT_ADDR + 11),
                      ram_read_byte(R1H_OUTPUT_ADDR + 12), ram_read_byte(R1H_OUTPUT_ADDR + 13),
                      ram_read_byte(R1H_OUTPUT_ADDR + 14), ram_read_byte(R1H_OUTPUT_ADDR + 15));
            $fdisplay(byte3_trace_fd, "  \"pre_fix_root_cause\": \"q3 was owned by acc_buffer[3] but lane0-word store placed it at byte12 while package dense HWC requires byte3\",");
            if (rq_read3_word_store_mode)
                $fdisplay(byte3_trace_fd, "  \"post_fix_ownership_status\": \"error_word_store_mode_still_active\",");
            else
                $fdisplay(byte3_trace_fd, "  \"post_fix_ownership_status\": \"dense packed requant maps q3 to stored byte3\",");
            $fdisplay(byte3_trace_fd, "  \"not_full_resnet20\": true");
            $fdisplay(byte3_trace_fd, "}");
            $fclose(byte3_trace_fd);
        end

        debug_fd = $fopen("tb/generated/resnet20_r1h_package_compare_debug_summary.json", "w");
        if (debug_fd) begin
            $fdisplay(debug_fd, "{");
            $fdisplay(debug_fd, "  \"scope\": \"R1h package-faithful conv1 debug summary\",");
            $fdisplay(debug_fd, "  \"compared_bytes\": %0d,", compared_bytes);
            $fdisplay(debug_fd, "  \"mismatch_count\": %0d,", mismatch_count);
            $fdisplay(debug_fd, "  \"unknown_bytes\": %0d,", unknown_bytes);
            $fdisplay(debug_fd, "  \"first_mismatch\": %0d,", first_mismatch);
            $fdisplay(debug_fd, "  \"first_unknown_idx\": %0d,", first_unknown_idx);
            $fdisplay(debug_fd, "  \"first_unknown_position_dense_hwc\": {\"oh\": %0d, \"ow\": %0d, \"oc\": %0d},",
                      first_unknown_oh, first_unknown_ow, first_unknown_oc);
            $fdisplay(debug_fd, "  \"first_divergence_stage_code\": %0d,", divergence_stage_code);
            if (divergence_stage_code == 1)
                $fdisplay(debug_fd, "  \"first_divergence_stage\": \"input_window_or_weight_mapping_before_mac\",");
            else if (divergence_stage_code == 2)
                $fdisplay(debug_fd, "  \"first_divergence_stage\": \"mac_accumulation\",");
            else if (divergence_stage_code == 3)
                $fdisplay(debug_fd, "  \"first_divergence_stage\": \"bias_add\",");
            else if (divergence_stage_code == 4)
                $fdisplay(debug_fd, "  \"first_divergence_stage\": \"requant\",");
            else if (divergence_stage_code == 5)
                $fdisplay(debug_fd, "  \"first_divergence_stage\": \"store_packing\",");
            else
                $fdisplay(debug_fd, "  \"first_divergence_stage\": \"none_for_output_0_0_0\",");
            if (first_unknown_idx >= 0)
                $fdisplay(debug_fd, "  \"unknown_origin_hypothesis\": \"single final output byte is unknown at dense HWC decoded position; likely store/packing or source-index follow-up, not address-contract failure\",");
            else
                $fdisplay(debug_fd, "  \"unknown_origin_hypothesis\": \"no_unknown_output_byte_observed\",");
            $fdisplay(debug_fd, "  \"trace_path\": \"tb/generated/resnet20_r1h_conv1_trace.json\",");
            $fdisplay(debug_fd, "  \"acc_source_trace_path\": \"tb/generated/resnet20_r1h_conv1_acc_source_trace.json\",");
            $fdisplay(debug_fd, "  \"window_truth_path\": \"tb/generated/resnet20_r1h_conv1_window_truth.json\",");
            $fdisplay(debug_fd, "  \"acc_ownership_truth_path\": \"tb/generated/resnet20_r1h_conv1_acc_ownership_truth.json\",");
            $fdisplay(debug_fd, "  \"not_full_resnet20\": true");
            $fdisplay(debug_fd, "}");
            $fclose(debug_fd);
        end

        $display("tb_resnet20_r1h_package_compare PASS compare_completed=1 numeric_match=%0d",
                 mismatch_count == 0);
        $finish;
    end
endmodule
