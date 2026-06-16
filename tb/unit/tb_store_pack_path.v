`timescale 1ns / 1ps

module store_pack_case #(
    parameter [127:0] CASE_NAME = "case",
    parameter [1:0] MODE = 2'd0,
    parameter [31:0] BASE_ADDR = 32'h0000_0100,
    parameter integer BYTES = 32,
    parameter integer CASE_ID = 0,
    parameter integer STALL_FIRST_BEAT = 0
) (
    output reg done
);
    localparam WORDS = (BYTES + 3) / 4;
    localparam BEATS = (BYTES + 31) / 32;

    reg clk;
    reg rst_n;
    integer errors;
    integer i;

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

    npu_top #(
        .BUF_ENTRIES(64),
        .BUF_ADDR_W(6),
        .TILE_ROWS(4),
        .TILE_COLS(4)
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

    function [31:0] word_value;
        input integer idx;
        begin
            word_value = 32'hA500_0000 | (CASE_ID[7:0] << 16) | idx[15:0];
        end
    endfunction

    function [255:0] expected_beat;
        input integer beat_idx;
        integer lane;
        integer word_idx;
        begin
            expected_beat = 256'h0;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                word_idx = beat_idx * 8 + lane;
                if (word_idx < WORDS)
                    expected_beat[lane*32 +: 32] = word_value(word_idx);
            end
        end
    endfunction

    function [31:0] expected_wstrb;
        input integer beat_idx;
        integer bytes_before;
        integer bytes_left;
        integer valid_bytes;
        integer lane;
        begin
            bytes_before = beat_idx * 32;
            bytes_left = BYTES - bytes_before;
            if (bytes_left >= 32)
                valid_bytes = 32;
            else if (bytes_left > 0)
                valid_bytes = bytes_left;
            else
                valid_bytes = 0;
            expected_wstrb = 32'h0;
            for (lane = 0; lane < 32; lane = lane + 1) begin
                if (lane < valid_bytes)
                    expected_wstrb[lane] = 1'b1;
            end
        end
    endfunction

    task fail;
        input [255:0] msg;
        begin
            $display("FAIL %0s %0s", CASE_NAME, msg);
            errors = errors + 1;
        end
    endtask

    task check;
        input cond;
        input [255:0] msg;
        begin
            if (!cond)
                fail(msg);
        end
    endtask

    task reset_case;
        begin
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
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (4) @(posedge clk);
        end
    endtask

    task check_aw;
        begin
            m_axi_awready = 1'b1;
            while (!m_axi_awvalid) @(posedge clk);
            #1;
            check(m_axi_awaddr == BASE_ADDR, "AWADDR mismatch");
            check(m_axi_awlen == (BEATS - 1), "AWLEN mismatch");
            check(m_axi_awsize == 3'd5, "AWSIZE should be 256-bit");
            check(m_axi_awburst == 2'b01, "AWBURST should be INCR");
            @(posedge clk);
            #1;
            m_axi_awready = 1'b0;
        end
    endtask

    task check_w_beat;
        input integer beat_idx;
        input integer stall_cycles;
        integer s;
        reg [255:0] hold_data;
        reg [31:0] hold_strb;
        reg hold_last;
        begin
            while (!m_axi_wvalid) @(posedge clk);
            #1;
            check(m_axi_wdata == expected_beat(beat_idx), "WDATA packed lane order mismatch");
            check(m_axi_wstrb == expected_wstrb(beat_idx), "WSTRB mismatch");
            check(m_axi_wlast == (beat_idx == BEATS - 1), "WLAST mismatch");
            hold_data = m_axi_wdata;
            hold_strb = m_axi_wstrb;
            hold_last = m_axi_wlast;
            m_axi_wready = 1'b0;
            for (s = 0; s < stall_cycles; s = s + 1) begin
                @(posedge clk);
                #1;
                check(m_axi_wvalid, "WVALID dropped during stall");
                check(m_axi_wdata == hold_data, "WDATA changed during stall");
                check(m_axi_wstrb == hold_strb, "WSTRB changed during stall");
                check(m_axi_wlast == hold_last, "WLAST changed during stall");
            end
            m_axi_wready = 1'b1;
            @(posedge clk);
            #1;
            m_axi_wready = 1'b0;
        end
    endtask

    task send_bresp_ok;
        begin
            m_axi_bresp = 2'b00;
            m_axi_bvalid = 1'b1;
            while (!m_axi_bready) @(posedge clk);
            @(posedge clk);
            #1;
            m_axi_bvalid = 1'b0;
        end
    endtask

    initial begin
        done = 1'b0;
        errors = 0;
        reset_case();

        for (i = 0; i < WORDS; i = i + 1)
            dut.u_acc_buffer.bank_a[i] = word_value(i);

        force dut.task_type = MODE;
        force dut.fsm_state = 5'd11; // FSM_STORE
        force dut.acc_load_bank = 1'b0;
        force dut.dma_wr_started = 1'b0;
        force dut.dma_rd_ptr = {6{1'b0}};
        force dut.store_pack_state = 2'd0;
        force dut.store_pack_lane = 3'd0;
        force dut.store_word_idx = 32'd0;
        force dut.store_pack_data = 256'h0;
        force dut.dma_wr_valid_r = 1'b0;

        if (MODE == 2'd0) begin
            force dut.blk_out_addr = BASE_ADDR;
            force dut.blk_out_bytes = BYTES[31:0];
        end else if (MODE == 2'd1) begin
            force dut.fc_store_addr = BASE_ADDR;
            force dut.fc_store_bytes = BYTES[31:0];
        end else if (MODE == 2'd3) begin
            force dut.rq_store_addr = BASE_ADDR;
            force dut.rq_store_bytes = BYTES[31:0];
        end

        @(posedge clk);
        release dut.dma_wr_started;
        release dut.dma_rd_ptr;
        release dut.store_pack_state;
        release dut.store_pack_lane;
        release dut.store_word_idx;
        release dut.store_pack_data;
        release dut.dma_wr_valid_r;

        check_aw();
        for (i = 0; i < BEATS; i = i + 1)
            check_w_beat(i, (i == 0) ? STALL_FIRST_BEAT : 0);
        send_bresp_ok();

        repeat (3) @(posedge clk);
        if (errors == 0)
            $display("STORE_PACK_CASE case=%0s mode=%0d bytes=%0d words=%0d beats=%0d status=PASS",
                     CASE_NAME, MODE, BYTES, WORDS, BEATS);
        else
            $fatal(1, "STORE_PACK_CASE case=%0s errors=%0d", CASE_NAME, errors);
        done = 1'b1;
    end
endmodule

module tb_store_pack_path;
    wire conv_done;
    wire fc_done;
    wire rq_done;

    store_pack_case #(
        .CASE_NAME("conv_10_words"),
        .MODE(2'd0),
        .BASE_ADDR(32'h0000_0100),
        .BYTES(40),
        .CASE_ID(1),
        .STALL_FIRST_BEAT(2)
    ) u_conv_case (
        .done(conv_done)
    );

    store_pack_case #(
        .CASE_NAME("fc_5_words"),
        .MODE(2'd1),
        .BASE_ADDR(32'h0000_0200),
        .BYTES(20),
        .CASE_ID(2),
        .STALL_FIRST_BEAT(1)
    ) u_fc_case (
        .done(fc_done)
    );

    store_pack_case #(
        .CASE_NAME("requant_7_bytes"),
        .MODE(2'd3),
        .BASE_ADDR(32'h0000_0300),
        .BYTES(7),
        .CASE_ID(3),
        .STALL_FIRST_BEAT(1)
    ) u_rq_case (
        .done(rq_done)
    );

    initial begin
        #200000;
        $display("FAIL tb_store_pack_path timeout");
        $fatal(1);
    end

    initial begin
        wait (conv_done && fc_done && rq_done);
        $display("PASS tb_store_pack_path");
        $finish;
    end
endmodule
