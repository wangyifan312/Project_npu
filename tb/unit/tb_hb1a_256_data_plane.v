`timescale 1ns / 1ps

module tb_hb1a_256_data_plane;
    reg clk;
    reg rst_n;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    integer errors;

    initial begin
        #10000000;
        $display("FAIL tb_hb1a_256_data_plane timeout");
        $display("DBG timeout axim_sel=%0d wr_state=%0d wr_done=%0b wr_done_seen=%0b wr_busy=%0b wr_ready=%0b wr_valid=%0b wr_awvalid=%0b wr_awready=%0b wr_wvalid=%0b wr_wready=%0b wr_wlast=%0b wr_bready=%0b ax_bvalid=%0b ram_bvalid=%0b beat_counter=%0d burst_len=%0d bytes_remaining=%0d",
                 axim_sel, u_dma_writer.state, wr_done, wr_done_seen, wr_busy, wr_ready, wr_valid,
                 wr_awvalid, ax_awready, wr_wvalid, ax_wready, wr_wlast, wr_bready,
                 ax_bvalid, u_axi4_ram.bvalid, u_dma_writer.beat_counter,
                 u_dma_writer.burst_len, u_dma_writer.bytes_remaining);
        $fatal(1);
    end

    function [255:0] beat_pattern;
        input [7:0] base;
        integer i;
        begin
            beat_pattern = 256'h0;
            for (i = 0; i < 32; i = i + 1)
                beat_pattern[i*8 +: 8] = base + i[7:0];
        end
    endfunction

    task check32;
        input [31:0] actual;
        input [31:0] expected;
        input [255:0] label;
        begin
            if (actual !== expected) begin
                $display("FAIL %0s actual=0x%08x expected=0x%08x", label, actual, expected);
                errors = errors + 1;
            end
        end
    endtask

    task check256;
        input [255:0] actual;
        input [255:0] expected;
        input [255:0] label;
        begin
            if (actual !== expected) begin
                $display("FAIL %0s actual=0x%064x expected=0x%064x", label, actual, expected);
                errors = errors + 1;
            end
        end
    endtask

    // ============================================================
    // shared_ram DUT
    // ============================================================
    reg         sh_cpu_awvalid;
    wire        sh_cpu_awready;
    reg  [31:0] sh_cpu_awaddr;
    reg         sh_cpu_wvalid;
    wire        sh_cpu_wready;
    reg  [31:0] sh_cpu_wdata;
    reg  [3:0]  sh_cpu_wstrb;
    wire        sh_cpu_bvalid;
    reg         sh_cpu_bready;
    reg         sh_cpu_arvalid;
    wire        sh_cpu_arready;
    reg  [31:0] sh_cpu_araddr;
    wire        sh_cpu_rvalid;
    reg         sh_cpu_rready;
    wire [31:0] sh_cpu_rdata;

    reg         sh_npu_awvalid;
    wire        sh_npu_awready;
    reg  [31:0] sh_npu_awaddr;
    reg  [7:0]  sh_npu_awlen;
    reg         sh_npu_wvalid;
    wire        sh_npu_wready;
    reg  [255:0] sh_npu_wdata;
    reg          sh_npu_wlast;
    reg  [31:0] sh_npu_wstrb;
    wire         sh_npu_bvalid;
    reg          sh_npu_bready;
    reg          sh_npu_arvalid;
    wire         sh_npu_arready;
    reg  [31:0] sh_npu_araddr;
    reg  [7:0]  sh_npu_arlen;
    wire         sh_npu_rvalid;
    reg          sh_npu_rready;
    wire [255:0] sh_npu_rdata;
    wire         sh_npu_rlast;

    shared_ram #(.RAM_DEPTH(32768)) u_shared_ram (
        .clk(clk), .rst_n(rst_n),
        .cpu_awvalid(sh_cpu_awvalid), .cpu_awready(sh_cpu_awready), .cpu_awaddr(sh_cpu_awaddr),
        .cpu_wvalid(sh_cpu_wvalid), .cpu_wready(sh_cpu_wready), .cpu_wdata(sh_cpu_wdata),
        .cpu_wstrb(sh_cpu_wstrb), .cpu_bvalid(sh_cpu_bvalid), .cpu_bready(sh_cpu_bready),
        .cpu_bresp(), .cpu_arvalid(sh_cpu_arvalid), .cpu_arready(sh_cpu_arready),
        .cpu_araddr(sh_cpu_araddr), .cpu_rvalid(sh_cpu_rvalid), .cpu_rready(sh_cpu_rready),
        .cpu_rdata(sh_cpu_rdata), .cpu_rresp(),
        .npu_awvalid(sh_npu_awvalid), .npu_awready(sh_npu_awready), .npu_awaddr(sh_npu_awaddr),
        .npu_awlen(sh_npu_awlen), .npu_awsize(3'd5), .npu_awburst(2'b01),
        .npu_wvalid(sh_npu_wvalid), .npu_wready(sh_npu_wready), .npu_wdata(sh_npu_wdata),
        .npu_wlast(sh_npu_wlast), .npu_wstrb(sh_npu_wstrb), .npu_bvalid(sh_npu_bvalid),
        .npu_bready(sh_npu_bready), .npu_bresp(), .npu_arvalid(sh_npu_arvalid),
        .npu_arready(sh_npu_arready), .npu_araddr(sh_npu_araddr), .npu_arlen(sh_npu_arlen),
        .npu_arsize(3'd5), .npu_arburst(2'b01), .npu_rvalid(sh_npu_rvalid),
        .npu_rready(sh_npu_rready), .npu_rdata(sh_npu_rdata), .npu_rlast(sh_npu_rlast),
        .npu_rresp()
    );

    task sh_cpu_write;
        input [31:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        begin
            @(posedge clk);
            sh_cpu_awaddr <= addr;
            sh_cpu_awvalid <= 1'b1;
            while (!sh_cpu_awready) @(posedge clk);
            @(posedge clk);
            sh_cpu_awvalid <= 1'b0;
            sh_cpu_wdata <= data;
            sh_cpu_wstrb <= strb;
            sh_cpu_wvalid <= 1'b1;
            sh_cpu_bready <= 1'b1;
            while (!sh_cpu_wready) @(posedge clk);
            @(posedge clk);
            sh_cpu_wvalid <= 1'b0;
            while (!sh_cpu_bvalid) @(posedge clk);
            @(posedge clk);
            sh_cpu_bready <= 1'b0;
        end
    endtask

    task sh_cpu_read;
        input [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            sh_cpu_araddr <= addr;
            sh_cpu_arvalid <= 1'b1;
            sh_cpu_rready <= 1'b1;
            while (!sh_cpu_arready) @(posedge clk);
            @(posedge clk);
            sh_cpu_arvalid <= 1'b0;
            while (!sh_cpu_rvalid) @(posedge clk);
            data = sh_cpu_rdata;
            @(posedge clk);
            sh_cpu_rready <= 1'b0;
        end
    endtask

    task sh_npu_write_beat;
        input [31:0] addr;
        input [255:0] data;
        input [31:0] strb;
        begin
            @(posedge clk);
            sh_npu_awaddr <= addr;
            sh_npu_awlen <= 8'd0;
            sh_npu_awvalid <= 1'b1;
            while (!sh_npu_awready) @(posedge clk);
            @(posedge clk);
            sh_npu_awvalid <= 1'b0;
            sh_npu_wdata <= data;
            sh_npu_wstrb <= strb;
            sh_npu_wlast <= 1'b1;
            sh_npu_wvalid <= 1'b1;
            sh_npu_bready <= 1'b1;
            while (!sh_npu_wready) @(posedge clk);
            @(posedge clk);
            sh_npu_wvalid <= 1'b0;
            sh_npu_wlast <= 1'b0;
            while (!sh_npu_bvalid) @(posedge clk);
            @(posedge clk);
            sh_npu_bready <= 1'b0;
        end
    endtask

    task sh_npu_read_beat;
        input [31:0] addr;
        output [255:0] data;
        begin
            @(posedge clk);
            sh_npu_araddr <= addr;
            sh_npu_arlen <= 8'd0;
            sh_npu_arvalid <= 1'b1;
            sh_npu_rready <= 1'b1;
            while (!sh_npu_arready) @(posedge clk);
            @(posedge clk);
            sh_npu_arvalid <= 1'b0;
            while (!sh_npu_rvalid) @(posedge clk);
            data = sh_npu_rdata;
            if (!sh_npu_rlast) begin
                $display("FAIL shared_ram NPU read expected rlast");
                errors = errors + 1;
            end
            @(posedge clk);
            sh_npu_rready <= 1'b0;
        end
    endtask

    // ============================================================
    // AXI4 RAM + DMA DUTs share one RAM instance.
    // The test muxes either direct AXI stimulus, dma_reader, or dma_writer.
    // ============================================================
    reg [1:0] axim_sel; // 0=direct, 1=dma_reader, 2=dma_writer

    reg         ax_awvalid_d;
    wire        ax_awready;
    reg  [31:0] ax_awaddr_d;
    reg  [7:0]  ax_awlen_d;
    reg         ax_wvalid_d;
    wire        ax_wready;
    reg  [255:0] ax_wdata_d;
    reg  [31:0]  ax_wstrb_d;
    reg          ax_wlast_d;
    wire         ax_bvalid;
    reg          ax_bready_d;
    reg          ax_arvalid_d;
    wire         ax_arready;
    reg  [31:0] ax_araddr_d;
    reg  [7:0]  ax_arlen_d;
    wire         ax_rvalid;
    reg          ax_rready_d;
    wire [255:0] ax_rdata;
    wire         ax_rlast;

    reg          rd_start;
    reg  [31:0]  rd_addr;
    reg  [31:0]  rd_bytes;
    wire         rd_done;
    wire [255:0] rd_data;
    wire         rd_valid;
    reg          rd_ready;
    wire         rd_arvalid;
    wire [31:0]  rd_araddr;
    wire [7:0]   rd_arlen;
    wire [2:0]   rd_arsize;
    wire [1:0]   rd_arburst;
    wire         rd_rready;

    dma_axi_reader #(.AXI_DATA_WIDTH(256), .MAX_BURST_LEN(2)) u_dma_reader (
        .clk(clk), .rst_n(rst_n), .start(rd_start), .base_addr(rd_addr), .byte_count(rd_bytes),
        .done(rd_done), .error(), .error_code(), .busy(),
        .data_out(rd_data), .data_valid(rd_valid), .data_ready(rd_ready),
        .m_axi_araddr(rd_araddr), .m_axi_arvalid(rd_arvalid), .m_axi_arready(ax_arready),
        .m_axi_arlen(rd_arlen), .m_axi_arsize(rd_arsize), .m_axi_arburst(rd_arburst),
        .m_axi_rdata(ax_rdata), .m_axi_rvalid((axim_sel == 2'd1) && ax_rvalid),
        .m_axi_rready(rd_rready), .m_axi_rlast(ax_rlast), .m_axi_rresp(2'b00)
    );

    reg          wr_start;
    reg  [31:0]  wr_addr;
    reg  [31:0]  wr_bytes;
    wire         wr_done;
    wire         wr_busy;
    reg          wr_done_seen;
    reg  [255:0] wr_data;
    reg          wr_valid;
    wire         wr_ready;
    wire         wr_awvalid;
    wire [31:0]  wr_awaddr;
    wire [7:0]   wr_awlen;
    wire [2:0]   wr_awsize;
    wire [1:0]   wr_awburst;
    wire         wr_wvalid;
    wire [255:0] wr_wdata;
    wire [31:0]  wr_wstrb;
    wire         wr_wlast;
    wire         wr_bready;

    dma_axi_writer #(.AXI_DATA_WIDTH(256), .MAX_BURST_LEN(2)) u_dma_writer (
        .clk(clk), .rst_n(rst_n), .start(wr_start), .base_addr(wr_addr), .byte_count(wr_bytes),
        .done(wr_done), .error(), .error_code(), .busy(wr_busy),
        .data_in(wr_data), .data_valid(wr_valid), .data_ready(wr_ready),
        .m_axi_awaddr(wr_awaddr), .m_axi_awvalid(wr_awvalid), .m_axi_awready(ax_awready),
        .m_axi_awlen(wr_awlen), .m_axi_awsize(wr_awsize), .m_axi_awburst(wr_awburst),
        .m_axi_wdata(wr_wdata), .m_axi_wvalid(wr_wvalid), .m_axi_wready(ax_wready),
        .m_axi_wlast(wr_wlast), .m_axi_wstrb(wr_wstrb),
        .m_axi_bresp(2'b00), .m_axi_bvalid((axim_sel == 2'd2) && ax_bvalid), .m_axi_bready(wr_bready)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            wr_done_seen <= 1'b0;
        else if (wr_start)
            wr_done_seen <= 1'b0;
        else if (wr_done)
            wr_done_seen <= 1'b1;
    end

    wire        ax_awvalid = (axim_sel == 2'd2) ? wr_awvalid : ax_awvalid_d;
    wire [31:0] ax_awaddr  = (axim_sel == 2'd2) ? wr_awaddr  : ax_awaddr_d;
    wire [7:0]  ax_awlen   = (axim_sel == 2'd2) ? wr_awlen   : ax_awlen_d;
    wire [2:0]  ax_awsize  = (axim_sel == 2'd2) ? wr_awsize  : 3'd5;
    wire [1:0]  ax_awburst = (axim_sel == 2'd2) ? wr_awburst : 2'b01;
    wire        ax_wvalid  = (axim_sel == 2'd2) ? wr_wvalid  : ax_wvalid_d;
    wire [255:0] ax_wdata  = (axim_sel == 2'd2) ? wr_wdata   : ax_wdata_d;
    wire [31:0]  ax_wstrb  = (axim_sel == 2'd2) ? wr_wstrb   : ax_wstrb_d;
    wire         ax_wlast  = (axim_sel == 2'd2) ? wr_wlast   : ax_wlast_d;
    wire         ax_bready = (axim_sel == 2'd2) ? wr_bready  : ax_bready_d;
    wire         ax_arvalid = (axim_sel == 2'd1) ? rd_arvalid : ax_arvalid_d;
    wire [31:0]  ax_araddr  = (axim_sel == 2'd1) ? rd_araddr  : ax_araddr_d;
    wire [7:0]   ax_arlen   = (axim_sel == 2'd1) ? rd_arlen   : ax_arlen_d;
    wire [2:0]   ax_arsize  = (axim_sel == 2'd1) ? rd_arsize  : 3'd5;
    wire [1:0]   ax_arburst = (axim_sel == 2'd1) ? rd_arburst : 2'b01;
    wire         ax_rready  = (axim_sel == 2'd1) ? rd_rready  : ax_rready_d;

    axi4_ram #(.AXI_DATA_W(256), .RAM_DEPTH(32768)) u_axi4_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(ax_awvalid), .s_axi_awready(ax_awready), .s_axi_awaddr(ax_awaddr),
        .s_axi_awlen(ax_awlen), .s_axi_awsize(ax_awsize), .s_axi_awburst(ax_awburst),
        .s_axi_wvalid(ax_wvalid), .s_axi_wready(ax_wready), .s_axi_wdata(ax_wdata),
        .s_axi_wstrb(ax_wstrb), .s_axi_wlast(ax_wlast), .s_axi_bvalid(ax_bvalid),
        .s_axi_bready(ax_bready), .s_axi_bresp(), .s_axi_arvalid(ax_arvalid),
        .s_axi_arready(ax_arready), .s_axi_araddr(ax_araddr), .s_axi_arlen(ax_arlen),
        .s_axi_arsize(ax_arsize), .s_axi_arburst(ax_arburst), .s_axi_rvalid(ax_rvalid),
        .s_axi_rready(ax_rready), .s_axi_rdata(ax_rdata), .s_axi_rlast(ax_rlast),
        .s_axi_rresp()
    );

    task ax_write_burst3;
        input [31:0] addr;
        begin
            @(negedge clk);
            ax_awaddr_d = addr;
            ax_awlen_d = 8'd2;
            ax_awvalid_d = 1'b1;
            while (!ax_awready) @(posedge clk);
            @(negedge clk);
            ax_awvalid_d = 1'b0;

            @(negedge clk);
            ax_wdata_d = beat_pattern(8'h10);
            ax_wstrb_d = 32'hFFFF_FFFF;
            ax_wlast_d = 1'b0;
            ax_wvalid_d = 1'b1;
            while (!ax_wready) @(posedge clk);
            @(negedge clk);
            ax_wvalid_d = 1'b0;

            @(negedge clk);
            ax_wdata_d = beat_pattern(8'h40);
            ax_wlast_d = 1'b0;
            ax_wvalid_d = 1'b1;
            while (!ax_wready) @(posedge clk);
            @(negedge clk);
            ax_wvalid_d = 1'b0;

            @(negedge clk);
            ax_wdata_d = beat_pattern(8'h70);
            ax_wlast_d = 1'b1;
            ax_wvalid_d = 1'b1;
            while (!ax_wready) @(posedge clk);
            @(negedge clk);
            ax_wvalid_d = 1'b0;
            ax_wlast_d = 1'b0;
            ax_bready_d = 1'b1;
            while (!ax_bvalid) @(posedge clk);
            @(negedge clk);
            ax_bready_d = 1'b0;
        end
    endtask

    task ax_read_burst3;
        input [31:0] addr;
        begin
            @(posedge clk);
            ax_araddr_d <= addr;
            ax_arlen_d <= 8'd2;
            ax_arvalid_d <= 1'b1;
            ax_rready_d <= 1'b0;
            while (!ax_arready) @(posedge clk);
            @(posedge clk);
            ax_arvalid_d <= 1'b0;
            while (!ax_rvalid) @(posedge clk);
            #1;
            check256(ax_rdata, beat_pattern(8'h10), "axi4 read burst beat0");
            ax_rready_d <= 1'b1;
            @(posedge clk);
            ax_rready_d <= 1'b0;
            while (!ax_rvalid) @(posedge clk);
            #1;
            check256(ax_rdata, beat_pattern(8'h40), "axi4 read burst beat1");
            ax_rready_d <= 1'b1;
            @(posedge clk);
            ax_rready_d <= 1'b0;
            while (!ax_rvalid) @(posedge clk);
            #1;
            check256(ax_rdata, beat_pattern(8'h70), "axi4 read burst beat2");
            if (!ax_rlast) begin
                $display("FAIL axi4 read burst expected rlast on beat2");
                errors = errors + 1;
            end
            ax_rready_d <= 1'b1;
            @(posedge clk);
            ax_rready_d <= 1'b0;
        end
    endtask

    task ax_write_one;
        input [31:0] addr;
        input [255:0] data;
        input [31:0] strb;
        begin
            @(negedge clk);
            ax_awaddr_d = addr;
            ax_awlen_d = 8'd0;
            ax_awvalid_d = 1'b1;
            while (!ax_awready) @(posedge clk);
            @(negedge clk);
            ax_awvalid_d = 1'b0;
            ax_wdata_d = data;
            ax_wstrb_d = strb;
            ax_wlast_d = 1'b1;
            ax_wvalid_d = 1'b1;
            while (!ax_wready) @(posedge clk);
            @(negedge clk);
            ax_wvalid_d = 1'b0;
            ax_wlast_d = 1'b0;
            ax_bready_d = 1'b1;
            while (!ax_bvalid) @(posedge clk);
            @(negedge clk);
            ax_bready_d = 1'b0;
        end
    endtask

    task ax_read_one;
        input [31:0] addr;
        output [255:0] data;
        begin
            @(posedge clk);
            ax_araddr_d <= addr;
            ax_arlen_d <= 8'd0;
            ax_arvalid_d <= 1'b1;
            ax_rready_d <= 1'b0;
            while (!ax_arready) @(posedge clk);
            @(posedge clk);
            ax_arvalid_d <= 1'b0;
            while (!ax_rvalid) @(posedge clk);
            #1;
            data = ax_rdata;
            ax_rready_d <= 1'b1;
            @(posedge clk);
            ax_rready_d <= 1'b0;
        end
    endtask

    integer i;
    reg [31:0] rd_word;
    reg [255:0] rd_beat;
    reg [255:0] expected_beat;
    integer rd_count;

    initial begin
        errors = 0;
        rst_n = 1'b0;
        sh_cpu_awvalid = 0; sh_cpu_awaddr = 0; sh_cpu_wvalid = 0; sh_cpu_wdata = 0; sh_cpu_wstrb = 0;
        sh_cpu_bready = 0; sh_cpu_arvalid = 0; sh_cpu_araddr = 0; sh_cpu_rready = 0;
        sh_npu_awvalid = 0; sh_npu_awaddr = 0; sh_npu_awlen = 0; sh_npu_wvalid = 0;
        sh_npu_wdata = 0; sh_npu_wlast = 0; sh_npu_wstrb = 0; sh_npu_bready = 0;
        sh_npu_arvalid = 0; sh_npu_araddr = 0; sh_npu_arlen = 0; sh_npu_rready = 0;
        axim_sel = 0; ax_awvalid_d = 0; ax_awaddr_d = 0; ax_awlen_d = 0; ax_wvalid_d = 0;
        ax_wdata_d = 0; ax_wstrb_d = 0; ax_wlast_d = 0; ax_bready_d = 0;
        ax_arvalid_d = 0; ax_araddr_d = 0; ax_arlen_d = 0; ax_rready_d = 0;
        rd_start = 0; rd_addr = 0; rd_bytes = 0; rd_ready = 0;
        wr_start = 0; wr_addr = 0; wr_bytes = 0; wr_data = 0; wr_valid = 0; wr_done_seen = 0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // shared_ram: CPU writes all 8 words in a beat, NPU reads the full 256-bit beat.
        $display("HB1A_STEP shared CPU->NPU");
        expected_beat = 256'h0;
        for (i = 0; i < 8; i = i + 1) begin
            sh_cpu_write(32'h0000_0040 + i*4, 32'hA500_0000 + i, 4'hF);
            expected_beat[i*32 +: 32] = 32'hA500_0000 + i;
        end
        sh_npu_read_beat(32'h0000_0040, rd_beat);
        check256(rd_beat, expected_beat, "shared CPU writes -> NPU read");

        // shared_ram: CPU partial byte mask modifies only selected byte lanes.
        sh_cpu_write(32'h0000_0048, 32'hDEAD_BEEF, 4'b0101);
        expected_beat[2*32 +: 32] = 32'hA5AD_00EF;
        sh_npu_read_beat(32'h0000_0040, rd_beat);
        check256(rd_beat, expected_beat, "shared CPU partial mask -> NPU read");

        // shared_ram: NPU writes one full beat, CPU reads every 32-bit word slot.
        $display("HB1A_STEP shared NPU->CPU");
        sh_npu_write_beat(32'h0000_0080, beat_pattern(8'h80), 32'hFFFF_FFFF);
        expected_beat = beat_pattern(8'h80);
        for (i = 0; i < 8; i = i + 1) begin
            sh_cpu_read(32'h0000_0080 + i*4, rd_word);
            check32(rd_word, expected_beat[i*32 +: 32], "shared NPU write -> CPU read");
        end

        // shared_ram: NPU partial byte mask, then CPU verifies affected and unaffected words.
        sh_npu_write_beat(32'h0000_00A0, 256'h0, 32'hFFFF_FFFF);
        sh_npu_write_beat(32'h0000_00A0, beat_pattern(8'h20), 32'h0000_1FFF);
        expected_beat = beat_pattern(8'h20);
        sh_cpu_read(32'h0000_00A0, rd_word); check32(rd_word, expected_beat[31:0], "shared NPU partial word0");
        sh_cpu_read(32'h0000_00AC, rd_word); check32(rd_word, 32'h0000_002c, "shared NPU partial word3");
        sh_cpu_read(32'h0000_00B0, rd_word); check32(rd_word, 32'h0000_0000, "shared NPU partial word4 unaffected");

        // axi4_ram direct 256-bit write/read burst.
        $display("HB1A_STEP axi4 direct burst");
        axim_sel = 0;
        ax_write_burst3(32'h0000_0100);
        $display("HB1A_STEP axi4 direct read burst");
        ax_read_burst3(32'h0000_0100);
        $display("HB1A_STEP axi4 direct partial zero");
        ax_write_one(32'h0000_0200, 256'h0, 32'hFFFF_FFFF);
        rd_beat = beat_pattern(8'hC0);
        expected_beat = 256'h0;
        expected_beat[0 +: 104] = rd_beat[0 +: 104];
        $display("HB1A_STEP axi4 direct partial write");
        ax_write_one(32'h0000_0200, beat_pattern(8'hC0), 32'h0000_1FFF);
        $display("HB1A_STEP axi4 direct partial read");
        ax_read_one(32'h0000_0200, rd_beat);
        check256(rd_beat, expected_beat, "axi4 partial tail mask");

        // dma_axi_reader: byte_count=80 should read three 256-bit beats with MAX_BURST_LEN=2 split.
        $display("HB1A_STEP dma reader");
        ax_write_one(32'h0000_0300, beat_pattern(8'h01), 32'hFFFF_FFFF);
        ax_write_one(32'h0000_0320, beat_pattern(8'h21), 32'hFFFF_FFFF);
        ax_write_one(32'h0000_0340, beat_pattern(8'h41), 32'hFFFF_FFFF);
        axim_sel = 1;
        rd_count = 0;
        rd_addr = 32'h0000_0300;
        rd_bytes = 32'd80;
        rd_ready = 1'b1;
        @(posedge clk);
        rd_start = 1'b1;
        @(posedge clk);
        rd_start = 1'b0;
        while (!rd_done) begin
            @(posedge clk);
            if (rd_valid) begin
                if (rd_count == 0) check256(rd_data, beat_pattern(8'h01), "dma reader beat0");
                if (rd_count == 1) check256(rd_data, beat_pattern(8'h21), "dma reader beat1");
                if (rd_count == 2) check256(rd_data, beat_pattern(8'h41), "dma reader beat2 tail");
                rd_count = rd_count + 1;
            end
        end
        check32(rd_count, 32'd3, "dma reader rounded beat count");
        rd_ready = 1'b0;

        // dma_axi_writer: byte_count=50 should write one full beat and 18 bytes of tail beat.
        $display("HB1A_STEP dma writer");
        axim_sel = 0;
        ax_write_one(32'h0000_0400, 256'h0, 32'hFFFF_FFFF);
        ax_write_one(32'h0000_0420, 256'h0, 32'hFFFF_FFFF);
        axim_sel = 2;
        wr_addr = 32'h0000_0400;
        wr_bytes = 32'd50;
        @(posedge clk);
        wr_start = 1'b1;
        @(posedge clk);
        wr_start = 1'b0;
        wr_data = beat_pattern(8'h90);
        wr_valid = 1'b1;
        while (!wr_ready) @(posedge clk);
        @(negedge clk);
        wr_data = beat_pattern(8'hB0);
        wr_valid = 1'b1;
        while (wr_busy) @(posedge clk);
        @(negedge clk);
        wr_valid = 1'b0;
        if (!wr_done_seen) begin
            $display("FAIL dma writer done strobe not observed");
            errors = errors + 1;
        end
        axim_sel = 0;
        ax_read_one(32'h0000_0400, rd_beat);
        check256(rd_beat, beat_pattern(8'h90), "dma writer beat0");
        rd_beat = beat_pattern(8'hB0);
        expected_beat = 256'h0;
        expected_beat[0 +: 144] = rd_beat[0 +: 144];
        ax_read_one(32'h0000_0420, rd_beat);
        check256(rd_beat, expected_beat, "dma writer tail beat");

        if (errors == 0) begin
            $display("tb_hb1a_256_data_plane PASS");
            $finish;
        end else begin
            $display("tb_hb1a_256_data_plane FAIL errors=%0d", errors);
            $fatal(1);
        end
    end
endmodule
