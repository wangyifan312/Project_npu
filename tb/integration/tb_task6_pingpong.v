// tb_task6_pingpong: verify multi-block bank toggling in npu_top
// Uses a 50x5 Conv that splits into 3 blocks with BUF_ENTRIES=128.
`timescale 1ns / 1ps

module tb_task6_pingpong;
    reg clk, rst_n;

    reg  s_axi_awvalid, s_axi_wvalid, s_axi_bready;
    wire s_axi_awready, s_axi_wready, s_axi_bvalid;
    reg  [31:0] s_axi_awaddr, s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    wire [1:0]  s_axi_bresp;
    reg  s_axi_arvalid, s_axi_rready;
    wire s_axi_arready, s_axi_rvalid;
    reg  [31:0] s_axi_araddr;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;

    wire npu_arvalid, npu_awvalid, npu_wvalid, npu_wlast;
    wire [31:0] npu_araddr, npu_awaddr, npu_wdata;
    wire [7:0]  npu_arlen, npu_awlen;
    wire [2:0]  npu_arsize, npu_awsize;
    wire [1:0]  npu_arburst, npu_awburst;
    wire [3:0]  npu_wstrb;
    wire npu_rready, npu_bready, npu_busy, npu_done, npu_error;
    wire [7:0] npu_error_code;
    wire npu_arready, npu_awready, npu_wready;
    wire npu_rvalid, npu_bvalid;
    wire [31:0] npu_rdata;
    wire npu_rlast;
    wire [1:0] npu_rresp, npu_bresp;

    reg  preload, tb_awvalid, tb_wvalid;
    reg  [31:0] tb_awaddr, tb_wdata;
    reg  [31:0] tb_araddr;
    reg         tb_arvalid, tb_rready;
    wire        tb_arready, tb_rvalid;
    wire [31:0] tb_rdata;
    wire        tb_rlast;
    wire [1:0]  tb_rresp;

    wire ram_awvalid = preload ? tb_awvalid : npu_awvalid;
    wire [31:0] ram_awaddr = preload ? tb_awaddr : npu_awaddr;
    wire [7:0]  ram_awlen = preload ? 8'h0 : npu_awlen;
    wire [2:0]  ram_awsize = preload ? 3'd2 : npu_awsize;
    wire [1:0]  ram_awburst = preload ? 2'd1 : npu_awburst;
    wire        ram_wvalid = preload ? tb_wvalid : npu_wvalid;
    wire [31:0] ram_wdata = preload ? tb_wdata : npu_wdata;
    wire [3:0]  ram_wstrb = preload ? 4'hF : npu_wstrb;
    wire        ram_wlast = preload ? 1'b1 : npu_wlast;
    wire        ram_bready = preload ? 1'b1 : npu_bready;
    wire        ram_arvalid = preload ? tb_arvalid : npu_arvalid;
    wire [31:0] ram_araddr = preload ? tb_araddr : npu_araddr;
    wire [7:0]  ram_arlen = preload ? 8'h0 : npu_arlen;
    wire [2:0]  ram_arsize = preload ? 3'd2 : npu_arsize;
    wire [1:0]  ram_arburst = preload ? 2'd1 : npu_arburst;
    wire        ram_rready = preload ? tb_rready : npu_rready;
    wire        ram_awready, ram_wready, ram_bvalid, ram_arready;
    wire [1:0]  ram_bresp, ram_rresp;
    wire        ram_rvalid, ram_rlast;
    wire [31:0] ram_rdata;

    assign npu_arready = preload ? 1'b0 : ram_arready;
    assign npu_awready = preload ? 1'b0 : ram_awready;
    assign npu_wready  = preload ? 1'b0 : ram_wready;
    assign npu_rvalid  = preload ? 1'b0 : ram_rvalid;
    assign npu_bvalid  = preload ? 1'b0 : ram_bvalid;
    assign npu_rdata   = ram_rdata;
    assign npu_rlast   = ram_rlast;
    assign npu_rresp   = preload ? 2'b0 : ram_rresp;
    assign npu_bresp   = preload ? 2'b0 : ram_bresp;
    assign tb_arready  = preload ? ram_arready : 1'b0;
    assign tb_rvalid   = preload ? ram_rvalid : 1'b0;
    assign tb_rdata    = preload ? ram_rdata : 32'h0;
    assign tb_rlast    = preload ? ram_rlast : 1'b0;
    assign tb_rresp    = preload ? ram_rresp : 2'b0;

    npu_top #(.TILE_ROWS(7), .TILE_COLS(2), .BUF_ENTRIES(128), .BUF_ADDR_W(7)) u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_awaddr(s_axi_awaddr),   .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),   .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),     .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),   .s_axi_bresp(s_axi_bresp),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_araddr(s_axi_araddr),   .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),   .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .m_axi_arvalid(npu_arvalid),   .m_axi_arready(npu_arready),
        .m_axi_araddr(npu_araddr),     .m_axi_arlen(npu_arlen),
        .m_axi_arsize(npu_arsize),     .m_axi_arburst(npu_arburst),
        .m_axi_rvalid(npu_rvalid),     .m_axi_rready(npu_rready),
        .m_axi_rdata(npu_rdata),       .m_axi_rlast(npu_rlast),
        .m_axi_rresp(npu_rresp),
        .m_axi_awvalid(npu_awvalid),   .m_axi_awready(npu_awready),
        .m_axi_awaddr(npu_awaddr),     .m_axi_awlen(npu_awlen),
        .m_axi_awsize(npu_awsize),     .m_axi_awburst(npu_awburst),
        .m_axi_wvalid(npu_wvalid),     .m_axi_wready(npu_wready),
        .m_axi_wdata(npu_wdata),       .m_axi_wlast(npu_wlast),
        .m_axi_wstrb(npu_wstrb),       .m_axi_bvalid(npu_bvalid),
        .m_axi_bready(npu_bready),     .m_axi_bresp(npu_bresp),
        .npu_busy(npu_busy),           .npu_done(npu_done),
        .npu_error(npu_error),         .npu_error_code(npu_error_code)
    );

    axi4_ram #(.RAM_DEPTH(16384)) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awvalid(ram_awvalid), .s_axi_awready(ram_awready),
        .s_axi_awaddr(ram_awaddr),   .s_axi_awlen(ram_awlen),
        .s_axi_awsize(ram_awsize),   .s_axi_awburst(ram_awburst),
        .s_axi_wvalid(ram_wvalid),   .s_axi_wready(ram_wready),
        .s_axi_wdata(ram_wdata),     .s_axi_wstrb(ram_wstrb),
        .s_axi_wlast(ram_wlast),     .s_axi_bvalid(ram_bvalid),
        .s_axi_bready(ram_bready),   .s_axi_bresp(ram_bresp),
        .s_axi_arvalid(ram_arvalid), .s_axi_arready(ram_arready),
        .s_axi_araddr(ram_araddr),   .s_axi_arlen(ram_arlen),
        .s_axi_arsize(ram_arsize),   .s_axi_arburst(ram_arburst),
        .s_axi_rvalid(ram_rvalid),   .s_axi_rready(ram_rready),
        .s_axi_rdata(ram_rdata),     .s_axi_rlast(ram_rlast),
        .s_axi_rresp(ram_rresp)
    );

    always #2.5 clk = ~clk;

    task axi_write;
        input [31:0] addr, data;
        begin
            @(posedge clk);
            s_axi_awvalid = 1; s_axi_awaddr = addr;
            s_axi_wvalid  = 1; s_axi_wdata  = data; s_axi_wstrb = 4'hF;
            @(posedge clk);
            s_axi_awvalid = 0; s_axi_wvalid = 0;
            @(posedge clk);
            s_axi_bready = 1;
            @(posedge clk);
            s_axi_bready = 0;
        end
    endtask

    task preload_word;
        input [31:0] addr, data;
        begin
            @(posedge clk);
            tb_awvalid = 1; tb_awaddr = addr;
            tb_wvalid  = 1; tb_wdata  = data;
            @(posedge clk);
            tb_awvalid = 0;
            @(posedge clk);
            tb_wvalid = 0;
            @(posedge clk);
        end
    endtask

    integer i;
    integer load_wgt_count, load_act_count, compute_count;
    integer errors;
    reg [3:0] prev_fsm_state;
    reg [31:0] rd_val;
    reg [0:2] seen_wgt_bank;
    reg [0:2] seen_act_load_bank;
    reg [0:2] seen_act_comp_bank;

    localparam FSM_LOAD_WGT = 4'd1;
    localparam FSM_LOAD_ACT = 4'd4;
    localparam FSM_COMPUTE  = 4'd6;

    always @(posedge clk) begin
        if (!rst_n) begin
            prev_fsm_state  <= 4'hF;
            load_wgt_count  <= 0;
            load_act_count  <= 0;
            compute_count   <= 0;
        end else begin
            if (u_npu.fsm_state != prev_fsm_state) begin
                if (u_npu.fsm_state == FSM_LOAD_WGT && load_wgt_count < 3) begin
                    seen_wgt_bank[load_wgt_count] <= u_npu.wgt_load_bank;
                    load_wgt_count <= load_wgt_count + 1;
                end
                if (u_npu.fsm_state == FSM_LOAD_ACT && load_act_count < 3) begin
                    seen_act_load_bank[load_act_count] <= u_npu.act_load_bank;
                    load_act_count <= load_act_count + 1;
                end
                if (u_npu.fsm_state == FSM_COMPUTE && compute_count < 3) begin
                    seen_act_comp_bank[compute_count] <= u_npu.act_comp_bank;
                    compute_count <= compute_count + 1;
                end
            end
            prev_fsm_state <= u_npu.fsm_state;
        end
    end

    initial begin
        $dumpfile("sim/tb_task6_pingpong.vcd");
        $dumpvars(0, tb_task6_pingpong);

        clk = 0; rst_n = 0; preload = 1;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_arvalid = 0; s_axi_rready = 0;
        tb_awvalid = 0; tb_wvalid = 0; tb_arvalid = 0; tb_rready = 0;
        load_wgt_count = 0; load_act_count = 0; compute_count = 0;
        errors = 0; prev_fsm_state = 4'hF;

        #20 rst_n = 1; #20;

        $display("=== Pre-load activations (50x5, all 1s) ===");
        for (i = 0; i < 63; i = i + 1)
            preload_word(32'h100 + i*4, 32'h01010101);

        $display("=== Pre-load weights (5x5, all 2s) ===");
        for (i = 0; i < 7; i = i + 1)
            preload_word(32'h200 + i*4, 32'h02020202);

        preload = 0;

        $display("=== Configure Conv: 50x5 input, 3 blocks expected ===");
        axi_write(32'h1000_0008, 32'h0000_0000);
        axi_write(32'h1000_000C, 32'h0000_0100);
        axi_write(32'h1000_0010, 32'h0000_0200);
        axi_write(32'h1000_0014, 32'h0000_0300);
        axi_write(32'h1000_0018, 32'h0000_00FA);
        axi_write(32'h1000_001C, 32'h0000_0019);
        axi_write(32'h1000_0020, 32'h0000_00B8);
        axi_write(32'h1000_0024, 32'h0005_0032);  // H=50,W=5
        axi_write(32'h1000_0028, 32'h0001_0001);
        axi_write(32'h1000_002C, 32'h0);

        $display("=== Start ===");
        axi_write(32'h1000_0000, 32'h1);

        repeat(150000) @(posedge clk);
        @(posedge clk);
        s_axi_arvalid = 1; s_axi_araddr = 32'h1000_0000;
        @(posedge clk);
        s_axi_arvalid = 0;
        @(posedge clk);
        rd_val = s_axi_rdata; s_axi_rready = 1;
        @(posedge clk);
        s_axi_rready = 0;

        $display("CTRL=0x%08h done=%b error=%b", rd_val, rd_val[2], rd_val[3]);
        $display("wgt banks: %0d %0d %0d", seen_wgt_bank[0], seen_wgt_bank[1], seen_wgt_bank[2]);
        $display("act load banks: %0d %0d %0d", seen_act_load_bank[0], seen_act_load_bank[1], seen_act_load_bank[2]);
        $display("act comp banks: %0d %0d %0d", seen_act_comp_bank[0], seen_act_comp_bank[1], seen_act_comp_bank[2]);

        if (!rd_val[2]) begin
            $display("FAIL: task did not complete");
            errors = errors + 1;
        end
        if (load_wgt_count != 3 || load_act_count != 3 || compute_count != 3) begin
            $display("FAIL: expected 3 blocks, got wgt=%0d act=%0d comp=%0d", load_wgt_count, load_act_count, compute_count);
            errors = errors + 1;
        end

        if (seen_wgt_bank[0] !== 1'b0 || seen_wgt_bank[1] !== 1'b1 || seen_wgt_bank[2] !== 1'b0) begin
            $display("FAIL: weight bank sequence incorrect");
            errors = errors + 1;
        end
        if (seen_act_load_bank[0] !== 1'b0 || seen_act_load_bank[1] !== 1'b1 || seen_act_load_bank[2] !== 1'b0) begin
            $display("FAIL: act load bank sequence incorrect");
            errors = errors + 1;
        end
        if (seen_act_comp_bank[0] !== 1'b0 || seen_act_comp_bank[1] !== 1'b1 || seen_act_comp_bank[2] !== 1'b0) begin
            $display("FAIL: act comp bank sequence incorrect");
            errors = errors + 1;
        end

        if (errors == 0) $display("=== FINAL: ALL PASS ===");
        else $display("=== FINAL: %0d ERRORS ===", errors);

        #20 $finish;
    end
endmodule
