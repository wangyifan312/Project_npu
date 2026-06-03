// tb_fc_formal_sanity: minimal formal FC path smoke on 16x16 dual-cluster NPU.
`timescale 1ns / 1ps

module tb_fc_formal_sanity;
    reg clk, rst_n;
    reg s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    reg [31:0] s_axi_awaddr, s_axi_wdata;
    reg [3:0] s_axi_wstrb;

    wire s_axi_awready, s_axi_wready, s_axi_bvalid;
    wire [1:0] s_axi_bresp;
    wire npu_busy, npu_done, npu_error;
    wire [7:0] npu_error_code;
    wire npu_arvalid, npu_awvalid, npu_wvalid, npu_wlast;
    wire [31:0] npu_araddr, npu_awaddr, npu_wdata;
    wire [7:0] npu_arlen, npu_awlen;
    wire [2:0] npu_arsize, npu_awsize;
    wire [1:0] npu_arburst, npu_awburst;
    wire [3:0] npu_wstrb;
    wire npu_rready, npu_bready;
    wire ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0] ram_bresp, ram_rresp;
    wire ram_rvalid, ram_rlast;
    wire [31:0] ram_rdata;

    localparam INPUT_ADDR  = 32'h0000_0100;
    localparam WEIGHT_ADDR = 32'h0000_0200;
    localparam OUTPUT_ADDR = 32'h0000_0300;
    localparam NPU_BASE    = 32'h1000_0000;

    npu_top #(
        .TILE_ROWS(16),
        .TILE_COLS(16),
        .BUF_ENTRIES(256),
        .BUF_ADDR_W(8),
        .CLUSTER_MODE(2'd1),
        .CLUSTER_MASK_REQ(6'b00_0011)
    ) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(1'b0), .s_axi_arready(), .s_axi_araddr(32'h0),
        .s_axi_rvalid(), .s_axi_rready(1'b0), .s_axi_rdata(), .s_axi_rresp(),
        .m_axi_arvalid(npu_arvalid), .m_axi_arready(ram_arready),
        .m_axi_araddr(npu_araddr), .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize), .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(ram_rvalid), .m_axi_rready(npu_rready),
        .m_axi_rdata(ram_rdata), .m_axi_rlast(ram_rlast), .m_axi_rresp(ram_rresp),
        .m_axi_awvalid(npu_awvalid), .m_axi_awready(ram_awready),
        .m_axi_awaddr(npu_awaddr), .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize), .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid), .m_axi_wready(ram_wready),
        .m_axi_wdata(npu_wdata), .m_axi_wlast(npu_wlast),
        .m_axi_wstrb(npu_wstrb), .m_axi_bvalid(ram_bvalid),
        .m_axi_bready(npu_bready), .m_axi_bresp(ram_bresp),
        .npu_busy(npu_busy), .npu_done(npu_done),
        .npu_error(npu_error), .npu_error_code(npu_error_code)
    );

    axi4_ram #(.RAM_DEPTH(4096)) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(npu_awvalid), .s_axi_awready(ram_awready),
        .s_axi_awaddr(npu_awaddr), .s_axi_awlen(npu_awlen),
        .s_axi_awsize(npu_awsize), .s_axi_awburst(npu_awburst),
        .s_axi_wvalid(npu_wvalid), .s_axi_wready(ram_wready),
        .s_axi_wdata(npu_wdata), .s_axi_wstrb(npu_wstrb),
        .s_axi_wlast(npu_wlast), .s_axi_bvalid(ram_bvalid),
        .s_axi_bready(npu_bready), .s_axi_bresp(ram_bresp),
        .s_axi_arvalid(npu_arvalid), .s_axi_arready(ram_arready),
        .s_axi_araddr(npu_araddr), .s_axi_arlen(npu_arlen),
        .s_axi_arsize(npu_arsize), .s_axi_arburst(npu_arburst),
        .s_axi_rvalid(ram_rvalid), .s_axi_rready(npu_rready),
        .s_axi_rdata(ram_rdata), .s_axi_rlast(ram_rlast),
        .s_axi_rresp(ram_rresp)
    );

    always #2.5 clk = ~clk;

    task axi_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            s_axi_awvalid <= 1'b1;
            s_axi_awaddr  <= addr;
            s_axi_wvalid  <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            @(posedge clk);
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;
            s_axi_bready  <= 1'b1;
            wait (s_axi_bvalid);
            @(posedge clk);
            s_axi_bready  <= 1'b0;
        end
    endtask

    task wait_done;
        input integer max_cycles;
        integer cnt;
        begin
            cnt = 0;
            while (!npu_done && !npu_error && cnt < max_cycles) begin
                @(posedge clk);
                cnt = cnt + 1;
            end
            if (npu_error)
                $fatal(1, "NPU error code=0x%02x", npu_error_code);
            if (!npu_done)
                $fatal(1, "FC formal sanity timeout");
        end
    endtask

    reg seen_output_arbiter;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            seen_output_arbiter <= 1'b0;
        else if (u_npu.cluster_arb_out_valid)
            seen_output_arbiter <= 1'b1;
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        s_axi_awvalid = 1'b0;
        s_axi_wvalid = 1'b0;
        s_axi_bready = 1'b0;
        s_axi_awaddr = 32'h0;
        s_axi_wdata = 32'h0;
        s_axi_wstrb = 4'h0;

        #20 rst_n = 1'b1;
        #20;

        u_ram.ram[INPUT_ADDR >> 2] = 32'h0702FD05; // [5, -3, 2, 7]
        u_ram.ram[WEIGHT_ADDR >> 2] = 32'h01010101;
        u_ram.ram[(WEIGHT_ADDR >> 2) + 1] = 32'h02020202;
        u_ram.ram[OUTPUT_ADDR >> 2] = 32'd0;
        u_ram.ram[(OUTPUT_ADDR >> 2) + 1] = 32'd0;

        axi_write(NPU_BASE + 32'h08, 32'h1);
        axi_write(NPU_BASE + 32'h0C, INPUT_ADDR);
        axi_write(NPU_BASE + 32'h10, WEIGHT_ADDR);
        axi_write(NPU_BASE + 32'h14, OUTPUT_ADDR);
        axi_write(NPU_BASE + 32'h18, 32'd4);
        axi_write(NPU_BASE + 32'h1C, 32'd8);
        axi_write(NPU_BASE + 32'h20, 32'd8);
        axi_write(NPU_BASE + 32'h24, {16'd1, 16'd1});
        axi_write(NPU_BASE + 32'h28, {16'd2, 16'd4});
        axi_write(NPU_BASE + 32'h2C, 32'h0);
        axi_write(NPU_BASE + 32'h00, 32'h1);

        wait_done(200000);

        if (!seen_output_arbiter)
            $fatal(1, "FC formal sanity did not observe output_arbiter");
        if ($signed(u_ram.ram[OUTPUT_ADDR >> 2]) !== 32'sd11)
            $fatal(1, "FC out0 mismatch got %0d", $signed(u_ram.ram[OUTPUT_ADDR >> 2]));
        if ($signed(u_ram.ram[(OUTPUT_ADDR >> 2) + 1]) !== 32'sd22)
            $fatal(1, "FC out1 mismatch got %0d", $signed(u_ram.ram[(OUTPUT_ADDR >> 2) + 1]));

        $display("FC_FORMAL_SANITY PASS out0=%0d out1=%0d", $signed(u_ram.ram[OUTPUT_ADDR >> 2]), $signed(u_ram.ram[(OUTPUT_ADDR >> 2) + 1]));
        $finish;
    end
endmodule
