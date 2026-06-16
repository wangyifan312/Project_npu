`timescale 1ns / 1ps

module tb_axil_npu_ctrl_protocol;
    reg clk;
    reg rst_n;

    reg         awvalid;
    wire        awready;
    reg  [31:0] awaddr;
    reg         wvalid;
    wire        wready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    wire        bvalid;
    reg         bready;
    wire [1:0]  bresp;
    reg         arvalid;
    wire        arready;
    reg  [31:0] araddr;
    wire        rvalid;
    reg         rready;
    wire [31:0] rdata;
    wire [1:0]  rresp;

    wire        ctrl_busy;
    wire        ctrl_done;
    wire        ctrl_error;
    wire [7:0]  ctrl_error_code;
    wire        task_go;
    wire        task_start;
    wire [1:0]  task_type;
    wire [31:0] input_addr;
    wire [31:0] weight_addr;
    wire [31:0] output_addr;
    wire [31:0] input_bytes;
    wire [31:0] weight_bytes;
    wire [31:0] output_bytes;
    wire [15:0] input_h;
    wire [15:0] input_w;
    wire [15:0] input_c;
    wire [15:0] output_c;
    wire        relu_en;
    wire        pool_en;
    wire [1:0]  requant_slot_sel;
    wire [31:0] requant_multiplier;
    wire [5:0]  requant_shift;
    wire [1:0]  cluster_mode_cfg;
    wire [5:0]  cluster_mask_cfg;

    npu_ctrl u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_awaddr(awaddr),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_bresp(bresp),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_araddr(araddr),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .ctrl_busy(ctrl_busy),
        .ctrl_done(ctrl_done),
        .ctrl_error(ctrl_error),
        .ctrl_error_code(ctrl_error_code),
        .task_go(task_go),
        .task_start(task_start),
        .task_type(task_type),
        .input_addr(input_addr),
        .weight_addr(weight_addr),
        .output_addr(output_addr),
        .input_bytes(input_bytes),
        .weight_bytes(weight_bytes),
        .output_bytes(output_bytes),
        .input_h(input_h),
        .input_w(input_w),
        .input_c(input_c),
        .output_c(output_c),
        .relu_en(relu_en),
        .pool_en(pool_en),
        .requant_slot_sel(requant_slot_sel),
        .requant_multiplier(requant_multiplier),
        .requant_shift(requant_shift),
        .cluster_mode_cfg(cluster_mode_cfg),
        .cluster_mask_cfg(cluster_mask_cfg),
        .task_done_i(1'b0),
        .task_error_i(1'b0),
        .task_error_code_i(8'h0),
        .check_done_i(1'b0),
        .checks_pass_i(1'b0),
        .perf_cycle_lo_i(32'h1111_0001),
        .perf_cycle_hi_i(32'h1111_0002),
        .perf_read_beats_i(32'h1111_0003),
        .perf_write_beats_i(32'h1111_0004),
        .perf_read_active_i(32'h1111_0005),
        .perf_write_active_i(32'h1111_0006),
        .perf_mac_lo_i(32'h1111_0007),
        .perf_mac_hi_i(32'h1111_0008),
        .perf_array_active_i(32'h1111_0009),
        .perf_array_stall_i(32'h1111_000a),
        .perf_cluster_active_i(32'h1111_000b),
        .perf_cluster_stall_i(32'h1111_000c),
        .perf_cluster_cfg_i(32'h1111_000d)
    );

    always #5 clk = ~clk;

    task fail;
        input [255:0] msg;
        begin
            $display("tb_axil_npu_ctrl_protocol FAIL: %0s", msg);
            $finish;
        end
    endtask

    task init_bus;
        begin
            awvalid = 1'b0;
            awaddr  = 32'h0;
            wvalid  = 1'b0;
            wdata   = 32'h0;
            wstrb   = 4'h0;
            bready  = 1'b0;
            arvalid = 1'b0;
            araddr  = 32'h0;
            rready  = 1'b0;
        end
    endtask

    task accept_aw;
        input [31:0] addr;
        begin
            awaddr  <= addr;
            awvalid <= 1'b1;
            while (!awready) @(posedge clk);
            @(posedge clk);
            awvalid <= 1'b0;
        end
    endtask

    task accept_w;
        input [31:0] data;
        input [3:0]  strb;
        begin
            wdata  <= data;
            wstrb  <= strb;
            wvalid <= 1'b1;
            while (!wready) @(posedge clk);
            @(posedge clk);
            wvalid <= 1'b0;
        end
    endtask

    task check_b_stall;
        input [1:0] expected_resp;
        reg [1:0] held_resp;
        begin
            bready <= 1'b0;
            while (!bvalid) @(posedge clk);
            held_resp = bresp;
            repeat (3) begin
                @(posedge clk);
                if (!bvalid) fail("BVALID dropped while BREADY=0");
                if (bresp !== held_resp) fail("BRESP changed while BREADY=0");
            end
            if (held_resp !== expected_resp) begin
                $display("got BRESP=%0d expected=%0d", held_resp, expected_resp);
                fail("unexpected BRESP");
            end
            bready <= 1'b1;
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    task write_aw_first;
        input [31:0] addr;
        input [31:0] data;
        input [1:0]  expected_resp;
        begin
            accept_aw(addr);
            repeat (2) @(posedge clk);
            accept_w(data, 4'hF);
            check_b_stall(expected_resp);
        end
    endtask

    task write_w_first;
        input [31:0] addr;
        input [31:0] data;
        input [1:0]  expected_resp;
        begin
            accept_w(data, 4'hF);
            repeat (2) @(posedge clk);
            accept_aw(addr);
            check_b_stall(expected_resp);
        end
    endtask

    task write_same_cycle;
        input [31:0] addr;
        input [31:0] data;
        input [1:0]  expected_resp;
        begin
            awaddr  <= addr;
            wdata   <= data;
            wstrb   <= 4'hF;
            awvalid <= 1'b1;
            wvalid  <= 1'b1;
            while (!(awready && wready)) @(posedge clk);
            @(posedge clk);
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            check_b_stall(expected_resp);
        end
    endtask

    task read_check;
        input [31:0] addr;
        input [31:0] expected_data;
        input [1:0]  expected_resp;
        reg [31:0] held_data;
        reg [1:0]  held_resp;
        begin
            araddr  <= addr;
            arvalid <= 1'b1;
            while (!arready) @(posedge clk);
            @(posedge clk);
            arvalid <= 1'b0;
            rready  <= 1'b0;
            while (!rvalid) @(posedge clk);
            held_data = rdata;
            held_resp = rresp;
            repeat (3) begin
                @(posedge clk);
                if (!rvalid) fail("RVALID dropped while RREADY=0");
                if (rdata !== held_data) fail("RDATA changed while RREADY=0");
                if (rresp !== held_resp) fail("RRESP changed while RREADY=0");
            end
            if (held_resp !== expected_resp) fail("unexpected RRESP");
            if (held_data !== expected_data) begin
                $display("read addr=0x%08x got=0x%08x expected=0x%08x", addr, held_data, expected_data);
                fail("read data mismatch");
            end
            rready <= 1'b1;
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        init_bus();
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        write_aw_first(32'h0000_0008, 32'h0000_0002, 2'b00);
        write_w_first(32'h0000_000c, 32'h0000_1000, 2'b00);
        write_same_cycle(32'h0000_0010, 32'h0000_2000, 2'b00);
        write_same_cycle(32'h0000_00fc, 32'hdead_beef, 2'b10);

        read_check(32'h0000_0008, 32'h0000_0002, 2'b00);
        read_check(32'h0000_000c, 32'h0000_1000, 2'b00);
        read_check(32'h0000_0010, 32'h0000_2000, 2'b00);
        read_check(32'h0000_0030, 32'h1111_0001, 2'b00);
        read_check(32'h0000_00fc, 32'h0000_0000, 2'b10);

        $display("tb_axil_npu_ctrl_protocol PASS");
        $finish;
    end
endmodule
