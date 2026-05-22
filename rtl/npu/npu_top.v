// npu_top: NPU accelerator orchestration top for the formal 6-cluster SoC baseline
// Multi-channel Conv: temporal input-channel iteration with parallel output channels
// Current top-level execution path keeps a single-cluster compatibility-mode hookup
// while the formal compute hierarchy is compute_core_6cluster / cluster_scheduler / output_arbiter
`timescale 1ns / 1ps

module npu_top #(
    parameter AXI_ADDR_W = 32,
    parameter AXI_DATA_W = 32,
    parameter BUF_DATA_W  = 32,
    parameter BUF_ENTRIES = 1024,
    parameter BUF_ADDR_W  = 10,
    parameter TILE_ROWS   = 16,
    parameter TILE_COLS   = 16
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite Slave
    input  wire                        s_axi_awvalid,
    output wire                        s_axi_awready,
    input  wire [AXI_ADDR_W-1:0]       s_axi_awaddr,
    input  wire                        s_axi_wvalid,
    output wire                        s_axi_wready,
    input  wire [AXI_DATA_W-1:0]       s_axi_wdata,
    input  wire [3:0]                  s_axi_wstrb,
    output wire                        s_axi_bvalid,
    input  wire                        s_axi_bready,
    output wire [1:0]                  s_axi_bresp,
    input  wire                        s_axi_arvalid,
    output wire                        s_axi_arready,
    input  wire [AXI_ADDR_W-1:0]       s_axi_araddr,
    output wire                        s_axi_rvalid,
    input  wire                        s_axi_rready,
    output wire [AXI_DATA_W-1:0]       s_axi_rdata,
    output wire [1:0]                  s_axi_rresp,

    // AXI4 Master Read
    output wire [AXI_ADDR_W-1:0]       m_axi_araddr,
    output wire                        m_axi_arvalid,
    input  wire                        m_axi_arready,
    output wire [7:0]                  m_axi_arlen,
    output wire [2:0]                  m_axi_arsize,
    output wire [1:0]                  m_axi_arburst,
    input  wire [AXI_DATA_W-1:0]       m_axi_rdata,
    input  wire                        m_axi_rvalid,
    output wire                        m_axi_rready,
    input  wire                        m_axi_rlast,
    input  wire [1:0]                  m_axi_rresp,

    // AXI4 Master Write
    output wire [AXI_ADDR_W-1:0]       m_axi_awaddr,
    output wire                        m_axi_awvalid,
    input  wire                        m_axi_awready,
    output wire [7:0]                  m_axi_awlen,
    output wire [2:0]                  m_axi_awsize,
    output wire [1:0]                  m_axi_awburst,
    output wire [AXI_DATA_W-1:0]       m_axi_wdata,
    output wire                        m_axi_wvalid,
    input  wire                        m_axi_wready,
    output wire                        m_axi_wlast,
    output wire [3:0]                  m_axi_wstrb,
    input  wire [1:0]                  m_axi_bresp,
    input  wire                        m_axi_bvalid,
    output wire                        m_axi_bready,

    // Status
    output wire                        npu_busy,
    output wire                        npu_done,
    output wire                        npu_error,
    output wire [7:0]                  npu_error_code
);

    localparam PE_ROWS = TILE_ROWS * 4;
    localparam PE_COLS = TILE_COLS * 4;
    localparam N_TILES = TILE_ROWS * TILE_COLS;
    localparam KERNEL_SPATIAL = 25;   // 5x5 spatial kernel elements (never changes)

    // ============================================================
    // npu_ctrl signals
    // ============================================================
    wire        task_start;
    wire [1:0]  task_type;
    wire [31:0] input_addr, weight_addr, output_addr;
    wire [31:0] input_bytes, weight_bytes, output_bytes;
    wire [15:0] input_h, input_w, input_c, output_c;
    wire        relu_en, pool_en;
    wire        ctrl_busy, ctrl_done, ctrl_error, task_go;
    wire [7:0]  ctrl_error_code;

    wire        task_done_fb;
    wire        task_error_fb;
    wire [7:0]  task_error_code_fb;
    wire        check_done_fb;
    wire        checks_pass_fb;

    wire [31:0] perf_cycle_lo, perf_cycle_hi;
    wire [31:0] perf_read_beats, perf_write_beats;
    wire [31:0] perf_read_active, perf_write_active;
    wire [31:0] perf_mac_lo, perf_mac_hi;
    wire [31:0] perf_array_active, perf_array_stall;
    wire [31:0] perf_cluster_active, perf_cluster_stall;
    wire [31:0] perf_cluster_cfg;

    wire [31:0] blk_in_addr, blk_wgt_addr, blk_out_addr;
    wire [31:0] blk_in_bytes, blk_wgt_bytes, blk_out_bytes;
    wire [15:0] blk_in_rows, blk_out_rows;
    wire [31:0] blk_wgt_per_cin;
    wire [15:0] blk_cin_total;

    // ============================================================
    // npu_ctrl
    // ============================================================
    npu_ctrl u_ctrl (
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
        .ctrl_busy(ctrl_busy), .ctrl_done(ctrl_done),
        .ctrl_error(ctrl_error), .ctrl_error_code(ctrl_error_code),
        .task_go(task_go), .task_start(task_start), .task_type(task_type),
        .input_addr(input_addr), .weight_addr(weight_addr), .output_addr(output_addr),
        .input_bytes(input_bytes), .weight_bytes(weight_bytes), .output_bytes(output_bytes),
        .input_h(input_h), .input_w(input_w), .input_c(input_c), .output_c(output_c),
        .relu_en(relu_en), .pool_en(pool_en),
        .task_done_i(task_done_fb), .task_error_i(task_error_fb),
        .task_error_code_i(task_error_code_fb),
        .check_done_i(check_done_fb), .checks_pass_i(checks_pass_fb),
        .perf_cycle_lo_i(perf_cycle_lo), .perf_cycle_hi_i(perf_cycle_hi),
        .perf_read_beats_i(perf_read_beats), .perf_write_beats_i(perf_write_beats),
        .perf_read_active_i(perf_read_active), .perf_write_active_i(perf_write_active),
        .perf_mac_lo_i(perf_mac_lo), .perf_mac_hi_i(perf_mac_hi),
        .perf_array_active_i(perf_array_active), .perf_array_stall_i(perf_array_stall),
        .perf_cluster_active_i(perf_cluster_active), .perf_cluster_stall_i(perf_cluster_stall),
        .perf_cluster_cfg_i(perf_cluster_cfg)
    );

    assign npu_busy = ctrl_busy;
    assign npu_done = ctrl_done;
    assign npu_error = ctrl_error;
    assign npu_error_code = ctrl_error_code;

    // ============================================================
    // task_checker
    // ============================================================
    task_checker u_checker (
        .clk(clk), .rst_n(rst_n), .task_start(task_start),
        .task_type(task_type), .input_addr(input_addr), .weight_addr(weight_addr),
        .output_addr(output_addr), .input_bytes(input_bytes), .weight_bytes(weight_bytes),
        .output_bytes(output_bytes), .input_h(input_h), .input_w(input_w),
        .input_c(input_c), .output_c(output_c), .relu_en(relu_en), .pool_en(pool_en),
        .checks_pass(checks_pass_fb), .error_code(task_error_code_fb), .check_done(check_done_fb)
    );

    // ============================================================
    // DMA instances (act, weight — shared AXI read mux)
    // ============================================================
    reg         act_dma_start;
    reg  [31:0] act_dma_addr;
    reg  [31:0] act_dma_bytes;
    wire        act_dma_done, act_dma_error, act_dma_busy;
    wire [7:0]  act_dma_error_code;
    wire [BUF_ADDR_W-1:0] act_buf_wr_addr;
    wire [BUF_DATA_W-1:0] act_buf_wr_data;
    wire                  act_buf_wr_en;

    wire [AXI_ADDR_W-1:0] act_araddr, wgt_araddr;
    wire                  act_arvalid, wgt_arvalid;
    wire                  act_arready, wgt_arready;
    wire [7:0]            act_arlen, wgt_arlen;
    wire [2:0]            act_arsize, wgt_arsize;
    wire [1:0]            act_arburst, wgt_arburst;
    wire                  act_rready, wgt_rready;
    wire read_sel_act;

    act_read_path #(.AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
                    .BUF_DATA_W(BUF_DATA_W), .BUF_ADDR_W(BUF_ADDR_W))
    u_act_dma (
        .clk(clk), .rst_n(rst_n), .start(act_dma_start),
        .base_addr(act_dma_addr), .byte_count(act_dma_bytes),
        .done(act_dma_done), .error(act_dma_error), .error_code(act_dma_error_code), .busy(act_dma_busy),
        .buf_wr_addr(act_buf_wr_addr), .buf_wr_data(act_buf_wr_data), .buf_wr_en(act_buf_wr_en),
        .m_axi_araddr(act_araddr), .m_axi_arvalid(act_arvalid), .m_axi_arready(act_arready),
        .m_axi_arlen(act_arlen), .m_axi_arsize(act_arsize), .m_axi_arburst(act_arburst),
        .m_axi_rdata(m_axi_rdata), .m_axi_rvalid(m_axi_rvalid && read_sel_act),
        .m_axi_rready(act_rready), .m_axi_rlast(m_axi_rlast), .m_axi_rresp(m_axi_rresp)
    );

    reg         wgt_dma_start;
    reg  [31:0] wgt_dma_addr;
    reg  [31:0] wgt_dma_bytes;
    wire        wgt_dma_done, wgt_dma_error, wgt_dma_busy;
    wire [7:0]  wgt_dma_error_code;
    wire [BUF_ADDR_W-1:0] wgt_buf_wr_addr;
    wire [BUF_DATA_W-1:0] wgt_buf_wr_data;
    wire                  wgt_buf_wr_en;

    weight_read_path #(.AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
                       .BUF_DATA_W(BUF_DATA_W), .BUF_ADDR_W(BUF_ADDR_W))
    u_wgt_dma (
        .clk(clk), .rst_n(rst_n), .start(wgt_dma_start),
        .base_addr(wgt_dma_addr), .byte_count(wgt_dma_bytes),
        .done(wgt_dma_done), .error(wgt_dma_error), .error_code(wgt_dma_error_code), .busy(wgt_dma_busy),
        .buf_wr_addr(wgt_buf_wr_addr), .buf_wr_data(wgt_buf_wr_data), .buf_wr_en(wgt_buf_wr_en),
        .m_axi_araddr(wgt_araddr), .m_axi_arvalid(wgt_arvalid), .m_axi_arready(wgt_arready),
        .m_axi_arlen(wgt_arlen), .m_axi_arsize(wgt_arsize), .m_axi_arburst(wgt_arburst),
        .m_axi_rdata(m_axi_rdata), .m_axi_rvalid(m_axi_rvalid && !read_sel_act),
        .m_axi_rready(wgt_rready), .m_axi_rlast(m_axi_rlast), .m_axi_rresp(m_axi_rresp)
    );

    assign read_sel_act = act_dma_busy;
    assign m_axi_araddr  = read_sel_act ? act_araddr  : wgt_araddr;
    assign m_axi_arvalid = read_sel_act ? act_arvalid : wgt_arvalid;
    assign act_arready   = read_sel_act ? m_axi_arready : 1'b0;
    assign wgt_arready   = !read_sel_act ? m_axi_arready : 1'b0;
    assign m_axi_arlen   = read_sel_act ? act_arlen   : wgt_arlen;
    assign m_axi_arsize  = read_sel_act ? act_arsize  : wgt_arsize;
    assign m_axi_arburst = read_sel_act ? act_arburst : wgt_arburst;
    assign m_axi_rready  = read_sel_act ? act_rready  : wgt_rready;

    // ============================================================
    // DMA writer
    // ============================================================
    reg         dma_wr_start, dma_wr_started;
    reg         block_bank;
    reg  [31:0] dma_wr_addr, dma_wr_bytes;
    wire        dma_wr_done, dma_wr_error, dma_wr_busy;
    wire [7:0]  dma_wr_error_code;
    wire [31:0] dma_wr_data;
    wire        dma_wr_valid, dma_wr_ready;

    dma_axi_writer u_dma_writer (
        .clk(clk), .rst_n(rst_n), .start(dma_wr_start),
        .base_addr(dma_wr_addr), .byte_count(dma_wr_bytes),
        .done(dma_wr_done), .error(dma_wr_error), .error_code(dma_wr_error_code), .busy(dma_wr_busy),
        .data_in(dma_wr_data), .data_valid(dma_wr_valid), .data_ready(dma_wr_ready),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_wdata(m_axi_wdata), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_wlast(m_axi_wlast), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );

    // ============================================================
    // Buffer instances
    // ============================================================
    wire [BUF_ADDR_W-1:0] act_rd_addr, wgt_rd_addr;
    wire [BUF_DATA_W-1:0] act_rd_data, wgt_rd_data;
    wire                  act_rd_bank, wgt_rd_bank;
    reg                   act_load_start, act_load_done, act_comp_start, act_comp_done;
    reg                   act_load_bank, act_comp_bank;

    npu_buffer #(.DATA_WIDTH(BUF_DATA_W), .ENTRIES(BUF_ENTRIES), .ADDR_WIDTH(BUF_ADDR_W))
    u_act_buffer (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(act_buf_wr_addr), .wr_data(act_buf_wr_data), .wr_en(act_buf_wr_en), .wr_bank_sel(act_load_bank),
        .rd_addr(act_rd_addr), .rd_data(act_rd_data), .rd_bank_sel(act_rd_bank),
        .load_start(act_load_start), .load_done(act_load_done),
        .comp_start(act_comp_start), .comp_done(act_comp_done),
        .load_bank_sel(act_load_bank), .comp_bank_sel(act_comp_bank),
        .flush(1'b0), .load_ready(), .comp_ready(), .comp_active(),
        .bank_a_state(), .bank_b_state()
    );

    reg  wgt_load_start, wgt_load_done, wgt_load_bank;
    reg wgt_buf_flush;
    npu_buffer #(.DATA_WIDTH(BUF_DATA_W), .ENTRIES(BUF_ENTRIES), .ADDR_WIDTH(BUF_ADDR_W))
    u_wgt_buffer (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(wgt_buf_wr_addr), .wr_data(wgt_buf_wr_data), .wr_en(wgt_buf_wr_en), .wr_bank_sel(wgt_load_bank),
        .rd_addr(wgt_rd_addr), .rd_data(wgt_rd_data), .rd_bank_sel(wgt_rd_bank),
        .load_start(wgt_load_start), .load_done(wgt_load_done),
        .comp_start(1'b0), .comp_done(1'b0),
        .load_bank_sel(wgt_load_bank), .comp_bank_sel(1'b0),
        .flush(wgt_buf_flush), .load_ready(), .comp_ready(), .comp_active(),
        .bank_a_state(), .bank_b_state()
    );

    wire [BUF_ADDR_W-1:0] acc_wr_addr, acc_rd_addr;
    wire [BUF_DATA_W-1:0] acc_wr_data, acc_rd_data;
    wire                  acc_wr_en, acc_rd_bank, acc_wr_bank;
    reg  acc_load_start, acc_load_done, acc_comp_start, acc_comp_done;
    reg  acc_load_bank, acc_comp_bank;

    npu_buffer #(.DATA_WIDTH(BUF_DATA_W), .ENTRIES(BUF_ENTRIES), .ADDR_WIDTH(BUF_ADDR_W))
    u_acc_buffer (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(acc_wr_addr), .wr_data(acc_wr_data), .wr_en(acc_wr_en), .wr_bank_sel(acc_wr_bank),
        .rd_addr(acc_rd_addr), .rd_data(acc_rd_data), .rd_bank_sel(acc_rd_bank),
        .load_start(acc_load_start), .load_done(acc_load_done),
        .comp_start(acc_comp_start), .comp_done(acc_comp_done),
        .load_bank_sel(acc_load_bank), .comp_bank_sel(acc_comp_bank),
        .flush(1'b0), .load_ready(), .comp_ready(), .comp_active(),
        .bank_a_state(), .bank_b_state()
    );

    // ============================================================
    // conv_frontend
    // ============================================================
    wire [7:0]  cf_act_data;
    wire        cf_act_valid;
    wire        conv_act_ready;
    wire [7:0]  cf_window [0:24];
    wire        cf_window_valid_i;
    wire        cf_start, cf_done;
    wire [15:0] cf_cur_row, cf_cur_col;
    reg  [15:0] cf_last_row, cf_last_col;
    reg  [5:0]  cf_channel_sel;
    wire        cf_new_window = (cf_window_valid_i && (cf_cur_row != cf_last_row || cf_cur_col != cf_last_col));
    wire        cf_window_hold;

    conv_frontend #(.MAX_W(32), .MAX_C_IN(64), .AW(11)) u_conv_fe (
        .clk(clk), .rst_n(rst_n),
        .act_data(cf_act_data), .act_valid(cf_act_valid), .act_ready(conv_act_ready),
        .window_00(cf_window[0]), .window_01(cf_window[1]), .window_02(cf_window[2]),
        .window_03(cf_window[3]), .window_04(cf_window[4]),
        .window_10(cf_window[5]), .window_11(cf_window[6]), .window_12(cf_window[7]),
        .window_13(cf_window[8]), .window_14(cf_window[9]),
        .window_20(cf_window[10]), .window_21(cf_window[11]), .window_22(cf_window[12]),
        .window_23(cf_window[13]), .window_24(cf_window[14]),
        .window_30(cf_window[15]), .window_31(cf_window[16]), .window_32(cf_window[17]),
        .window_33(cf_window[18]), .window_34(cf_window[19]),
        .window_40(cf_window[20]), .window_41(cf_window[21]), .window_42(cf_window[22]),
        .window_43(cf_window[23]), .window_44(cf_window[24]),
        .window_valid(cf_window_valid_i),
        .channel_sel(cf_channel_sel),
        .input_w(input_w), .input_h(input_h), .input_c(input_c),
        .block_out_rows(blk_out_rows), .block_in_rows(blk_in_rows),
        .start(cf_start), .window_hold(cf_window_hold),
        .done(cf_done), .cur_row(cf_cur_row), .cur_col(cf_cur_col)
    );

    // ============================================================
    // fc_frontend
    // ============================================================
    wire [7:0]  fc_act_out;
    wire        fc_act_valid_o, fc_act_ready;

    fc_frontend u_fc_fe (
        .clk(clk), .rst_n(rst_n),
        .act_data(cf_act_data), .act_valid(cf_act_valid), .act_ready(fc_act_ready),
        .act_out(fc_act_out), .act_valid_o(fc_act_valid_o),
        .input_size(input_bytes[15:0]), .output_size(output_c),
        .block_start(16'd0), .start(1'b0), .done(), .block_done()
    );

    // ============================================================
    // Compute core compatibility wrapper
    // ============================================================
    wire [(PE_ROWS*8)-1:0]    array_act_in;
    wire [(PE_COLS*32)-1:0]   array_sum_in;
    wire [(N_TILES*16*8)-1:0] array_weight;
    wire                      array_weight_ld;
    wire [(PE_COLS*32)-1:0]   array_sum_out;
    wire [(N_TILES)-1:0]      array_clk_en;
    wire [(PE_ROWS*8)-1:0]    compat_cluster_act_in_flat;
    wire [(PE_COLS*32)-1:0]   compat_cluster_sum_in_flat;
    wire [(N_TILES*16*8)-1:0] compat_cluster_weight_flat;
    wire                      compat_cluster_weight_ld;
    wire [(N_TILES)-1:0]      compat_cluster_tile_clk_en_flat;
    wire [(PE_COLS*32)-1:0]   compat_cluster_sum_out_flat;
    wire                      compat_cluster_busy;
    wire                      compat_cluster_valid;
    wire                      compat_cluster_done;
    wire                      compat_any_cluster_busy;
    wire                      compat_all_enabled_done;
    wire [5:0]                perf_cluster_enable;
    wire [2:0]                perf_cluster_count;
    wire                      perf_schedule_valid;

    assign array_sum_in = {PE_COLS{32'h0}};
    assign array_clk_en = {N_TILES{1'b1}};
    assign compat_cluster_act_in_flat = array_act_in;
    assign compat_cluster_sum_in_flat = array_sum_in;
    assign compat_cluster_weight_flat = array_weight;
    assign compat_cluster_weight_ld = array_weight_ld;
    assign compat_cluster_tile_clk_en_flat = array_clk_en;
    assign array_sum_out = compat_cluster_sum_out_flat;

    cluster_scheduler u_cluster_scheduler (
        .cluster_mode(2'd0),
        .cluster_mask_req(6'b11_1111),
        .cluster_enable(perf_cluster_enable),
        .cluster_count(perf_cluster_count),
        .schedule_valid(perf_schedule_valid)
    );

    compute_core_6cluster #(
        .CLUSTER_COUNT(1),
        .TILE_ROWS(TILE_ROWS),
        .TILE_COLS(TILE_COLS)
    ) u_compute_core (
        .clk(clk), .rst_n(rst_n),
        .start(array_weight_ld),
        .cluster_enable(perf_cluster_enable[0]),
        .cluster_act_in_flat(compat_cluster_act_in_flat),
        .cluster_sum_in_flat(compat_cluster_sum_in_flat),
        .cluster_weight_flat(compat_cluster_weight_flat),
        .cluster_weight_ld(compat_cluster_weight_ld),
        .cluster_tile_clk_en_flat(compat_cluster_tile_clk_en_flat),
        .cluster_sum_out_flat(compat_cluster_sum_out_flat),
        .cluster_busy(compat_cluster_busy),
        .cluster_valid(compat_cluster_valid),
        .cluster_done(compat_cluster_done),
        .any_cluster_busy(compat_any_cluster_busy),
        .all_enabled_done(compat_all_enabled_done)
    );

    // ============================================================
    // postproc
    // ============================================================
    wire [31:0] pp_data_in, pp_data_out;
    wire        pp_data_valid, pp_data_ready, pp_data_valid_o;
    wire        pp_start, pp_done;

    wire is_fc_mode   = (task_type == 2'd1);
    wire is_pool_mode = (task_type == 2'd2);
    wire is_conv_mode = (task_type == 2'd0);
    wire perf_conv_array_active;
    wire perf_conv_array_stall;
    wire perf_fc_array_active;
    wire perf_array_active_evt;
    wire perf_array_stall_evt;
    wire [63:0] perf_conv_window_count;
    wire [63:0] perf_conv_channel_work;
    wire [63:0] perf_conv_mac_count;
    wire [63:0] perf_fc_mac_count;

    wire [15:0] pp_input_h = is_pool_mode ? blk_in_rows : input_h;
    wire [15:0] pp_input_c = is_pool_mode ? input_c : 16'd1;
    postproc #(.DATA_W(32), .MAX_OUT_W(240)) u_postproc (
        .clk(clk), .rst_n(rst_n),
        .data_in(pp_data_in), .data_valid(pp_data_valid), .data_ready(pp_data_ready),
        .data_out(pp_data_out), .data_valid_o(pp_data_valid_o),
        .relu_en(relu_en), .pool_en(pool_en),
        .input_w(input_w), .input_h(pp_input_h), .input_c(pp_input_c),
        .start(pp_start), .done(pp_done)
    );

    // ============================================================
    // Main FSM — multi-channel Conv support
    // ============================================================
    localparam FSM_IDLE        = 5'd0;
    localparam FSM_LOAD_ACT    = 5'd1;   // DMA activations for block
    localparam FSM_CF_START    = 5'd2;   // start conv_frontend
    localparam FSM_PRE_COMP    = 5'd3;   // init compute
    localparam FSM_CIN_START   = 5'd4;   // begin new input channel iteration
    localparam FSM_CIN_LOAD_WGT= 5'd5;   // DMA weights for current c_in
    localparam FSM_CIN_LOAD_DONE=5'd6;   // weight DMA done
    localparam FSM_LOAD_ARRAY  = 5'd7;   // load weights from wgt_buffer into array
    localparam FSM_WGT_LD      = 5'd8;   // pulse weight_ld
    localparam FSM_COMPUTE     = 5'd9;   // compute all windows for current c_in
    localparam FSM_CIN_NEXT    = 5'd10;  // check if more input channels
    localparam FSM_STORE       = 5'd11;  // DMA acc_buffer to memory
    localparam FSM_BLK_CHECK   = 5'd12;  // check if more blocks
    localparam FSM_BLK_DONE    = 5'd13;  // wait for block_scheduler to register blk_done
    localparam FSM_CIN_RESTART = 5'd16;  // restart conv_frontend for next c_in
    localparam FSM_FC_TILE_PREP= 5'd17;
    localparam FSM_FC_LOAD_WGT = 5'd18;
    localparam FSM_FC_LOAD_WAIT= 5'd19;
    localparam FSM_FC_COMPUTE  = 5'd20;
    localparam FSM_DONE        = 5'd15;
    localparam FSM_ERROR       = 5'd14;

    // COMPUTE sub-states
    localparam CP_WAIT_WIN = 3'd0;
    localparam CP_FEED_ACT = 3'd1;
    localparam CP_DRAIN    = 3'd2;
    localparam CP_COLLECT  = 3'd3;  // latch C_out results + accumulate
    localparam CP_NEXT     = 3'd4;

    reg [4:0]  fsm_state;
    reg [2:0]  comp_sub_state;
    reg [15:0] comp_total_wins;
    reg [15:0] comp_win_idx;
    reg [4:0]  comp_feed_cnt;
    reg [15:0] comp_drain_cnt;

    // Per-input-channel tracking
    reg [15:0] cin_idx;             // current input channel (0..input_c-1)
    reg [15:0] cin_total;           // total input channels for this task
    reg [31:0] wgt_per_cin;         // weight bytes per input channel (25 * output_c)
    reg [31:0] wgt_words_per_cin;   // 32-bit words per input channel weight load

    // Per-row activation hold: latched during FEED_ACT, driven continuously
    // This allows activation to propagate through all columns (not just col 0)
    reg [7:0] act_held [0:PE_ROWS-1];

    // Accumulation: per-window column accumulator (collect one column per cycle)
    reg [15:0] acc_col_idx;         // which output column to accumulate
    reg [31:0] col_results [0:63];  // latched array column results (max 64 columns)
    reg [15:0] fc_out_start;
    reg [15:0] fc_tile_outputs;
    reg [15:0] fc_neuron_idx;
    reg [15:0] fc_in_idx;
    reg signed [31:0] fc_accum;
    reg                 fc_acc_wr_en_r;
    reg [BUF_ADDR_W-1:0] fc_acc_wr_addr_r;
    reg [31:0]          fc_acc_wr_data_r;
    reg [31:0]          fc_store_addr;
    reg [31:0]          fc_store_bytes;

    // ============================================================
    // perf counter
    // ============================================================
    wire perf_freeze, perf_task_active;
    assign perf_conv_array_active =
        is_conv_mode &&
        (fsm_state == FSM_COMPUTE) &&
        ((comp_sub_state == CP_FEED_ACT) ||
         (comp_sub_state == CP_DRAIN) ||
         (comp_sub_state == CP_COLLECT));
    assign perf_conv_array_stall =
        is_conv_mode &&
        (fsm_state == FSM_COMPUTE) &&
        (comp_sub_state == CP_WAIT_WIN) &&
        !cf_new_window &&
        !cf_done;
    assign perf_fc_array_active = is_fc_mode && (fsm_state == FSM_FC_COMPUTE);
    assign perf_array_active_evt = perf_conv_array_active || perf_fc_array_active;
    assign perf_array_stall_evt = perf_conv_array_stall;
    assign perf_conv_window_count =
        ((input_h >= 16'd5) && (input_w >= 16'd5)) ? ((input_h - 16'd4) * (input_w - 16'd4)) : 64'd0;
    assign perf_conv_channel_work = input_c * output_c;
    assign perf_conv_mac_count = perf_conv_window_count * perf_conv_channel_work * 64'd25;
    assign perf_fc_mac_count = (input_bytes >> 2) * output_c;
    assign perf_mac_lo = is_conv_mode ? perf_conv_mac_count[31:0] :
                         is_fc_mode   ? perf_fc_mac_count[31:0] :
                                        32'd0;
    assign perf_mac_hi = is_conv_mode ? perf_conv_mac_count[63:32] :
                         is_fc_mode   ? perf_fc_mac_count[63:32] :
                                        32'd0;
    assign perf_cluster_cfg = {24'd0, 2'd0, perf_cluster_enable};

    perf_counter u_perf (
        .clk(clk), .rst_n(rst_n), .task_active(perf_task_active), .freeze(perf_freeze),
        .read_beat(m_axi_rvalid && m_axi_rready), .write_beat(dma_wr_valid && dma_wr_ready),
        .read_active(act_dma_busy || wgt_dma_busy), .write_active(dma_wr_busy),
        .array_active(perf_array_active_evt), .array_stall(perf_array_stall_evt),
        .cluster_active_inc(perf_array_active_evt ? perf_cluster_count : 3'd0),
        .cluster_stall_inc(perf_array_stall_evt ? perf_cluster_count : 3'd0),
        .total_cycle_lo(perf_cycle_lo), .total_cycle_hi(perf_cycle_hi),
        .read_beat_count(perf_read_beats), .write_beat_count(perf_write_beats),
        .read_active_cycles(perf_read_active), .write_active_cycles(perf_write_active),
        .array_active_cycles(perf_array_active), .array_stall_cycles(perf_array_stall),
        .cluster_active_cycles(perf_cluster_active), .cluster_stall_cycles(perf_cluster_stall)
    );

    function signed [7:0] sat_i32_to_i8;
        input signed [31:0] val;
        begin
            if (val > 32'sd127)
                sat_i32_to_i8 = 8'sd127;
            else if (val < -32'sd128)
                sat_i32_to_i8 = -8'sd128;
            else
                sat_i32_to_i8 = val[7:0];
        end
    endfunction

    wire [15:0] fc_tile_capacity_raw = ((BUF_ENTRIES * 4) / input_c);
    wire [15:0] fc_tile_capacity = (fc_tile_capacity_raw == 16'd0) ? 16'd1 : fc_tile_capacity_raw;
    wire [15:0] fc_out_remaining = output_c - fc_out_start;
    wire [15:0] fc_tile_outputs_next = (fc_out_remaining > fc_tile_capacity) ? fc_tile_capacity : fc_out_remaining;
    wire [31:0] fc_weight_index = fc_neuron_idx * input_c + fc_in_idx;
    wire [BUF_ADDR_W-1:0] fc_weight_word_addr = fc_weight_index[BUF_ADDR_W+1:2];
    wire [1:0] fc_weight_byte_sel = fc_weight_index[1:0];
    wire signed [7:0] fc_act_q = sat_i32_to_i8($signed(act_rd_data));
    wire signed [7:0] fc_wgt_q =
        (fc_weight_byte_sel == 2'd0) ? $signed(wgt_rd_data[7:0])   :
        (fc_weight_byte_sel == 2'd1) ? $signed(wgt_rd_data[15:8])  :
        (fc_weight_byte_sel == 2'd2) ? $signed(wgt_rd_data[23:16]) :
                                       $signed(wgt_rd_data[31:24]);
    wire signed [31:0] fc_acc_next = fc_accum + (fc_act_q * fc_wgt_q);
    wire signed [31:0] fc_final_out = (relu_en && fc_acc_next[31]) ? 32'd0 : fc_acc_next;

    assign array_weight_ld = (fsm_state == FSM_WGT_LD);
    assign cf_start = (fsm_state == FSM_CF_START) || (fsm_state == FSM_CIN_RESTART);
    assign cf_window_hold = !(fsm_state == FSM_COMPUTE && comp_sub_state == CP_WAIT_WIN && !cf_new_window);

    // Activation feeder
    reg [BUF_ADDR_W-1:0] act_feed_ptr;
    reg [1:0]            act_feed_byte;
    reg [15:0]           act_feed_done_cnt;
    wire [BUF_ADDR_W-1:0] act_feed_waddr = act_feed_ptr[BUF_ADDR_W-1:2];

    assign cf_act_data  = (act_feed_ptr[1:0] == 2'd0) ? act_rd_data[7:0]   :
                          (act_feed_ptr[1:0] == 2'd1) ? act_rd_data[15:8]  :
                          (act_feed_ptr[1:0] == 2'd2) ? act_rd_data[23:16] :
                                                        act_rd_data[31:24];
    assign act_rd_bank  = act_comp_bank;

    assign act_rd_addr  = is_pool_mode ? act_feed_ptr[BUF_ADDR_W-1:0] :
                          is_fc_mode   ? fc_in_idx[BUF_ADDR_W-1:0] :
                                         act_feed_waddr;

    // Feed activations during WAIT_WIN (conv_frontend consumes them)
    assign cf_act_valid = is_conv_mode && (fsm_state == FSM_COMPUTE) && (comp_sub_state == CP_WAIT_WIN) && !cf_done && (act_feed_done_cnt < blk_in_bytes[15:0]);

    // Weight buffer read
    wire [BUF_ADDR_W-1:0] wgt_mac_addr;
    assign wgt_rd_addr  = (is_fc_mode && (fsm_state == FSM_FC_COMPUTE)) ? fc_weight_word_addr : wgt_mac_addr;
    assign wgt_rd_bank  = wgt_load_bank;

    // ============================================================
    // Weight → array mapping (registered, multi-cycle loading)
    // Up to 25*C_out weights loaded per input channel
    // ============================================================
    // wgt_load_reg: sized for full PE array (PE_ROWS x PE_COLS)
    localparam WGT_REG_BITS = PE_ROWS * PE_COLS * 8;

    reg [WGT_REG_BITS-1:0] wgt_load_reg;
    reg [8:0]  wgt_load_phase;
    reg        wgt_load_done_r;

    // Connect registered weights to array_weight (strided by PE_COLS per spatial position)
    genvar wb;
    generate
        for (wb = 0; wb < N_TILES*16; wb = wb + 1) begin : wgt_byte
            localparam integer WB_TILE_IDX   = wb / 16;
            localparam integer WB_LOCAL_ROW  = (wb % 16) / 4;
            localparam integer WB_LOCAL_COL  = (wb % 16) % 4;
            localparam integer WB_GLOBAL_ROW = (WB_TILE_IDX / TILE_COLS) * 4 + WB_LOCAL_ROW;
            localparam integer WB_GLOBAL_COL = (WB_TILE_IDX % TILE_COLS) * 4 + WB_LOCAL_COL;
            localparam integer WB_FLAT_BASE  = WB_TILE_IDX * 128 + WB_LOCAL_ROW * 32 + WB_LOCAL_COL * 8;
            if (WB_GLOBAL_ROW < KERNEL_SPATIAL)
                assign array_weight[WB_FLAT_BASE +: 8] = wgt_load_reg[(WB_GLOBAL_ROW * PE_COLS + WB_GLOBAL_COL)*8 +: 8];
            else
                assign array_weight[WB_FLAT_BASE +: 8] = 8'd0;
        end
    endgenerate

    // ============================================================
    // array_act_in: skewed activation feeding with per-row hold
    // During the feeding cycle for row r: drive cf_window[r] directly (combinational)
    // After feeding: drive held value (registered) for column propagation
    // ============================================================
    wire act_feed_en = (fsm_state == FSM_COMPUTE) && (comp_sub_state == CP_FEED_ACT);
    genvar ai;
    generate
        for (ai = 0; ai < PE_ROWS; ai = ai + 1) begin : act_map
            if (ai < KERNEL_SPATIAL) begin
                wire [7:0] win_val = is_conv_mode ? cf_window[ai] : (is_fc_mode ? cf_act_data : 8'd0);
                wire conv_act_drive = (comp_sub_state == CP_FEED_ACT) || (comp_sub_state == CP_DRAIN);
                assign array_act_in[ai*8 +: 8] = is_conv_mode ?
                    (conv_act_drive ? (act_feed_en && comp_feed_cnt == ai ? cf_window[ai] : act_held[ai]) : 8'd0) :
                    ((act_feed_en && comp_feed_cnt == ai) ? win_val : 8'd0);
            end else begin
                assign array_act_in[ai*8 +: 8] = 8'd0;
            end
        end
    endgenerate

    // Latch per-row activations during FEED_ACT (skewed feeding)
    // Clear on restart to prevent stale values from previous c_in iteration
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            integer ri;
            for (ri = 0; ri < PE_ROWS; ri = ri + 1)
                act_held[ri] <= 8'd0;
        end else if (fsm_state == FSM_CIN_RESTART) begin
            integer ri;
            for (ri = 0; ri < PE_ROWS; ri = ri + 1)
                act_held[ri] <= 8'd0;
        end else if (act_feed_en) begin
            if (comp_feed_cnt < KERNEL_SPATIAL[4:0])
                act_held[comp_feed_cnt] <= cf_window[comp_feed_cnt];
        end
    end

    // ============================================================
    // postproc connection
    // ============================================================
    reg [31:0] pp_result;
    assign pp_data_in   = is_pool_mode ? act_rd_data : pp_result;
    // Conv: write directly to acc_buffer via acc_partial (bypass postproc)
    // Pool: feed postproc; FC: feed postproc (for ReLU after FC1)
    assign pp_data_valid = is_conv_mode ? 1'b0 :
                           is_pool_mode ? ((fsm_state == FSM_COMPUTE) && (comp_sub_state == CP_WAIT_WIN) &&
                                           !pp_start && (act_feed_done_cnt < blk_in_bytes[15:0])) :
                           ((fsm_state == FSM_COMPUTE) && (comp_sub_state == CP_COLLECT));
    assign pp_data_ready = 1'b1;
    // pp_start: pulse at start of compute (PRE_COMP for Conv/FC, COMPUTE entry for Pool)
    reg pp_start_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pp_start_r <= 1'b0;
        else if (fsm_state == FSM_PRE_COMP) pp_start_r <= 1'b1;
        else if (is_pool_mode && fsm_state == FSM_LOAD_ACT && act_dma_done) pp_start_r <= 1'b1;
        else pp_start_r <= 1'b0;
    end
    assign pp_start = pp_start_r;

    // ============================================================
    // acc_buffer write: postproc output → acc_buffer (for final results)
    // During Conv compute: acc_wr serves as partial sum store
    // ============================================================
    reg [BUF_ADDR_W-1:0] acc_wr_ptr;
    reg [BUF_ADDR_W-1:0] acc_partial_addr;  // partial sum address during COLLECT
    assign acc_wr_addr = ((fsm_state == FSM_COMPUTE) && (comp_sub_state == CP_COLLECT))
                         ? acc_partial_addr
                         : (is_fc_mode ? fc_acc_wr_addr_r : acc_wr_ptr);
    wire [31:0] conv_acc_sum =
        (cin_idx == 16'd0) ? col_results[acc_col_idx] : (acc_rd_data + col_results[acc_col_idx]);
    wire conv_relu_final = relu_en && (cin_idx + 16'd1 >= cin_total) && conv_acc_sum[31];
    wire [31:0] conv_acc_wr_data = conv_relu_final ? 32'd0 : conv_acc_sum;
    assign acc_wr_data = is_conv_mode ? conv_acc_wr_data :
                         is_fc_mode   ? fc_acc_wr_data_r :
                                        pp_data_out;
    assign acc_wr_en   = is_conv_mode
        ? ((fsm_state == FSM_COMPUTE) && (comp_sub_state == CP_COLLECT))
        : is_fc_mode ? fc_acc_wr_en_r
        : pp_data_valid_o;
    assign acc_wr_bank = acc_load_bank;

    // ============================================================
    // block_scheduler
    // ============================================================
    wire blk_valid, blk_all_done;
    reg  blk_done;

    block_scheduler #(.BUF_ENTRIES(BUF_ENTRIES), .BUF_ADDR_W(BUF_ADDR_W))
    u_block_sched (
        .clk(clk), .rst_n(rst_n), .task_start(task_start), .task_type(task_type),
        .input_addr(input_addr), .weight_addr(weight_addr), .output_addr(output_addr),
        .input_bytes(input_bytes), .weight_bytes(weight_bytes), .output_bytes(output_bytes),
        .input_h(input_h), .input_w(input_w), .input_c(input_c), .output_c(output_c),
        .block_done(blk_done), .block_valid(blk_valid), .all_blocks_done(blk_all_done),
        .blk_input_addr(blk_in_addr), .blk_weight_addr(blk_wgt_addr), .blk_output_addr(blk_out_addr),
        .blk_input_bytes(blk_in_bytes), .blk_weight_bytes(blk_wgt_bytes), .blk_output_bytes(blk_out_bytes),
        .blk_input_rows(blk_in_rows), .blk_output_rows(blk_out_rows),
        .blk_wgt_per_cin(blk_wgt_per_cin), .blk_cin_total(blk_cin_total)
    );

    // acc_wr_ptr management
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc_wr_ptr <= 0;
        else if (fsm_state == FSM_IDLE)
            acc_wr_ptr <= 0;
        else if (fsm_state == FSM_BLK_CHECK && !blk_all_done)
            acc_wr_ptr <= 0;
        else if ((fsm_state == FSM_LOAD_ACT) && act_dma_done && is_pool_mode)
            acc_wr_ptr <= 0;
        else if ((fsm_state == FSM_CIN_START) && is_conv_mode)
            acc_wr_ptr <= 0;
        else if (acc_wr_en)
            acc_wr_ptr <= acc_wr_ptr + 1;
    end

    // DMA writer: stream from acc_buffer during STORE
    // During CP_COLLECT: read the current column's old partial sum.
    reg [BUF_ADDR_W-1:0] dma_rd_ptr;
    assign acc_rd_addr = ((fsm_state == FSM_COMPUTE) && (comp_sub_state == CP_COLLECT))
                         ? acc_partial_addr
                         : dma_rd_ptr;
    assign acc_rd_bank = acc_load_bank;
    assign dma_wr_data = acc_rd_data;
    wire [31:0] store_bytes_active = is_fc_mode ? fc_store_bytes : blk_out_bytes;
    assign dma_wr_valid = (fsm_state == FSM_STORE) && ({dma_rd_ptr, 2'b00} < store_bytes_active);

    // perf control
    reg task_active_r;
    assign perf_task_active = task_active_r;
    assign perf_freeze = (fsm_state == FSM_DONE) || (fsm_state == FSM_ERROR);

    // ============================================================
    // Main FSM — sequential
    // ============================================================
    reg        task_done_r, task_error_r;
    reg [7:0]  task_error_code_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_state <= FSM_IDLE;  comp_sub_state <= CP_WAIT_WIN;
            comp_total_wins <= 16'd0; comp_win_idx <= 16'd0;
            comp_feed_cnt <= 5'd0; comp_drain_cnt <= 16'd0;
            act_feed_ptr <= 0; act_feed_done_cnt <= 16'd0;
            pp_result <= 32'd0; task_active_r <= 1'b0;
            task_done_r <= 1'b0; task_error_r <= 1'b0; task_error_code_r <= 8'h0;
            act_dma_start <= 1'b0; act_dma_addr <= 32'h0; act_dma_bytes <= 32'h0;
            wgt_dma_start <= 1'b0; wgt_dma_addr <= 32'h0; wgt_dma_bytes <= 32'h0;
            dma_wr_start <= 1'b0; dma_wr_started <= 1'b0;
            block_bank <= 1'b0; dma_wr_addr <= 32'h0; dma_wr_bytes <= 32'h0;
            dma_rd_ptr <= 0;
            wgt_load_phase <= 9'd0; wgt_load_done_r <= 1'b0;
            wgt_load_reg <= 0;
            wgt_buf_flush <= 1'b0;
            act_load_start <= 1'b0; act_load_done <= 1'b0;
            act_comp_start <= 1'b0; act_comp_done <= 1'b0;
            act_load_bank <= 1'b0; act_comp_bank <= 1'b0;
            wgt_load_start <= 1'b0; wgt_load_done <= 1'b0; wgt_load_bank <= 1'b0;
            acc_load_start <= 1'b0; acc_load_done <= 1'b0;
            acc_comp_start <= 1'b0; acc_comp_done <= 1'b0;
            acc_load_bank <= 1'b0; acc_comp_bank <= 1'b0;
            blk_done <= 1'b0;
            cf_last_row <= 16'hFFFF; cf_last_col <= 16'hFFFF;
            cf_channel_sel <= 6'd0;
            cin_idx <= 16'd0; cin_total <= 16'd0;
            wgt_per_cin <= 32'd0; wgt_words_per_cin <= 32'd0;
            acc_col_idx <= 16'd0;
            fc_out_start <= 16'd0; fc_tile_outputs <= 16'd0;
            fc_neuron_idx <= 16'd0; fc_in_idx <= 16'd0; fc_accum <= 32'sd0;
            fc_acc_wr_en_r <= 1'b0; fc_acc_wr_addr_r <= {BUF_ADDR_W{1'b0}}; fc_acc_wr_data_r <= 32'd0;
            fc_store_addr <= 32'd0; fc_store_bytes <= 32'd0;
        end else begin
            // Default: pulse signals low
            act_dma_start <= 1'b0; wgt_dma_start <= 1'b0; dma_wr_start <= 1'b0;
            act_load_start <= 1'b0; act_load_done <= 1'b0;
            act_comp_start <= 1'b0; act_comp_done <= 1'b0;
            wgt_load_start <= 1'b0; wgt_load_done <= 1'b0;
            acc_load_start <= 1'b0; acc_load_done <= 1'b0;
            acc_comp_start <= 1'b0; acc_comp_done <= 1'b0;
            blk_done <= 1'b0;
            wgt_buf_flush <= 1'b0;
            fc_acc_wr_en_r <= 1'b0;

            if (fsm_state == FSM_COMPUTE && comp_sub_state == CP_FEED_ACT) begin
                cf_last_row <= cf_cur_row;
                cf_last_col <= cf_cur_col;
            end

            case (fsm_state)

                FSM_IDLE: begin
                    if (task_go && !task_active_r) begin
                        task_active_r <= 1'b1;
                        task_done_r <= 1'b0; task_error_r <= 1'b0; task_error_code_r <= 8'h0;
                        dma_rd_ptr <= 0; dma_wr_started <= 1'b0;
                        wgt_load_phase <= 9'd0; wgt_load_done_r <= 1'b0;
                        wgt_load_reg <= 0; blk_done <= 1'b0;
                        // Capture per-task parameters
                        cin_total <= input_c;
                        wgt_per_cin <= blk_wgt_per_cin;
                        wgt_words_per_cin <= blk_wgt_per_cin[31:2];

                        if (is_pool_mode) begin
                            act_dma_start <= 1'b1; act_dma_addr <= blk_in_addr;
                            act_dma_bytes <= blk_in_bytes;
                            act_load_start <= 1'b1; act_load_bank <= block_bank;
                            fsm_state <= FSM_LOAD_ACT;
                        end else begin
                            // Conv/FC: load activations first (all input channels for block)
                            act_dma_start <= 1'b1; act_dma_addr <= blk_in_addr;
                            act_dma_bytes <= blk_in_bytes;
                            act_load_start <= 1'b1; act_load_bank <= block_bank;
                            fsm_state <= FSM_LOAD_ACT;
                        end
                    end
                end

                // ============================================================
                // FSM_LOAD_ACT: DMA activations into act_buffer
                // ============================================================
                FSM_LOAD_ACT: begin
                    if (act_dma_done) begin
                        act_load_done <= 1'b1;
                        act_comp_start <= 1'b1;
                        act_comp_bank <= act_load_bank;
                        acc_load_bank <= act_load_bank;
                        act_feed_ptr <= 0;
                        act_feed_done_cnt <= 16'd0;
                        if (is_pool_mode) begin
                            fsm_state <= FSM_COMPUTE;
                            comp_sub_state <= CP_WAIT_WIN;
                            comp_total_wins <= 16'd1;
                            comp_win_idx <= 16'd0;
                        end else if (is_fc_mode) begin
                            fc_out_start <= 16'd0;
                            fc_accum <= 32'sd0;
                            fc_neuron_idx <= 16'd0;
                            fc_in_idx <= 16'd0;
                            fsm_state <= FSM_FC_TILE_PREP;
                        end else begin
                            // Conv: start conv_frontend
                            comp_total_wins <= blk_out_rows * (input_w - 16'd5 + 16'd1);
                            comp_win_idx <= 16'd0;
                            fsm_state <= FSM_CF_START;
                        end
                    end else if (act_dma_error) begin
                        task_error_r <= 1'b1; task_error_code_r <= act_dma_error_code;
                        fsm_state <= FSM_ERROR;
                    end
                end

                FSM_CF_START: begin
                    fsm_state <= FSM_PRE_COMP;
                end

                FSM_PRE_COMP: begin
                    comp_sub_state <= CP_WAIT_WIN;
                    cin_idx <= 16'd0;
                    cf_channel_sel <= 6'd0;
                    // Start first input channel weight load
                    fsm_state <= FSM_CIN_START;
                end

                FSM_FC_TILE_PREP: begin
                    fc_tile_outputs <= fc_tile_outputs_next;
                    fc_neuron_idx <= 16'd0;
                    fc_in_idx <= 16'd0;
                    fc_accum <= 32'sd0;
                    dma_rd_ptr <= 0;
                    wgt_buf_flush <= 1'b1;
                    fsm_state <= FSM_FC_LOAD_WGT;
                end

                FSM_FC_LOAD_WGT: begin
                    wgt_dma_start <= 1'b1;
                    wgt_dma_addr <= blk_wgt_addr + fc_out_start * input_c;
                    wgt_dma_bytes <= fc_tile_outputs * input_c;
                    wgt_load_start <= 1'b1;
                    wgt_load_bank <= block_bank;
                    fsm_state <= FSM_FC_LOAD_WAIT;
                end

                FSM_FC_LOAD_WAIT: begin
                    if (wgt_dma_done) begin
                        wgt_load_done <= 1'b1;
                        fc_neuron_idx <= 16'd0;
                        fc_in_idx <= 16'd0;
                        fc_accum <= 32'sd0;
                        fsm_state <= FSM_FC_COMPUTE;
                    end else if (wgt_dma_error) begin
                        task_error_r <= 1'b1; task_error_code_r <= wgt_dma_error_code;
                        fsm_state <= FSM_ERROR;
                    end
                end

                FSM_FC_COMPUTE: begin
                    if (fc_in_idx + 16'd1 < input_c) begin
                        fc_accum <= fc_acc_next;
                        fc_in_idx <= fc_in_idx + 16'd1;
                    end else begin
                        fc_acc_wr_en_r <= 1'b1;
                        fc_acc_wr_addr_r <= fc_neuron_idx[BUF_ADDR_W-1:0];
                        fc_acc_wr_data_r <= fc_final_out;
                        if (fc_neuron_idx + 16'd1 < fc_tile_outputs) begin
                            fc_neuron_idx <= fc_neuron_idx + 16'd1;
                            fc_in_idx <= 16'd0;
                            fc_accum <= 32'sd0;
                        end else begin
                            fc_store_addr <= blk_out_addr + fc_out_start * 32'd4;
                            fc_store_bytes <= fc_tile_outputs * 32'd4;
                            acc_load_start <= 1'b1;
                            fsm_state <= FSM_STORE;
                        end
                    end
                end

                // ============================================================
                // FSM_CIN_START: begin new input channel iteration
                // ============================================================
                FSM_CIN_START: begin
                    if (is_conv_mode) begin
                        cf_last_row <= 16'hFFFF;
                        cf_last_col <= 16'hFFFF;
                        cf_channel_sel <= cin_idx[5:0];
                        comp_win_idx <= 16'd0;
                        wgt_dma_start <= 1'b1;
                        wgt_dma_addr <= blk_wgt_addr + cin_idx * wgt_per_cin;
                        wgt_dma_bytes <= wgt_per_cin;
                        wgt_load_start <= 1'b1;
                        wgt_load_bank <= block_bank;
                        wgt_load_phase <= 9'd0;
                        wgt_load_done_r <= 1'b0;
                        fsm_state <= FSM_CIN_LOAD_WGT;
                    end else if (is_fc_mode) begin
                        // FC: load all weights (output_c * input_c INT8 bytes)
                        wgt_dma_start <= 1'b1;
                        wgt_dma_addr <= blk_wgt_addr;
                        wgt_dma_bytes <= output_c * input_c;
                        wgt_load_start <= 1'b1;
                        wgt_load_bank <= block_bank;
                        wgt_load_phase <= 9'd0;
                        wgt_load_done_r <= 1'b0;
                        fsm_state <= FSM_CIN_LOAD_WGT;
                    end else begin
                        comp_sub_state <= CP_WAIT_WIN;
                        fsm_state <= FSM_COMPUTE;
                    end
                end

                FSM_CIN_LOAD_WGT: begin
                    if (wgt_dma_done) begin
                        wgt_load_done <= 1'b1;
                        fsm_state <= FSM_CIN_LOAD_DONE;
                    end else if (wgt_dma_error) begin
                        task_error_r <= 1'b1; task_error_code_r <= wgt_dma_error_code;
                        fsm_state <= FSM_ERROR;
                    end
                end

                FSM_CIN_LOAD_DONE: begin
                    fsm_state <= FSM_LOAD_ARRAY;
                end

                // ============================================================
                // FSM_LOAD_ARRAY: load weights from wgt_buffer into array + wgt_load_reg
                // ============================================================
                FSM_LOAD_ARRAY: begin
                    if (wgt_load_phase < wgt_words_per_cin) begin
                        // Map memory byte idx to wgt_load_reg byte idx:
                        // memory: spatial_pos * C_out + out_c  (sequential)
                        // wgt_reg: spatial_pos * 64 + out_c   (strided for array columns)
                        // For each of 4 bytes in current word:
                        //   byte_in_mem = phase*4 + bi
                        //   sp = byte_in_mem / C_out
                        //   oc = byte_in_mem % C_out
                        //   wgt_byte = sp * 64 + oc
                        reg [15:0] sp0, sp1, sp2, sp3;
                        reg [5:0]  oc0, oc1, oc2, oc3;
                        reg [31:0] bim0, bim1, bim2, bim3;
                        bim0 = wgt_load_phase * 4 + 0;
                        bim1 = wgt_load_phase * 4 + 1;
                        bim2 = wgt_load_phase * 4 + 2;
                        bim3 = wgt_load_phase * 4 + 3;
                        sp0 = bim0 / {16'd0, output_c};
                        sp1 = bim1 / {16'd0, output_c};
                        sp2 = bim2 / {16'd0, output_c};
                        sp3 = bim3 / {16'd0, output_c};
                        oc0 = bim0 % {16'd0, output_c};
                        oc1 = bim1 % {16'd0, output_c};
                        oc2 = bim2 % {16'd0, output_c};
                        oc3 = bim3 % {16'd0, output_c};
                        wgt_load_reg[(sp0 * PE_COLS + oc0)*8 +: 8] <= wgt_rd_data[ 7: 0];
                        wgt_load_reg[(sp1 * PE_COLS + oc1)*8 +: 8] <= wgt_rd_data[15: 8];
                        wgt_load_reg[(sp2 * PE_COLS + oc2)*8 +: 8] <= wgt_rd_data[23:16];
                        wgt_load_reg[(sp3 * PE_COLS + oc3)*8 +: 8] <= wgt_rd_data[31:24];
                        wgt_load_phase <= wgt_load_phase + 9'd1;
                    end else begin
                        wgt_load_done_r <= 1'b1;
                        fsm_state <= FSM_WGT_LD;
                    end
                end

                FSM_WGT_LD: begin
                    // weight_ld pulsed → weights now in array PEs
                    comp_sub_state <= CP_WAIT_WIN;
                    fsm_state <= FSM_COMPUTE;
                end

                // ============================================================
                // FSM_COMPUTE: process all spatial windows for current c_in
                // ============================================================
                FSM_COMPUTE: begin
                    case (comp_sub_state)
                        CP_WAIT_WIN: begin
                            if (is_fc_mode) begin
                                // FC: feed INT8 activations (read 4 at a time from INT32 buffer)
                                act_feed_ptr <= act_feed_ptr + 1;  // advance byte
                                act_feed_done_cnt <= act_feed_done_cnt + 16'd1;
                                if (act_feed_done_cnt + 16'd1 >= input_c[15:0]) begin
                                    // All input activations fed → transition to FEED_ACT
                                    comp_feed_cnt <= 5'd0;
                                    act_feed_ptr <= 0;
                                    comp_sub_state <= CP_FEED_ACT;
                                end
                            end else if (is_pool_mode) begin
                                // Pool: feed INT32 words, wait for postproc to finish
                                if (!pp_start && (act_feed_done_cnt < blk_in_bytes[15:0])) begin
                                    act_feed_ptr <= act_feed_ptr + 1;
                                    act_feed_done_cnt <= act_feed_done_cnt + 16'd4;
                                end
                                if (!pp_start && pp_done) begin
                                    acc_load_start <= 1'b1;
                                    act_comp_done <= 1'b1;
                                    fsm_state <= FSM_STORE;
                                end
                            end else begin
                                // Conv: feed activations to conv_frontend
                                if (conv_act_ready && (act_feed_done_cnt < blk_in_bytes[15:0])) begin
                                    act_feed_ptr <= act_feed_ptr + 1;
                                    act_feed_done_cnt <= act_feed_done_cnt + 16'd1;
                                end
                                if (cf_new_window) begin
                                    comp_feed_cnt <= 5'd0;
                                    comp_sub_state <= CP_FEED_ACT;
                                end else if (cf_done) begin
                                    comp_sub_state <= CP_NEXT;
                                end
                            end
                        end

                        CP_FEED_ACT: begin
                            if (comp_feed_cnt < KERNEL_SPATIAL[4:0]) begin
                                if (is_fc_mode)
                                    act_feed_ptr <= act_feed_ptr + 1;
                                comp_feed_cnt <= comp_feed_cnt + 5'd1;
                            end else begin
                                comp_drain_cnt <= 16'd0;
                                // Set up partial sum address for this window
                                if (is_conv_mode)
                                    acc_partial_addr <= acc_wr_ptr;
                                comp_sub_state <= CP_DRAIN;
                            end
                        end

                        CP_DRAIN: begin
                            // Drain: + output_c for per-column skew, + 3 for last-column propagation safety
                            // Capture each output column at its own valid cycle.
                            // For a PE array with registered act and sum propagation, column c becomes
                            // valid a fixed number of cycles after feed plus its horizontal distance.
                            if ((comp_drain_cnt >= (PE_ROWS - KERNEL_SPATIAL + 5)) &&
                                (comp_drain_cnt <  (PE_ROWS - KERNEL_SPATIAL + 5 + output_c))) begin
                                col_results[comp_drain_cnt - (PE_ROWS - KERNEL_SPATIAL + 5)]
                                    <= array_sum_out[(comp_drain_cnt - (PE_ROWS - KERNEL_SPATIAL + 5))*32 +: 32];
                            end

                            if (comp_drain_cnt < (PE_ROWS - KERNEL_SPATIAL + 5 + output_c - 1)) begin
                                comp_drain_cnt <= comp_drain_cnt + 16'd1;
                            end else begin
                                acc_col_idx <= 16'd0;
                                acc_partial_addr <= acc_wr_ptr;
                                comp_sub_state <= CP_COLLECT;
                            end
                        end

                        CP_COLLECT: begin
                            // Write accumulated result to acc_buffer (one column per cycle).
                            if (acc_col_idx + 16'd1 < output_c) begin
                                acc_col_idx <= acc_col_idx + 16'd1;
                                acc_partial_addr <= acc_partial_addr + 1;
                            end else begin
                                comp_sub_state <= CP_NEXT;
                            end
                        end

                        CP_NEXT: begin
                            comp_win_idx <= comp_win_idx + 16'd1;
                            if (comp_win_idx + 16'd1 >= comp_total_wins) begin
                                // All windows processed for this c_in
                                fsm_state <= FSM_CIN_NEXT;
                            end else begin
                                comp_sub_state <= CP_WAIT_WIN;
                            end
                        end

                        default: comp_sub_state <= CP_WAIT_WIN;
                    endcase
                end

                // ============================================================
                // FSM_CIN_NEXT: check if more input channels
                // ============================================================
                FSM_CIN_NEXT: begin
                    if (cin_idx + 16'd1 < cin_total) begin
                        cin_idx <= cin_idx + 16'd1;
                        // Restart conv_frontend and reset feed pointers for next c_in
                        act_feed_ptr <= 0;
                        act_feed_done_cnt <= 16'd0;
                        comp_win_idx <= 16'd0;
                        fsm_state <= FSM_CIN_RESTART;
                    end else begin
                        act_comp_done <= 1'b1;
                        acc_load_start <= 1'b1;
                        fsm_state <= FSM_STORE;
                    end
                end

                FSM_CIN_RESTART: begin
                    // Pulse cf_start, clear tracking for next c_in iteration
                    cf_last_row <= 16'hFFFF;
                    cf_last_col <= 16'hFFFF;
                    // Flush wgt_buffer so it can accept new DMA load for next c_in
                    wgt_buf_flush <= 1'b1;
                    fsm_state <= FSM_CIN_START;
                end

                // ============================================================
                // FSM_STORE: DMA write acc_buffer to memory
                // ============================================================
                FSM_STORE: begin
                    dma_wr_addr <= is_fc_mode ? fc_store_addr : blk_out_addr;
                    dma_wr_bytes <= is_fc_mode ? fc_store_bytes : blk_out_bytes;
                    if (!dma_wr_started) begin
                        dma_wr_start <= 1'b1;
                        dma_wr_started <= 1'b1;
                    end
                    if (dma_wr_done) begin
                        dma_wr_started <= 1'b0;
                    end
                    if (dma_wr_valid && dma_wr_ready)
                        dma_rd_ptr <= dma_rd_ptr + 1;
                    if (dma_wr_done) begin
                        if (is_fc_mode) begin
                            dma_wr_started <= 1'b0;
                            dma_rd_ptr <= 0;
                            if (fc_out_start + fc_tile_outputs < output_c) begin
                                fc_out_start <= fc_out_start + fc_tile_outputs;
                                fsm_state <= FSM_FC_TILE_PREP;
                            end else begin
                                act_comp_done <= 1'b1;
                                task_done_r <= 1'b1;
                                task_active_r <= 1'b0;
                                fsm_state <= FSM_DONE;
                            end
                        end else begin
                            acc_comp_start <= 1'b1;
                            acc_comp_bank <= acc_load_bank;
                            blk_done <= 1'b1;
                            fsm_state <= FSM_BLK_DONE;
                        end
                    end else if (dma_wr_error) begin
                        task_error_r <= 1'b1; task_error_code_r <= dma_wr_error_code;
                        fsm_state <= FSM_ERROR;
                    end
                end

                FSM_BLK_DONE: begin
                    fsm_state <= FSM_BLK_CHECK;
                end

                FSM_BLK_CHECK: begin
                    if (blk_all_done) begin
                        task_done_r <= 1'b1;
                        task_active_r <= 1'b0;
                        fsm_state <= FSM_DONE;
                    end else begin
                        // Next block
                        dma_rd_ptr <= 0;
                        dma_wr_started <= 1'b0;
                        block_bank <= ~block_bank;
                        wgt_load_phase <= 9'd0;
                        wgt_load_done_r <= 1'b0;
                        wgt_load_reg <= 0;
                        cf_last_row <= 16'hFFFF;
                        cf_last_col <= 16'hFFFF;
                        cin_idx <= 16'd0;
                        if (is_pool_mode) begin
                            act_dma_start <= 1'b1;
                            act_dma_addr <= blk_in_addr;
                            act_dma_bytes <= blk_in_bytes;
                            act_load_start <= 1'b1;
                            act_load_bank <= ~block_bank;
                            fsm_state <= FSM_LOAD_ACT;
                        end else begin
                            act_dma_start <= 1'b1;
                            act_dma_addr <= blk_in_addr;
                            act_dma_bytes <= blk_in_bytes;
                            act_load_start <= 1'b1;
                            act_load_bank <= ~block_bank;
                            fsm_state <= FSM_LOAD_ACT;
                        end
                    end
                end

                FSM_DONE: begin
                    task_done_r <= 1'b0;
                    fsm_state <= FSM_IDLE;
                end

                FSM_ERROR: begin
                    task_active_r <= 1'b0;
                    if (!ctrl_busy && !ctrl_error) begin
                        task_error_r <= 1'b0;
                        fsm_state <= FSM_IDLE;
                    end
                end

                default: fsm_state <= FSM_IDLE;
            endcase
        end
    end

    assign task_done_fb = task_done_r;
    assign task_error_fb = task_error_r;
    assign task_error_code_fb = task_error_code_r;

    // weight_mac_addr
    assign wgt_mac_addr = {BUF_ADDR_W{1'b0}} | wgt_load_phase;

endmodule
