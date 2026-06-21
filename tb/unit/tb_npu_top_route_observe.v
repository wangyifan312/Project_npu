`timescale 1ns / 1ps

module npu_top_route_case #(
    parameter [127:0] CASE_NAME = "case",
    parameter [1:0] CLUSTER_MODE_P = 2'd0,
    parameter [5:0] CLUSTER_MASK_P = 6'b11_1111,
    parameter integer ACTIVE_COLS = 16,
    parameter integer EXPECTED_CLUSTERS = 1
) (
    output reg done
);
    localparam CLUSTER_COUNT = 6;
    localparam TILE_ROWS = 4;
    localparam TILE_COLS = 16;
    localparam PE_COLS = TILE_COLS * 4;
    localparam CLUSTER_SUM_W = PE_COLS * 32;
    localparam PE_ROWS = TILE_ROWS * 4;
    localparam ROUTE_DRAIN_OFFSET = (PE_ROWS > 25) ? (PE_ROWS - 25 + 5) : 5;

    reg clk;
    reg rst_n;

    reg s_axi_awvalid;
    reg [31:0] s_axi_awaddr;
    reg s_axi_wvalid;
    reg [31:0] s_axi_wdata;
    reg [3:0] s_axi_wstrb;
    reg s_axi_bready;
    reg s_axi_arvalid;
    reg [31:0] s_axi_araddr;
    reg s_axi_rready;
    reg [255:0] m_axi_rdata;
    reg m_axi_arready;
    reg m_axi_rvalid;
    reg m_axi_rlast;
    reg [1:0] m_axi_rresp;
    reg m_axi_awready;
    reg m_axi_wready;
    reg [1:0] m_axi_bresp;
    reg m_axi_bvalid;

    wire s_axi_awready;
    wire s_axi_wready;
    wire s_axi_bvalid;
    wire [1:0] s_axi_bresp;
    wire s_axi_arready;
    wire s_axi_rvalid;
    wire [31:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire [31:0] m_axi_araddr;
    wire m_axi_arvalid;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_rready;
    wire [31:0] m_axi_awaddr;
    wire m_axi_awvalid;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire [255:0] m_axi_wdata;
    wire m_axi_wvalid;
    wire m_axi_wlast;
    wire [31:0] m_axi_wstrb;
    wire m_axi_bready;
    wire npu_busy;
    wire npu_done;
    wire npu_error;
    wire [7:0] npu_error_code;

    reg [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] raw_sum_flat;
    reg [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] expected_routed_flat;
    reg [CLUSTER_COUNT-1:0] expected_valid;
    reg [31:0] expected [0:PE_COLS-1];
    integer c;
    integer col;
    integer route_col;
    integer rank;
    integer count_i;
    integer base_i;
    integer end_i;
    integer global_col;
    reg [31:0] value;

    npu_top #(
        .TILE_ROWS(TILE_ROWS),
        .TILE_COLS(TILE_COLS),
        .CLUSTER_MODE(CLUSTER_MODE_P),
        .CLUSTER_MASK_REQ(CLUSTER_MASK_P)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .npu_busy(npu_busy),
        .npu_done(npu_done),
        .npu_error(npu_error),
        .npu_error_code(npu_error_code)
    );

    always #5 clk = ~clk;

    function integer rank_of;
        input integer cluster_id;
        integer i;
        begin
            rank_of = 0;
            for (i = 0; i < cluster_id; i = i + 1) begin
                if (dut.perf_cluster_enable[i])
                    rank_of = rank_of + 1;
            end
        end
    endfunction

    task clear_expected;
        begin
            raw_sum_flat = {(CLUSTER_COUNT*CLUSTER_SUM_W){1'b1}};
            expected_routed_flat = {(CLUSTER_COUNT*CLUSTER_SUM_W){1'b0}};
            expected_valid = {CLUSTER_COUNT{1'b0}};
            for (col = 0; col < PE_COLS; col = col + 1)
                expected[col] = 32'h0;
        end
    endtask

    task check_route_col;
        input integer local_route_col;
        begin
            clear_expected();
            count_i = (dut.perf_cluster_count == 3'd0) ? 1 : dut.perf_cluster_count;
            for (c = 0; c < CLUSTER_COUNT; c = c + 1) begin
                if (dut.perf_cluster_enable[c]) begin
                    rank = rank_of(c);
                    base_i = (ACTIVE_COLS * rank) / count_i;
                    end_i  = (ACTIVE_COLS * (rank + 1)) / count_i;
                    global_col = base_i + local_route_col;
                    value = 32'h5000_0000 | (c[7:0] << 16) | global_col[15:0];
                    raw_sum_flat[c*CLUSTER_SUM_W + local_route_col*32 +: 32] = value;
                    if ((global_col < end_i) && (global_col < ACTIVE_COLS)) begin
                        expected_valid[c] = 1'b1;
                        expected_routed_flat[c*CLUSTER_SUM_W + global_col*32 +: 32] = value;
                        expected[global_col] = value;
                    end
                end
            end

            release dut.cluster_sum_out_all_flat;
            force dut.cluster_sum_out_all_flat = raw_sum_flat;
            force dut.comp_drain_cnt = ROUTE_DRAIN_OFFSET + local_route_col;
            #1;

            if (dut.cluster_arb_valid !== expected_valid)
                $fatal(1, "%0s route_col=%0d cluster_arb_valid=%b expect=%b",
                       CASE_NAME, local_route_col, dut.cluster_arb_valid, expected_valid);

            for (c = 0; c < CLUSTER_COUNT; c = c + 1) begin
                for (col = 0; col < PE_COLS; col = col + 1) begin
                    if (dut.cluster_routed_sum_out_all_flat[c*CLUSTER_SUM_W + col*32 +: 32] !==
                        expected_routed_flat[c*CLUSTER_SUM_W + col*32 +: 32]) begin
                        $fatal(1, "%0s routed mismatch cluster=%0d col=%0d got=%08x expect=%08x",
                               CASE_NAME, c, col,
                               dut.cluster_routed_sum_out_all_flat[c*CLUSTER_SUM_W + col*32 +: 32],
                               expected_routed_flat[c*CLUSTER_SUM_W + col*32 +: 32]);
                    end
                end
            end

            for (col = 0; col < PE_COLS; col = col + 1) begin
                if (dut.array_sum_out[col*32 +: 32] !== expected[col])
                    $fatal(1, "%0s array_sum_out col=%0d got=%08x expect=%08x",
                           CASE_NAME, col, dut.array_sum_out[col*32 +: 32], expected[col]);
            end
        end
    endtask

    initial begin
        done = 1'b0;
        clk = 1'b0;
        rst_n = 1'b0;
        s_axi_awvalid = 1'b0;
        s_axi_awaddr = 32'h0;
        s_axi_wvalid = 1'b0;
        s_axi_wdata = 32'h0;
        s_axi_wstrb = 4'h0;
        s_axi_bready = 1'b0;
        s_axi_arvalid = 1'b0;
        s_axi_araddr = 32'h0;
        s_axi_rready = 1'b0;
        m_axi_rdata = 256'h0;
        m_axi_arready = 1'b0;
        m_axi_rvalid = 1'b0;
        m_axi_rlast = 1'b0;
        m_axi_rresp = 2'b00;
        m_axi_awready = 1'b0;
        m_axi_wready = 1'b0;
        m_axi_bresp = 2'b00;
        m_axi_bvalid = 1'b0;

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        if (dut.perf_cluster_count !== EXPECTED_CLUSTERS[2:0])
            $fatal(1, "%0s cluster_count=%0d expect=%0d",
                   CASE_NAME, dut.perf_cluster_count, EXPECTED_CLUSTERS);

        force dut.task_type = 3'd0;
        force dut.output_c = ACTIVE_COLS[15:0];
        force dut.fsm_state = 5'd9;
        force dut.comp_sub_state = 3'd2;
        #1;

        for (route_col = 0; route_col < PE_COLS; route_col = route_col + 1)
            check_route_col(route_col);

        $display("NPU_TOP_ROUTE_OBSERVE case=%0s mode=%0d mask=%b enable=%b active_cols=%0d clusters=%0d status=PASS",
                 CASE_NAME, CLUSTER_MODE_P, CLUSTER_MASK_P, dut.perf_cluster_enable,
                 ACTIVE_COLS, dut.perf_cluster_count);
        done = 1'b1;
    end
endmodule

module tb_npu_top_route_observe;
    wire done_mask;

    npu_top_route_case #(
        .CASE_NAME("mask_50cols"),
        .CLUSTER_MODE_P(2'd2),
        .CLUSTER_MASK_P(6'b10_1011),
        .ACTIVE_COLS(50),
        .EXPECTED_CLUSTERS(4)
    ) u_mask (.done(done_mask));

    initial begin
        wait (done_mask);
        $display("tb_npu_top_route_observe PASS");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "tb_npu_top_route_observe timeout");
    end
endmodule
