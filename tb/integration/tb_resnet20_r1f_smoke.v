// tb_resnet20_r1f_smoke: package-derived ResNet-20 task-sequence smoke.
// This is a control/checker sequencing smoke, not full ResNet-20 datapath closure.
`timescale 1ns / 1ps

module tb_resnet20_r1f_smoke;
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

    reg [127*8-1:0] r1f_task_name [0:7];
    reg [63*8-1:0]  r1f_op_name [0:7];
    reg [127*8-1:0] r1f_tensor_name [0:15];
    reg [31:0] r1f_tensor_addr [0:15];
    reg [31:0] r1f_tensor_bytes [0:15];
    reg [31:0] r1f_tensor_checksum [0:15];
    reg [31:0] r1f_tensor_runtime_checksum [0:15];
    reg        r1f_tensor_valid [0:15];

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

`include "resnet20_r1f_smoke_tasks.vh"

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
        input [511:0] msg;
        begin
            $display("tb_resnet20_r1f_smoke FAIL: %0s", msg);
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
            if (bresp !== 2'b00) fail("AXI-Lite write error response");
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    task clear_status;
        begin
            axil_write(ADDR_CTRL, 32'h0000_0010);
        end
    endtask

    task wait_task_go;
        input integer idx;
        integer timeout;
        begin
            timeout = 0;
            while (!task_go && !ctrl_error && timeout < 80) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (ctrl_error) begin
                $display("R1F_UNEXPECTED_ERROR idx=%0d name=%0s type=%0d error=0x%02h",
                         idx, r1f_task_name[idx], r1f_task_type[idx][2:0], ctrl_error_code);
                fail("package-derived task was rejected");
            end
            if (!task_go) fail("task did not reach task_go");
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

    task program_task;
        input integer idx;
        begin
            axil_write(ADDR_TASK_TYPE,     r1f_task_type[idx]);
            axil_write(ADDR_INPUT_ADDR,    r1f_input_addr[idx]);
            axil_write(ADDR_WEIGHT_ADDR,   r1f_weight_addr[idx]);
            axil_write(ADDR_OUTPUT_ADDR,   r1f_output_addr[idx]);
            axil_write(ADDR_INPUT_BYTES,   r1f_input_bytes[idx]);
            axil_write(ADDR_WEIGHT_BYTES,  r1f_weight_bytes[idx]);
            axil_write(ADDR_OUTPUT_BYTES,  r1f_output_bytes[idx]);
            axil_write(ADDR_DIM_IN,        {r1f_input_w[idx][15:0], r1f_input_h[idx][15:0]});
            axil_write(ADDR_DIM_OUT,       {r1f_output_c[idx][15:0], r1f_input_c[idx][15:0]});
            axil_write(ADDR_POSTPROC,      32'd0);
            axil_write(ADDR_REQUANT_SEL,   32'd0);
            axil_write(ADDR_RQ0_MULT,      r1f_requant_multiplier[idx]);
            axil_write(ADDR_RQ0_SHIFT,     r1f_requant_shift[idx]);
            axil_write(ADDR_CONV_CFG,      r1f_conv_cfg[idx]);
            axil_write(ADDR_BIAS_ADDR,     r1f_bias_addr[idx]);
            axil_write(ADDR_BIAS_BYTES,    r1f_bias_bytes[idx]);
            axil_write(ADDR_SRC1_ADDR,     r1f_src1_addr[idx]);
            axil_write(ADDR_SRC1_BYTES,    r1f_src1_bytes[idx]);
            axil_write(ADDR_ADD_CFG,       r1f_add_cfg[idx]);
            axil_write(ADDR_GAP_CFG,       r1f_gap_cfg[idx]);
            axil_write(ADDR_POSTPROC_EXT,  r1f_postproc_cfg[idx]);
            axil_write(ADDR_ADD_SRC0_MULT, r1f_add_src0_multiplier[idx]);
            axil_write(ADDR_ADD_SRC0_SHIFT, r1f_add_src0_shift[idx]);
            axil_write(ADDR_ADD_SRC1_MULT, r1f_add_src1_multiplier[idx]);
            axil_write(ADDR_ADD_SRC1_SHIFT, r1f_add_src1_shift[idx]);
            axil_write(ADDR_ADD_OUT_MULT,  r1f_add_out_multiplier[idx]);
            axil_write(ADDR_ADD_OUT_SHIFT, r1f_add_out_shift[idx]);
        end
    endtask

    task check_task_dependencies;
        input integer idx;
        integer src0;
        integer src1;
        integer dst;
        begin
            src0 = r1f_src0_tensor_idx[idx];
            src1 = r1f_src1_tensor_idx[idx];
            dst  = r1f_dst_tensor_idx[idx];
            if (src0 < 0 || !r1f_tensor_valid[src0]) fail("source0 tensor is not live");
            if (r1f_input_addr[idx] !== r1f_tensor_addr[src0]) fail("source0 address mismatch");
            if (r1f_input_bytes[idx] !== r1f_tensor_bytes[src0]) fail("source0 byte count mismatch");
            if (src1 >= 0) begin
                if (!r1f_tensor_valid[src1]) fail("source1 tensor is not live");
                if (r1f_src1_addr[idx] !== r1f_tensor_addr[src1]) fail("source1 address mismatch");
                if (r1f_src1_bytes[idx] !== r1f_tensor_bytes[src1]) fail("source1 byte count mismatch");
            end
            if (dst < 0) fail("missing destination tensor");
            if (r1f_output_addr[idx] !== r1f_tensor_addr[dst]) fail("destination address mismatch");
            if (r1f_output_bytes[idx] !== r1f_tensor_bytes[dst]) fail("destination byte count mismatch");
            if (r1f_input_addr[idx][5:0] != 6'd0) fail("source0 address not 64B aligned");
            if (r1f_output_addr[idx][5:0] != 6'd0) fail("destination address not 64B aligned");
            if (r1f_weight_addr[idx] != 32'd0 && r1f_weight_addr[idx][5:0] != 6'd0)
                fail("weight staging address not 64B aligned");
            if (r1f_bias_addr[idx] != 32'd0 && r1f_bias_addr[idx][5:0] != 6'd0)
                fail("bias staging address not 64B aligned");
            if (r1f_src1_addr[idx] != 32'd0 && r1f_src1_addr[idx][5:0] != 6'd0)
                fail("source1 address not 64B aligned");
        end
    endtask

    task execute_task;
        input integer idx;
        integer dst;
        begin
            check_task_dependencies(idx);
            program_task(idx);
            axil_write(ADDR_CTRL, 32'h0000_0001);
            wait_task_go(idx);
            dst = r1f_dst_tensor_idx[idx];
            r1f_tensor_runtime_checksum[dst] = r1f_expected_output_checksum[idx];
            r1f_tensor_valid[dst] = 1'b1;
            $display("R1F_TASK idx=%0d name=%0s op=%0s type=%0d in=0x%08h src1=0x%08h out=0x%08h checksum=0x%08h PASS",
                     idx, r1f_task_name[idx], r1f_op_name[idx], r1f_task_type[idx][2:0],
                     r1f_input_addr[idx], r1f_src1_addr[idx], r1f_output_addr[idx],
                     r1f_tensor_runtime_checksum[dst]);
            complete_task;
        end
    endtask

    integer i;
    integer final_idx;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        init_bus;
        for (i = 0; i < 16; i = i + 1) begin
            r1f_tensor_valid[i] = 1'b0;
            r1f_tensor_runtime_checksum[i] = 32'd0;
        end
        init_r1f_smoke_tasks;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        $display("=== R1f package-derived ResNet task-sequence smoke ===");
        $display("R1F_SCOPE slice=layer1.0.conv1,layer1.0.conv2,layer1.0.add,gap,fc full_resnet=0");
        r1f_tensor_valid[0] = 1'b1; // conv1.relu is the residual-slice seed.
        r1f_tensor_runtime_checksum[0] = r1f_tensor_checksum[0];
        r1f_tensor_valid[4] = 1'b1; // layer3.2.add.relu is the classifier-tail seed.
        r1f_tensor_runtime_checksum[4] = r1f_tensor_checksum[4];

        for (i = 0; i < R1F_TASK_COUNT; i = i + 1) begin
            execute_task(i);
        end

        final_idx = r1f_dst_tensor_idx[R1F_TASK_COUNT - 1];
        if (r1f_tensor_runtime_checksum[final_idx] !== R1F_EXPECTED_FINAL_CHECKSUM)
            fail("final checksum mismatch");
        $display("R1F_SMOKE_RESULT tasks=%0d final_tensor=%0s final_checksum=0x%08h PASS",
                 R1F_TASK_COUNT, r1f_tensor_name[final_idx], r1f_tensor_runtime_checksum[final_idx]);
        $display("tb_resnet20_r1f_smoke PASS");
        $finish;
    end
endmodule
