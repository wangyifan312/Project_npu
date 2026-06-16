`timescale 1ns / 1ps

module tb_npu_runtime_cluster_config;
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

    wire [31:0] m_axi_araddr;
    wire        m_axi_arvalid;
    reg         m_axi_arready;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    reg  [255:0] m_axi_rdata;
    reg         m_axi_rvalid;
    wire        m_axi_rready;
    reg         m_axi_rlast;
    reg  [1:0]  m_axi_rresp;
    wire [31:0] m_axi_awaddr;
    wire        m_axi_awvalid;
    reg         m_axi_awready;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire [255:0] m_axi_wdata;
    wire        m_axi_wvalid;
    reg         m_axi_wready;
    wire        m_axi_wlast;
    wire [31:0] m_axi_wstrb;
    reg  [1:0]  m_axi_bresp;
    reg         m_axi_bvalid;
    wire        m_axi_bready;
    wire        npu_busy;
    wire        npu_done;
    wire        npu_error;
    wire [7:0]  npu_error_code;

    localparam ADDR_PERF_CLUSTER_CFG = 32'h0000_0060;
    localparam ADDR_CLUSTER_MODE     = 32'h0000_0088;
    localparam ADDR_CLUSTER_MASK     = 32'h0000_008c;

    npu_top #(
        .BUF_ENTRIES(64),
        .BUF_ADDR_W(6),
        .TILE_ROWS(4),
        .TILE_COLS(16),
        .CLUSTER_MODE(2'd1),
        .CLUSTER_MASK_REQ(6'b00_0011)
    ) dut (
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

    task fail;
        input [255:0] msg;
        begin
            $display("FAIL tb_npu_runtime_cluster_config: %0s", msg);
            $fatal(1);
        end
    endtask

    task axil_write;
        input [31:0] addr;
        input [31:0] data;
        reg aw_seen;
        reg w_seen;
        begin
            aw_seen = 1'b0;
            w_seen = 1'b0;
            awaddr <= addr;
            wdata <= data;
            wstrb <= 4'hf;
            awvalid <= 1'b1;
            wvalid <= 1'b1;
            while (!(aw_seen && w_seen)) begin
                @(posedge clk);
                if (awvalid && awready) begin
                    awvalid <= 1'b0;
                    aw_seen = 1'b1;
                end
                if (wvalid && wready) begin
                    wvalid <= 1'b0;
                    w_seen = 1'b1;
                end
            end
            bready <= 1'b1;
            while (!bvalid) @(posedge clk);
            if (bresp !== 2'b00)
                fail("AXI-Lite write returned error");
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    task axil_read;
        input [31:0] addr;
        output [31:0] data;
        begin
            araddr <= addr;
            arvalid <= 1'b1;
            while (!arready) @(posedge clk);
            @(posedge clk);
            arvalid <= 1'b0;
            rready <= 1'b1;
            while (!rvalid) @(posedge clk);
            data = rdata;
            if (rresp !== 2'b00)
                fail("AXI-Lite read returned error");
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    task check_cfg;
        input [127:0] name;
        input [1:0] exp_mode;
        input [5:0] exp_mask;
        input [5:0] exp_enable;
        reg [31:0] mode_rd;
        reg [31:0] mask_rd;
        reg [31:0] cfg_rd;
        begin
            axil_read(ADDR_CLUSTER_MODE, mode_rd);
            axil_read(ADDR_CLUSTER_MASK, mask_rd);
            axil_read(ADDR_PERF_CLUSTER_CFG, cfg_rd);
            if (mode_rd[1:0] !== exp_mode)
                fail("cluster mode readback mismatch");
            if (mask_rd[5:0] !== exp_mask)
                fail("cluster mask readback mismatch");
            if (cfg_rd[7:0] !== {exp_mode, exp_enable})
                fail("perf cluster cfg mismatch");
            if (dut.perf_cluster_enable !== exp_enable)
                fail("scheduler cluster_enable mismatch");
            $display("RUNTIME_CLUSTER_CFG case=%0s mode=%0d mask=%b enable=%b perf_cfg=0x%02x status=PASS",
                     name, mode_rd[1:0], mask_rd[5:0], dut.perf_cluster_enable, cfg_rd[7:0]);
        end
    endtask

    initial begin
        #100000;
        fail("timeout");
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        awvalid = 1'b0;
        awaddr = 32'h0;
        wvalid = 1'b0;
        wdata = 32'h0;
        wstrb = 4'h0;
        bready = 1'b0;
        arvalid = 1'b0;
        araddr = 32'h0;
        rready = 1'b0;
        m_axi_arready = 1'b0;
        m_axi_rdata = 256'h0;
        m_axi_rvalid = 1'b0;
        m_axi_rlast = 1'b0;
        m_axi_rresp = 2'b00;
        m_axi_awready = 1'b0;
        m_axi_wready = 1'b0;
        m_axi_bresp = 2'b00;
        m_axi_bvalid = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        check_cfg("reset_dual_default", 2'd1, 6'b00_0011, 6'b00_0011);

        axil_write(ADDR_CLUSTER_MASK, 32'h0000_003f);
        axil_write(ADDR_CLUSTER_MODE, 32'h0000_0000);
        check_cfg("runtime_single", 2'd0, 6'b11_1111, 6'b00_0001);

        axil_write(ADDR_CLUSTER_MASK, 32'h0000_003f);
        axil_write(ADDR_CLUSTER_MODE, 32'h0000_0001);
        check_cfg("runtime_dual", 2'd1, 6'b11_1111, 6'b00_0011);

        axil_write(ADDR_CLUSTER_MASK, 32'h0000_003f);
        axil_write(ADDR_CLUSTER_MODE, 32'h0000_0002);
        check_cfg("runtime_full", 2'd2, 6'b11_1111, 6'b11_1111);

        axil_write(ADDR_CLUSTER_MASK, 32'h0000_002b);
        axil_write(ADDR_CLUSTER_MODE, 32'h0000_0003);
        check_cfg("runtime_mask", 2'd3, 6'b10_1011, 6'b10_1011);

        $display("PASS tb_npu_runtime_cluster_config");
        $finish;
    end
endmodule
