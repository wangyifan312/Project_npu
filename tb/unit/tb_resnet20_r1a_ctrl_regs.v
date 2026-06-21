// tb_resnet20_r1a_ctrl_regs: R1a control/register foundation checks
`timescale 1ns / 1ps

module tb_resnet20_r1a_ctrl_regs;
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
    wire [2:0]  task_type;
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
    wire [31:0] conv_cfg;
    wire [31:0] bias_addr;
    wire [31:0] bias_bytes;
    wire [31:0] src1_addr;
    wire [31:0] src1_bytes;
    wire [31:0] add_cfg;
    wire [31:0] gap_cfg;
    wire [31:0] postproc_cfg_ext;
    wire [31:0] add_src0_multiplier;
    wire [5:0]  add_src0_shift;
    wire [31:0] add_src1_multiplier;
    wire [5:0]  add_src1_shift;
    wire [31:0] add_out_multiplier;
    wire [5:0]  add_out_shift;

    reg         task_done;
    wire        check_done;
    wire        checks_pass;
    wire [7:0]  check_error_code;

    localparam [31:0] ADDR_CTRL         = 32'h0000_0000;
    localparam [31:0] ADDR_STATUS       = 32'h0000_0004;
    localparam [31:0] ADDR_TASK_TYPE    = 32'h0000_0008;
    localparam [31:0] ADDR_INPUT_ADDR   = 32'h0000_000c;
    localparam [31:0] ADDR_WEIGHT_ADDR  = 32'h0000_0010;
    localparam [31:0] ADDR_OUTPUT_ADDR  = 32'h0000_0014;
    localparam [31:0] ADDR_INPUT_BYTES  = 32'h0000_0018;
    localparam [31:0] ADDR_WEIGHT_BYTES = 32'h0000_001c;
    localparam [31:0] ADDR_OUTPUT_BYTES = 32'h0000_0020;
    localparam [31:0] ADDR_DIM_IN       = 32'h0000_0024;
    localparam [31:0] ADDR_DIM_OUT      = 32'h0000_0028;
    localparam [31:0] ADDR_POSTPROC     = 32'h0000_002c;
    localparam [31:0] ADDR_RQ0_MULT     = 32'h0000_0068;
    localparam [31:0] ADDR_RQ0_SHIFT    = 32'h0000_006c;
    localparam [31:0] ADDR_VERSION      = 32'h0000_0090;
    localparam [31:0] ADDR_CAPABILITY   = 32'h0000_0094;
    localparam [31:0] ADDR_CONV_CFG     = 32'h0000_0098;
    localparam [31:0] ADDR_BIAS_ADDR    = 32'h0000_009c;
    localparam [31:0] ADDR_BIAS_BYTES   = 32'h0000_00a0;
    localparam [31:0] ADDR_SRC1_ADDR    = 32'h0000_00a4;
    localparam [31:0] ADDR_SRC1_BYTES   = 32'h0000_00a8;
    localparam [31:0] ADDR_ADD_CFG      = 32'h0000_00ac;
    localparam [31:0] ADDR_GAP_CFG      = 32'h0000_00b0;
    localparam [31:0] ADDR_POSTPROC_EXT = 32'h0000_00b4;
    localparam [31:0] ADDR_ADD_SRC0_MULT = 32'h0000_00b8;
    localparam [31:0] ADDR_ADD_SRC0_SHIFT = 32'h0000_00bc;
    localparam [31:0] ADDR_ADD_SRC1_MULT = 32'h0000_00c0;
    localparam [31:0] ADDR_ADD_SRC1_SHIFT = 32'h0000_00c4;
    localparam [31:0] ADDR_ADD_OUT_MULT = 32'h0000_00c8;
    localparam [31:0] ADDR_ADD_OUT_SHIFT = 32'h0000_00cc;

    npu_ctrl u_ctrl (
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
        .conv_cfg(conv_cfg),
        .bias_addr(bias_addr),
        .bias_bytes(bias_bytes),
        .src1_addr(src1_addr),
        .src1_bytes(src1_bytes),
        .add_cfg(add_cfg),
        .gap_cfg(gap_cfg),
        .postproc_cfg_ext(postproc_cfg_ext),
        .add_src0_multiplier(add_src0_multiplier),
        .add_src0_shift(add_src0_shift),
        .add_src1_multiplier(add_src1_multiplier),
        .add_src1_shift(add_src1_shift),
        .add_out_multiplier(add_out_multiplier),
        .add_out_shift(add_out_shift),
        .task_done_i(task_done),
        .task_error_i(1'b0),
        .task_error_code_i(check_error_code),
        .check_done_i(check_done),
        .checks_pass_i(checks_pass),
        .perf_cycle_lo_i(32'd0),
        .perf_cycle_hi_i(32'd0),
        .perf_read_beats_i(32'd0),
        .perf_write_beats_i(32'd0),
        .perf_read_active_i(32'd0),
        .perf_write_active_i(32'd0),
        .perf_mac_lo_i(32'd0),
        .perf_mac_hi_i(32'd0),
        .perf_array_active_i(32'd0),
        .perf_array_stall_i(32'd0),
        .perf_cluster_active_i(32'd0),
        .perf_cluster_stall_i(32'd0),
        .perf_cluster_cfg_i(32'd0)
    );

    task_checker u_checker (
        .clk(clk),
        .rst_n(rst_n),
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
        .conv_cfg(conv_cfg),
        .bias_addr(bias_addr),
        .bias_bytes(bias_bytes),
        .src1_addr(src1_addr),
        .src1_bytes(src1_bytes),
        .add_cfg(add_cfg),
        .gap_cfg(gap_cfg),
        .postproc_cfg_ext(postproc_cfg_ext),
        .requant_multiplier(requant_multiplier),
        .requant_shift(requant_shift),
        .add_src0_multiplier(add_src0_multiplier),
        .add_src0_shift(add_src0_shift),
        .add_src1_multiplier(add_src1_multiplier),
        .add_src1_shift(add_src1_shift),
        .add_out_multiplier(add_out_multiplier),
        .add_out_shift(add_out_shift),
        .checks_pass(checks_pass),
        .error_code(check_error_code),
        .check_done(check_done)
    );

    always #5 clk = ~clk;

    task fail;
        input [255:0] msg;
        begin
            $display("tb_resnet20_r1a_ctrl_regs FAIL: %0s", msg);
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
            task_done = 1'b0;
        end
    endtask

    task axil_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            awaddr  <= addr;
            wdata   <= data;
            wstrb   <= 4'hf;
            awvalid <= 1'b1;
            wvalid  <= 1'b1;
            while (!(awready && wready)) @(posedge clk);
            @(posedge clk);
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            bready  <= 1'b1;
            while (!bvalid) @(posedge clk);
            @(posedge clk);
            bready  <= 1'b0;
        end
    endtask

    task axil_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            araddr  <= addr;
            arvalid <= 1'b1;
            while (!arready) @(posedge clk);
            @(posedge clk);
            arvalid <= 1'b0;
            rready  <= 1'b1;
            while (!rvalid) @(posedge clk);
            data = rdata;
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    task clear_status;
        begin
            axil_write(ADDR_CTRL, 32'h0000_0010);
        end
    endtask

    task complete_task;
        begin
            repeat (2) @(posedge clk);
            task_done <= 1'b1;
            @(posedge clk);
            task_done <= 1'b0;
            repeat (2) @(posedge clk);
            clear_status;
        end
    endtask

    task wait_task_go;
        integer timeout;
        begin
            timeout = 0;
            while (!task_go && !ctrl_error && timeout < 40) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!task_go) fail("legacy task did not reach task_go");
            if (ctrl_error) fail("legacy task unexpectedly rejected");
        end
    endtask

    task wait_error;
        input [7:0] expected_code;
        integer timeout;
        begin
            timeout = 0;
            while (!ctrl_error && timeout < 40) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!ctrl_error) fail("expected ctrl_error was not asserted");
            if (ctrl_error_code !== expected_code) begin
                $display("got error=0x%02h expected=0x%02h", ctrl_error_code, expected_code);
                fail("unexpected ctrl_error_code");
            end
            clear_status;
        end
    endtask

    task program_conv_like;
        input [2:0] type_value;
        begin
            axil_write(ADDR_TASK_TYPE, {29'd0, type_value});
            axil_write(ADDR_INPUT_ADDR,   32'h0000_0100);
            axil_write(ADDR_WEIGHT_ADDR,  32'h0000_1000);
            axil_write(ADDR_OUTPUT_ADDR,  32'h0000_2000);
            axil_write(ADDR_INPUT_BYTES,  32'd784);
            axil_write(ADDR_WEIGHT_BYTES, 32'd150);
            axil_write(ADDR_OUTPUT_BYTES, 32'd2304);
            axil_write(ADDR_DIM_IN,       {16'd28, 16'd28});
            axil_write(ADDR_DIM_OUT,      {16'd6, 16'd1});
            axil_write(ADDR_POSTPROC,     32'h0000_0001);
        end
    endtask

    task program_fc;
        begin
            axil_write(ADDR_TASK_TYPE, 32'd1);
            axil_write(ADDR_INPUT_ADDR,   32'h0000_0100);
            axil_write(ADDR_WEIGHT_ADDR,  32'h0000_1000);
            axil_write(ADDR_OUTPUT_ADDR,  32'h0000_2000);
            axil_write(ADDR_INPUT_BYTES,  32'd64);
            axil_write(ADDR_WEIGHT_BYTES, 32'd640);
            axil_write(ADDR_OUTPUT_BYTES, 32'd40);
            axil_write(ADDR_DIM_IN,       {16'd1, 16'd1});
            axil_write(ADDR_DIM_OUT,      {16'd10, 16'd64});
            axil_write(ADDR_POSTPROC,     32'h0000_0000);
        end
    endtask

    task program_pool;
        begin
            axil_write(ADDR_TASK_TYPE, 32'd2);
            axil_write(ADDR_INPUT_ADDR,   32'h0000_0100);
            axil_write(ADDR_WEIGHT_ADDR,  32'h0000_0000);
            axil_write(ADDR_OUTPUT_ADDR,  32'h0000_2000);
            axil_write(ADDR_INPUT_BYTES,  32'd2304);
            axil_write(ADDR_WEIGHT_BYTES, 32'd0);
            axil_write(ADDR_OUTPUT_BYTES, 32'd576);
            axil_write(ADDR_DIM_IN,       {16'd24, 16'd24});
            axil_write(ADDR_DIM_OUT,      {16'd6, 16'd6});
            axil_write(ADDR_POSTPROC,     32'h0000_0002);
        end
    endtask

    task program_requant;
        begin
            axil_write(ADDR_TASK_TYPE, 32'd3);
            axil_write(ADDR_INPUT_ADDR,   32'h0000_0100);
            axil_write(ADDR_WEIGHT_ADDR,  32'h0000_0000);
            axil_write(ADDR_OUTPUT_ADDR,  32'h0000_2000);
            axil_write(ADDR_INPUT_BYTES,  32'd256);
            axil_write(ADDR_WEIGHT_BYTES, 32'd0);
            axil_write(ADDR_OUTPUT_BYTES, 32'd64);
            axil_write(ADDR_DIM_IN,       {16'd1, 16'd1});
            axil_write(ADDR_DIM_OUT,      {16'd1, 16'd1});
            axil_write(ADDR_RQ0_MULT,     32'd12345);
            axil_write(ADDR_RQ0_SHIFT,    32'd7);
        end
    endtask

    task program_add;
        begin
            axil_write(ADDR_TASK_TYPE,    32'd4);
            axil_write(ADDR_INPUT_ADDR,   32'h0000_0100);
            axil_write(ADDR_WEIGHT_ADDR,  32'h0000_0000);
            axil_write(ADDR_OUTPUT_ADDR,  32'h0000_3000);
            axil_write(ADDR_INPUT_BYTES,  32'd64);
            axil_write(ADDR_WEIGHT_BYTES, 32'd0);
            axil_write(ADDR_OUTPUT_BYTES, 32'd64);
            axil_write(ADDR_DIM_IN,       {16'd1, 16'd1});
            axil_write(ADDR_DIM_OUT,      {16'd1, 16'd1});
            axil_write(ADDR_SRC1_ADDR,    32'h0000_2000);
            axil_write(ADDR_SRC1_BYTES,   32'd64);
            axil_write(ADDR_ADD_CFG,      32'h0000_000c);
            axil_write(ADDR_POSTPROC_EXT, 32'd0);
            axil_write(ADDR_ADD_SRC0_MULT, 32'd1);
            axil_write(ADDR_ADD_SRC0_SHIFT, 32'd0);
            axil_write(ADDR_ADD_SRC1_MULT, 32'd1);
            axil_write(ADDR_ADD_SRC1_SHIFT, 32'd0);
            axil_write(ADDR_ADD_OUT_MULT, 32'd1);
            axil_write(ADDR_ADD_OUT_SHIFT, 32'd0);
        end
    endtask

    task program_add_without_requant_params;
        begin
            axil_write(ADDR_TASK_TYPE,    32'd4);
            axil_write(ADDR_INPUT_ADDR,   32'h0000_0100);
            axil_write(ADDR_WEIGHT_ADDR,  32'h0000_0000);
            axil_write(ADDR_OUTPUT_ADDR,  32'h0000_3000);
            axil_write(ADDR_INPUT_BYTES,  32'd64);
            axil_write(ADDR_WEIGHT_BYTES, 32'd0);
            axil_write(ADDR_OUTPUT_BYTES, 32'd64);
            axil_write(ADDR_DIM_IN,       {16'd1, 16'd1});
            axil_write(ADDR_DIM_OUT,      {16'd1, 16'd1});
            axil_write(ADDR_SRC1_ADDR,    32'h0000_2000);
            axil_write(ADDR_SRC1_BYTES,   32'd64);
            axil_write(ADDR_ADD_CFG,      32'h0000_000c);
            axil_write(ADDR_POSTPROC_EXT, 32'd0);
        end
    endtask

    task program_gap;
        begin
            axil_write(ADDR_TASK_TYPE,    32'd5);
            axil_write(ADDR_INPUT_ADDR,   32'h0000_0100);
            axil_write(ADDR_WEIGHT_ADDR,  32'h0000_0000);
            axil_write(ADDR_OUTPUT_ADDR,  32'h0000_3000);
            axil_write(ADDR_INPUT_BYTES,  32'd4096); // 8x8x64 INT8
            axil_write(ADDR_WEIGHT_BYTES, 32'd0);
            axil_write(ADDR_OUTPUT_BYTES, 32'd64);
            axil_write(ADDR_DIM_IN,       {16'd8, 16'd8});
            axil_write(ADDR_DIM_OUT,      {16'd64, 16'd64});
            axil_write(ADDR_GAP_CFG,      (32'd6 << 20));
            axil_write(ADDR_POSTPROC_EXT, 32'd0);
        end
    endtask

    task start_expect_go;
        begin
            axil_write(ADDR_CTRL, 32'h0000_0001);
            wait_task_go;
            complete_task;
        end
    endtask

    reg [31:0] rd;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        init_bus;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        $display("=== R1a VERSION/CAPABILITY readback ===");
        axil_read(ADDR_VERSION, rd);
        if (rd !== 32'h0001_000a) fail("VERSION mismatch");
        axil_read(ADDR_CAPABILITY, rd);
        if (rd !== 32'h0000_7be1) fail("CAPABILITY mismatch");
        if ({rd[10], rd[4:1]} !== 5'd0) fail("unsupported ResNet capability bits are set");

        $display("=== R1a new register reset/read/write ===");
        axil_read(ADDR_CONV_CFG, rd);
        if (rd !== 32'd0) fail("CONV_CFG reset mismatch");
        axil_read(ADDR_BIAS_ADDR, rd);
        if (rd !== 32'd0) fail("BIAS_ADDR reset mismatch");
        axil_read(ADDR_ADD_SRC0_MULT, rd);
        if (rd !== 32'd0) fail("ADD_SRC0_MULT reset mismatch");
        axil_read(ADDR_ADD_SRC1_MULT, rd);
        if (rd !== 32'd0) fail("ADD_SRC1_MULT reset mismatch");
        axil_read(ADDR_ADD_OUT_MULT, rd);
        if (rd !== 32'd0) fail("ADD_OUT_MULT reset mismatch");
        axil_read(ADDR_ADD_SRC0_SHIFT, rd);
        if (rd !== 32'd0) fail("ADD_SRC0_SHIFT reset mismatch");
        axil_read(ADDR_ADD_SRC1_SHIFT, rd);
        if (rd !== 32'd0) fail("ADD_SRC1_SHIFT reset mismatch");
        axil_read(ADDR_ADD_OUT_SHIFT, rd);
        if (rd !== 32'd0) fail("ADD_OUT_SHIFT reset mismatch");

        $display("=== R1d ADD reset requant params reject ===");
        program_add_without_requant_params;
        axil_write(ADDR_CTRL, 32'h0000_0001);
        wait_error(8'h0b);

        axil_write(ADDR_CONV_CFG, 32'hffff_ffff);
        axil_write(ADDR_BIAS_ADDR, 32'h0000_3000);
        axil_write(ADDR_BIAS_BYTES, 32'h0000_0040);
        axil_write(ADDR_SRC1_ADDR, 32'h0000_4000);
        axil_write(ADDR_SRC1_BYTES, 32'h0000_0080);
        axil_write(ADDR_ADD_CFG, 32'hffff_ffff);
        axil_write(ADDR_GAP_CFG, 32'hffff_ffff);
        axil_write(ADDR_POSTPROC_EXT, 32'h0000_00a5);
        axil_write(ADDR_ADD_SRC0_MULT, 32'h0000_0123);
        axil_write(ADDR_ADD_SRC0_SHIFT, 32'hffff_ffff);
        axil_write(ADDR_ADD_SRC1_MULT, 32'h0000_0456);
        axil_write(ADDR_ADD_SRC1_SHIFT, 32'hffff_ffff);
        axil_write(ADDR_ADD_OUT_MULT, 32'h0000_0789);
        axil_write(ADDR_ADD_OUT_SHIFT, 32'hffff_ffff);
        axil_read(ADDR_CONV_CFG, rd);
        if (rd !== 32'h0000_003f) fail("CONV_CFG masked readback mismatch");
        axil_read(ADDR_BIAS_ADDR, rd);
        if (rd !== 32'h0000_3000) fail("BIAS_ADDR readback mismatch");
        axil_read(ADDR_ADD_CFG, rd);
        if (rd !== 32'h0000_000f) fail("ADD_CFG masked readback mismatch");
        axil_read(ADDR_GAP_CFG, rd);
        if (rd !== 32'h03ff_ffff) fail("GAP_CFG masked readback mismatch");
        axil_read(ADDR_POSTPROC_EXT, rd);
        if (rd !== 32'h0000_00a5) fail("POSTPROC_CFG readback mismatch");
        axil_read(ADDR_ADD_SRC0_MULT, rd);
        if (rd !== 32'h0000_0123) fail("ADD_SRC0_MULT readback mismatch");
        axil_read(ADDR_ADD_SRC0_SHIFT, rd);
        if (rd !== 32'h0000_003f) fail("ADD_SRC0_SHIFT masked readback mismatch");
        axil_read(ADDR_ADD_SRC1_MULT, rd);
        if (rd !== 32'h0000_0456) fail("ADD_SRC1_MULT readback mismatch");
        axil_read(ADDR_ADD_SRC1_SHIFT, rd);
        if (rd !== 32'h0000_003f) fail("ADD_SRC1_SHIFT masked readback mismatch");
        axil_read(ADDR_ADD_OUT_MULT, rd);
        if (rd !== 32'h0000_0789) fail("ADD_OUT_MULT readback mismatch");
        axil_read(ADDR_ADD_OUT_SHIFT, rd);
        if (rd !== 32'h0000_003f) fail("ADD_OUT_SHIFT masked readback mismatch");

        $display("=== R1a legacy task_type 0..3 still accepted ===");
        axil_write(ADDR_CONV_CFG, 32'h0000_0000);
        program_conv_like(3'd0);
        start_expect_go;
        program_fc;
        start_expect_go;
        program_pool;
        start_expect_go;
        program_requant;
        start_expect_go;

        $display("=== R1d ADD accepted and R1e GAP accepted ===");
        program_add;
        start_expect_go;
        program_gap;
        start_expect_go;

        $display("tb_resnet20_r1a_ctrl_regs PASS");
        $finish;
    end
endmodule
