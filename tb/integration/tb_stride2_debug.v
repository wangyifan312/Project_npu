// tb_stride2_debug: MODE_DUAL + 3x3 stride2 X-injection debug
// Test A: MODE_SINGLE, 16ch -> baseline (should be clean)
// Test B: MODE_DUAL,   16ch -> dual-cluster minimal test
// Test C: MODE_DUAL,   32ch -> matches R1j task 0 config
`timescale 1ns / 1ps

module tb_stride2_debug;
    reg clk, rst_n;
    reg s_axi_awvalid, s_axi_wvalid, s_axi_bready, s_axi_arvalid, s_axi_rready;
    reg [31:0] s_axi_awaddr, s_axi_wdata, s_axi_araddr;
    reg [3:0] s_axi_wstrb;
    wire s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
    wire [1:0] s_axi_bresp, s_axi_rresp;
    wire [31:0] s_axi_rdata;
    wire npu_arvalid, npu_arready, npu_rvalid, npu_rready, npu_rlast;
    wire [31:0] npu_araddr; wire [7:0] npu_arlen; wire [2:0] npu_arsize; wire [1:0] npu_arburst;
    wire [255:0] npu_rdata; wire [1:0] npu_rresp;
    wire npu_awvalid, npu_awready, npu_wvalid, npu_wready, npu_wlast, npu_bvalid, npu_bready;
    wire [31:0] npu_awaddr; wire [7:0] npu_awlen; wire [2:0] npu_awsize; wire [1:0] npu_awburst;
    wire [255:0] npu_wdata; wire [31:0] npu_wstrb; wire [1:0] npu_bresp;
    wire npu_busy, npu_done, npu_error;
    wire [7:0] npu_error_code;

    localparam [31:0] ADDR_CTRL=32'h0, ADDR_TASK_TYPE=32'h8, ADDR_INPUT_ADDR=32'hc;
    localparam [31:0] ADDR_WEIGHT_ADDR=32'h10, ADDR_OUTPUT_ADDR=32'h14;
    localparam [31:0] ADDR_INPUT_BYTES=32'h18, ADDR_WEIGHT_BYTES=32'h1c, ADDR_OUTPUT_BYTES=32'h20;
    localparam [31:0] ADDR_DIM_IN=32'h24, ADDR_DIM_OUT=32'h28, ADDR_POSTPROC=32'h2c;
    localparam [31:0] ADDR_REQUANT_SEL=32'h64, ADDR_RQ0_MULT=32'h68, ADDR_RQ0_SHIFT=32'h6c;
    localparam [31:0] ADDR_CONV_CFG=32'h98, ADDR_BIAS_ADDR=32'h9c, ADDR_BIAS_BYTES=32'ha0;
    localparam [31:0] ADDR_SRC1_ADDR=32'ha4, ADDR_SRC1_BYTES=32'ha8, ADDR_ADD_CFG=32'hac;
    localparam [31:0] ADDR_CLUSTER_MODE=32'h88, ADDR_CLUSTER_MASK=32'h8c;

    npu_top #(.TILE_ROWS(4), .TILE_COLS(4), .BUF_ENTRIES(16384), .BUF_ADDR_W(14))
    u_npu (.clk(clk), .rst_n(rst_n),
        .s_axi_awvalid, .s_axi_awready, .s_axi_awaddr, .s_axi_wvalid, .s_axi_wready,
        .s_axi_wdata, .s_axi_wstrb, .s_axi_bvalid, .s_axi_bready, .s_axi_bresp,
        .s_axi_arvalid, .s_axi_arready, .s_axi_araddr, .s_axi_rvalid, .s_axi_rready,
        .s_axi_rdata, .s_axi_rresp,
        .m_axi_arvalid(npu_arvalid), .m_axi_arready(npu_arready),
        .m_axi_araddr(npu_araddr), .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize), .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(npu_rvalid), .m_axi_rready(npu_rready),
        .m_axi_rdata(npu_rdata), .m_axi_rlast(npu_rlast), .m_axi_rresp(npu_rresp),
        .m_axi_awvalid(npu_awvalid), .m_axi_awready(npu_awready),
        .m_axi_awaddr(npu_awaddr), .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize), .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid), .m_axi_wready(npu_wready),
        .m_axi_wdata(npu_wdata), .m_axi_wlast(npu_wlast), .m_axi_wstrb(npu_wstrb),
        .m_axi_bvalid(npu_bvalid), .m_axi_bready(npu_bready), .m_axi_bresp(npu_bresp),
        .npu_busy, .npu_done, .npu_error, .npu_error_code);

    axi4_ram #(.RAM_DEPTH(32768)) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(npu_awvalid), .s_axi_awready(npu_awready),
        .s_axi_awaddr(npu_awaddr), .s_axi_awlen(npu_awlen),
        .s_axi_awsize(npu_awsize), .s_axi_awburst(npu_awburst),
        .s_axi_wvalid(npu_wvalid), .s_axi_wready(npu_wready),
        .s_axi_wdata(npu_wdata), .s_axi_wstrb(npu_wstrb), .s_axi_wlast(npu_wlast),
        .s_axi_bvalid(npu_bvalid), .s_axi_bready(npu_bready), .s_axi_bresp(npu_bresp),
        .s_axi_arvalid(npu_arvalid), .s_axi_arready(npu_arready),
        .s_axi_araddr(npu_araddr), .s_axi_arlen(npu_arlen),
        .s_axi_arsize(npu_arsize), .s_axi_arburst(npu_arburst),
        .s_axi_rvalid(npu_rvalid), .s_axi_rready(npu_rready),
        .s_axi_rdata(npu_rdata), .s_axi_rlast(npu_rlast), .s_axi_rresp(npu_rresp));

    always #2.5 clk = ~clk;

    task fail; input [1023:0] msg; begin
        $display("DEBUG_TB FAIL: %0s", msg); $finish;
    end endtask

    task init_bus; begin
        s_axi_awvalid=0; s_axi_wvalid=0; s_axi_wstrb=4'hf;
        s_axi_bready=0; s_axi_arvalid=0; s_axi_rready=0;
    end endtask

    task axi_write; input [31:0] addr, data;
        reg aw_done, w_done; integer to; begin
            @(posedge clk);
            s_axi_awvalid=1; s_axi_awaddr=addr; s_axi_wvalid=1; s_axi_wdata=data;
            s_axi_wstrb=4'hf; aw_done=0; w_done=0; to=0;
            while ((!aw_done||!w_done) && to<1000) begin
                @(posedge clk); to=to+1;
                if (s_axi_awvalid&&s_axi_awready) begin aw_done=1; s_axi_awvalid=0; end
                if (s_axi_wvalid&&s_axi_wready) begin w_done=1; s_axi_wvalid=0; end
            end
            if (!aw_done||!w_done) fail("AXI write timeout");
            s_axi_bready=1; @(posedge clk); to=0;
            while (!s_axi_bvalid && to<1000) begin @(posedge clk); to=to+1; end
            if (!s_axi_bvalid) fail("AXI bvalid timeout");
            if (s_axi_bresp!==2'b00) fail("AXI write err");
            @(posedge clk); s_axi_bready=0;
    end endtask

    task ram_wb; input [31:0] a; input [7:0] d;
        integer beat,lane; begin beat=a>>5; lane=a[4:0];
        u_ram.ram[beat][lane*8+:8]=d; end
    endtask

    function [7:0] ram_rb; input [31:0] a;
        integer beat,lane; begin beat=a>>5; lane=a[4:0];
        ram_rb=u_ram.ram[beat][lane*8+:8]; end
    endfunction

    reg [7:0] lb [0:16383];
    reg [7:0] exp_b [0:16383];
    integer kk;

    task run_test;
        input [1023:0] label;
        input [31:0] cluster_mode;
        input [31:0] out_c;
        input [31:0] out_bytes;
        input [31:0] wgt_bytes;
        input [31:0] bias_bytes;
        input [1023:0] fixture_dir;
        input [31:0] exp_csum;
        reg [31:0] out_addr;
        integer j, mismatch, unknown, first_mm, first_x;
        reg [7:0] exp_v, act_v; reg act_x;
        reg [31:0] act_csum;
        begin
            $display("=== %0s ===", label);
            $display("DEBUG_TB_TEST %0s cluster_mode=%0d out_c=%0d", label, cluster_mode, out_c);

            // Clear RAM
            for (kk=0; kk<32768; kk=kk+1) u_ram.ram[kk]=256'd0;

            // Load input (always 16ch 32x32 = 16384 bytes)
            $readmemh({fixture_dir, "/input.memh"}, lb);
            for (kk=0; kk<16384; kk=kk+1) ram_wb(64+kk, lb[kk]);

            // Load weights
            $readmemh({fixture_dir, "/weights.memh"}, lb);
            for (kk=0; kk<wgt_bytes; kk=kk+1) ram_wb(524288+kk, lb[kk]);

            // Load bias as byte stream
            $readmemh({fixture_dir, "/bias_bytes.memh"}, lb);
            for (kk=0; kk<bias_bytes; kk=kk+1) ram_wb(528384+kk, lb[kk]);

            // Load expected output
            $readmemh({fixture_dir, "/expected.memh"}, lb);
            for (kk=0; kk<out_bytes; kk=kk+1) exp_b[kk]=lb[kk];

            // Cluster config
            axi_write(ADDR_CLUSTER_MODE, cluster_mode);
            axi_write(ADDR_CLUSTER_MASK, 32'h3f);

            // Program conv task
            out_addr = (out_c == 32) ? 32'd166976 : 32'd3136;
            axi_write(ADDR_TASK_TYPE, 32'd0);
            axi_write(ADDR_INPUT_ADDR, 32'd64);
            axi_write(ADDR_WEIGHT_ADDR, 32'd524288);
            axi_write(ADDR_OUTPUT_ADDR, out_addr);
            axi_write(ADDR_INPUT_BYTES, 32'd16384);
            axi_write(ADDR_WEIGHT_BYTES, wgt_bytes);
            axi_write(ADDR_OUTPUT_BYTES, out_bytes);
            axi_write(ADDR_DIM_IN, {16'd32, 16'd32});
            axi_write(ADDR_DIM_OUT, {out_c[15:0], 16'd16});
            axi_write(ADDR_POSTPROC, 32'd0);
            axi_write(ADDR_REQUANT_SEL, 32'd0);
            axi_write(ADDR_RQ0_MULT, 32'd1234567);
            axi_write(ADDR_RQ0_SHIFT, 32'd27);
            axi_write(ADDR_CONV_CFG, 32'd30);
            axi_write(ADDR_BIAS_ADDR, 32'd528384);
            axi_write(ADDR_BIAS_BYTES, bias_bytes);
            axi_write(ADDR_SRC1_ADDR, 32'd0);
            axi_write(ADDR_SRC1_BYTES, 32'd0);
            axi_write(ADDR_ADD_CFG, 32'd0);

            // Start
            axi_write(ADDR_CTRL, 32'h1);

            // Wait
            begin integer cnt; cnt=0;
            while (!npu_done && !npu_error && cnt<12000000) begin
                @(posedge clk); cnt=cnt+1;
                if ((cnt%500000)==0) $display("  progress cyc=%0d busy=%0b", cnt, npu_busy);
            end
            if (npu_error) begin
                $display("  ERROR code=0x%02h", npu_error_code);
                fail({label, " npu_error"});
            end
            if (!npu_done) fail({label, " timeout"});
            end

            // Compare
            mismatch=0; unknown=0; first_mm=-1; first_x=-1; act_csum=0;
            for (j=0; j<out_bytes; j=j+1) begin
                exp_v = exp_b[j];
                act_v = ram_rb(out_addr + j);
                act_x = $isunknown(act_v) ? 1 : 0;
                act_csum = (act_csum + ({24'd0, act_x ? 8'd0 : act_v} * (j+1))) & 32'hffff_ffff;
                if (act_x) begin
                    unknown=unknown+1;
                    if (first_x<0) first_x=j;
                end else if (act_v !== exp_v) begin
                    mismatch=mismatch+1;
                    if (first_mm<0) begin
                        first_mm=j;
                        $display("  FIRST_MISMATCH byte=%0d (oh=%0d ow=%0d oc=%0d) exp=0x%02h act=0x%02h",
                                 j, (j/(out_c*16))/16, (j/out_c)%16, j%out_c, exp_v, act_v);
                    end
                end
            end
            if (first_x>=0) begin
                j=first_x;
                $display("  FIRST_UNKNOWN byte=%0d (oh=%0d ow=%0d oc=%0d)",
                         j, (j/(out_c*16))/16, (j/out_c)%16, j%out_c);
            end
            $display("  RESULT compared=%0d mismatch=%0d unknown=%0d exp_csum=0x%08h act_csum=0x%08h",
                     out_bytes, mismatch, unknown, exp_csum, act_csum);
            $display("  VERDICT: %0s",
                     (unknown==0&&mismatch==0)?"CLEAN":
                     (unknown>0)?"X_DETECTED":"ARITH_MISMATCH");

            // Clear status for next test
            axi_write(ADDR_CTRL, 32'h10);
        end
    endtask

    initial begin
        clk=0; rst_n=0; init_bus;
        for (kk=0; kk<32768; kk=kk+1) u_ram.ram[kk]=256'd0;
        repeat(6) @(posedge clk); rst_n=1; repeat(6) @(posedge clk);

        $display("================================================");
        $display(" stride2 MODE_DUAL X-injection debug");
        $display("================================================");

        // Test A: MODE_SINGLE, 16ch (baseline, should be clean)
        run_test("Test_A_SINGLE_16ch", 32'd0, 32'd16, 32'd4096, 32'd2304, 32'd64,
                 "tb/generated/stride2_smoke", 32'h1002919e);

        // Test B: MODE_DUAL, 16ch (each cluster 8ch)
        run_test("Test_B_DUAL_16ch", 32'd1, 32'd16, 32'd4096, 32'd2304, 32'd64,
                 "tb/generated/stride2_smoke", 32'h1002919e);

        // Test C: MODE_DUAL, 32ch (each cluster 16ch, matches R1j task 0)
        run_test("Test_C_DUAL_32ch", 32'd1, 32'd32, 32'd8192, 32'd4608, 32'd128,
                 "tb/generated/stride2_smoke_32ch", 32'h4398760d);

        $display("================================================");
        $display(" tb_stride2_debug FINISH");
        $display("================================================");
        $finish;
    end
endmodule
