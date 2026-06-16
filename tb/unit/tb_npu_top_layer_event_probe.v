`timescale 1ns / 1ps

module tb_npu_top_layer_event_probe;
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
    localparam WEIGHT_ADDR = 32'h0000_0400;
    localparam OUTPUT_ADDR = 32'h0000_0800;
    localparam NPU_BASE    = 32'h1000_0000;

    localparam INPUT_H = 8;
    localparam INPUT_W = 8;
    localparam INPUT_C = 2;
    localparam OUTPUT_C = 8;
    localparam OUT_H = INPUT_H - 5 + 1;
    localparam OUT_W = INPUT_W - 5 + 1;
    localparam INPUT_BYTES = INPUT_H * INPUT_W * INPUT_C;
    localparam WGT_PER_CIN = ((25 * OUTPUT_C) + 3) & ~3;
    localparam WEIGHT_BYTES = WGT_PER_CIN * INPUT_C;
    localparam OUTPUT_BYTES = OUT_H * OUT_W * OUTPUT_C * 4;
    localparam EXPECTED_OUT = 25 * 2 * INPUT_C;

    localparam FSM_LOAD_ACT     = 5'd1;
    localparam FSM_CIN_LOAD_WGT = 5'd5;
    localparam FSM_LOAD_ARRAY   = 5'd7;
    localparam FSM_WGT_LD       = 5'd8;
    localparam FSM_COMPUTE      = 5'd9;
    localparam FSM_STORE        = 5'd11;
    localparam CP_DRAIN         = 3'd2;
    localparam CP_COLLECT       = 3'd3;

    top #(
        .NPU_TILE_ROWS(16),
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
    integer wgt_compute_overlap_cycles;
    integer wgt_preload_compute_cycles;
    integer write_dma_busy_cycles;
    integer route_valid_cycles;
    integer collect_events;

    always @(posedge clk) begin
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
            wgt_compute_overlap_cycles <= 0;
            wgt_preload_compute_cycles <= 0;
            write_dma_busy_cycles <= 0;
            route_valid_cycles <= 0;
            collect_events <= 0;
        end else if (monitor_active) begin
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
                    if (u_top.u_npu.comp_sub_state == CP_COLLECT) begin
                        collect_cycles <= collect_cycles + 1;
                        if (!u_top.u_npu.acc_collect_wait)
                            collect_events <= collect_events + 1;
                    end
                end
                FSM_STORE:        store_cycles <= store_cycles + 1;
                default: ;
            endcase

            if (u_top.u_npu.cluster_arb_out_valid)
                route_valid_cycles <= route_valid_cycles + 1;
            if (u_top.u_npu.act_dma_busy)
                act_dma_busy_cycles <= act_dma_busy_cycles + 1;
            if (u_top.u_npu.wgt_dma_busy)
                wgt_dma_busy_cycles <= wgt_dma_busy_cycles + 1;
            if (u_top.u_npu.act_dma_busy && u_top.u_npu.wgt_dma_busy)
                act_wgt_overlap_cycles <= act_wgt_overlap_cycles + 1;
            if ((u_top.u_npu.fsm_state == FSM_COMPUTE) && u_top.u_npu.wgt_dma_busy)
                wgt_compute_overlap_cycles <= wgt_compute_overlap_cycles + 1;
            if ((u_top.u_npu.fsm_state == FSM_COMPUTE) && u_top.u_npu.wgt_preload_active)
                wgt_preload_compute_cycles <= wgt_preload_compute_cycles + 1;
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
                $fatal(1, "NPU error in layer event probe");
            if (!npu_status[2])
                $fatal(1, "NPU timeout in layer event probe");
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

        for (word_idx = 0; word_idx < (INPUT_BYTES / 4); word_idx = word_idx + 1)
            axil_write(INPUT_ADDR + word_idx*4, 32'h01010101);
        for (word_idx = 0; word_idx < (WEIGHT_BYTES / 4); word_idx = word_idx + 1)
            axil_write(WEIGHT_ADDR + word_idx*4, 32'h02020202);
        for (word_idx = 0; word_idx < (OUTPUT_BYTES / 4); word_idx = word_idx + 1)
            axil_write(OUTPUT_ADDR + word_idx*4, 32'h0);

        axil_write(NPU_BASE + 32'h08, 32'h0);
        axil_write(NPU_BASE + 32'h0C, INPUT_ADDR);
        axil_write(NPU_BASE + 32'h10, WEIGHT_ADDR);
        axil_write(NPU_BASE + 32'h14, OUTPUT_ADDR);
        axil_write(NPU_BASE + 32'h18, INPUT_BYTES);
        axil_write(NPU_BASE + 32'h1C, WEIGHT_BYTES);
        axil_write(NPU_BASE + 32'h20, OUTPUT_BYTES);
        axil_write(NPU_BASE + 32'h24, {16'd8, 16'd8});
        axil_write(NPU_BASE + 32'h28, {16'd8, 16'd2});
        axil_write(NPU_BASE + 32'h2C, 32'h0);

        monitor_active = 1'b1;
        axil_write(NPU_BASE + 32'h00, 32'h1);
        wait_done(2000000);
        monitor_active = 1'b0;

        axil_read(OUTPUT_ADDR, rd_data);
        if ($signed(rd_data) !== EXPECTED_OUT)
            $fatal(1, "layer event output[0] mismatch got %0d expect %0d",
                   $signed(rd_data), EXPECTED_OUT);
        axil_read(OUTPUT_ADDR + OUTPUT_BYTES - 4, rd_data);
        if ($signed(rd_data) !== EXPECTED_OUT)
            $fatal(1, "layer event output[last] mismatch got %0d expect %0d",
                   $signed(rd_data), EXPECTED_OUT);

        if (load_act_cycles == 0 || cin_load_wgt_cycles == 0 ||
            load_array_cycles == 0 || compute_cycles == 0 || store_cycles == 0)
            $fatal(1, "layer event counters missing required non-zero stage");
        if (route_valid_cycles == 0 || collect_events == 0)
            $fatal(1, "layer event route/collect counters should be non-zero");
        if (act_dma_busy_cycles == 0 || wgt_dma_busy_cycles == 0)
            $fatal(1, "layer event DMA busy counters should be non-zero");
        if (act_wgt_overlap_cycles != 0)
            $fatal(1, "act/wgt DMA overlap observed unexpectedly: %0d", act_wgt_overlap_cycles);
        if (wgt_compute_overlap_cycles == 0 || wgt_preload_compute_cycles == 0)
            $fatal(1, "weight preload/compute overlap should be non-zero");

        $display("LAYER_EVENT_RESULT shape=%0dx%0dx%0d_to_%0dx%0dx%0d total=%0d load_act=%0d cin_load_wgt=%0d load_array=%0d wgt_ld=%0d compute=%0d drain=%0d collect=%0d store=%0d route_valid=%0d collect_events=%0d act_dma_busy=%0d wgt_dma_busy=%0d act_wgt_overlap=%0d wgt_compute_overlap=%0d wgt_preload_compute=%0d write_dma_busy=%0d first_last_output=%0d status=PASS",
                 INPUT_H, INPUT_W, INPUT_C, OUT_H, OUT_W, OUTPUT_C,
                 total_cycles, load_act_cycles, cin_load_wgt_cycles, load_array_cycles,
                 wgt_ld_cycles, compute_cycles, drain_cycles, collect_cycles, store_cycles,
                 route_valid_cycles, collect_events,
                 act_dma_busy_cycles, wgt_dma_busy_cycles, act_wgt_overlap_cycles,
                 wgt_compute_overlap_cycles, wgt_preload_compute_cycles,
                 write_dma_busy_cycles, EXPECTED_OUT);
        $display("tb_npu_top_layer_event_probe PASS");
        $finish;
    end
endmodule
