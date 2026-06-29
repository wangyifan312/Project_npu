`timescale 1ns / 1ps

module tb_top;

    reg         clk;
    reg         rst_n;
    reg         tb_axil_enable;
    reg         tb_awvalid;
    wire        tb_awready;
    reg  [31:0] tb_awaddr;
    reg         tb_wvalid;
    wire        tb_wready;
    reg  [31:0] tb_wdata;
    reg  [3:0]  tb_wstrb;
    wire        tb_bvalid;
    reg         tb_bready;
    wire [1:0]  tb_bresp;
    reg         tb_arvalid;
    wire        tb_arready;
    reg  [31:0] tb_araddr;
    wire        tb_rvalid;
    reg         tb_rready;
    wire [31:0] tb_rdata;
    wire [1:0]  tb_rresp;
    wire        cpu_trap;
    wire [31:0] npu_status;

    localparam INPUT_ADDR  = 32'h0000_0100;
    localparam WEIGHT_ADDR = 32'h0000_0200;
    localparam OUTPUT_ADDR = 32'h0000_0300;
    localparam NPU_BASE    = 32'h1000_0000;
    localparam PERF_CYCLE_LO      = NPU_BASE + 32'h30;
    localparam PERF_CYCLE_HI      = NPU_BASE + 32'h34;
    localparam PERF_READ_BEATS    = NPU_BASE + 32'h38;
    localparam PERF_WRITE_BEATS   = NPU_BASE + 32'h3C;
    localparam PERF_READ_ACTIVE   = NPU_BASE + 32'h40;
    localparam PERF_WRITE_ACTIVE  = NPU_BASE + 32'h44;
    localparam PERF_ARRAY_ACTIVE  = NPU_BASE + 32'h48;
    localparam PERF_ARRAY_STALL   = NPU_BASE + 32'h4C;
    localparam PERF_MAC_LO        = NPU_BASE + 32'h50;
    localparam PERF_MAC_HI        = NPU_BASE + 32'h54;
    localparam PERF_CLUSTER_ACTIVE = NPU_BASE + 32'h58;
    localparam PERF_CLUSTER_STALL  = NPU_BASE + 32'h5C;
    localparam PERF_CLUSTER_CFG    = NPU_BASE + 32'h60;

    top #(
        .NPU_TILE_ROWS(16),
        .NPU_TILE_COLS(16)
    ) u_top (
        .clk(clk),
        .rst_n(rst_n),
        .tb_axil_enable(tb_axil_enable),
        .tb_awvalid(tb_awvalid),
        .tb_awready(tb_awready),
        .tb_awaddr(tb_awaddr),
        .tb_wvalid(tb_wvalid),
        .tb_wready(tb_wready),
        .tb_wdata(tb_wdata),
        .tb_wstrb(tb_wstrb),
        .tb_bvalid(tb_bvalid),
        .tb_bready(tb_bready),
        .tb_bresp(tb_bresp),
        .tb_arvalid(tb_arvalid),
        .tb_arready(tb_arready),
        .tb_araddr(tb_araddr),
        .tb_rvalid(tb_rvalid),
        .tb_rready(tb_rready),
        .tb_rdata(tb_rdata),
        .tb_rresp(tb_rresp),
        .cpu_trap(cpu_trap),
        .npu_status(npu_status)
    );

    always #2.5 clk = ~clk;

    task axil_write;
        input [31:0] addr;
        input [31:0] data;
        reg aw_done;
        reg w_done;
        begin
            aw_done = 1'b0;
            w_done = 1'b0;
            tb_awvalid <= 1'b1;
            tb_awaddr  <= addr;
            tb_wvalid  <= 1'b1;
            tb_wdata   <= data;
            tb_wstrb   <= 4'hF;
            while (!(aw_done && w_done)) begin
                @(posedge clk);
                if (tb_awvalid && tb_awready) begin
                    tb_awvalid <= 1'b0;
                    aw_done = 1'b1;
                end
                if (tb_wvalid && tb_wready) begin
                    tb_wvalid <= 1'b0;
                    w_done = 1'b1;
                end
            end
            tb_bready  <= 1'b1;
            wait (tb_bvalid);
            @(posedge clk);
            tb_bready  <= 1'b0;
        end
    endtask

    task report_perf;
        input [127:0] tag;
        input [31:0] expected_mac_lo;
        reg [31:0] cycle_lo;
        reg [31:0] cycle_hi;
        reg [31:0] read_beats;
        reg [31:0] write_beats;
        reg [31:0] read_active;
        reg [31:0] write_active;
        reg [31:0] array_active;
        reg [31:0] array_stall;
        reg [31:0] mac_lo;
        reg [31:0] mac_hi;
        reg [31:0] cluster_active;
        reg [31:0] cluster_stall;
        reg [31:0] cluster_cfg;
        real read_bw_util;
        real write_bw_util;
        real array_util;
        begin
            axil_read(PERF_CYCLE_LO, cycle_lo);
            axil_read(PERF_CYCLE_HI, cycle_hi);
            axil_read(PERF_READ_BEATS, read_beats);
            axil_read(PERF_WRITE_BEATS, write_beats);
            axil_read(PERF_READ_ACTIVE, read_active);
            axil_read(PERF_WRITE_ACTIVE, write_active);
            axil_read(PERF_ARRAY_ACTIVE, array_active);
            axil_read(PERF_ARRAY_STALL, array_stall);
            axil_read(PERF_MAC_LO, mac_lo);
            axil_read(PERF_MAC_HI, mac_hi);
            axil_read(PERF_CLUSTER_ACTIVE, cluster_active);
            axil_read(PERF_CLUSTER_STALL, cluster_stall);
            axil_read(PERF_CLUSTER_CFG, cluster_cfg);

            if (mac_lo !== expected_mac_lo || mac_hi !== 32'd0)
                $fatal(1, "%0s perf mac mismatch got 0x%08x_%08x expect 0x00000000_%08x", tag, mac_hi, mac_lo, expected_mac_lo);
            if (cycle_lo == 32'd0)
                $fatal(1, "%0s perf cycles should be non-zero", tag);
            if (cluster_cfg[7:0] !== 8'h01)
                $fatal(1, "%0s cluster cfg mismatch: 0x%08x", tag, cluster_cfg);

            read_bw_util = (read_active != 0) ? (read_beats * 1.0 / read_active) : 0.0;
            write_bw_util = (write_active != 0) ? (write_beats * 1.0 / write_active) : 0.0;
            array_util = (cycle_lo != 0) ? (array_active * 1.0 / cycle_lo) : 0.0;

            $display("PERF %0s cycles=%0d read_beats=%0d write_beats=%0d read_bw_util=%0.4f write_bw_util=%0.4f array_active=%0d array_stall=%0d cluster_active=%0d cluster_stall=%0d mac=%0d cluster_cfg=0x%08x array_util=%0.4f",
                     tag, cycle_lo, read_beats, write_beats, read_bw_util, write_bw_util,
                     array_active, array_stall, cluster_active, cluster_stall, mac_lo, cluster_cfg, array_util);
        end
    endtask

    task axil_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            tb_arvalid <= 1'b1;
            tb_araddr  <= addr;
            @(posedge clk);
            while (!tb_arready)
                @(posedge clk);
            tb_arvalid <= 1'b0;
            tb_rready  <= 1'b1;
            wait (tb_rvalid);
            data = tb_rdata;
            @(posedge clk);
            tb_rready  <= 1'b0;
        end
    endtask

    task wait_done;
        input integer max_cycles;
        integer cnt;
        begin
            cnt = 0;
            while (!npu_status[2] && !npu_status[3] && cnt < max_cycles) begin
                @(posedge clk);
                cnt = cnt + 1;
            end
            if (npu_status[3])
                $fatal(1, "top-level NPU error");
            if (!npu_status[2])
                $fatal(1, "top-level timeout");
        end
    endtask

    integer word_idx;
    reg [31:0] rd_data;

    initial begin
        $dumpfile("sim/tb_top.vcd");
        $dumpvars(0, tb_top);

        clk = 1'b0;
        rst_n = 1'b0;
        tb_axil_enable = 1'b1;
        tb_awvalid = 1'b0;
        tb_awaddr  = 32'h0;
        tb_wvalid  = 1'b0;
        tb_wdata   = 32'h0;
        tb_wstrb   = 4'h0;
        tb_bready  = 1'b0;
        tb_arvalid = 1'b0;
        tb_araddr  = 32'h0;
        tb_rready  = 1'b0;

        #20;
        rst_n = 1'b1;
        #20;

        $display("=== AXI-Lite write shared memory ===");
        for (word_idx = 0; word_idx < 7; word_idx = word_idx + 1)
            axil_write(INPUT_ADDR + word_idx*4, 32'h01010101);
        for (word_idx = 0; word_idx < 7; word_idx = word_idx + 1)
            axil_write(WEIGHT_ADDR + word_idx*4, 32'h02020202);
        axil_write(OUTPUT_ADDR, 32'h0);

        axil_read(INPUT_ADDR, rd_data);
        if (rd_data !== 32'h01010101)
            $fatal(1, "shared memory readback mismatch for input");
        axil_read(WEIGHT_ADDR, rd_data);
        if (rd_data !== 32'h02020202)
            $fatal(1, "shared memory readback mismatch for weight");

        $display("=== Configure NPU through top AXI-Lite ===");
        axil_write(NPU_BASE + 32'h08, 32'h0);
        axil_write(NPU_BASE + 32'h0C, INPUT_ADDR);
        axil_write(NPU_BASE + 32'h10, WEIGHT_ADDR);
        axil_write(NPU_BASE + 32'h14, OUTPUT_ADDR);
        axil_write(NPU_BASE + 32'h18, 32'd25);
        axil_write(NPU_BASE + 32'h1C, 32'd25);
        axil_write(NPU_BASE + 32'h20, 32'd4);
        axil_write(NPU_BASE + 32'h24, {16'd5, 16'd5});
        axil_write(NPU_BASE + 32'h28, {16'd1, 16'd1});
        axil_write(NPU_BASE + 32'h2C, 32'h0);
        axil_write(NPU_BASE + 32'h00, 32'h1);

        wait_done(400000);

        $display("=== AXI-Lite read output shared memory ===");
        axil_read(OUTPUT_ADDR, rd_data);
        if ($signed(rd_data) !== 32'sd50)
            $fatal(1, "output mismatch got %0d expect 50", $signed(rd_data));

        report_perf("top_conv_smoke", 32'd25);

        $display("tb_top PASS");
        $finish;
    end

endmodule
