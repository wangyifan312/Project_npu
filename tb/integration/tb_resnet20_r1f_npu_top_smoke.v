// tb_resnet20_r1f_npu_top_smoke: npu_top datapath-carrying R1f smoke.
// Uses a package-derived contiguous residual slice with compact test-only
// alias addresses/dimensions. This is not full ResNet-20 RTL closure.
`timescale 1ns / 1ps

module tb_resnet20_r1f_npu_top_smoke;
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

`include "resnet20_r1f_npu_top_residual_tasks.vh"

    npu_top #(
        .TILE_ROWS(1),
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
            $display("tb_resnet20_r1f_npu_top_smoke FAIL: %0s", msg);
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
                seed = r1f_weight_checksum[idx];
                for (i = 0; i < r1f_weight_bytes[idx]; i = i + 1)
                    ram_write_byte(r1f_weight_addr[idx] + i, (seed >> ((i % 4) * 8)) ^ i[7:0]);
            end
            if (r1f_bias_addr[idx] != 32'd0) begin
                seed = r1f_bias_checksum[idx];
                for (i = 0; i < r1f_bias_bytes[idx]; i = i + 1)
                    ram_write_byte(r1f_bias_addr[idx] + i, (seed >> ((i % 4) * 8)));
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
    end

    task execute_task;
        input integer idx;
        begin
            preload_task_payload(idx);
            monitor_idx = idx;
            monitor_active = 1'b1;
            $display("R1F_NPU_TOP_PROGRAM idx=%0d name=%0s type=%0d in=0x%08h out=0x%08h bytes=%0d",
                     idx, r1f_task_name[idx], r1f_task_type[idx][2:0],
                     r1f_input_addr[idx], r1f_output_addr[idx], r1f_output_bytes[idx]);
            program_task(idx);
            $display("R1F_NPU_TOP_START idx=%0d name=%0s", idx, r1f_task_name[idx]);
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
            $display("R1F_NPU_TOP_TASK idx=%0d name=%0s op=%0s type=%0d ar=%0d aw=%0d w=%0d out_checksum_masked=0x%08h unknown_bytes=%0d PASS",
                     idx, r1f_task_name[idx], r1f_op_name[idx], r1f_task_type[idx][2:0],
                     ar_count[idx], aw_count[idx], w_count[idx], output_checksum[idx],
                     output_unknown_bytes[idx]);
            clear_status;
        end
    endtask

    integer i;
    integer final_idx;
    reg [31:0] final_checksum;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        init_bus;
        init_r1f_smoke_tasks;
        monitor_active = 1'b0;
        monitor_idx = 0;
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
        end
        for (i = 0; i < 4096; i = i + 1)
            u_ram.ram[i] = 256'd0;

        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (6) @(posedge clk);

        $display("=== R1f npu_top contiguous residual-slice smoke ===");
        $display("R1F_NPU_TOP_SCOPE slice=layer1.0.conv1,layer1.0.conv2,layer1.0.add full_resnet=0 compact_alias=1");

        for (i = 0; i < R1F_TASK_COUNT; i = i + 1)
            execute_task(i);

        final_idx = R1F_TASK_COUNT - 1;
        final_checksum = output_checksum[final_idx];
        $display("R1F_NPU_TOP_RESULT tasks=%0d final_tensor=%0s final_checksum_masked=0x%08h final_unknown_bytes=%0d PASS",
                 R1F_TASK_COUNT, r1f_tensor_name[r1f_dst_tensor_idx[final_idx]],
                 final_checksum, output_unknown_bytes[final_idx]);
        $display("tb_resnet20_r1f_npu_top_smoke PASS");
        $finish;
    end
endmodule
