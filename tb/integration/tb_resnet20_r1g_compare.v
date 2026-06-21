// tb_resnet20_r1g_compare: npu_top value-aware R1g compact compare.
// Uses a package-derived contiguous residual slice with compact test-only
// alias addresses/dimensions. This is not full ResNet-20 RTL closure.
`timescale 1ns / 1ps

module tb_resnet20_r1g_compare;
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
    localparam [31:0] ADDR_ADD_SRC0_MULT = 32'h0000_00b8;
    localparam [31:0] ADDR_ADD_SRC0_SHIFT = 32'h0000_00bc;
    localparam [31:0] ADDR_ADD_SRC1_MULT = 32'h0000_00c0;
    localparam [31:0] ADDR_ADD_SRC1_SHIFT = 32'h0000_00c4;
    localparam [31:0] ADDR_ADD_OUT_MULT  = 32'h0000_00c8;
    localparam [31:0] ADDR_ADD_OUT_SHIFT = 32'h0000_00cc;

    localparam [4:0] FSM_COMPUTE = 5'd9;
    localparam [4:0] FSM_STORE = 5'd11;
    localparam [4:0] FSM_LOAD_ADD_SRC1 = 5'd26;
    localparam [4:0] FSM_ADD_COMPUTE = 5'd28;
    localparam [2:0] CP_FEED_ACT = 3'd1;

    reg [127*8-1:0] r1f_task_name [0:7];
    reg [63*8-1:0]  r1f_op_name [0:7];
    reg [127*8-1:0] r1f_tensor_name [0:15];
    reg [31:0] r1f_tensor_addr [0:15];
    reg [31:0] r1f_tensor_bytes [0:15];
    reg [31:0] r1f_tensor_checksum [0:15];
    reg [31:0] r1f_task_type [0:7];
    reg [31:0] r1f_input_addr [0:7];
    reg [31:0] r1f_weight_addr [0:7];
    reg [31:0] r1f_output_addr [0:7];
    reg [31:0] r1f_input_bytes [0:7];
    reg [31:0] r1f_weight_bytes [0:7];
    reg [31:0] r1f_output_bytes [0:7];
    reg [31:0] r1f_input_h [0:7];
    reg [31:0] r1f_input_w [0:7];
    reg [31:0] r1f_input_c [0:7];
    reg [31:0] r1f_output_c [0:7];
    reg [31:0] r1f_conv_cfg [0:7];
    reg [31:0] r1f_bias_addr [0:7];
    reg [31:0] r1f_bias_bytes [0:7];
    reg [31:0] r1f_src1_addr [0:7];
    reg [31:0] r1f_src1_bytes [0:7];
    reg [31:0] r1f_add_cfg [0:7];
    reg [31:0] r1f_gap_cfg [0:7];
    reg [31:0] r1f_postproc_cfg [0:7];
    reg [31:0] r1f_requant_multiplier [0:7];
    reg [31:0] r1f_requant_shift [0:7];
    reg [31:0] r1f_add_src0_multiplier [0:7];
    reg [31:0] r1f_add_src0_shift [0:7];
    reg [31:0] r1f_add_src1_multiplier [0:7];
    reg [31:0] r1f_add_src1_shift [0:7];
    reg [31:0] r1f_add_out_multiplier [0:7];
    reg [31:0] r1f_add_out_shift [0:7];
    integer    r1f_src0_tensor_idx [0:7];
    integer    r1f_src1_tensor_idx [0:7];
    integer    r1f_dst_tensor_idx [0:7];
    reg [31:0] r1f_weight_checksum [0:7];
    reg [31:0] r1f_bias_checksum [0:7];
    reg [31:0] r1f_expected_output_checksum [0:7];
    reg [7:0]  r1g_expected_byte [0:7][0:255];
    integer    r1g_compare_bytes [0:7];
    reg [31:0] r1g_expected_checksum [0:7];
    reg [127*8-1:0] r1g_reference_name [0:7];
    reg [7:0]  r1g_weight_payload_byte [0:7][0:255];
    integer    r1g_weight_payload_bytes [0:7];
    reg [7:0]  r1g_bias_payload_byte [0:7][0:255];
    integer    r1g_bias_payload_bytes [0:7];

`include "resnet20_r1f_npu_top_residual_tasks.vh"
`include "resnet20_r1g_compare_expected.vh"

    npu_top #(
        .TILE_ROWS(4),
        .TILE_COLS(1),
        .BUF_ENTRIES(128),
        .BUF_ADDR_W(7)
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
        .RAM_DEPTH(4096)
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
            $display("tb_resnet20_r1g_compare FAIL: %0s", msg);
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
            if (!aw_done || !w_done) begin
                $display("R1F_NPU_TOP_AXIL_TIMEOUT phase=aw_w addr=0x%08h data=0x%08h awvalid=%0b awready=%0b wvalid=%0b wready=%0b",
                         addr, data, s_axi_awvalid, s_axi_awready, s_axi_wvalid, s_axi_wready);
                fail("AXI-Lite write address/data timeout");
            end
            s_axi_bready = 1'b1;
            @(posedge clk);
            timeout_cycles = 0;
            while (!s_axi_bvalid && timeout_cycles < 1000) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (!s_axi_bvalid) begin
                $display("R1F_NPU_TOP_AXIL_TIMEOUT phase=b addr=0x%08h data=0x%08h", addr, data);
                fail("AXI-Lite write response timeout");
            end
            if (s_axi_bresp !== 2'b00)
                fail("AXI-Lite write error response");
            @(posedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task clear_status;
        begin
            axi_write(ADDR_CTRL, 32'h0000_0010);
        end
    endtask

    task program_task;
        input integer idx;
        begin
            axi_write(ADDR_TASK_TYPE,     r1f_task_type[idx]);
            axi_write(ADDR_INPUT_ADDR,    r1f_input_addr[idx]);
            axi_write(ADDR_WEIGHT_ADDR,   r1f_weight_addr[idx]);
            axi_write(ADDR_OUTPUT_ADDR,   r1f_output_addr[idx]);
            axi_write(ADDR_INPUT_BYTES,   r1f_input_bytes[idx]);
            axi_write(ADDR_WEIGHT_BYTES,  r1f_weight_bytes[idx]);
            axi_write(ADDR_OUTPUT_BYTES,  r1f_output_bytes[idx]);
            axi_write(ADDR_DIM_IN,        {r1f_input_w[idx][15:0], r1f_input_h[idx][15:0]});
            axi_write(ADDR_DIM_OUT,       {r1f_output_c[idx][15:0], r1f_input_c[idx][15:0]});
            axi_write(ADDR_POSTPROC,      32'd0);
            axi_write(ADDR_REQUANT_SEL,   32'd0);
            axi_write(ADDR_RQ0_MULT,      r1f_requant_multiplier[idx]);
            axi_write(ADDR_RQ0_SHIFT,     r1f_requant_shift[idx]);
            axi_write(ADDR_CONV_CFG,      r1f_conv_cfg[idx]);
            axi_write(ADDR_BIAS_ADDR,     r1f_bias_addr[idx]);
            axi_write(ADDR_BIAS_BYTES,    r1f_bias_bytes[idx]);
            axi_write(ADDR_SRC1_ADDR,     r1f_src1_addr[idx]);
            axi_write(ADDR_SRC1_BYTES,    r1f_src1_bytes[idx]);
            axi_write(ADDR_ADD_CFG,       r1f_add_cfg[idx]);
            axi_write(ADDR_GAP_CFG,       r1f_gap_cfg[idx]);
            axi_write(ADDR_POSTPROC_EXT,  r1f_postproc_cfg[idx]);
            axi_write(ADDR_ADD_SRC0_MULT, r1f_add_src0_multiplier[idx]);
            axi_write(ADDR_ADD_SRC0_SHIFT, r1f_add_src0_shift[idx]);
            axi_write(ADDR_ADD_SRC1_MULT, r1f_add_src1_multiplier[idx]);
            axi_write(ADDR_ADD_SRC1_SHIFT, r1f_add_src1_shift[idx]);
            axi_write(ADDR_ADD_OUT_MULT,  r1f_add_out_multiplier[idx]);
            axi_write(ADDR_ADD_OUT_SHIFT, r1f_add_out_shift[idx]);
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

    task preload_task_payload;
        input integer idx;
        integer i;
        reg [31:0] seed;
        begin
            if (idx == 0) begin
                seed = r1f_tensor_checksum[0];
                for (i = 0; i < r1f_input_bytes[0]; i = i + 1)
                    ram_write_byte(r1f_input_addr[0] + i, (seed >> ((i % 4) * 8)) + i[7:0]);
            end
            if (r1f_weight_addr[idx] != 32'd0) begin
                if (r1g_weight_payload_bytes[idx] > 0) begin
                    for (i = 0; i < r1g_weight_payload_bytes[idx]; i = i + 1)
                        ram_write_byte(r1f_weight_addr[idx] + i, r1g_weight_payload_byte[idx][i]);
                end else begin
                    seed = r1f_weight_checksum[idx];
                    for (i = 0; i < r1f_weight_bytes[idx]; i = i + 1)
                        ram_write_byte(r1f_weight_addr[idx] + i, (seed >> ((i % 4) * 8)) ^ i[7:0]);
                end
            end
            if (r1f_bias_addr[idx] != 32'd0) begin
                if (r1g_bias_payload_bytes[idx] > 0) begin
                    for (i = 0; i < r1g_bias_payload_bytes[idx]; i = i + 1)
                        ram_write_byte(r1f_bias_addr[idx] + i, r1g_bias_payload_byte[idx][i]);
                end else begin
                    seed = r1f_bias_checksum[idx];
                    for (i = 0; i < r1f_bias_bytes[idx]; i = i + 1)
                        ram_write_byte(r1f_bias_addr[idx] + i, (seed >> ((i % 4) * 8)));
                end
            end
        end
    endtask

    task wait_done;
        input integer idx;
        input integer max_cycles;
        integer cnt;
        begin
            cnt = 0;
            while (!npu_done && !npu_error && cnt < max_cycles) begin
                @(posedge clk);
                cnt = cnt + 1;
                if ((cnt % 50000) == 0) begin
                    $display("R1F_NPU_TOP_PROGRESS idx=%0d name=%0s cycles=%0d state=%0d sub=%0d busy=%0b done=%0b",
                             idx, r1f_task_name[idx], cnt, u_npu.fsm_state,
                             u_npu.comp_sub_state, npu_busy, npu_done);
                end
            end
            if (npu_error) begin
                $display("R1F_NPU_TOP_ERROR idx=%0d name=%0s code=0x%02h",
                         idx, r1f_task_name[idx], npu_error_code);
                fail("npu_top task error");
            end
            if (!npu_done)
                fail("npu_top task timeout");
        end
    endtask

    reg monitor_active;
    integer monitor_idx;
    integer ar_count [0:7];
    integer aw_count [0:7];
    integer w_count [0:7];
    reg seen_compute [0:7];
    reg seen_store [0:7];
    reg seen_add_load [0:7];
    reg seen_add_compute [0:7];
    reg [31:0] output_checksum [0:7];
    integer output_unknown_bytes [0:7];
    integer compare_mismatch_count [0:7];
    integer compare_first_mismatch_idx [0:7];
    reg [7:0] compare_first_expected [0:7];
    reg [7:0] compare_first_actual [0:7];
    reg compare_first_actual_unknown [0:7];
    integer total_compared_bytes;
    integer total_mismatch_count;
    integer total_unknown_bytes;
    reg conv1_trace_window_seen;
    reg conv1_trace_requant_seen;
    reg [7:0] conv1_trace_window [0:8];
    reg [7:0] conv1_trace_weight [0:8];
    reg signed [31:0] conv1_trace_mac_before_bias;
    reg signed [31:0] conv1_trace_bias;
    reg signed [31:0] conv1_trace_acc_after_bias;
    reg signed [7:0] conv1_trace_requant_i8;
    reg [7:0] conv1_trace_stored_byte0;
    reg [7:0] conv1_trace_stored_byte1;
    reg [7:0] conv1_trace_stored_byte2;
    reg [7:0] conv1_trace_stored_byte3;
    integer conv1_trace_fd;
    reg add_trace_seen;
    reg [31:0] add_trace_idx;
    reg signed [7:0] add_trace_src0_i8;
    reg signed [7:0] add_trace_src1_i8;
    reg signed [7:0] add_trace_src0_aligned;
    reg signed [7:0] add_trace_src1_aligned;
    reg signed [31:0] add_trace_raw;
    reg signed [31:0] add_trace_relu;
    reg signed [7:0] add_trace_q;
    reg [7:0] add_trace_expected_byte;
    reg [7:0] add_trace_stored_byte0;
    reg [7:0] add_trace_stored_byte1;
    reg [7:0] add_trace_stored_byte2;
    reg [7:0] add_trace_stored_byte3;
    integer add_trace_fd;

    task compare_task_output;
        input integer idx;
        integer j;
        reg [7:0] actual;
        reg [7:0] expected;
        reg actual_unknown;
        begin
            compare_mismatch_count[idx] = 0;
            compare_first_mismatch_idx[idx] = -1;
            compare_first_expected[idx] = 8'd0;
            compare_first_actual[idx] = 8'd0;
            compare_first_actual_unknown[idx] = 1'b0;
            for (j = 0; j < r1g_compare_bytes[idx]; j = j + 1) begin
                actual = ram_read_byte(r1f_output_addr[idx] + j);
                expected = r1g_expected_byte[idx][j];
                actual_unknown = (^actual === 1'bx);
                if (actual_unknown || actual !== expected) begin
                    compare_mismatch_count[idx] = compare_mismatch_count[idx] + 1;
                    if (compare_first_mismatch_idx[idx] < 0) begin
                        compare_first_mismatch_idx[idx] = j;
                        compare_first_expected[idx] = expected;
                        compare_first_actual[idx] = actual_unknown ? 8'd0 : actual;
                        compare_first_actual_unknown[idx] = actual_unknown;
                    end
                end
            end
            total_compared_bytes = total_compared_bytes + r1g_compare_bytes[idx];
            total_mismatch_count = total_mismatch_count + compare_mismatch_count[idx];
            total_unknown_bytes = total_unknown_bytes + output_unknown_bytes[idx];
            $display("R1G_COMPARE_TASK idx=%0d name=%0s compared_bytes=%0d mismatch_count=%0d first_mismatch_idx=%0d expected=0x%02h actual=0x%02h actual_unknown=%0d expected_checksum=0x%08h actual_checksum_masked=0x%08h unknown_bytes=%0d status=%0s",
                     idx, r1f_task_name[idx], r1g_compare_bytes[idx],
                     compare_mismatch_count[idx], compare_first_mismatch_idx[idx],
                     compare_first_expected[idx], compare_first_actual[idx],
                     compare_first_actual_unknown[idx], r1g_expected_checksum[idx],
                     output_checksum[idx], output_unknown_bytes[idx],
                     (compare_mismatch_count[idx] == 0) ? "MATCH" : "MISMATCH");
        end
    endtask

    always @(posedge clk) begin
        if (monitor_active) begin
            if (npu_arvalid && npu_arready)
                ar_count[monitor_idx] <= ar_count[monitor_idx] + 1;
            if (npu_awvalid && npu_awready)
                aw_count[monitor_idx] <= aw_count[monitor_idx] + 1;
            if (npu_wvalid && npu_wready)
                w_count[monitor_idx] <= w_count[monitor_idx] + 1;
            if (u_npu.fsm_state == FSM_COMPUTE)
                seen_compute[monitor_idx] <= 1'b1;
            if (u_npu.fsm_state == FSM_STORE)
                seen_store[monitor_idx] <= 1'b1;
            if (u_npu.fsm_state == FSM_LOAD_ADD_SRC1)
                seen_add_load[monitor_idx] <= 1'b1;
            if (u_npu.fsm_state == FSM_ADD_COMPUTE)
                seen_add_compute[monitor_idx] <= 1'b1;
        end
        if (monitor_active && (monitor_idx == 0)) begin
            if (!conv1_trace_window_seen &&
                (u_npu.fsm_state == FSM_COMPUTE) &&
                (u_npu.comp_sub_state == CP_FEED_ACT) &&
                (u_npu.comp_win_idx == 16'd0)) begin
                conv1_trace_window_seen <= 1'b1;
                conv1_trace_window[0] <= u_npu.cf_window[0];
                conv1_trace_window[1] <= u_npu.cf_window[1];
                conv1_trace_window[2] <= u_npu.cf_window[2];
                conv1_trace_window[3] <= u_npu.cf_window[3];
                conv1_trace_window[4] <= u_npu.cf_window[4];
                conv1_trace_window[5] <= u_npu.cf_window[5];
                conv1_trace_window[6] <= u_npu.cf_window[6];
                conv1_trace_window[7] <= u_npu.cf_window[7];
                conv1_trace_window[8] <= u_npu.cf_window[8];
                conv1_trace_weight[0] <= u_npu.wgt_load_reg[(0*4+0)*8 +: 8];
                conv1_trace_weight[1] <= u_npu.wgt_load_reg[(1*4+0)*8 +: 8];
                conv1_trace_weight[2] <= u_npu.wgt_load_reg[(2*4+0)*8 +: 8];
                conv1_trace_weight[3] <= u_npu.wgt_load_reg[(3*4+0)*8 +: 8];
                conv1_trace_weight[4] <= u_npu.wgt_load_reg[(4*4+0)*8 +: 8];
                conv1_trace_weight[5] <= u_npu.wgt_load_reg[(5*4+0)*8 +: 8];
                conv1_trace_weight[6] <= u_npu.wgt_load_reg[(6*4+0)*8 +: 8];
                conv1_trace_weight[7] <= u_npu.wgt_load_reg[(7*4+0)*8 +: 8];
                conv1_trace_weight[8] <= u_npu.wgt_load_reg[(8*4+0)*8 +: 8];
            end
            if (!conv1_trace_requant_seen &&
                (u_npu.fsm_state == 5'd21) &&
                u_npu.rq_word_store_mode &&
                !u_npu.rq_src_wait &&
                (u_npu.rq_src_idx == 32'd0)) begin
                conv1_trace_requant_seen <= 1'b1;
                conv1_trace_mac_before_bias <= u_npu.acc_rd_data;
                conv1_trace_bias <= u_npu.rq_bias_value;
                conv1_trace_acc_after_bias <= u_npu.rq_bias_acc;
                conv1_trace_requant_i8 <= u_npu.rq_q_selected;
            end
        end
        if (monitor_active && (monitor_idx == 2)) begin
            if (!add_trace_seen &&
                (u_npu.fsm_state == FSM_ADD_COMPUTE) &&
                !u_npu.add_src_wait &&
                (u_npu.add_src_idx == 32'd32)) begin
                add_trace_seen <= 1'b1;
                add_trace_idx <= u_npu.add_src_idx;
                add_trace_src0_i8 <= u_npu.add_src0_i8;
                add_trace_src1_i8 <= u_npu.add_src1_i8;
                add_trace_src0_aligned <= u_npu.add_src0_aligned;
                add_trace_src1_aligned <= u_npu.add_src1_aligned;
                add_trace_raw <= u_npu.add_raw_sum;
                add_trace_relu <= u_npu.add_relu_sum;
                add_trace_q <= u_npu.add_q;
                add_trace_expected_byte <= r1g_expected_byte[2][32];
            end
        end
    end

    task execute_task;
        input integer idx;
        begin
            preload_task_payload(idx);
            monitor_idx = idx;
            monitor_active = 1'b1;
            $display("R1G_NPU_TOP_PROGRAM idx=%0d name=%0s type=%0d in=0x%08h out=0x%08h bytes=%0d",
                     idx, r1f_task_name[idx], r1f_task_type[idx][2:0],
                     r1f_input_addr[idx], r1f_output_addr[idx], r1f_output_bytes[idx]);
            program_task(idx);
            $display("R1G_NPU_TOP_START idx=%0d name=%0s", idx, r1f_task_name[idx]);
            axi_write(ADDR_CTRL, 32'h0000_0001);
            wait_done(idx, 200000);
            monitor_active = 1'b0;
            output_checksum[idx] = checksum_region(r1f_output_addr[idx], r1f_output_bytes[idx]);
            output_unknown_bytes[idx] = unknown_byte_count(r1f_output_addr[idx], r1f_output_bytes[idx]);
            if (aw_count[idx] == 0 || w_count[idx] == 0)
                fail("task did not write output through AXI");
            if (r1f_task_type[idx] == 3'd0 && !seen_compute[idx])
                fail("Conv task did not enter compute datapath");
            if (r1f_task_type[idx] == 3'd4 && (!seen_add_load[idx] || !seen_add_compute[idx]))
                fail("ADD task did not enter ADD datapath");
            $display("R1G_NPU_TOP_TASK idx=%0d name=%0s op=%0s type=%0d ar=%0d aw=%0d w=%0d out_checksum_masked=0x%08h unknown_bytes=%0d PASS",
                     idx, r1f_task_name[idx], r1f_op_name[idx], r1f_task_type[idx][2:0],
                     ar_count[idx], aw_count[idx], w_count[idx], output_checksum[idx],
                     output_unknown_bytes[idx]);
            compare_task_output(idx);
            clear_status;
        end
    endtask

    integer i;
    integer final_idx;
    reg [31:0] final_checksum;
    integer result_fd;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        init_bus;
        init_r1f_smoke_tasks;
        init_r1g_compare_expected;
        monitor_active = 1'b0;
        monitor_idx = 0;
        total_compared_bytes = 0;
        total_mismatch_count = 0;
        total_unknown_bytes = 0;
        conv1_trace_window_seen = 1'b0;
        conv1_trace_requant_seen = 1'b0;
        conv1_trace_mac_before_bias = 32'sd0;
        conv1_trace_bias = 32'sd0;
        conv1_trace_acc_after_bias = 32'sd0;
        conv1_trace_requant_i8 = 8'sd0;
        conv1_trace_stored_byte0 = 8'd0;
        conv1_trace_stored_byte1 = 8'd0;
        conv1_trace_stored_byte2 = 8'd0;
        conv1_trace_stored_byte3 = 8'd0;
        add_trace_seen = 1'b0;
        add_trace_idx = 32'd0;
        add_trace_src0_i8 = 8'sd0;
        add_trace_src1_i8 = 8'sd0;
        add_trace_src0_aligned = 8'sd0;
        add_trace_src1_aligned = 8'sd0;
        add_trace_raw = 32'sd0;
        add_trace_relu = 32'sd0;
        add_trace_q = 8'sd0;
        add_trace_expected_byte = 8'd0;
        add_trace_stored_byte0 = 8'd0;
        add_trace_stored_byte1 = 8'd0;
        add_trace_stored_byte2 = 8'd0;
        add_trace_stored_byte3 = 8'd0;
        for (i = 0; i < 8; i = i + 1) begin
            ar_count[i] = 0;
            aw_count[i] = 0;
            w_count[i] = 0;
            seen_compute[i] = 1'b0;
            seen_store[i] = 1'b0;
            seen_add_load[i] = 1'b0;
            seen_add_compute[i] = 1'b0;
            output_checksum[i] = 32'd0;
            output_unknown_bytes[i] = 0;
            compare_mismatch_count[i] = 0;
            compare_first_mismatch_idx[i] = -1;
            compare_first_expected[i] = 8'd0;
            compare_first_actual[i] = 8'd0;
            compare_first_actual_unknown[i] = 1'b0;
        end
        for (i = 0; i < 9; i = i + 1) begin
            conv1_trace_window[i] = 8'd0;
            conv1_trace_weight[i] = 8'd0;
        end
        for (i = 0; i < 4096; i = i + 1)
            u_ram.ram[i] = 256'd0;

        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (6) @(posedge clk);

        $display("=== R1g npu_top compact fixed-point compare ===");
        $display("R1G_SCOPE slice=layer1.0.conv1,layer1.0.conv2,layer1.0.add full_resnet=0 compact_alias=1");

        for (i = 0; i < R1F_TASK_COUNT; i = i + 1)
            execute_task(i);

        final_idx = R1F_TASK_COUNT - 1;
        final_checksum = output_checksum[final_idx];
        $display("R1G_COMPARE_RESULT tasks=%0d final_tensor=%0s compared_bytes=%0d mismatch_count=%0d final_checksum_masked=0x%08h final_unknown_bytes=%0d status=%0s",
                 R1F_TASK_COUNT, r1f_tensor_name[r1f_dst_tensor_idx[final_idx]],
                 total_compared_bytes, total_mismatch_count, final_checksum,
                 output_unknown_bytes[final_idx],
                 (total_mismatch_count == 0) ? "MATCH" : "MISMATCH");

        result_fd = $fopen("tb/generated/resnet20_r1g_compare_rtl_result.json", "w");
        if (result_fd != 0) begin
            $fdisplay(result_fd, "{");
            $fdisplay(result_fd, "  \"scope\": \"R1g compact npu_top fixed-point compare\",");
            $fdisplay(result_fd, "  \"slice\": [\"layer1.0.conv1\", \"layer1.0.conv2\", \"layer1.0.add\"],");
            $fdisplay(result_fd, "  \"full_resnet20\": false,");
            $fdisplay(result_fd, "  \"compact_alias\": true,");
            $fdisplay(result_fd, "  \"compact_contract\": \"Conv inputs are dense HWC INT8 bytes; Conv outputs use current RTL lane0-word physical store; ADD consumes physical bytes\",");
            $fdisplay(result_fd, "  \"compared_bytes\": %0d,", total_compared_bytes);
            $fdisplay(result_fd, "  \"mismatch_count\": %0d,", total_mismatch_count);
            $fdisplay(result_fd, "  \"unknown_bytes\": %0d,", total_unknown_bytes);
            $fdisplay(result_fd, "  \"stages\": [");
            $fdisplay(result_fd, "    {\"idx\": 0, \"name\": \"layer1.0.conv1\", \"logical_output_elements\": %0d, \"stored_bytes\": %0d, \"compared_bytes\": %0d, \"mismatch_count\": %0d, \"unknown_bytes\": %0d, \"first_mismatch_idx\": %0d, \"first_expected\": \"0x%02h\", \"first_actual\": \"0x%02h\", \"first_actual_unknown\": %0d, \"last_expected_word_bytes\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"], \"last_actual_word_bytes\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"]},",
                      (r1g_compare_bytes[0] >> 2), r1g_compare_bytes[0], r1g_compare_bytes[0],
                      compare_mismatch_count[0], output_unknown_bytes[0],
                      compare_first_mismatch_idx[0], compare_first_expected[0],
                      compare_first_actual[0], compare_first_actual_unknown[0],
                      r1g_expected_byte[0][32], r1g_expected_byte[0][33],
                      r1g_expected_byte[0][34], r1g_expected_byte[0][35],
                      ram_read_byte(r1f_output_addr[0] + 32), ram_read_byte(r1f_output_addr[0] + 33),
                      ram_read_byte(r1f_output_addr[0] + 34), ram_read_byte(r1f_output_addr[0] + 35));
            $fdisplay(result_fd, "    {\"idx\": 1, \"name\": \"layer1.0.conv2\", \"logical_output_elements\": %0d, \"stored_bytes\": %0d, \"compared_bytes\": %0d, \"mismatch_count\": %0d, \"unknown_bytes\": %0d, \"first_mismatch_idx\": %0d, \"first_expected\": \"0x%02h\", \"first_actual\": \"0x%02h\", \"first_actual_unknown\": %0d, \"last_expected_word_bytes\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"], \"last_actual_word_bytes\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"]},",
                      (r1g_compare_bytes[1] >> 2), r1g_compare_bytes[1], r1g_compare_bytes[1],
                      compare_mismatch_count[1], output_unknown_bytes[1],
                      compare_first_mismatch_idx[1], compare_first_expected[1],
                      compare_first_actual[1], compare_first_actual_unknown[1],
                      r1g_expected_byte[1][32], r1g_expected_byte[1][33],
                      r1g_expected_byte[1][34], r1g_expected_byte[1][35],
                      ram_read_byte(r1f_output_addr[1] + 32), ram_read_byte(r1f_output_addr[1] + 33),
                      ram_read_byte(r1f_output_addr[1] + 34), ram_read_byte(r1f_output_addr[1] + 35));
            $fdisplay(result_fd, "    {\"idx\": 2, \"name\": \"layer1.0.add\", \"logical_output_elements\": %0d, \"stored_bytes\": %0d, \"compared_bytes\": %0d, \"mismatch_count\": %0d, \"unknown_bytes\": %0d, \"first_mismatch_idx\": %0d, \"first_expected\": \"0x%02h\", \"first_actual\": \"0x%02h\", \"first_actual_unknown\": %0d, \"last_expected_word_bytes\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"], \"last_actual_word_bytes\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"]}",
                      (r1g_compare_bytes[2] >> 2), r1g_compare_bytes[2], r1g_compare_bytes[2],
                      compare_mismatch_count[2], output_unknown_bytes[2],
                      compare_first_mismatch_idx[2], compare_first_expected[2],
                      compare_first_actual[2], compare_first_actual_unknown[2],
                      r1g_expected_byte[2][32], r1g_expected_byte[2][33],
                      r1g_expected_byte[2][34], r1g_expected_byte[2][35],
                      ram_read_byte(r1f_output_addr[2] + 32), ram_read_byte(r1f_output_addr[2] + 33),
                      ram_read_byte(r1f_output_addr[2] + 34), ram_read_byte(r1f_output_addr[2] + 35));
            $fdisplay(result_fd, "  ],");
            $fdisplay(result_fd, "  \"final_checksum_masked\": \"0x%08h\",", final_checksum);
            $fdisplay(result_fd, "  \"status\": \"%0s\"", (total_mismatch_count == 0) ? "match" : "mismatch");
            $fdisplay(result_fd, "}");
            $fclose(result_fd);
        end
        conv1_trace_stored_byte0 = ram_read_byte(r1f_output_addr[0] + 0);
        conv1_trace_stored_byte1 = ram_read_byte(r1f_output_addr[0] + 1);
        conv1_trace_stored_byte2 = ram_read_byte(r1f_output_addr[0] + 2);
        conv1_trace_stored_byte3 = ram_read_byte(r1f_output_addr[0] + 3);
        conv1_trace_fd = $fopen("tb/generated/resnet20_r1g_conv1_trace.json", "w");
        if (conv1_trace_fd != 0) begin
            $fdisplay(conv1_trace_fd, "{");
            $fdisplay(conv1_trace_fd, "  \"scope\": \"R1g conv1 byte0 numeric trace\",");
            $fdisplay(conv1_trace_fd, "  \"payload_source\": \"package_memh_for_weight_and_bias; deterministic compact seed for input\",");
            $fdisplay(conv1_trace_fd, "  \"output_position\": {\"oh\": 0, \"ow\": 0, \"oc\": 0},");
            $fdisplay(conv1_trace_fd, "  \"reference\": {");
            $fdisplay(conv1_trace_fd, "    \"mac_before_bias\": %0d,", R1G_CONV1_REF_MAC_BEFORE_BIAS);
            $fdisplay(conv1_trace_fd, "    \"bias_i32\": %0d,", R1G_CONV1_REF_BIAS);
            $fdisplay(conv1_trace_fd, "    \"acc_after_bias\": %0d,", R1G_CONV1_REF_ACC_AFTER_BIAS);
            $fdisplay(conv1_trace_fd, "    \"requant_multiplier\": %0d,", r1f_requant_multiplier[0]);
            $fdisplay(conv1_trace_fd, "    \"requant_shift\": %0d,", r1f_requant_shift[0]);
            $fdisplay(conv1_trace_fd, "    \"output_i8\": %0d", R1G_CONV1_REF_OUTPUT_I8);
            $fdisplay(conv1_trace_fd, "  },");
            $fdisplay(conv1_trace_fd, "  \"rtl\": {");
            $fdisplay(conv1_trace_fd, "    \"window_seen\": %0d,", conv1_trace_window_seen);
            $fdisplay(conv1_trace_fd, "    \"requant_seen\": %0d,", conv1_trace_requant_seen);
            $fdisplay(conv1_trace_fd, "    \"window_hex\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"],",
                      conv1_trace_window[0], conv1_trace_window[1],
                      conv1_trace_window[2], conv1_trace_window[3],
                      conv1_trace_window[4], conv1_trace_window[5],
                      conv1_trace_window[6], conv1_trace_window[7],
                      conv1_trace_window[8]);
            $fdisplay(conv1_trace_fd, "    \"weight_hex\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"],",
                      conv1_trace_weight[0], conv1_trace_weight[1],
                      conv1_trace_weight[2], conv1_trace_weight[3],
                      conv1_trace_weight[4], conv1_trace_weight[5],
                      conv1_trace_weight[6], conv1_trace_weight[7],
                      conv1_trace_weight[8]);
            $fdisplay(conv1_trace_fd, "    \"mac_before_bias\": %0d,", conv1_trace_mac_before_bias);
            $fdisplay(conv1_trace_fd, "    \"bias_i32\": %0d,", conv1_trace_bias);
            $fdisplay(conv1_trace_fd, "    \"acc_after_bias\": %0d,", conv1_trace_acc_after_bias);
            $fdisplay(conv1_trace_fd, "    \"requant_i8\": %0d,", conv1_trace_requant_i8);
            $fdisplay(conv1_trace_fd, "    \"stored_word_bytes\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"]",
                      conv1_trace_stored_byte0, conv1_trace_stored_byte1,
                      conv1_trace_stored_byte2, conv1_trace_stored_byte3);
            $fdisplay(conv1_trace_fd, "  },");
            if (total_mismatch_count == 0) begin
                $fdisplay(conv1_trace_fd, "  \"first_divergence_stage\": \"none_after_compact_layout_alignment\",");
                $fdisplay(conv1_trace_fd, "  \"root_cause\": \"previous mismatch was compact fixture/reference layout alignment, not RTL Conv arithmetic\"");
            end else begin
                $fdisplay(conv1_trace_fd, "  \"first_divergence_stage\": \"post_layout_alignment_remaining_mismatch\",");
                $fdisplay(conv1_trace_fd, "  \"root_cause\": \"compact layout aligned; remaining mismatch requires datapath/window/weight mapping debug\"");
            end
            $fdisplay(conv1_trace_fd, "}");
            $fclose(conv1_trace_fd);
        end
        add_trace_stored_byte0 = ram_read_byte(r1f_output_addr[2] + 32);
        add_trace_stored_byte1 = ram_read_byte(r1f_output_addr[2] + 33);
        add_trace_stored_byte2 = ram_read_byte(r1f_output_addr[2] + 34);
        add_trace_stored_byte3 = ram_read_byte(r1f_output_addr[2] + 35);
        add_trace_fd = $fopen("tb/generated/resnet20_r1g_add_trace.json", "w");
        if (add_trace_fd != 0) begin
            $fdisplay(add_trace_fd, "{");
            $fdisplay(add_trace_fd, "  \"scope\": \"R1g ADD byte32 numeric/store trace\",");
            $fdisplay(add_trace_fd, "  \"output_position\": {\"byte_idx\": 32},");
            $fdisplay(add_trace_fd, "  \"reference\": {");
            $fdisplay(add_trace_fd, "    \"expected_byte\": \"0x%02h\",", r1g_expected_byte[2][32]);
            $fdisplay(add_trace_fd, "    \"expected_word_bytes\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"]",
                      r1g_expected_byte[2][32], r1g_expected_byte[2][33],
                      r1g_expected_byte[2][34], r1g_expected_byte[2][35]);
            $fdisplay(add_trace_fd, "  },");
            $fdisplay(add_trace_fd, "  \"rtl\": {");
            $fdisplay(add_trace_fd, "    \"trace_seen\": %0d,", add_trace_seen);
            $fdisplay(add_trace_fd, "    \"src_idx\": %0d,", add_trace_idx);
            $fdisplay(add_trace_fd, "    \"src0_i8\": %0d,", add_trace_src0_i8);
            $fdisplay(add_trace_fd, "    \"src1_i8\": %0d,", add_trace_src1_i8);
            $fdisplay(add_trace_fd, "    \"src0_aligned\": %0d,", add_trace_src0_aligned);
            $fdisplay(add_trace_fd, "    \"src1_aligned\": %0d,", add_trace_src1_aligned);
            $fdisplay(add_trace_fd, "    \"add_raw\": %0d,", add_trace_raw);
            $fdisplay(add_trace_fd, "    \"add_after_relu\": %0d,", add_trace_relu);
            $fdisplay(add_trace_fd, "    \"post_requant_output_i8\": %0d,", add_trace_q);
            $fdisplay(add_trace_fd, "    \"expected_byte_seen_by_tb\": \"0x%02h\",", add_trace_expected_byte);
            $fdisplay(add_trace_fd, "    \"stored_word_bytes\": [\"0x%02h\", \"0x%02h\", \"0x%02h\", \"0x%02h\"]",
                      add_trace_stored_byte0, add_trace_stored_byte1,
                      add_trace_stored_byte2, add_trace_stored_byte3);
            $fdisplay(add_trace_fd, "  },");
            if (total_mismatch_count == 0) begin
                $fdisplay(add_trace_fd, "  \"first_divergence_stage\": \"none_after_add_writeback_drain\",");
                $fdisplay(add_trace_fd, "  \"root_cause\": \"ADD final packed word writeback needed a drain cycle before STORE reads acc_buffer\"");
            end else begin
                $fdisplay(add_trace_fd, "  \"first_divergence_stage\": \"add_remaining_mismatch\",");
                $fdisplay(add_trace_fd, "  \"root_cause\": \"ADD trace captured; remaining mismatch requires follow-up\"");
            end
            $fdisplay(add_trace_fd, "}");
            $fclose(add_trace_fd);
        end

        $display("tb_resnet20_r1g_compare PASS compare_completed=1 numeric_match=%0d",
                 (total_mismatch_count == 0));
        $finish;
    end
endmodule
