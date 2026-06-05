`timescale 1ns / 1ps

module tb_top_lenet;

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

    localparam INPUT_ADDR     = 32'h0000_0100;
    localparam CONV1_WGT_ADDR = 32'h0000_1000;
    localparam CONV1_OUT_ADDR = 32'h0000_4000;
    localparam POOL1_OUT_ADDR = 32'h0001_8000;
    localparam CONV2_IN_ADDR  = 32'h0001_C000;
    localparam CONV2_WGT_ADDR = 32'h0002_0000;
    localparam CONV2_OUT_ADDR = 32'h0006_0000;
    localparam POOL2_OUT_ADDR = 32'h0008_0000;
    localparam FC1_WGT_ADDR   = 32'h0009_0000;
    localparam FC1_OUT_ADDR   = 32'h000F_2000;
    localparam FC2_WGT_ADDR   = 32'h000F_3000;
    localparam FC2_OUT_ADDR   = 32'h000F_5000;
    localparam NPU_BASE       = 32'h1000_0000;
    localparam MAX_FILE_WORDS = 131072;
    localparam PERF_CYCLE_LO       = NPU_BASE + 32'h30;
    localparam PERF_CYCLE_HI       = NPU_BASE + 32'h34;
    localparam PERF_READ_BEATS     = NPU_BASE + 32'h38;
    localparam PERF_WRITE_BEATS    = NPU_BASE + 32'h3C;
    localparam PERF_READ_ACTIVE    = NPU_BASE + 32'h40;
    localparam PERF_WRITE_ACTIVE   = NPU_BASE + 32'h44;
    localparam PERF_ARRAY_ACTIVE   = NPU_BASE + 32'h48;
    localparam PERF_ARRAY_STALL    = NPU_BASE + 32'h4C;
    localparam PERF_MAC_LO         = NPU_BASE + 32'h50;
    localparam PERF_MAC_HI         = NPU_BASE + 32'h54;
    localparam PERF_CLUSTER_ACTIVE = NPU_BASE + 32'h58;
    localparam PERF_CLUSTER_STALL  = NPU_BASE + 32'h5C;
    localparam PERF_CLUSTER_CFG    = NPU_BASE + 32'h60;
    localparam REQUANT_SEL         = NPU_BASE + 32'h64;
    localparam REQUANT0_MULT       = NPU_BASE + 32'h68;
    localparam REQUANT0_SHIFT      = NPU_BASE + 32'h6C;
    localparam REQUANT1_MULT       = NPU_BASE + 32'h70;
    localparam REQUANT1_SHIFT      = NPU_BASE + 32'h74;
    localparam REQUANT2_MULT       = NPU_BASE + 32'h78;
    localparam REQUANT2_SHIFT      = NPU_BASE + 32'h7C;

    reg [31:0] file_words [0:MAX_FILE_WORDS-1];
    string fixture_dir, sample_name, sample_dir, weights_dir, sample_root_dir, weights_root_dir;
    string path_input, path_conv1_w, path_conv2_w, path_fc1_w, path_fc2_w;
    string path_conv1_g, path_pool1_g, path_conv2_input_g, path_conv2_g;
    string path_pool2_g, path_fc1_g, path_fc2_g, path_expected;
    string input_memh_name, expected_file_name;
    string dump_file, dump_vcd_file, dump_fsdb_file;
    integer dump_vcd, dump_fsdb;
    integer show_progress, eval_mode, sample_ordinal, verbose_limit, verbose_this_sample, skip_perf_reads;
    integer expected_class_override;
    integer debug_axil, debug_trace, debug_trace_period, debug_cycle_count;
    integer debug_compute, debug_stop_cycle;
    integer debug_arbiter_window, debug_force_drain_threshold;
    integer debug_project_drain_threshold, debug_project_drain_done;
    integer debug_natural_drain_stop;
    integer debug_stop_on_collect;
    integer debug_stop_on_acc_write;
    integer debug_stop_on_store;
    integer debug_stop_on_first_writeback;
    integer debug_stop_on_task_done;
    integer debug_stop_on_pool1_start;
    integer debug_stop_on_pool1_done;
    integer debug_stop_on_conv2_requant_start;
    integer debug_stop_on_conv2_requant_done;
    integer debug_stop_on_conv2_start;
    integer debug_stop_on_conv2_compute;
    integer debug_stop_on_conv2_cf_window;
    integer debug_stop_on_conv2_arb;
    integer debug_stop_on_conv2_collect;
    integer debug_dump_conv2_final_collect;
    integer debug_stop_on_conv2_store;
    integer debug_stop_on_conv2_done;
    integer debug_conv2_probe_active;
    integer debug_stop_on_pool2_start;
    integer debug_stop_on_pool2_done;
    integer debug_stop_on_fc1_requant_start;
    integer debug_stop_on_fc1_requant_done;
    integer debug_stop_on_fc1_start;
    integer debug_stop_on_fc1_compute;
    integer debug_stop_on_fc1_arb;
    integer debug_stop_on_fc1_collect;
    integer debug_dump_fc1_final_collect;
    integer debug_dump_fc1_chunks;
    integer debug_stop_on_fc1_store;
    integer debug_stop_on_fc1_done;
    integer debug_stop_on_fc2_start;
    integer debug_stop_on_fc1_progress;
    integer debug_fc1_progress_cycles;
    integer debug_fc1_progress_seen;
    integer debug_fc1_progress_start_cycle;
    integer debug_fc1_probe_active;
    integer debug_stop_on_fc2_compute;
    integer debug_stop_on_fc2_arb;
    integer debug_stop_on_fc2_collect;
    integer debug_stop_on_fc2_store;
    integer debug_stop_on_fc2_done;
    integer debug_stop_on_top_result;
    integer debug_fc2_probe_active;
    integer debug_stop_on_fc2_last_chunk_collect;
    integer debug_dump_fc2_logits;
    integer debug_compare_fc2_golden;
    integer debug_fc2_dump_chunk_inputs;
    integer debug_fc2_dump_chunk_weights;
    integer debug_fc2_dump_chunk_col_results;
    integer debug_fc2_compare_chunk_golden;
    integer debug_natural_drain_seen;
    integer debug_natural_drain_start_cycle;
    integer debug_force_drain_state;
    reg [4:0] debug_prev_fsm;
    reg [2:0] debug_prev_sub;
    reg [5:0] debug_prev_cluster_valid;
    reg       debug_prev_arb_valid;
    integer rq_conv2_mult, rq_conv2_shift;
    integer rq_fc1_mult, rq_fc1_shift;
    integer rq_fc2_mult, rq_fc2_shift;
    reg [63:0] sample_total_cycles, sample_total_mac;
    reg [63:0] sample_total_read_beats, sample_total_write_beats;
    reg [63:0] sample_total_read_active, sample_total_write_active;
    reg [63:0] sample_total_array_active, sample_total_array_stall;
    reg [63:0] sample_total_cluster_active, sample_total_cluster_stall;

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

    initial begin
        dump_vcd = 0;
        dump_fsdb = 0;
        dump_file = "";
        void'($value$plusargs("dump_vcd=%d", dump_vcd));
        void'($value$plusargs("dump_fsdb=%d", dump_fsdb));
        void'($value$plusargs("dump_file=%s", dump_file));

        if (dump_vcd != 0) begin
            dump_vcd_file = "sim/tb_top_lenet.vcd";
            if (dump_file.len() != 0)
                dump_vcd_file = dump_file;
            $display("TB_DUMP vcd file=%0s", dump_vcd_file);
            $dumpfile(dump_vcd_file);
            $dumpvars(0, tb_top_lenet);
        end

        if (dump_fsdb != 0) begin
`ifdef ENABLE_FSDB_DUMP
            dump_fsdb_file = "sim/tb_top_lenet.fsdb";
            if (dump_file.len() != 0)
                dump_fsdb_file = dump_file;
            $display("TB_DUMP fsdb file=%0s", dump_fsdb_file);
            $fsdbDumpfile(dump_fsdb_file);
            $fsdbDumpvars(0, tb_top_lenet);
`else
            $display("TB_DUMP warning: +dump_fsdb=1 ignored; compile with +define+ENABLE_FSDB_DUMP");
`endif
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            debug_cycle_count <= 0;
            debug_force_drain_state <= 0;
            debug_project_drain_done <= 0;
            debug_natural_drain_seen <= 0;
            debug_natural_drain_start_cycle <= 0;
            debug_prev_fsm <= 5'h0;
            debug_prev_sub <= 3'h0;
            debug_prev_cluster_valid <= 6'h0;
            debug_prev_arb_valid <= 1'b0;
        end else begin
            debug_cycle_count <= debug_cycle_count + 1;
            if ((debug_trace != 0) && (debug_trace_period > 0) &&
                ((debug_cycle_count % debug_trace_period) == 0)) begin
                $display("DBG_TRACE cyc=%0d status=0x%08x fsm=%0d sub=%0d cluster_en=%b arb_valid=%b arb_sum0=%0d done=%b err=%b dma_wr_vr=%b%b m_ar_vr=%b%b m_r_vr=%b%b m_aw_vr=%b%b m_w_vr=%b%b",
                         debug_cycle_count, npu_status,
                         u_top.u_npu.fsm_state, u_top.u_npu.comp_sub_state,
                         u_top.u_npu.perf_cluster_enable,
                         u_top.u_npu.cluster_arb_out_valid,
                         $signed(u_top.u_npu.cluster_arb_sum_out[31:0]),
                         u_top.u_npu.npu_done, u_top.u_npu.npu_error,
                         u_top.u_npu.dma_wr_valid, u_top.u_npu.dma_wr_ready,
                         u_top.u_npu.m_axi_arvalid, u_top.u_npu.m_axi_arready,
                         u_top.u_npu.m_axi_rvalid, u_top.u_npu.m_axi_rready,
                         u_top.u_npu.m_axi_awvalid, u_top.u_npu.m_axi_awready,
                         u_top.u_npu.m_axi_wvalid, u_top.u_npu.m_axi_wready);
            end
            if (debug_compute != 0) begin
                if ((u_top.u_npu.fsm_state != debug_prev_fsm) ||
                    (u_top.u_npu.comp_sub_state != debug_prev_sub) ||
                    (u_top.u_npu.cluster_valid != debug_prev_cluster_valid) ||
                    (u_top.u_npu.cluster_arb_out_valid != debug_prev_arb_valid) ||
                    ((debug_trace_period > 0) && ((debug_cycle_count % debug_trace_period) == 0))) begin
                    $display("DBG_COMP cyc=%0d fsm=%0d sub=%0d cf_new=%b cf_done=%b cf_hold=%b cf_act_valid=%b act_done=%0d act_ptr=%0d comp_feed=%0d drain=%0d cin=%0d/%0d blk_in_bytes=%0d blk_rows=%0d/%0d wgt_phase=%0d array_wld=%b cluster_busy=%b cluster_valid=%b cluster_done=%b arb_valid=%b arb_sum0=%0d",
                             debug_cycle_count,
                             u_top.u_npu.fsm_state,
                             u_top.u_npu.comp_sub_state,
                             u_top.u_npu.cf_new_window,
                             u_top.u_npu.cf_done,
                             u_top.u_npu.cf_window_hold,
                             u_top.u_npu.cf_act_valid,
                             u_top.u_npu.act_feed_done_cnt,
                             u_top.u_npu.act_feed_ptr,
                             u_top.u_npu.comp_feed_cnt,
                             u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.cin_idx,
                             u_top.u_npu.cin_total,
                             u_top.u_npu.blk_in_bytes,
                             u_top.u_npu.blk_in_rows,
                             u_top.u_npu.blk_out_rows,
                             u_top.u_npu.wgt_load_phase,
                             u_top.u_npu.array_weight_ld,
                             u_top.u_npu.cluster_busy,
                             u_top.u_npu.cluster_valid,
                             u_top.u_npu.cluster_done,
                             u_top.u_npu.cluster_arb_out_valid,
                             $signed(u_top.u_npu.cluster_arb_sum_out[31:0]));
                end
                if (u_top.u_npu.cluster_arb_out_valid) begin
                    $display("DBG_COMP_FIRST_ARB cyc=%0d fsm=%0d sub=%0d cluster_valid=%b arb_sum0=%0d",
                             debug_cycle_count,
                             u_top.u_npu.fsm_state,
                             u_top.u_npu.comp_sub_state,
                             u_top.u_npu.cluster_valid,
                             $signed(u_top.u_npu.cluster_arb_sum_out[31:0]));
                    $finish;
                end
                if ((debug_stop_cycle > 0) && (debug_cycle_count >= debug_stop_cycle)) begin
                    $display("DBG_COMP_STOP cyc=%0d fsm=%0d sub=%0d cluster_valid=%b arb_valid=%b",
                             debug_cycle_count,
                             u_top.u_npu.fsm_state,
                             u_top.u_npu.comp_sub_state,
                             u_top.u_npu.cluster_valid,
                             u_top.u_npu.cluster_arb_out_valid);
                    $finish;
                end
            end
            if ((debug_arbiter_window != 0) &&
                (u_top.u_npu.fsm_state == 5'd9) &&
                (u_top.u_npu.comp_sub_state == 3'd2) &&
                ((u_top.u_npu.comp_drain_cnt + 16'd4) >= u_top.u_npu.array_drain_offset)) begin
                $display("DBG_ARB_WINDOW cyc=%0d drain=%0d offset=%0d active_cols=%0d route_col=%0d cluster_busy=%b cluster_valid=%b cluster_done=%b arb_in_valid=%b arb_out_valid=%b arb_sum0=%0d",
                         debug_cycle_count,
                         u_top.u_npu.comp_drain_cnt,
                         u_top.u_npu.array_drain_offset,
                         u_top.u_npu.array_active_cols,
                         u_top.u_npu.cluster_route_col_i,
                         u_top.u_npu.cluster_busy,
                         u_top.u_npu.cluster_valid,
                         u_top.u_npu.cluster_done,
                         u_top.u_npu.cluster_arb_valid,
                         u_top.u_npu.cluster_arb_out_valid,
                         $signed(u_top.u_npu.cluster_arb_sum_out[31:0]));
            end
            if ((debug_project_drain_threshold != 0) &&
                (debug_project_drain_done == 0) &&
                (u_top.u_npu.fsm_state == 5'd9) &&
                (u_top.u_npu.comp_sub_state == 3'd2)) begin
                $display("DBG_PROJECT_DRAIN_THRESHOLD cyc=%0d natural_drain=%0d projected_drain=%0d active_cols=%0d route_col=0 cluster_enable=%b projected_arb_in_valid=%b projected_arb_out_valid=%b cluster_busy=%b cluster_valid=%b cluster_done=%b cluster_sum0=%0d",
                         debug_cycle_count,
                         u_top.u_npu.comp_drain_cnt,
                         u_top.u_npu.array_drain_offset,
                         u_top.u_npu.array_active_cols,
                         u_top.u_npu.perf_cluster_enable,
                         (u_top.u_npu.perf_cluster_enable[0] && (u_top.u_npu.array_active_cols != 16'd0)),
                         (|(u_top.u_npu.perf_cluster_enable & {5'b0, (u_top.u_npu.array_active_cols != 16'd0)})),
                         u_top.u_npu.cluster_busy,
                         u_top.u_npu.cluster_valid,
                         u_top.u_npu.cluster_done,
                         $signed(u_top.u_npu.cluster_sum_out_all_flat[31:0]));
                debug_project_drain_done <= 1;
                $finish;
            end
            if ((debug_natural_drain_stop > 0) &&
                (u_top.u_npu.fsm_state == 5'd9) &&
                (u_top.u_npu.comp_sub_state == 3'd2)) begin
                if (debug_natural_drain_seen == 0) begin
                    debug_natural_drain_seen <= 1;
                    debug_natural_drain_start_cycle <= debug_cycle_count;
                    $display("DBG_NAT_DRAIN_BEGIN cyc=%0d drain=%0d offset=%0d active_cols=%0d cluster_valid=%b arb_in_valid=%b arb_out_valid=%b",
                             debug_cycle_count,
                             u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset,
                             u_top.u_npu.array_active_cols,
                             u_top.u_npu.cluster_valid,
                             u_top.u_npu.cluster_arb_valid,
                             u_top.u_npu.cluster_arb_out_valid);
                end
                if ((u_top.u_npu.comp_drain_cnt >= debug_natural_drain_stop[15:0]) ||
                    ((debug_natural_drain_stop[15:0] <= u_top.u_npu.array_drain_offset) &&
                     (u_top.u_npu.comp_drain_cnt >= u_top.u_npu.array_drain_offset))) begin
                    $display("DBG_NAT_DRAIN_STOP cyc=%0d elapsed_cycles=%0d drain=%0d target=%0d offset=%0d route_col=%0d cluster_busy=%b cluster_valid=%b cluster_done=%b arb_in_valid=%b arb_out_valid=%b arb_sum0=%0d",
                             debug_cycle_count,
                             debug_cycle_count - debug_natural_drain_start_cycle,
                             u_top.u_npu.comp_drain_cnt,
                             debug_natural_drain_stop,
                             u_top.u_npu.array_drain_offset,
                             u_top.u_npu.cluster_route_col_i,
                             u_top.u_npu.cluster_busy,
                             u_top.u_npu.cluster_valid,
                             u_top.u_npu.cluster_done,
                             u_top.u_npu.cluster_arb_valid,
                             u_top.u_npu.cluster_arb_out_valid,
                             $signed(u_top.u_npu.cluster_arb_sum_out[31:0]));
                    $finish;
                end
            end
            if ((debug_stop_on_collect != 0) &&
                (u_top.u_npu.fsm_state == 5'd9) &&
                (u_top.u_npu.comp_sub_state == 3'd3)) begin
                $display("DBG_POST_ARB_COLLECT cyc=%0d drain=%0d offset=%0d acc_wr_en=%b acc_wr_addr=%0d acc_partial_addr=%0d acc_wr_ptr=%0d acc_wr_data=%0d col0=%0d arb_valid=%b",
                         debug_cycle_count,
                         u_top.u_npu.comp_drain_cnt,
                         u_top.u_npu.array_drain_offset,
                         u_top.u_npu.acc_wr_en,
                         u_top.u_npu.acc_wr_addr,
                         u_top.u_npu.acc_partial_addr,
                         u_top.u_npu.acc_wr_ptr,
                         $signed(u_top.u_npu.acc_wr_data),
                         $signed(u_top.u_npu.col_results[0]),
                         u_top.u_npu.cluster_arb_out_valid);
                $finish;
            end
            if ((debug_stop_on_acc_write != 0) && u_top.u_npu.acc_wr_en) begin
                $display("DBG_POST_ARB_ACC_WRITE cyc=%0d fsm=%0d sub=%0d acc_wr_addr=%0d acc_partial_addr=%0d acc_wr_ptr=%0d acc_wr_data=%0d col_idx=%0d col_data=%0d",
                         debug_cycle_count,
                         u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state,
                         u_top.u_npu.acc_wr_addr,
                         u_top.u_npu.acc_partial_addr,
                         u_top.u_npu.acc_wr_ptr,
                         $signed(u_top.u_npu.acc_wr_data),
                         u_top.u_npu.acc_col_idx,
                         $signed(u_top.u_npu.col_results[u_top.u_npu.acc_col_idx]));
                $finish;
            end
            if ((debug_stop_on_store != 0) &&
                (u_top.u_npu.fsm_state == 5'd11)) begin
                $display("DBG_POST_ARB_STORE cyc=%0d sub=%0d task_type=%0d dma_wr_valid=%b dma_wr_ready=%b dma_wr_busy=%b dma_rd_ptr=%0d dma_wr_addr=0x%08x dma_wr_bytes=%0d store_bytes=%0d blk_out_addr=0x%08x blk_out_bytes=%0d blk_done=%b blk_all_done=%b done=%b err=%b",
                         debug_cycle_count,
                         u_top.u_npu.comp_sub_state,
                         u_top.u_npu.task_type,
                         u_top.u_npu.dma_wr_valid,
                         u_top.u_npu.dma_wr_ready,
                         u_top.u_npu.dma_wr_busy,
                         u_top.u_npu.dma_rd_ptr,
                         u_top.u_npu.dma_wr_addr,
                         u_top.u_npu.dma_wr_bytes,
                         u_top.u_npu.store_bytes_active,
                         u_top.u_npu.blk_out_addr,
                         u_top.u_npu.blk_out_bytes,
                         u_top.u_npu.blk_done,
                         u_top.u_npu.blk_all_done,
                         u_top.u_npu.npu_done,
                         u_top.u_npu.npu_error);
                $finish;
            end
            if ((debug_stop_on_first_writeback != 0) &&
                ((u_top.u_npu.dma_wr_valid && u_top.u_npu.dma_wr_ready) ||
                 u_top.u_npu.m_axi_awvalid ||
                 u_top.u_npu.m_axi_wvalid ||
                 u_top.u_npu.m_axi_bvalid)) begin
                $display("DBG_POST_ARB_WRITEBACK cyc=%0d fsm=%0d sub=%0d dma_vr=%b%b dma_busy=%b aw_vr=%b%b w_vr=%b%b b_vr=%b%b dma_rd_ptr=%0d data=%0d done=%b err=%b",
                         debug_cycle_count,
                         u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state,
                         u_top.u_npu.dma_wr_valid,
                         u_top.u_npu.dma_wr_ready,
                         u_top.u_npu.dma_wr_busy,
                         u_top.u_npu.m_axi_awvalid,
                         u_top.u_npu.m_axi_awready,
                         u_top.u_npu.m_axi_wvalid,
                         u_top.u_npu.m_axi_wready,
                         u_top.u_npu.m_axi_bvalid,
                         u_top.u_npu.m_axi_bready,
                         u_top.u_npu.dma_rd_ptr,
                         $signed(u_top.u_npu.dma_wr_data),
                         u_top.u_npu.npu_done,
                         u_top.u_npu.npu_error);
                $finish;
            end
            if ((debug_stop_on_task_done != 0) &&
                (u_top.u_npu.npu_done || u_top.u_npu.npu_error)) begin
                $display("DBG_POST_ARB_TASK_DONE cyc=%0d fsm=%0d sub=%0d done=%b err=%b err_code=0x%02x blk_done=%b blk_all_done=%b dma_busy=%b dma_done=%b dma_error=%b status=0x%08x",
                         debug_cycle_count,
                         u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state,
                         u_top.u_npu.npu_done,
                         u_top.u_npu.npu_error,
                         u_top.u_npu.npu_error_code,
                         u_top.u_npu.blk_done,
                         u_top.u_npu.blk_all_done,
                         u_top.u_npu.dma_wr_busy,
                         u_top.u_npu.dma_wr_done,
                         u_top.u_npu.dma_wr_error,
                         npu_status);
                $finish;
            end
            if (debug_conv2_probe_active != 0) begin
                if ((debug_stop_on_conv2_compute != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9)) begin
                    $display("DBG_CONV2_COMPUTE cyc=%0d status=0x%08x fsm=%0d sub=%0d task_type=%0d cf_new=%b cf_done=%b cf_hold=%b act_done=%0d comp_feed=%0d drain=%0d cin=%0d/%0d offset=%0d cluster_busy=%b cluster_valid=%b arb_valid=%b",
                             debug_cycle_count, npu_status, u_top.u_npu.fsm_state,
                             u_top.u_npu.comp_sub_state, u_top.u_npu.task_type,
                             u_top.u_npu.cf_new_window, u_top.u_npu.cf_done,
                             u_top.u_npu.cf_window_hold, u_top.u_npu.act_feed_done_cnt,
                             u_top.u_npu.comp_feed_cnt, u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.cin_idx, u_top.u_npu.cin_total,
                             u_top.u_npu.array_drain_offset, u_top.u_npu.cluster_busy,
                             u_top.u_npu.cluster_valid, u_top.u_npu.cluster_arb_out_valid);
                    $finish;
                end
                if ((debug_stop_on_conv2_cf_window != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9) &&
                    u_top.u_npu.cf_new_window) begin
                    $display("DBG_CONV2_CF_WINDOW cyc=%0d status=0x%08x fsm=%0d sub=%0d cf_new=%b cf_done=%b cf_hold=%b act_done=%0d act_ptr=%0d comp_feed=%0d cin=%0d/%0d blk_in_bytes=%0d blk_rows=%0d/%0d",
                             debug_cycle_count, npu_status, u_top.u_npu.fsm_state,
                             u_top.u_npu.comp_sub_state, u_top.u_npu.cf_new_window,
                             u_top.u_npu.cf_done, u_top.u_npu.cf_window_hold,
                             u_top.u_npu.act_feed_done_cnt, u_top.u_npu.act_feed_ptr,
                             u_top.u_npu.comp_feed_cnt, u_top.u_npu.cin_idx,
                             u_top.u_npu.cin_total, u_top.u_npu.blk_in_bytes,
                             u_top.u_npu.blk_in_rows, u_top.u_npu.blk_out_rows);
                    $finish;
                end
                if ((debug_stop_on_conv2_arb != 0) &&
                    u_top.u_npu.cluster_arb_out_valid) begin
                    $display("DBG_CONV2_ARB cyc=%0d status=0x%08x fsm=%0d sub=%0d drain=%0d offset=%0d route_col=%0d cluster_busy=%b cluster_valid=%b cluster_done=%b arb_in_valid=%b arb_out_valid=%b arb_sum0=%0d cin=%0d/%0d",
                             debug_cycle_count, npu_status, u_top.u_npu.fsm_state,
                             u_top.u_npu.comp_sub_state, u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset, u_top.u_npu.cluster_route_col_i,
                             u_top.u_npu.cluster_busy, u_top.u_npu.cluster_valid,
                             u_top.u_npu.cluster_done, u_top.u_npu.cluster_arb_valid,
                             u_top.u_npu.cluster_arb_out_valid,
                             $signed(u_top.u_npu.cluster_arb_sum_out[31:0]),
                             u_top.u_npu.cin_idx, u_top.u_npu.cin_total);
                    $finish;
                end
                if ((debug_stop_on_conv2_collect != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9) &&
                    (u_top.u_npu.comp_sub_state == 3'd3)) begin
                    $display("DBG_CONV2_COLLECT cyc=%0d status=0x%08x drain=%0d offset=%0d acc_wr_en=%b acc_wr_addr=%0d acc_partial_addr=%0d acc_wr_ptr=%0d acc_wr_data=%0d col0=%0d cin=%0d/%0d",
                             debug_cycle_count, npu_status, u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset, u_top.u_npu.acc_wr_en,
                             u_top.u_npu.acc_wr_addr, u_top.u_npu.acc_partial_addr,
                             u_top.u_npu.acc_wr_ptr, $signed(u_top.u_npu.acc_wr_data),
                             $signed(u_top.u_npu.col_results[0]), u_top.u_npu.cin_idx,
                             u_top.u_npu.cin_total);
                    $finish;
                end
                if ((debug_dump_conv2_final_collect != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9) &&
                    (u_top.u_npu.comp_sub_state == 3'd3) &&
                    u_top.u_npu.acc_wr_en &&
                    (u_top.u_npu.cin_idx + 16'd1 == u_top.u_npu.cin_total) &&
                    (u_top.u_npu.acc_col_idx < 16'd8)) begin
                    $display("DBG_CONV2_FINAL_COLLECT cyc=%0d col=%0d acc_addr=%0d old_acc=%0d col_partial=%0d wr_data=%0d",
                             debug_cycle_count,
                             u_top.u_npu.acc_col_idx,
                             u_top.u_npu.acc_wr_addr,
                             $signed(u_top.u_npu.acc_rd_data),
                             $signed(u_top.u_npu.col_results[u_top.u_npu.acc_col_idx]),
                             $signed(u_top.u_npu.acc_wr_data));
                    if (u_top.u_npu.acc_col_idx == 16'd7)
                        $finish;
                end
                if ((debug_stop_on_conv2_store != 0) &&
                    (u_top.u_npu.fsm_state == 5'd11)) begin
                    $display("DBG_CONV2_STORE cyc=%0d status=0x%08x sub=%0d task_type=%0d dma_wr_valid=%b dma_wr_ready=%b dma_wr_busy=%b dma_rd_ptr=%0d dma_wr_addr=0x%08x dma_wr_bytes=%0d store_bytes=%0d out=0x%08x out_bytes=%0d done=%b err=%b",
                             debug_cycle_count, npu_status, u_top.u_npu.comp_sub_state,
                             u_top.u_npu.task_type, u_top.u_npu.dma_wr_valid,
                             u_top.u_npu.dma_wr_ready, u_top.u_npu.dma_wr_busy,
                             u_top.u_npu.dma_rd_ptr, u_top.u_npu.dma_wr_addr,
                             u_top.u_npu.dma_wr_bytes, u_top.u_npu.store_bytes_active,
                             u_top.u_npu.output_addr, u_top.u_npu.output_bytes,
                             u_top.u_npu.npu_done, u_top.u_npu.npu_error);
                    $finish;
                end
            end
            if (debug_fc1_probe_active != 0) begin
                if ((debug_stop_on_fc1_progress != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9)) begin
                    if (debug_fc1_progress_seen == 0) begin
                        debug_fc1_progress_seen <= 1;
                        debug_fc1_progress_start_cycle <= debug_cycle_count;
                        $display("DBG_FC1_PROGRESS_BEGIN cyc=%0d status=0x%08x fsm=%0d sub=%0d task_type=%0d fc_out_start=%0d fc_tile_outputs=%0d fc_in_base=%0d fc_chunk_inputs=%0d comp_feed=%0d drain=%0d offset=%0d cluster_busy=%b cluster_valid=%b arb_valid=%b",
                                 debug_cycle_count, npu_status, u_top.u_npu.fsm_state,
                                 u_top.u_npu.comp_sub_state, u_top.u_npu.task_type,
                                 u_top.u_npu.fc_out_start, u_top.u_npu.fc_tile_outputs,
                                 u_top.u_npu.fc_in_base, u_top.u_npu.fc_chunk_inputs,
                                 u_top.u_npu.comp_feed_cnt, u_top.u_npu.comp_drain_cnt,
                                 u_top.u_npu.array_drain_offset, u_top.u_npu.cluster_busy,
                                 u_top.u_npu.cluster_valid, u_top.u_npu.cluster_arb_out_valid);
                    end else if ((debug_cycle_count - debug_fc1_progress_start_cycle) >= debug_fc1_progress_cycles) begin
                        $display("DBG_FC1_PROGRESS_STOP cyc=%0d elapsed=%0d status=0x%08x fsm=%0d sub=%0d task_type=%0d fc_out_start=%0d fc_tile_outputs=%0d fc_in_base=%0d fc_chunk_inputs=%0d comp_feed=%0d drain=%0d offset=%0d cluster_busy=%b cluster_valid=%b cluster_done=%b arb_in_valid=%b arb_out_valid=%b arb_sum0=%0d acc_wr_en=%b acc_wr_addr=%0d dma_busy=%b done=%b err=%b",
                                 debug_cycle_count, debug_cycle_count - debug_fc1_progress_start_cycle,
                                 npu_status, u_top.u_npu.fsm_state, u_top.u_npu.comp_sub_state,
                                 u_top.u_npu.task_type, u_top.u_npu.fc_out_start,
                                 u_top.u_npu.fc_tile_outputs, u_top.u_npu.fc_in_base,
                                 u_top.u_npu.fc_chunk_inputs, u_top.u_npu.comp_feed_cnt,
                                 u_top.u_npu.comp_drain_cnt, u_top.u_npu.array_drain_offset,
                                 u_top.u_npu.cluster_busy, u_top.u_npu.cluster_valid,
                                 u_top.u_npu.cluster_done, u_top.u_npu.cluster_arb_valid,
                                 u_top.u_npu.cluster_arb_out_valid,
                                 $signed(u_top.u_npu.cluster_arb_sum_out[31:0]),
                                 u_top.u_npu.acc_wr_en, u_top.u_npu.acc_wr_addr,
                                 u_top.u_npu.dma_wr_busy, u_top.u_npu.npu_done,
                                 u_top.u_npu.npu_error);
                        $finish;
                    end
                end
                if ((debug_stop_on_fc1_compute != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9)) begin
                    $display("DBG_FC1_COMPUTE cyc=%0d status=0x%08x fsm=%0d sub=%0d task_type=%0d fc_out_start=%0d fc_tile_outputs=%0d fc_in_base=%0d fc_chunk_inputs=%0d comp_feed=%0d drain=%0d offset=%0d cluster_busy=%b cluster_valid=%b arb_valid=%b",
                             debug_cycle_count, npu_status, u_top.u_npu.fsm_state,
                             u_top.u_npu.comp_sub_state, u_top.u_npu.task_type,
                             u_top.u_npu.fc_out_start, u_top.u_npu.fc_tile_outputs,
                             u_top.u_npu.fc_in_base, u_top.u_npu.fc_chunk_inputs,
                             u_top.u_npu.comp_feed_cnt, u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset, u_top.u_npu.cluster_busy,
                             u_top.u_npu.cluster_valid, u_top.u_npu.cluster_arb_out_valid);
                    $finish;
                end
                if ((debug_stop_on_fc1_arb != 0) &&
                    u_top.u_npu.cluster_arb_out_valid) begin
                    $display("DBG_FC1_ARB cyc=%0d status=0x%08x fsm=%0d sub=%0d drain=%0d offset=%0d route_col=%0d fc_out_start=%0d fc_tile_outputs=%0d fc_in_base=%0d fc_chunk_inputs=%0d cluster_busy=%b cluster_valid=%b cluster_done=%b arb_in_valid=%b arb_out_valid=%b arb_sum0=%0d",
                             debug_cycle_count, npu_status, u_top.u_npu.fsm_state,
                             u_top.u_npu.comp_sub_state, u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset, u_top.u_npu.cluster_route_col_i,
                             u_top.u_npu.fc_out_start, u_top.u_npu.fc_tile_outputs,
                             u_top.u_npu.fc_in_base, u_top.u_npu.fc_chunk_inputs,
                             u_top.u_npu.cluster_busy, u_top.u_npu.cluster_valid,
                             u_top.u_npu.cluster_done, u_top.u_npu.cluster_arb_valid,
                             u_top.u_npu.cluster_arb_out_valid,
                             $signed(u_top.u_npu.cluster_arb_sum_out[31:0]));
                    $finish;
                end
                if ((debug_stop_on_fc1_collect != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9) &&
                    (u_top.u_npu.comp_sub_state == 3'd3)) begin
                    $display("DBG_FC1_COLLECT cyc=%0d status=0x%08x drain=%0d offset=%0d acc_wr_en=%b acc_wr_addr=%0d acc_partial_addr=%0d acc_wr_ptr=%0d acc_wr_data=%0d col0=%0d fc_out_start=%0d fc_tile_outputs=%0d fc_in_base=%0d fc_chunk_inputs=%0d",
                             debug_cycle_count, npu_status, u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset, u_top.u_npu.acc_wr_en,
                             u_top.u_npu.acc_wr_addr, u_top.u_npu.acc_partial_addr,
                             u_top.u_npu.acc_wr_ptr, $signed(u_top.u_npu.acc_wr_data),
                             $signed(u_top.u_npu.col_results[0]), u_top.u_npu.fc_out_start,
                             u_top.u_npu.fc_tile_outputs, u_top.u_npu.fc_in_base,
                             u_top.u_npu.fc_chunk_inputs);
                    $finish;
                end
                if ((debug_dump_fc1_final_collect != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9) &&
                    (u_top.u_npu.comp_sub_state == 3'd3) &&
                    u_top.u_npu.acc_wr_en &&
                    (u_top.u_npu.fc_in_base + u_top.u_npu.fc_chunk_inputs >= u_top.u_npu.input_c) &&
                    (u_top.u_npu.acc_col_idx < 16'd12)) begin
                    $display("DBG_FC1_FINAL_COLLECT cyc=%0d col=%0d fc_out_start=%0d acc_addr=%0d old_acc=%0d col_partial=%0d wr_data=%0d",
                             debug_cycle_count,
                             u_top.u_npu.acc_col_idx,
                             u_top.u_npu.fc_out_start,
                             u_top.u_npu.acc_wr_addr,
                             $signed(u_top.u_npu.acc_rd_data),
                             $signed(u_top.u_npu.col_results[u_top.u_npu.acc_col_idx]),
                             $signed(u_top.u_npu.acc_wr_data));
                    if (u_top.u_npu.acc_col_idx == 16'd11)
                        $finish;
                end
                if ((debug_dump_fc1_chunks != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9) &&
                    (u_top.u_npu.comp_sub_state == 3'd3) &&
                    u_top.u_npu.acc_wr_en &&
                    ((u_top.u_npu.acc_col_idx == 16'd5) ||
                     (u_top.u_npu.acc_col_idx == 16'd11))) begin
                    $display("DBG_FC1_CHUNK col=%0d fc_out_start=%0d fc_in_base=%0d chunk=%0d old_acc=%0d col_partial=%0d wr_data=%0d",
                             u_top.u_npu.acc_col_idx,
                             u_top.u_npu.fc_out_start,
                             u_top.u_npu.fc_in_base,
                             u_top.u_npu.fc_chunk_inputs,
                             $signed(u_top.u_npu.acc_rd_data),
                             $signed(u_top.u_npu.col_results[u_top.u_npu.acc_col_idx]),
                             $signed(u_top.u_npu.acc_wr_data));
                    if ((u_top.u_npu.fc_in_base + u_top.u_npu.fc_chunk_inputs >= u_top.u_npu.input_c) &&
                        (u_top.u_npu.acc_col_idx == 16'd11))
                        $finish;
                end
                if ((debug_stop_on_fc1_store != 0) &&
                    (u_top.u_npu.fsm_state == 5'd11)) begin
                    $display("DBG_FC1_STORE cyc=%0d status=0x%08x sub=%0d task_type=%0d dma_wr_valid=%b dma_wr_ready=%b dma_wr_busy=%b dma_rd_ptr=%0d dma_wr_addr=0x%08x dma_wr_bytes=%0d store_bytes=%0d fc_store_addr=0x%08x fc_store_bytes=%0d out=0x%08x out_bytes=%0d done=%b err=%b",
                             debug_cycle_count, npu_status, u_top.u_npu.comp_sub_state,
                             u_top.u_npu.task_type, u_top.u_npu.dma_wr_valid,
                             u_top.u_npu.dma_wr_ready, u_top.u_npu.dma_wr_busy,
                             u_top.u_npu.dma_rd_ptr, u_top.u_npu.dma_wr_addr,
                             u_top.u_npu.dma_wr_bytes, u_top.u_npu.store_bytes_active,
                             u_top.u_npu.fc_store_addr, u_top.u_npu.fc_store_bytes,
                             u_top.u_npu.output_addr, u_top.u_npu.output_bytes,
                             u_top.u_npu.npu_done, u_top.u_npu.npu_error);
                    $finish;
                end
            end else begin
                debug_fc1_progress_seen <= 0;
            end
            if (debug_fc2_probe_active != 0) begin
                if ((debug_stop_on_fc2_compute != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9)) begin
                    $display("DBG_FC2_COMPUTE cyc=%0d status=0x%08x fsm=%0d sub=%0d task_type=%0d fc_out_start=%0d fc_tile_outputs=%0d fc_in_base=%0d fc_chunk_inputs=%0d comp_feed=%0d drain=%0d offset=%0d cluster_busy=%b cluster_valid=%b arb_valid=%b",
                             debug_cycle_count, npu_status, u_top.u_npu.fsm_state,
                             u_top.u_npu.comp_sub_state, u_top.u_npu.task_type,
                             u_top.u_npu.fc_out_start, u_top.u_npu.fc_tile_outputs,
                             u_top.u_npu.fc_in_base, u_top.u_npu.fc_chunk_inputs,
                             u_top.u_npu.comp_feed_cnt, u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset, u_top.u_npu.cluster_busy,
                             u_top.u_npu.cluster_valid, u_top.u_npu.cluster_arb_out_valid);
                    $finish;
                end
                if ((debug_stop_on_fc2_arb != 0) &&
                    u_top.u_npu.cluster_arb_out_valid) begin
                    $display("DBG_FC2_ARB cyc=%0d status=0x%08x fsm=%0d sub=%0d drain=%0d offset=%0d route_col=%0d fc_out_start=%0d fc_tile_outputs=%0d fc_in_base=%0d fc_chunk_inputs=%0d cluster_busy=%b cluster_valid=%b cluster_done=%b arb_in_valid=%b arb_out_valid=%b arb_sum0=%0d",
                             debug_cycle_count, npu_status, u_top.u_npu.fsm_state,
                             u_top.u_npu.comp_sub_state, u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset, u_top.u_npu.cluster_route_col_i,
                             u_top.u_npu.fc_out_start, u_top.u_npu.fc_tile_outputs,
                             u_top.u_npu.fc_in_base, u_top.u_npu.fc_chunk_inputs,
                             u_top.u_npu.cluster_busy, u_top.u_npu.cluster_valid,
                             u_top.u_npu.cluster_done, u_top.u_npu.cluster_arb_valid,
                             u_top.u_npu.cluster_arb_out_valid,
                             $signed(u_top.u_npu.cluster_arb_sum_out[31:0]));
                    $finish;
                end
                if ((debug_stop_on_fc2_collect != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9) &&
                    (u_top.u_npu.comp_sub_state == 3'd3)) begin
                    $display("DBG_FC2_COLLECT cyc=%0d status=0x%08x drain=%0d offset=%0d acc_wr_en=%b acc_wr_addr=%0d acc_partial_addr=%0d acc_wr_ptr=%0d acc_wr_data=%0d col0=%0d fc_out_start=%0d fc_tile_outputs=%0d fc_in_base=%0d fc_chunk_inputs=%0d",
                             debug_cycle_count, npu_status, u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset, u_top.u_npu.acc_wr_en,
                             u_top.u_npu.acc_wr_addr, u_top.u_npu.acc_partial_addr,
                             u_top.u_npu.acc_wr_ptr, $signed(u_top.u_npu.acc_wr_data),
                             $signed(u_top.u_npu.col_results[0]), u_top.u_npu.fc_out_start,
                             u_top.u_npu.fc_tile_outputs, u_top.u_npu.fc_in_base,
                             u_top.u_npu.fc_chunk_inputs);
                    $finish;
                end
                if ((debug_stop_on_fc2_store != 0) &&
                    (u_top.u_npu.fsm_state == 5'd11)) begin
                    $display("DBG_FC2_STORE cyc=%0d status=0x%08x sub=%0d task_type=%0d dma_wr_valid=%b dma_wr_ready=%b dma_wr_busy=%b dma_rd_ptr=%0d dma_wr_addr=0x%08x dma_wr_bytes=%0d store_bytes=%0d fc_store_addr=0x%08x fc_store_bytes=%0d out=0x%08x out_bytes=%0d done=%b err=%b",
                             debug_cycle_count, npu_status, u_top.u_npu.comp_sub_state,
                             u_top.u_npu.task_type, u_top.u_npu.dma_wr_valid,
                             u_top.u_npu.dma_wr_ready, u_top.u_npu.dma_wr_busy,
                             u_top.u_npu.dma_rd_ptr, u_top.u_npu.dma_wr_addr,
                             u_top.u_npu.dma_wr_bytes, u_top.u_npu.store_bytes_active,
                             u_top.u_npu.fc_store_addr, u_top.u_npu.fc_store_bytes,
                             u_top.u_npu.output_addr, u_top.u_npu.output_bytes,
                             u_top.u_npu.npu_done, u_top.u_npu.npu_error);
                    $finish;
                end
                if ((debug_stop_on_fc2_last_chunk_collect != 0) &&
                    (u_top.u_npu.fsm_state == 5'd9) &&
                    (u_top.u_npu.comp_sub_state == 3'd3) &&
                    (u_top.u_npu.fc_in_base + u_top.u_npu.fc_chunk_inputs >= u_top.u_npu.input_c) &&
                    u_top.u_npu.acc_wr_en) begin
                    $display("DBG_FC2_LAST_COLLECT cyc=%0d col=%0d fc_out_start=%0d fc_tile_outputs=%0d fc_in_base=%0d fc_chunk_inputs=%0d acc_wr_addr=%0d acc_partial_addr=%0d acc_wr_ptr=%0d old_acc=%0d col_result=%0d wr_data=%0d drain=%0d offset=%0d arb_sum0=%0d",
                             debug_cycle_count, u_top.u_npu.acc_col_idx,
                             u_top.u_npu.fc_out_start, u_top.u_npu.fc_tile_outputs,
                             u_top.u_npu.fc_in_base, u_top.u_npu.fc_chunk_inputs,
                             u_top.u_npu.acc_wr_addr, u_top.u_npu.acc_partial_addr,
                             u_top.u_npu.acc_wr_ptr, $signed(u_top.u_npu.acc_rd_data),
                             $signed(u_top.u_npu.col_results[u_top.u_npu.acc_col_idx]),
                             $signed(u_top.u_npu.acc_wr_data), u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset,
                             $signed(u_top.u_npu.cluster_arb_sum_out[31:0]));
                    if (u_top.u_npu.acc_col_idx + 16'd1 >= u_top.u_npu.fc_tile_outputs)
                        $finish;
                end
                if (((debug_fc2_compare_chunk_golden != 0) ||
                     (debug_fc2_dump_chunk_col_results != 0) ||
                     (debug_fc2_dump_chunk_inputs != 0) ||
                     (debug_fc2_dump_chunk_weights != 0)) &&
                    (u_top.u_npu.fsm_state == 5'd9) &&
                    (u_top.u_npu.comp_sub_state == 3'd3) &&
                    u_top.u_npu.acc_wr_en &&
                    ((u_top.u_npu.fc_in_base == 16'd0) ||
                     (u_top.u_npu.fc_in_base + u_top.u_npu.fc_chunk_inputs >= u_top.u_npu.input_c))) begin
                    if ((u_top.u_npu.acc_col_idx == 16'd0) &&
                        ((debug_fc2_dump_chunk_inputs != 0) || (debug_fc2_dump_chunk_weights != 0))) begin
                        $display("DBG_FC2_CHUNK_BYTES fc_in_base=%0d fc_chunk_inputs=%0d act0=%0d act1=%0d act2=%0d act3=%0d act_last0=%0d act_last1=%0d w0_0=%0d w0_1=%0d w0_2=%0d w0_3=%0d w0_last0=%0d w0_last1=%0d",
                                 u_top.u_npu.fc_in_base, u_top.u_npu.fc_chunk_inputs,
                                 ram_i8(FC1_OUT_ADDR, u_top.u_npu.fc_in_base + 0),
                                 ram_i8(FC1_OUT_ADDR, u_top.u_npu.fc_in_base + 1),
                                 ram_i8(FC1_OUT_ADDR, u_top.u_npu.fc_in_base + 2),
                                 ram_i8(FC1_OUT_ADDR, u_top.u_npu.fc_in_base + 3),
                                 ram_i8(FC1_OUT_ADDR, u_top.u_npu.fc_in_base + u_top.u_npu.fc_chunk_inputs - 2),
                                 ram_i8(FC1_OUT_ADDR, u_top.u_npu.fc_in_base + u_top.u_npu.fc_chunk_inputs - 1),
                                 ram_i8(FC2_WGT_ADDR, u_top.u_npu.fc_in_base + 0),
                                 ram_i8(FC2_WGT_ADDR, u_top.u_npu.fc_in_base + 1),
                                 ram_i8(FC2_WGT_ADDR, u_top.u_npu.fc_in_base + 2),
                                 ram_i8(FC2_WGT_ADDR, u_top.u_npu.fc_in_base + 3),
                                 ram_i8(FC2_WGT_ADDR, u_top.u_npu.fc_in_base + u_top.u_npu.fc_chunk_inputs - 2),
                                 ram_i8(FC2_WGT_ADDR, u_top.u_npu.fc_in_base + u_top.u_npu.fc_chunk_inputs - 1));
                    end
                    $display("DBG_FC2_CHUNK_COMPARE chunk_base=%0d chunk_inputs=%0d col=%0d sw_partial=%0d rtl_col=%0d old_acc=%0d wr_data=%0d acc_addr=%0d match_col=%0d",
                             u_top.u_npu.fc_in_base, u_top.u_npu.fc_chunk_inputs,
                             u_top.u_npu.acc_col_idx,
                             fc2_sw_partial_sum(u_top.u_npu.acc_col_idx, u_top.u_npu.fc_in_base, u_top.u_npu.fc_chunk_inputs),
                             $signed(u_top.u_npu.col_results[u_top.u_npu.acc_col_idx]),
                             $signed(u_top.u_npu.acc_rd_data),
                             $signed(u_top.u_npu.acc_wr_data),
                             u_top.u_npu.acc_wr_addr,
                             ($signed(u_top.u_npu.col_results[u_top.u_npu.acc_col_idx]) ==
                              fc2_sw_partial_sum(u_top.u_npu.acc_col_idx, u_top.u_npu.fc_in_base, u_top.u_npu.fc_chunk_inputs)));
                    if ((u_top.u_npu.fc_in_base + u_top.u_npu.fc_chunk_inputs >= u_top.u_npu.input_c) &&
                        (u_top.u_npu.acc_col_idx + 16'd1 >= u_top.u_npu.fc_tile_outputs))
                        $finish;
                end
            end
            if (debug_force_drain_threshold != 0) begin
                if ((debug_force_drain_state == 0) &&
                    (u_top.u_npu.fsm_state == 5'd9) &&
                    (u_top.u_npu.comp_sub_state == 3'd2)) begin
                    $display("DBG_FORCE_DRAIN_BEGIN cyc=%0d natural_drain=%0d offset=%0d active_cols=%0d",
                             debug_cycle_count,
                             u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset,
                             u_top.u_npu.array_active_cols);
                    force u_top.u_npu.comp_drain_cnt = u_top.u_npu.array_drain_offset;
                    #1;
                    $display("DBG_FORCE_DRAIN_SAMPLE cyc=%0d forced_drain=%0d offset=%0d route_col=%0d arb_in_valid=%b arb_out_valid=%b arb_sum0=%0d",
                             debug_cycle_count,
                             u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset,
                             u_top.u_npu.cluster_route_col_i,
                             u_top.u_npu.cluster_arb_valid,
                             u_top.u_npu.cluster_arb_out_valid,
                             $signed(u_top.u_npu.cluster_arb_sum_out[31:0]));
                    release u_top.u_npu.comp_drain_cnt;
                    if (u_top.u_npu.cluster_arb_out_valid) begin
                        $display("DBG_FORCE_DRAIN_ARB_PASS cyc=%0d", debug_cycle_count);
                        $finish;
                    end
                    debug_force_drain_state <= 2;
                end else if (debug_force_drain_state == 1) begin
                    $display("DBG_FORCE_DRAIN_SAMPLE cyc=%0d forced_drain=%0d offset=%0d route_col=%0d arb_in_valid=%b arb_out_valid=%b arb_sum0=%0d",
                             debug_cycle_count,
                             u_top.u_npu.comp_drain_cnt,
                             u_top.u_npu.array_drain_offset,
                             u_top.u_npu.cluster_route_col_i,
                             u_top.u_npu.cluster_arb_valid,
                             u_top.u_npu.cluster_arb_out_valid,
                             $signed(u_top.u_npu.cluster_arb_sum_out[31:0]));
                    release u_top.u_npu.comp_drain_cnt;
                    if (u_top.u_npu.cluster_arb_out_valid) begin
                        $display("DBG_FORCE_DRAIN_ARB_PASS cyc=%0d", debug_cycle_count);
                        $finish;
                    end
                    debug_force_drain_state <= 2;
                end
            end
            debug_prev_fsm <= u_top.u_npu.fsm_state;
            debug_prev_sub <= u_top.u_npu.comp_sub_state;
            debug_prev_cluster_valid <= u_top.u_npu.cluster_valid;
            debug_prev_arb_valid <= u_top.u_npu.cluster_arb_out_valid;
        end
    end

    function integer read_int_file;
        input string path;
        integer fd, value;
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("ERROR: failed to open %0s", path);
                read_int_file = -1;
            end else begin
                value = -1;
                if ($fscanf(fd, "%d", value) != 1)
                    value = -1;
                $fclose(fd);
                read_int_file = value;
            end
        end
    endfunction

    function [63:0] expected_mac_count;
        input [1:0] ttype;
        input [31:0] in_bytes;
        input [15:0] iw;
        input [15:0] ih;
        input [15:0] ic;
        input [15:0] oc;
        reg [63:0] conv_windows;
        begin
            if (ttype == 2'd0) begin
                conv_windows = ((ih >= 16'd5) && (iw >= 16'd5)) ? ((ih - 16'd4) * (iw - 16'd4)) : 64'd0;
                expected_mac_count = conv_windows * ic * oc * 64'd25;
            end else if (ttype == 2'd1) begin
                expected_mac_count = in_bytes * oc;
            end else begin
                expected_mac_count = 64'd0;
            end
        end
    endfunction

    function signed [7:0] ram_i8;
        input [31:0] base_addr;
        input integer byte_idx;
        reg [31:0] byte_addr;
        begin
            byte_addr = base_addr + byte_idx;
            ram_i8 = u_top.u_shared_ram.ram[byte_addr[19:5]][byte_addr[4:0] * 8 +: 8];
        end
    endfunction

    function [31:0] ram_word32;
        input [31:0] byte_addr;
        begin
            ram_word32 = u_top.u_shared_ram.ram[byte_addr[19:5]][byte_addr[4:2] * 32 +: 32];
        end
    endfunction

    task write_ram_word32;
        input [31:0] byte_addr;
        input [31:0] word;
        integer b;
        begin
            for (b = 0; b < 4; b = b + 1)
                u_top.u_shared_ram.ram[byte_addr[19:5]][(byte_addr[4:0] + b) * 8 +: 8] = word[b * 8 +: 8];
        end
    endtask

    function signed [31:0] fc2_sw_partial_sum;
        input integer out_idx;
        input integer in_base;
        input integer chunk_inputs;
        integer k;
        reg signed [7:0] act_b;
        reg signed [7:0] wgt_b;
        reg signed [31:0] sum;
        begin
            sum = 32'sd0;
            for (k = 0; k < chunk_inputs; k = k + 1) begin
                act_b = ram_i8(FC1_OUT_ADDR, in_base + k);
                wgt_b = ram_i8(FC2_WGT_ADDR, out_idx * 500 + in_base + k);
                sum = sum + ($signed(act_b) * $signed(wgt_b));
            end
            fc2_sw_partial_sum = sum;
        end
    endfunction

    task axil_write;
        input [31:0] addr;
        input [31:0] data;
        reg aw_done;
        reg w_done;
        begin
            if (debug_axil != 0)
                $display("DBG_AXIL_WRITE_BEGIN t=%0t addr=0x%08x data=0x%08x", $time, addr, data);
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
            if (debug_axil != 0)
                $display("DBG_AXIL_WRITE_DONE  t=%0t addr=0x%08x bresp=0x%0x", $time, addr, tb_bresp);
        end
    endtask

    task program_requant_slots;
        begin
            axil_write(REQUANT0_MULT, rq_conv2_mult[31:0]);
            axil_write(REQUANT0_SHIFT, rq_conv2_shift[31:0]);
            axil_write(REQUANT1_MULT, rq_fc1_mult[31:0]);
            axil_write(REQUANT1_SHIFT, rq_fc1_shift[31:0]);
            axil_write(REQUANT2_MULT, rq_fc2_mult[31:0]);
            axil_write(REQUANT2_SHIFT, rq_fc2_shift[31:0]);
        end
    endtask

    task axil_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            if (debug_axil != 0)
                $display("DBG_AXIL_READ_BEGIN t=%0t addr=0x%08x", $time, addr);
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
            if (debug_axil != 0)
                $display("DBG_AXIL_READ_DONE  t=%0t addr=0x%08x data=0x%08x rresp=0x%0x", $time, addr, data, tb_rresp);
        end
    endtask

    task wait_done;
        input integer maxc;
        output integer waited_cycles;
        integer c;
        begin
            c = 0;
            while (!npu_status[2] && !npu_status[3] && c < maxc) begin
                @(posedge clk);
                c = c + 1;
            if (show_progress != 0 && (c % 1000) == 0)
                    $display("  progress cycles=%0d status=0x%08x fsm=%0d sub=%0d", c, npu_status, u_top.u_npu.fsm_state, u_top.u_npu.comp_sub_state);
            end
            if (npu_status[3])
                $fatal(1,
                       "top_lenet NPU error status=0x%08x fsm=%0d sub=%0d task_err_code=0x%02x act_err=%0b act_code=0x%02x act_addr=0x%08x act_bytes=%0d wgt_err=%0b wgt_code=0x%02x wgt_addr=0x%08x wgt_bytes=%0d dma_wr_error=%0b dma_wr_error_code=0x%02x dma_wr_addr=0x%08x dma_wr_bytes=%0d",
                       npu_status, u_top.u_npu.fsm_state, u_top.u_npu.comp_sub_state,
                       u_top.u_npu.task_error_code_r,
                       u_top.u_npu.act_dma_error, u_top.u_npu.act_dma_error_code,
                       u_top.u_npu.act_dma_addr, u_top.u_npu.act_dma_bytes,
                       u_top.u_npu.wgt_dma_error, u_top.u_npu.wgt_dma_error_code,
                       u_top.u_npu.wgt_dma_addr, u_top.u_npu.wgt_dma_bytes,
                       u_top.u_npu.dma_wr_error,
                       u_top.u_npu.dma_wr_error_code, u_top.u_npu.dma_wr_addr,
                       u_top.u_npu.dma_wr_bytes);
            if (!npu_status[2])
                $fatal(1, "top_lenet timeout");
            while (npu_status[1] && c < maxc) begin
                @(posedge clk);
                c = c + 1;
            end
            if (npu_status[1])
                $fatal(1, "top_lenet busy stuck after done");
            waited_cycles = c;
        end
    endtask

    task load_memh_to_ram;
        input string path;
        input [31:0] base_addr;
        input integer word_count;
        integer i;
        begin
            $readmemh(path, file_words);
            for (i = 0; i < word_count; i = i + 1)
                write_ram_word32(base_addr + i * 4, file_words[i]);
        end
    endtask

    task compare_region_memh;
        input string path;
        input [31:0] base_addr;
        input integer word_count;
        input [127:0] name;
        inout integer total_errs;
        integer i, local_errs;
        reg [31:0] actual;
        begin
            local_errs = 0;
            $readmemh(path, file_words);
            for (i = 0; i < word_count; i = i + 1) begin
                actual = ram_word32(base_addr + i * 4);
                if (actual !== file_words[i]) begin
                    local_errs = local_errs + 1;
                    if (local_errs <= 8)
                        $display("  %0s mismatch[%0d]: got %0d exp %0d", name, i, $signed(actual), $signed(file_words[i]));
                end
            end
            if (local_errs == 0)
                $display("  %0s PASS", name);
            else
                $display("  %0s FAIL: %0d mismatches", name, local_errs);
            total_errs = total_errs + local_errs;
        end
    endtask

    task requantize_i32_to_i8_region;
        input [31:0] src_addr;
        input [31:0] dst_addr;
        input integer elem_count;
        input [1:0] slot_sel;
        input integer multiplier;
        input integer shift;
        begin
            axil_write(REQUANT_SEL, {30'd0, slot_sel});
            case (slot_sel)
                2'd0: begin
                    axil_write(REQUANT0_MULT, multiplier[31:0]);
                    axil_write(REQUANT0_SHIFT, shift[31:0]);
                end
                2'd1: begin
                    axil_write(REQUANT1_MULT, multiplier[31:0]);
                    axil_write(REQUANT1_SHIFT, shift[31:0]);
                end
                default: begin
                    axil_write(REQUANT2_MULT, multiplier[31:0]);
                    axil_write(REQUANT2_SHIFT, shift[31:0]);
                end
            endcase
            run_layer(2'd3, src_addr, 32'h0, dst_addr, elem_count * 4, 32'd0, elem_count,
                      16'd1, 16'd1, 16'd1, 16'd1, 1'b0, 1'b0, 3000000, "Requant");
        end
    endtask

    task report_perf;
        input [127:0] layer_name;
        input [63:0] expected_mac;
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

            if ({mac_hi, mac_lo} !== expected_mac)
                $fatal(1, "%0s perf mac mismatch got 0x%08x_%08x expect 0x%08x_%08x",
                       layer_name, mac_hi, mac_lo, expected_mac[63:32], expected_mac[31:0]);
            if (cycle_lo == 32'd0)
                $fatal(1, "%0s perf cycles should be non-zero", layer_name);
            if (cluster_cfg[7:0] !== 8'h01)
                $fatal(1, "%0s cluster cfg mismatch: 0x%08x", layer_name, cluster_cfg);

            sample_total_cycles         = sample_total_cycles + {cycle_hi, cycle_lo};
            sample_total_mac            = sample_total_mac + {mac_hi, mac_lo};
            sample_total_read_beats     = sample_total_read_beats + read_beats;
            sample_total_write_beats    = sample_total_write_beats + write_beats;
            sample_total_read_active    = sample_total_read_active + read_active;
            sample_total_write_active   = sample_total_write_active + write_active;
            sample_total_array_active   = sample_total_array_active + array_active;
            sample_total_array_stall    = sample_total_array_stall + array_stall;
            sample_total_cluster_active = sample_total_cluster_active + cluster_active;
            sample_total_cluster_stall  = sample_total_cluster_stall + cluster_stall;

            if (verbose_this_sample != 0) begin
                read_bw_util = (read_active != 0) ? (read_beats * 1.0 / read_active) : 0.0;
                write_bw_util = (write_active != 0) ? (write_beats * 1.0 / write_active) : 0.0;
                array_util = (cycle_lo != 0) ? (array_active * 1.0 / cycle_lo) : 0.0;

                $display("PERF %0s cycles=%0d read_beats=%0d write_beats=%0d read_bw_util=%0.4f write_bw_util=%0.4f array_active=%0d array_stall=%0d cluster_active=%0d cluster_stall=%0d mac=%0d cluster_cfg=0x%08x array_util=%0.4f",
                         layer_name, cycle_lo, read_beats, write_beats, read_bw_util, write_bw_util,
                         array_active, array_stall, cluster_active, cluster_stall, mac_lo, cluster_cfg, array_util);
            end
        end
    endtask

    task run_layer;
        input [1:0] ttype;
        input [31:0] in_addr, wgt_addr, out_addr;
        input [31:0] in_bytes, wgt_bytes, out_bytes;
        input [15:0] iw, ih, ic, oc;
        input relu, pool;
        input integer maxc;
        input [127:0] layer_name;
        reg [63:0] expected_mac;
        integer busy_clear_cycle;
        begin
            if (verbose_this_sample != 0)
                $display("=== %0s ===", layer_name);
            if (npu_status[2] || npu_status[3])
                axil_write(NPU_BASE + 32'h00, 32'h10);
            repeat (2) @(posedge clk);
            axil_write(NPU_BASE + 32'h08, {30'd0, ttype});
            axil_write(NPU_BASE + 32'h0C, in_addr);
            axil_write(NPU_BASE + 32'h10, wgt_addr);
            axil_write(NPU_BASE + 32'h14, out_addr);
            axil_write(NPU_BASE + 32'h18, in_bytes);
            axil_write(NPU_BASE + 32'h1C, wgt_bytes);
            axil_write(NPU_BASE + 32'h20, out_bytes);
            axil_write(NPU_BASE + 32'h24, {iw[15:0], ih[15:0]});
            axil_write(NPU_BASE + 32'h28, {oc[15:0], ic[15:0]});
            axil_write(NPU_BASE + 32'h2C, {30'd0, pool, relu});
            axil_write(NPU_BASE + 32'h00, 32'h1);
            repeat (2) @(posedge clk);
            if ((debug_stop_on_pool1_start != 0) &&
                (ttype == 2'd2) && (in_addr == CONV1_OUT_ADDR) && (out_addr == POOL1_OUT_ADDR)) begin
                $display("DBG_HANDOFF_POOL1_START cyc=%0d status=0x%08x task_start=%b task_type=%0d in=0x%08x out=0x%08x in_bytes=%0d out_bytes=%0d ih=%0d iw=%0d ic=%0d oc=%0d relu=%b pool=%b fsm=%0d sub=%0d pp_start=%b pp_done=%b",
                         debug_cycle_count, npu_status, u_top.u_npu.task_start,
                         u_top.u_npu.task_type, u_top.u_npu.input_addr,
                         u_top.u_npu.output_addr, u_top.u_npu.input_bytes,
                         u_top.u_npu.output_bytes, u_top.u_npu.input_h,
                         u_top.u_npu.input_w, u_top.u_npu.input_c,
                         u_top.u_npu.output_c, u_top.u_npu.relu_en,
                         u_top.u_npu.pool_en, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.pp_start,
                         u_top.u_npu.pp_done);
                $finish;
            end
            if ((debug_stop_on_conv2_requant_start != 0) &&
                (ttype == 2'd3) && (in_addr == POOL1_OUT_ADDR) && (out_addr == CONV2_IN_ADDR)) begin
                $display("DBG_HANDOFF_CONV2_REQUANT_START cyc=%0d status=0x%08x task_start=%b task_type=%0d in=0x%08x out=0x%08x in_bytes=%0d out_bytes=%0d multiplier=%0d shift=%0d fsm=%0d sub=%0d",
                         debug_cycle_count, npu_status, u_top.u_npu.task_start,
                         u_top.u_npu.task_type, u_top.u_npu.input_addr,
                         u_top.u_npu.output_addr, u_top.u_npu.input_bytes,
                         u_top.u_npu.output_bytes, u_top.u_npu.requant_multiplier,
                         u_top.u_npu.requant_shift, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state);
                $finish;
            end
            if ((debug_stop_on_conv2_start != 0) &&
                (ttype == 2'd0) && (in_addr == CONV2_IN_ADDR) && (out_addr == CONV2_OUT_ADDR)) begin
                $display("DBG_HANDOFF_CONV2_START cyc=%0d status=0x%08x task_start=%b task_type=%0d in=0x%08x wgt=0x%08x out=0x%08x in_bytes=%0d wgt_bytes=%0d out_bytes=%0d ih=%0d iw=%0d ic=%0d oc=%0d fsm=%0d sub=%0d cf_new=%b arb_valid=%b",
                         debug_cycle_count, npu_status, u_top.u_npu.task_start,
                         u_top.u_npu.task_type, u_top.u_npu.input_addr,
                         u_top.u_npu.weight_addr, u_top.u_npu.output_addr,
                         u_top.u_npu.input_bytes, u_top.u_npu.weight_bytes,
                         u_top.u_npu.output_bytes, u_top.u_npu.input_h,
                         u_top.u_npu.input_w, u_top.u_npu.input_c,
                         u_top.u_npu.output_c, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.cf_new_window,
                         u_top.u_npu.cluster_arb_out_valid);
                $finish;
            end
            if ((debug_stop_on_pool2_start != 0) &&
                (ttype == 2'd2) && (in_addr == CONV2_OUT_ADDR) && (out_addr == POOL2_OUT_ADDR)) begin
                $display("DBG_HANDOFF_POOL2_START cyc=%0d status=0x%08x task_start=%b task_type=%0d in=0x%08x out=0x%08x in_bytes=%0d out_bytes=%0d ih=%0d iw=%0d ic=%0d oc=%0d relu=%b pool=%b fsm=%0d sub=%0d pp_start=%b pp_done=%b",
                         debug_cycle_count, npu_status, u_top.u_npu.task_start,
                         u_top.u_npu.task_type, u_top.u_npu.input_addr,
                         u_top.u_npu.output_addr, u_top.u_npu.input_bytes,
                         u_top.u_npu.output_bytes, u_top.u_npu.input_h,
                         u_top.u_npu.input_w, u_top.u_npu.input_c,
                         u_top.u_npu.output_c, u_top.u_npu.relu_en,
                         u_top.u_npu.pool_en, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.pp_start,
                         u_top.u_npu.pp_done);
                $finish;
            end
            if ((debug_stop_on_fc1_requant_start != 0) &&
                (ttype == 2'd3) && (in_addr == POOL2_OUT_ADDR) && (out_addr == POOL2_OUT_ADDR)) begin
                $display("DBG_HANDOFF_FC1_REQUANT_START cyc=%0d status=0x%08x task_start=%b task_type=%0d in=0x%08x out=0x%08x in_bytes=%0d out_bytes=%0d multiplier=%0d shift=%0d fsm=%0d sub=%0d",
                         debug_cycle_count, npu_status, u_top.u_npu.task_start,
                         u_top.u_npu.task_type, u_top.u_npu.input_addr,
                         u_top.u_npu.output_addr, u_top.u_npu.input_bytes,
                         u_top.u_npu.output_bytes, u_top.u_npu.requant_multiplier,
                         u_top.u_npu.requant_shift, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state);
                $finish;
            end
            if ((debug_stop_on_fc1_start != 0) &&
                (ttype == 2'd1) && (in_addr == POOL2_OUT_ADDR) && (wgt_addr == FC1_WGT_ADDR) &&
                (out_addr == FC1_OUT_ADDR)) begin
                $display("DBG_HANDOFF_FC1_START cyc=%0d status=0x%08x task_start=%b task_type=%0d in=0x%08x wgt=0x%08x out=0x%08x in_bytes=%0d wgt_bytes=%0d out_bytes=%0d ih=%0d iw=%0d ic=%0d oc=%0d relu=%b pool=%b fsm=%0d sub=%0d arb_valid=%b acc_wr_en=%b",
                         debug_cycle_count, npu_status, u_top.u_npu.task_start,
                         u_top.u_npu.task_type, u_top.u_npu.input_addr,
                         u_top.u_npu.weight_addr, u_top.u_npu.output_addr,
                         u_top.u_npu.input_bytes, u_top.u_npu.weight_bytes,
                         u_top.u_npu.output_bytes, u_top.u_npu.input_h,
                         u_top.u_npu.input_w, u_top.u_npu.input_c,
                         u_top.u_npu.output_c, u_top.u_npu.relu_en,
                         u_top.u_npu.pool_en, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.cluster_arb_out_valid,
                         u_top.u_npu.acc_wr_en);
                $finish;
            end
            if ((debug_stop_on_fc2_start != 0) &&
                (ttype == 2'd1) && (in_addr == FC1_OUT_ADDR) && (wgt_addr == FC2_WGT_ADDR) &&
                (out_addr == FC2_OUT_ADDR)) begin
                $display("DBG_HANDOFF_FC2_START cyc=%0d status=0x%08x task_start=%b task_type=%0d in=0x%08x wgt=0x%08x out=0x%08x in_bytes=%0d wgt_bytes=%0d out_bytes=%0d ih=%0d iw=%0d ic=%0d oc=%0d relu=%b pool=%b fsm=%0d sub=%0d arb_valid=%b acc_wr_en=%b",
                         debug_cycle_count, npu_status, u_top.u_npu.task_start,
                         u_top.u_npu.task_type, u_top.u_npu.input_addr,
                         u_top.u_npu.weight_addr, u_top.u_npu.output_addr,
                         u_top.u_npu.input_bytes, u_top.u_npu.weight_bytes,
                         u_top.u_npu.output_bytes, u_top.u_npu.input_h,
                         u_top.u_npu.input_w, u_top.u_npu.input_c,
                         u_top.u_npu.output_c, u_top.u_npu.relu_en,
                         u_top.u_npu.pool_en, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.cluster_arb_out_valid,
                         u_top.u_npu.acc_wr_en);
                $finish;
            end
            if ((ttype == 2'd0) && (in_addr == CONV2_IN_ADDR) && (out_addr == CONV2_OUT_ADDR) &&
                ((debug_stop_on_conv2_compute != 0) ||
                 (debug_stop_on_conv2_cf_window != 0) ||
                 (debug_stop_on_conv2_arb != 0) ||
                 (debug_stop_on_conv2_collect != 0) ||
                 (debug_dump_conv2_final_collect != 0) ||
                 (debug_stop_on_conv2_store != 0) ||
                 (debug_stop_on_conv2_done != 0))) begin
                debug_conv2_probe_active = 1;
            end else begin
                debug_conv2_probe_active = 0;
            end
            if ((ttype == 2'd1) && (in_addr == POOL2_OUT_ADDR) && (wgt_addr == FC1_WGT_ADDR) &&
                (out_addr == FC1_OUT_ADDR) &&
                ((debug_stop_on_fc1_compute != 0) ||
                 (debug_stop_on_fc1_arb != 0) ||
                 (debug_stop_on_fc1_collect != 0) ||
                 (debug_dump_fc1_final_collect != 0) ||
                 (debug_dump_fc1_chunks != 0) ||
                 (debug_stop_on_fc1_store != 0) ||
                 (debug_stop_on_fc1_done != 0) ||
                 (debug_stop_on_fc1_progress != 0))) begin
                debug_fc1_probe_active = 1;
            end else begin
                debug_fc1_probe_active = 0;
            end
            if ((ttype == 2'd1) && (in_addr == FC1_OUT_ADDR) && (wgt_addr == FC2_WGT_ADDR) &&
                (out_addr == FC2_OUT_ADDR) &&
                ((debug_stop_on_fc2_compute != 0) ||
                 (debug_stop_on_fc2_arb != 0) ||
                 (debug_stop_on_fc2_collect != 0) ||
                 (debug_stop_on_fc2_store != 0) ||
                 (debug_stop_on_fc2_done != 0) ||
                 (debug_stop_on_fc2_last_chunk_collect != 0) ||
                 (debug_fc2_dump_chunk_inputs != 0) ||
                 (debug_fc2_dump_chunk_weights != 0) ||
                 (debug_fc2_dump_chunk_col_results != 0) ||
                 (debug_fc2_compare_chunk_golden != 0))) begin
                debug_fc2_probe_active = 1;
            end else begin
                debug_fc2_probe_active = 0;
            end
            wait_done(maxc, busy_clear_cycle);
            if ((debug_stop_on_fc1_done != 0) &&
                (ttype == 2'd1) && (in_addr == POOL2_OUT_ADDR) && (wgt_addr == FC1_WGT_ADDR) &&
                (out_addr == FC1_OUT_ADDR)) begin
                $display("DBG_FC1_DONE cyc=%0d waited=%0d status=0x%08x done=%b err=%b task_type=%0d fsm=%0d sub=%0d fc_out_start=%0d fc_tile_outputs=%0d fc_in_base=%0d fc_chunk_inputs=%0d acc_wr_en=%b acc_wr_addr=%0d dma_busy=%b dma_done=%b out=0x%08x out_bytes=%0d",
                         debug_cycle_count, busy_clear_cycle, npu_status,
                         u_top.u_npu.npu_done, u_top.u_npu.npu_error,
                         u_top.u_npu.task_type, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.fc_out_start,
                         u_top.u_npu.fc_tile_outputs, u_top.u_npu.fc_in_base,
                         u_top.u_npu.fc_chunk_inputs, u_top.u_npu.acc_wr_en,
                         u_top.u_npu.acc_wr_addr, u_top.u_npu.dma_wr_busy,
                         u_top.u_npu.dma_wr_done, u_top.u_npu.output_addr,
                         u_top.u_npu.output_bytes);
                $finish;
            end
            debug_fc1_probe_active = 0;
            if ((debug_stop_on_fc2_done != 0) &&
                (ttype == 2'd1) && (in_addr == FC1_OUT_ADDR) && (wgt_addr == FC2_WGT_ADDR) &&
                (out_addr == FC2_OUT_ADDR)) begin
                $display("DBG_FC2_DONE cyc=%0d waited=%0d status=0x%08x done=%b err=%b task_type=%0d fsm=%0d sub=%0d fc_out_start=%0d fc_tile_outputs=%0d fc_in_base=%0d fc_chunk_inputs=%0d acc_wr_en=%b acc_wr_addr=%0d dma_busy=%b dma_done=%b out=0x%08x out_bytes=%0d",
                         debug_cycle_count, busy_clear_cycle, npu_status,
                         u_top.u_npu.npu_done, u_top.u_npu.npu_error,
                         u_top.u_npu.task_type, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.fc_out_start,
                         u_top.u_npu.fc_tile_outputs, u_top.u_npu.fc_in_base,
                         u_top.u_npu.fc_chunk_inputs, u_top.u_npu.acc_wr_en,
                         u_top.u_npu.acc_wr_addr, u_top.u_npu.dma_wr_busy,
                         u_top.u_npu.dma_wr_done, u_top.u_npu.output_addr,
                         u_top.u_npu.output_bytes);
                $finish;
            end
            debug_fc2_probe_active = 0;
            if ((debug_stop_on_conv2_done != 0) &&
                (ttype == 2'd0) && (in_addr == CONV2_IN_ADDR) && (out_addr == CONV2_OUT_ADDR)) begin
                $display("DBG_CONV2_DONE cyc=%0d waited=%0d status=0x%08x done=%b err=%b task_type=%0d fsm=%0d sub=%0d cf_done=%b acc_wr_en=%b acc_wr_addr=%0d dma_busy=%b dma_done=%b out=0x%08x out_bytes=%0d",
                         debug_cycle_count, busy_clear_cycle, npu_status,
                         u_top.u_npu.npu_done, u_top.u_npu.npu_error,
                         u_top.u_npu.task_type, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.cf_done,
                         u_top.u_npu.acc_wr_en, u_top.u_npu.acc_wr_addr,
                         u_top.u_npu.dma_wr_busy, u_top.u_npu.dma_wr_done,
                         u_top.u_npu.output_addr, u_top.u_npu.output_bytes);
                $finish;
            end
            debug_conv2_probe_active = 0;
            if ((debug_stop_on_pool1_done != 0) &&
                (ttype == 2'd2) && (in_addr == CONV1_OUT_ADDR) && (out_addr == POOL1_OUT_ADDR)) begin
                $display("DBG_HANDOFF_POOL1_DONE cyc=%0d waited=%0d status=0x%08x done=%b err=%b task_type=%0d fsm=%0d sub=%0d pp_start=%b pp_done=%b pp_valid=%b acc_wr_en=%b acc_wr_addr=%0d acc_wr_data=%0d dma_busy=%b dma_done=%b out=0x%08x out_bytes=%0d",
                         debug_cycle_count, busy_clear_cycle, npu_status,
                         u_top.u_npu.npu_done, u_top.u_npu.npu_error,
                         u_top.u_npu.task_type, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.pp_start,
                         u_top.u_npu.pp_done, u_top.u_npu.pp_data_valid,
                         u_top.u_npu.acc_wr_en, u_top.u_npu.acc_wr_addr,
                         $signed(u_top.u_npu.acc_wr_data), u_top.u_npu.dma_wr_busy,
                         u_top.u_npu.dma_wr_done, u_top.u_npu.output_addr,
                         u_top.u_npu.output_bytes);
                $finish;
            end
            if ((debug_stop_on_conv2_requant_done != 0) &&
                (ttype == 2'd3) && (in_addr == POOL1_OUT_ADDR) && (out_addr == CONV2_IN_ADDR)) begin
                $display("DBG_HANDOFF_CONV2_REQUANT_DONE cyc=%0d waited=%0d status=0x%08x done=%b err=%b task_type=%0d fsm=%0d sub=%0d acc_wr_en=%b acc_wr_addr=%0d acc_wr_data=0x%08x dma_busy=%b dma_done=%b out=0x%08x out_bytes=%0d",
                         debug_cycle_count, busy_clear_cycle, npu_status,
                         u_top.u_npu.npu_done, u_top.u_npu.npu_error,
                         u_top.u_npu.task_type, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.acc_wr_en,
                         u_top.u_npu.acc_wr_addr, u_top.u_npu.acc_wr_data,
                         u_top.u_npu.dma_wr_busy, u_top.u_npu.dma_wr_done,
                         u_top.u_npu.output_addr, u_top.u_npu.output_bytes);
                $finish;
            end
            if ((debug_stop_on_pool2_done != 0) &&
                (ttype == 2'd2) && (in_addr == CONV2_OUT_ADDR) && (out_addr == POOL2_OUT_ADDR)) begin
                $display("DBG_HANDOFF_POOL2_DONE cyc=%0d waited=%0d status=0x%08x done=%b err=%b task_type=%0d fsm=%0d sub=%0d pp_start=%b pp_done=%b pp_valid=%b acc_wr_en=%b acc_wr_addr=%0d acc_wr_data=%0d dma_busy=%b dma_done=%b out=0x%08x out_bytes=%0d",
                         debug_cycle_count, busy_clear_cycle, npu_status,
                         u_top.u_npu.npu_done, u_top.u_npu.npu_error,
                         u_top.u_npu.task_type, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.pp_start,
                         u_top.u_npu.pp_done, u_top.u_npu.pp_data_valid,
                         u_top.u_npu.acc_wr_en, u_top.u_npu.acc_wr_addr,
                         $signed(u_top.u_npu.acc_wr_data), u_top.u_npu.dma_wr_busy,
                         u_top.u_npu.dma_wr_done, u_top.u_npu.output_addr,
                         u_top.u_npu.output_bytes);
                $finish;
            end
            if ((debug_stop_on_fc1_requant_done != 0) &&
                (ttype == 2'd3) && (in_addr == POOL2_OUT_ADDR) && (out_addr == POOL2_OUT_ADDR)) begin
                $display("DBG_HANDOFF_FC1_REQUANT_DONE cyc=%0d waited=%0d status=0x%08x done=%b err=%b task_type=%0d fsm=%0d sub=%0d acc_wr_en=%b acc_wr_addr=%0d acc_wr_data=0x%08x dma_busy=%b dma_done=%b out=0x%08x out_bytes=%0d",
                         debug_cycle_count, busy_clear_cycle, npu_status,
                         u_top.u_npu.npu_done, u_top.u_npu.npu_error,
                         u_top.u_npu.task_type, u_top.u_npu.fsm_state,
                         u_top.u_npu.comp_sub_state, u_top.u_npu.acc_wr_en,
                         u_top.u_npu.acc_wr_addr, u_top.u_npu.acc_wr_data,
                         u_top.u_npu.dma_wr_busy, u_top.u_npu.dma_wr_done,
                         u_top.u_npu.output_addr, u_top.u_npu.output_bytes);
                $finish;
            end
            expected_mac = expected_mac_count(ttype, in_bytes, iw, ih, ic, oc);
            if (!skip_perf_reads) begin
                report_perf(layer_name, expected_mac);
            end else begin
                sample_total_cycles = sample_total_cycles + busy_clear_cycle;
                sample_total_mac = sample_total_mac + expected_mac;
            end
        end
    endtask

    integer errs;
    integer fc2_numeric_errs;
    integer expected_class;
    integer pred_class;
    integer i;
    reg signed [31:0] best_val;
    reg [31:0] logits_word;
    reg [31:0] cpu_logits [0:9];

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
        errs = 0;
        sample_total_cycles = 64'd0;
        sample_total_mac = 64'd0;
        sample_total_read_beats = 64'd0;
        sample_total_write_beats = 64'd0;
        sample_total_read_active = 64'd0;
        sample_total_write_active = 64'd0;
        sample_total_array_active = 64'd0;
        sample_total_array_stall = 64'd0;
        sample_total_cluster_active = 64'd0;
        sample_total_cluster_stall = 64'd0;

        fixture_dir = "datasets/mnist/lenet_fixture";
        sample_name = "sample_00000_label_7";
        sample_root_dir = "";
        weights_root_dir = "";
        input_memh_name = "input.memh";
        expected_file_name = "argmax.txt";
        expected_class_override = -1;
        show_progress = 0;
        eval_mode = 0;
        skip_perf_reads = 0;
        debug_axil = 0;
        debug_trace = 0;
        debug_trace_period = 1000;
        debug_cycle_count = 0;
        debug_compute = 0;
        debug_stop_cycle = 0;
        debug_arbiter_window = 0;
        debug_force_drain_threshold = 0;
        debug_project_drain_threshold = 0;
        debug_project_drain_done = 0;
        debug_natural_drain_stop = 0;
        debug_stop_on_collect = 0;
        debug_stop_on_acc_write = 0;
        debug_stop_on_store = 0;
        debug_stop_on_first_writeback = 0;
        debug_stop_on_task_done = 0;
        debug_stop_on_pool1_start = 0;
        debug_stop_on_pool1_done = 0;
        debug_stop_on_conv2_requant_start = 0;
        debug_stop_on_conv2_requant_done = 0;
        debug_stop_on_conv2_start = 0;
        debug_stop_on_conv2_compute = 0;
        debug_stop_on_conv2_cf_window = 0;
        debug_stop_on_conv2_arb = 0;
        debug_stop_on_conv2_collect = 0;
        debug_dump_conv2_final_collect = 0;
        debug_stop_on_conv2_store = 0;
        debug_stop_on_conv2_done = 0;
        debug_conv2_probe_active = 0;
        debug_stop_on_pool2_start = 0;
        debug_stop_on_pool2_done = 0;
        debug_stop_on_fc1_requant_start = 0;
        debug_stop_on_fc1_requant_done = 0;
        debug_stop_on_fc1_start = 0;
        debug_stop_on_fc1_compute = 0;
        debug_stop_on_fc1_arb = 0;
        debug_stop_on_fc1_collect = 0;
        debug_dump_fc1_final_collect = 0;
        debug_dump_fc1_chunks = 0;
        debug_stop_on_fc1_store = 0;
        debug_stop_on_fc1_done = 0;
        debug_stop_on_fc2_start = 0;
        debug_stop_on_fc1_progress = 0;
        debug_fc1_progress_cycles = 1000;
        debug_fc1_progress_seen = 0;
        debug_fc1_progress_start_cycle = 0;
        debug_fc1_probe_active = 0;
        debug_stop_on_fc2_compute = 0;
        debug_stop_on_fc2_arb = 0;
        debug_stop_on_fc2_collect = 0;
        debug_stop_on_fc2_store = 0;
        debug_stop_on_fc2_done = 0;
        debug_stop_on_top_result = 0;
        debug_fc2_probe_active = 0;
        debug_stop_on_fc2_last_chunk_collect = 0;
        debug_dump_fc2_logits = 0;
        debug_compare_fc2_golden = 0;
        debug_fc2_dump_chunk_inputs = 0;
        debug_fc2_dump_chunk_weights = 0;
        debug_fc2_dump_chunk_col_results = 0;
        debug_fc2_compare_chunk_golden = 0;
        debug_natural_drain_seen = 0;
        debug_natural_drain_start_cycle = 0;
        debug_force_drain_state = 0;
        debug_prev_fsm = 5'h0;
        debug_prev_sub = 3'h0;
        debug_prev_cluster_valid = 6'h0;
        debug_prev_arb_valid = 1'b0;
        rq_conv2_mult = 1;
        rq_conv2_shift = 0;
        rq_fc1_mult = 1;
        rq_fc1_shift = 0;
        rq_fc2_mult = 1;
        rq_fc2_shift = 0;
        sample_ordinal = 0;
        verbose_limit = 16;
        void'($value$plusargs("fixture_dir=%s", fixture_dir));
        void'($value$plusargs("sample_name=%s", sample_name));
        void'($value$plusargs("sample_root_dir=%s", sample_root_dir));
        void'($value$plusargs("weights_root_dir=%s", weights_root_dir));
        void'($value$plusargs("input_memh_name=%s", input_memh_name));
        void'($value$plusargs("expected_file_name=%s", expected_file_name));
        void'($value$plusargs("expected_class_override=%d", expected_class_override));
        void'($value$plusargs("progress=%d", show_progress));
        void'($value$plusargs("eval_mode=%d", eval_mode));
        void'($value$plusargs("skip_perf_reads=%d", skip_perf_reads));
        void'($value$plusargs("debug_axil=%d", debug_axil));
        void'($value$plusargs("debug_trace=%d", debug_trace));
        void'($value$plusargs("debug_trace_period=%d", debug_trace_period));
        void'($value$plusargs("debug_compute=%d", debug_compute));
        void'($value$plusargs("debug_stop_cycle=%d", debug_stop_cycle));
        void'($value$plusargs("debug_arbiter_window=%d", debug_arbiter_window));
        void'($value$plusargs("debug_force_drain_threshold=%d", debug_force_drain_threshold));
        void'($value$plusargs("debug_project_drain_threshold=%d", debug_project_drain_threshold));
        void'($value$plusargs("debug_natural_drain_stop=%d", debug_natural_drain_stop));
        void'($value$plusargs("debug_stop_on_collect=%d", debug_stop_on_collect));
        void'($value$plusargs("debug_stop_on_acc_write=%d", debug_stop_on_acc_write));
        void'($value$plusargs("debug_stop_on_store=%d", debug_stop_on_store));
        void'($value$plusargs("debug_stop_on_first_writeback=%d", debug_stop_on_first_writeback));
        void'($value$plusargs("debug_stop_on_task_done=%d", debug_stop_on_task_done));
        void'($value$plusargs("debug_stop_on_pool1_start=%d", debug_stop_on_pool1_start));
        void'($value$plusargs("debug_stop_on_pool1_done=%d", debug_stop_on_pool1_done));
        void'($value$plusargs("debug_stop_on_conv2_requant_start=%d", debug_stop_on_conv2_requant_start));
        void'($value$plusargs("debug_stop_on_conv2_requant_done=%d", debug_stop_on_conv2_requant_done));
        void'($value$plusargs("debug_stop_on_conv2_start=%d", debug_stop_on_conv2_start));
        void'($value$plusargs("debug_stop_on_conv2_compute=%d", debug_stop_on_conv2_compute));
        void'($value$plusargs("debug_stop_on_conv2_cf_window=%d", debug_stop_on_conv2_cf_window));
        void'($value$plusargs("debug_stop_on_conv2_arb=%d", debug_stop_on_conv2_arb));
        void'($value$plusargs("debug_stop_on_conv2_collect=%d", debug_stop_on_conv2_collect));
        void'($value$plusargs("debug_dump_conv2_final_collect=%d", debug_dump_conv2_final_collect));
        void'($value$plusargs("debug_stop_on_conv2_store=%d", debug_stop_on_conv2_store));
        void'($value$plusargs("debug_stop_on_conv2_done=%d", debug_stop_on_conv2_done));
        void'($value$plusargs("debug_stop_on_pool2_start=%d", debug_stop_on_pool2_start));
        void'($value$plusargs("debug_stop_on_pool2_done=%d", debug_stop_on_pool2_done));
        void'($value$plusargs("debug_stop_on_fc1_requant_start=%d", debug_stop_on_fc1_requant_start));
        void'($value$plusargs("debug_stop_on_fc1_requant_done=%d", debug_stop_on_fc1_requant_done));
        void'($value$plusargs("debug_stop_on_fc1_start=%d", debug_stop_on_fc1_start));
        void'($value$plusargs("debug_stop_on_fc1_compute=%d", debug_stop_on_fc1_compute));
        void'($value$plusargs("debug_stop_on_fc1_arb=%d", debug_stop_on_fc1_arb));
        void'($value$plusargs("debug_stop_on_fc1_collect=%d", debug_stop_on_fc1_collect));
        void'($value$plusargs("debug_dump_fc1_final_collect=%d", debug_dump_fc1_final_collect));
        void'($value$plusargs("debug_dump_fc1_chunks=%d", debug_dump_fc1_chunks));
        void'($value$plusargs("debug_stop_on_fc1_store=%d", debug_stop_on_fc1_store));
        void'($value$plusargs("debug_stop_on_fc1_done=%d", debug_stop_on_fc1_done));
        void'($value$plusargs("debug_stop_on_fc2_start=%d", debug_stop_on_fc2_start));
        void'($value$plusargs("debug_stop_on_fc1_progress=%d", debug_stop_on_fc1_progress));
        void'($value$plusargs("debug_fc1_progress_cycles=%d", debug_fc1_progress_cycles));
        void'($value$plusargs("debug_stop_on_fc2_compute=%d", debug_stop_on_fc2_compute));
        void'($value$plusargs("debug_stop_on_fc2_arb=%d", debug_stop_on_fc2_arb));
        void'($value$plusargs("debug_stop_on_fc2_collect=%d", debug_stop_on_fc2_collect));
        void'($value$plusargs("debug_stop_on_fc2_store=%d", debug_stop_on_fc2_store));
        void'($value$plusargs("debug_stop_on_fc2_done=%d", debug_stop_on_fc2_done));
        void'($value$plusargs("debug_stop_on_top_result=%d", debug_stop_on_top_result));
        void'($value$plusargs("debug_stop_on_fc2_last_chunk_collect=%d", debug_stop_on_fc2_last_chunk_collect));
        void'($value$plusargs("debug_dump_fc2_logits=%d", debug_dump_fc2_logits));
        void'($value$plusargs("debug_compare_fc2_golden=%d", debug_compare_fc2_golden));
        void'($value$plusargs("debug_fc2_dump_chunk_inputs=%d", debug_fc2_dump_chunk_inputs));
        void'($value$plusargs("debug_fc2_dump_chunk_weights=%d", debug_fc2_dump_chunk_weights));
        void'($value$plusargs("debug_fc2_dump_chunk_col_results=%d", debug_fc2_dump_chunk_col_results));
        void'($value$plusargs("debug_fc2_compare_chunk_golden=%d", debug_fc2_compare_chunk_golden));
        void'($value$plusargs("sample_ordinal=%d", sample_ordinal));
        void'($value$plusargs("verbose_limit=%d", verbose_limit));
        void'($value$plusargs("rq_conv2_mult=%d", rq_conv2_mult));
        void'($value$plusargs("rq_conv2_shift=%d", rq_conv2_shift));
        void'($value$plusargs("rq_fc1_mult=%d", rq_fc1_mult));
        void'($value$plusargs("rq_fc1_shift=%d", rq_fc1_shift));
        void'($value$plusargs("rq_fc2_mult=%d", rq_fc2_mult));
        void'($value$plusargs("rq_fc2_shift=%d", rq_fc2_shift));
        if (sample_root_dir == "")
            sample_root_dir = fixture_dir;
        if (weights_root_dir == "")
            weights_root_dir = {fixture_dir, "/weights"};
        verbose_this_sample = (!eval_mode) || (sample_ordinal < verbose_limit);

        sample_dir = {sample_root_dir, "/", sample_name};
        weights_dir = weights_root_dir;
        path_input         = {sample_dir, "/", input_memh_name};
        path_conv1_w       = {weights_dir, "/conv1_weights.memh"};
        path_conv2_w       = {weights_dir, "/conv2_weights.memh"};
        path_fc1_w         = {weights_dir, "/fc1_weights.memh"};
        path_fc2_w         = {weights_dir, "/fc2_weights.memh"};
        path_conv1_g       = {fixture_dir, "/", sample_name, "/conv1_out.memh"};
        path_pool1_g       = {fixture_dir, "/", sample_name, "/pool1_out.memh"};
        path_conv2_input_g = {fixture_dir, "/", sample_name, "/conv2_input.memh"};
        path_conv2_g       = {fixture_dir, "/", sample_name, "/conv2_out.memh"};
        path_pool2_g       = {fixture_dir, "/", sample_name, "/pool2_out.memh"};
        path_fc1_g         = {fixture_dir, "/", sample_name, "/fc1_out.memh"};
        path_fc2_g         = {fixture_dir, "/", sample_name, "/fc2_logits.memh"};
        path_expected      = {sample_dir, "/", expected_file_name};

        #20 rst_n = 1'b1;
        #20;

        load_memh_to_ram(path_input, INPUT_ADDR, 196);
        load_memh_to_ram(path_conv1_w, CONV1_WGT_ADDR, 125);
        load_memh_to_ram(path_conv2_w, CONV2_WGT_ADDR, 12500);
        load_memh_to_ram(path_fc1_w, FC1_WGT_ADDR, 100000);
        load_memh_to_ram(path_fc2_w, FC2_WGT_ADDR, 1250);
        program_requant_slots();

        run_layer(2'd0, INPUT_ADDR, CONV1_WGT_ADDR, CONV1_OUT_ADDR, 32'd784, 32'd500, 32'd46080, 16'd28, 16'd28, 16'd1, 16'd20, 1'b0, 1'b0, 3000000, "Conv1");
        if (!eval_mode)
            compare_region_memh(path_conv1_g, CONV1_OUT_ADDR, 24*24*20, "Conv1 golden", errs);

        run_layer(2'd2, CONV1_OUT_ADDR, 32'h0, POOL1_OUT_ADDR, 32'd46080, 32'd0, 32'd11520, 16'd24, 16'd24, 16'd20, 16'd20, 1'b0, 1'b1, 1000000, "Pool1");
        if (!eval_mode)
            compare_region_memh(path_pool1_g, POOL1_OUT_ADDR, 12*12*20, "Pool1 golden", errs);

        requantize_i32_to_i8_region(POOL1_OUT_ADDR, CONV2_IN_ADDR, 12*12*20, 2'd0, rq_conv2_mult, rq_conv2_shift);
        if (!eval_mode)
            compare_region_memh(path_conv2_input_g, CONV2_IN_ADDR, (12*12*20 + 3) / 4, "Pool1->Conv2 requant", errs);

        run_layer(2'd0, CONV2_IN_ADDR, CONV2_WGT_ADDR, CONV2_OUT_ADDR, 32'd2880, 32'd25000, 32'd12800, 16'd12, 16'd12, 16'd20, 16'd50, 1'b0, 1'b0, 6000000, "Conv2");
        if (!eval_mode)
            compare_region_memh(path_conv2_g, CONV2_OUT_ADDR, 8*8*50, "Conv2 golden", errs);

        run_layer(2'd2, CONV2_OUT_ADDR, 32'h0, POOL2_OUT_ADDR, 32'd12800, 32'd0, 32'd3200, 16'd8, 16'd8, 16'd50, 16'd50, 1'b0, 1'b1, 1000000, "Pool2");
        if (!eval_mode)
            compare_region_memh(path_pool2_g, POOL2_OUT_ADDR, 4*4*50, "Pool2 golden", errs);

        requantize_i32_to_i8_region(POOL2_OUT_ADDR, POOL2_OUT_ADDR, 4*4*50, 2'd1, rq_fc1_mult, rq_fc1_shift);

        run_layer(2'd1, POOL2_OUT_ADDR, FC1_WGT_ADDR, FC1_OUT_ADDR, 32'd800, 32'd400000, 32'd2000, 16'd1, 16'd1, 16'd800, 16'd500, 1'b1, 1'b0, 10000000, "FC1");
        if (!eval_mode)
            compare_region_memh(path_fc1_g, FC1_OUT_ADDR, 500, "FC1 golden", errs);

        requantize_i32_to_i8_region(FC1_OUT_ADDR, FC1_OUT_ADDR, 500, 2'd2, rq_fc2_mult, rq_fc2_shift);

        run_layer(2'd1, FC1_OUT_ADDR, FC2_WGT_ADDR, FC2_OUT_ADDR, 32'd500, 32'd5000, 32'd40, 16'd1, 16'd1, 16'd500, 16'd10, 1'b0, 1'b0, 3000000, "FC2");
        if (!eval_mode)
            compare_region_memh(path_fc2_g, FC2_OUT_ADDR, 10, "FC2 golden", errs);

        expected_class = (expected_class_override >= 0) ? expected_class_override : read_int_file(path_expected);
        pred_class = 0;
        best_val = -32'sd2147483648;
        for (i = 0; i < 10; i = i + 1) begin
            axil_read(FC2_OUT_ADDR + i*4, logits_word);
            cpu_logits[i] = logits_word;
            if ($signed(logits_word) > best_val) begin
                best_val = $signed(logits_word);
                pred_class = i;
            end
        end

        if ((debug_dump_fc2_logits != 0) || (debug_compare_fc2_golden != 0)) begin
            $readmemh(path_fc2_g, file_words);
            fc2_numeric_errs = 0;
            for (i = 0; i < 10; i = i + 1) begin
                logits_word = ram_word32(FC2_OUT_ADDR + i * 4);
                if (cpu_logits[i] !== file_words[i])
                    fc2_numeric_errs = fc2_numeric_errs + 1;
                $display("DBG_FC2_LOGIT idx=%0d axil=%0d ram=%0d golden=%0d axil_hex=0x%08x ram_hex=0x%08x golden_hex=0x%08x match=%0d",
                         i, $signed(cpu_logits[i]), $signed(logits_word),
                         $signed(file_words[i]), cpu_logits[i], logits_word,
                         file_words[i], (cpu_logits[i] === file_words[i]));
            end
            $display("DBG_FC2_LOGIT_SUMMARY mismatches=%0d predicted=%0d expected=%0d",
                     fc2_numeric_errs, pred_class, expected_class);
            if (debug_compare_fc2_golden != 0)
                $finish;
        end

        if (verbose_this_sample != 0)
            $display("Predicted class=%0d expected=%0d", pred_class, expected_class);
        if (pred_class != expected_class) begin
            errs = errs + 1;
            if (verbose_this_sample != 0)
                $display("Classification mismatch");
        end

        if (debug_stop_on_top_result != 0) begin
            $display("DBG_TOP_RESULT sample=%0s predicted=%0d expected=%0d errs=%0d best_val=%0d logit0=%0d logit1=%0d logit2=%0d logit3=%0d logit4=%0d logit5=%0d logit6=%0d logit7=%0d logit8=%0d logit9=%0d",
                     sample_name, pred_class, expected_class, errs, best_val,
                     $signed(cpu_logits[0]), $signed(cpu_logits[1]), $signed(cpu_logits[2]),
                     $signed(cpu_logits[3]), $signed(cpu_logits[4]), $signed(cpu_logits[5]),
                     $signed(cpu_logits[6]), $signed(cpu_logits[7]), $signed(cpu_logits[8]),
                     $signed(cpu_logits[9]));
            $finish;
        end

        if (errs != 0) begin
            $display("TOP_RESULT sample=%0s predicted=%0d expected=%0d status=FAIL total_cycles=%0d total_mac=%0d total_read_beats=%0d total_write_beats=%0d total_read_active=%0d total_write_active=%0d total_array_active=%0d total_array_stall=%0d total_cluster_active=%0d total_cluster_stall=%0d",
                     sample_name, pred_class, expected_class,
                     sample_total_cycles, sample_total_mac, sample_total_read_beats, sample_total_write_beats,
                     sample_total_read_active, sample_total_write_active,
                     sample_total_array_active, sample_total_array_stall, sample_total_cluster_active, sample_total_cluster_stall);
            $fatal(1, "tb_top_lenet FAILED with %0d mismatches", errs);
        end

        $display("TOP_RESULT sample=%0s predicted=%0d expected=%0d status=PASS total_cycles=%0d total_mac=%0d total_read_beats=%0d total_write_beats=%0d total_read_active=%0d total_write_active=%0d total_array_active=%0d total_array_stall=%0d total_cluster_active=%0d total_cluster_stall=%0d",
                 sample_name, pred_class, expected_class,
                 sample_total_cycles, sample_total_mac, sample_total_read_beats, sample_total_write_beats,
                 sample_total_read_active, sample_total_write_active,
                 sample_total_array_active, sample_total_array_stall, sample_total_cluster_active, sample_total_cluster_stall);
        $display("tb_top_lenet PASS for %0s", sample_name);
        $finish;
    end

endmodule
