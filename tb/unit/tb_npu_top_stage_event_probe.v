`timescale 1ns / 1ps

module tb_npu_top_stage_event_probe;
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

    localparam FSM_LOAD_ACT     = 5'd1;
    localparam FSM_CIN_LOAD_WGT = 5'd5;
    localparam FSM_LOAD_ARRAY   = 5'd7;
    localparam FSM_WGT_LD       = 5'd8;
    localparam FSM_COMPUTE      = 5'd9;
    localparam FSM_STORE        = 5'd11;
    localparam CP_DRAIN         = 3'd2;
    localparam CP_COLLECT       = 3'd3;

    top #(
        .NPU_TILE_ROWS(8),
        .NPU_TILE_COLS(4)
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

    reg monitor_active;
    integer total_cycles;
    integer load_act_cycles;
    integer cin_load_wgt_cycles;
    integer load_array_cycles;
    integer wgt_ld_cycles;
    integer compute_cycles;
    integer drain_cycles;
    integer collect_cycles;
    integer store_cycles;
    integer act_dma_busy_cycles;
    integer wgt_dma_busy_cycles;
    integer act_wgt_overlap_cycles;
    integer write_dma_busy_cycles;

    always @(posedge clk) begin
        if (!rst_n || !monitor_active) begin
            if (!rst_n) begin
                total_cycles <= 0;
                load_act_cycles <= 0;
                cin_load_wgt_cycles <= 0;
                load_array_cycles <= 0;
                wgt_ld_cycles <= 0;
                compute_cycles <= 0;
                drain_cycles <= 0;
                collect_cycles <= 0;
                store_cycles <= 0;
                act_dma_busy_cycles <= 0;
                wgt_dma_busy_cycles <= 0;
                act_wgt_overlap_cycles <= 0;
                write_dma_busy_cycles <= 0;
            end
        end else begin
            total_cycles <= total_cycles + 1;
            case (u_top.u_npu.fsm_state)
                FSM_LOAD_ACT:     load_act_cycles <= load_act_cycles + 1;
                FSM_CIN_LOAD_WGT: cin_load_wgt_cycles <= cin_load_wgt_cycles + 1;
                FSM_LOAD_ARRAY:   load_array_cycles <= load_array_cycles + 1;
                FSM_WGT_LD:       wgt_ld_cycles <= wgt_ld_cycles + 1;
                FSM_COMPUTE: begin
                    compute_cycles <= compute_cycles + 1;
                    if (u_top.u_npu.comp_sub_state == CP_DRAIN)
                        drain_cycles <= drain_cycles + 1;
                    if (u_top.u_npu.comp_sub_state == CP_COLLECT)
                        collect_cycles <= collect_cycles + 1;
                end
                FSM_STORE:        store_cycles <= store_cycles + 1;
                default: ;
            endcase

            if (u_top.u_npu.act_dma_busy)
                act_dma_busy_cycles <= act_dma_busy_cycles + 1;
            if (u_top.u_npu.wgt_dma_busy)
                wgt_dma_busy_cycles <= wgt_dma_busy_cycles + 1;
            if (u_top.u_npu.act_dma_busy && u_top.u_npu.wgt_dma_busy)
                act_wgt_overlap_cycles <= act_wgt_overlap_cycles + 1;
            if (u_top.u_npu.dma_wr_busy)
                write_dma_busy_cycles <= write_dma_busy_cycles + 1;
        end
    end

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
            tb_bready <= 1'b1;
            wait (tb_bvalid);
            @(posedge clk);
            tb_bready <= 1'b0;
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
            tb_rready <= 1'b0;
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
                $fatal(1, "NPU error in stage event probe");
            if (!npu_status[2])
                $fatal(1, "NPU timeout in stage event probe");
        end
    endtask

    integer word_idx;
    reg [31:0] rd_data;

    initial begin
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
        monitor_active = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        for (word_idx = 0; word_idx < 7; word_idx = word_idx + 1)
            axil_write(INPUT_ADDR + word_idx*4, 32'h01010101);
        for (word_idx = 0; word_idx < 7; word_idx = word_idx + 1)
            axil_write(WEIGHT_ADDR + word_idx*4, 32'h02020202);
        axil_write(OUTPUT_ADDR, 32'h0);

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

        monitor_active = 1'b1;
        axil_write(NPU_BASE + 32'h00, 32'h1);
        wait_done(400000);
        monitor_active = 1'b0;

        axil_read(OUTPUT_ADDR, rd_data);
        if ($signed(rd_data) !== 32'sd50)
            $fatal(1, "stage event output mismatch got %0d expect 50", $signed(rd_data));

        if (load_act_cycles == 0 || cin_load_wgt_cycles == 0 ||
            load_array_cycles == 0 || compute_cycles == 0 || store_cycles == 0)
            $fatal(1, "stage event counters missing required non-zero stage");
        if (act_dma_busy_cycles == 0 || wgt_dma_busy_cycles == 0)
            $fatal(1, "stage event DMA busy counters should be non-zero");
        if (act_wgt_overlap_cycles != 0)
            $fatal(1, "act/wgt DMA overlap observed unexpectedly: %0d", act_wgt_overlap_cycles);
        if (collect_cycles == 0)
            $fatal(1, "collect_cycles should be non-zero");

        $display("STAGE_EVENT_RESULT total=%0d load_act=%0d cin_load_wgt=%0d load_array=%0d wgt_ld=%0d compute=%0d drain=%0d collect=%0d store=%0d act_dma_busy=%0d wgt_dma_busy=%0d act_wgt_overlap=%0d write_dma_busy=%0d output=%0d status=PASS",
                 total_cycles, load_act_cycles, cin_load_wgt_cycles, load_array_cycles,
                 wgt_ld_cycles, compute_cycles, drain_cycles, collect_cycles, store_cycles,
                 act_dma_busy_cycles, wgt_dma_busy_cycles, act_wgt_overlap_cycles,
                 write_dma_busy_cycles, $signed(rd_data));
        $display("tb_npu_top_stage_event_probe PASS");
        $finish;
    end
endmodule
