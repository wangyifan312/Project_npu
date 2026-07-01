// npu_top: NPU accelerator orchestration top for the formal single-cluster SoC baseline
// Multi-channel Conv: temporal input-channel iteration with parallel output channels
// Conv formal path: cluster_scheduler -> compute_core -> output_arbiter
`timescale 1ns / 1ps

module npu_top #(
    parameter AXI_ADDR_W = 32,
    parameter AXI_DATA_W = 32,
    parameter AXI_DMA_DATA_W = 256,
    parameter BUF_DATA_W  = 256,
    parameter ACC_DATA_W  = 32,
    parameter BUF_ENTRIES = 1024,
    parameter BUF_ADDR_W  = 10,
    parameter TILE_ROWS   = 16,
    parameter TILE_COLS   = 16,
    parameter [1:0] CLUSTER_MODE = 2'd0,
    parameter [5:0] CLUSTER_MASK_REQ = 6'b00_0001
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
    input  wire [AXI_DMA_DATA_W-1:0]   m_axi_rdata,
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
    output wire [AXI_DMA_DATA_W-1:0]   m_axi_wdata,
    output wire                        m_axi_wvalid,
    input  wire                        m_axi_wready,
    output wire                        m_axi_wlast,
    output wire [(AXI_DMA_DATA_W/8)-1:0] m_axi_wstrb,
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
    localparam KERNEL_SPATIAL = 25;   // 5x5 spatial kernel elements
    localparam CLUSTER_COUNT = 1;
    localparam CLUSTER_ACT_W = PE_ROWS * 8;
    localparam CLUSTER_SUM_W = PE_COLS * 32;
    localparam CLUSTER_WGT_W = N_TILES * 16 * 8;
    localparam CLUSTER_TILE_EN_W = N_TILES;
    localparam WGT_REG_BITS = PE_ROWS * PE_COLS * 8;
    localparam HB_BEAT_BYTES = BUF_DATA_W / 8;
    localparam HB_BEAT_BYTE_BITS = 5; // 256-bit beat = 32 byte lanes
    localparam [15:0] PE_ROWS_16 = PE_ROWS;
    localparam [15:0] PE_COLS_16 = PE_COLS;
    localparam [15:0] KERNEL_SPATIAL_16 = KERNEL_SPATIAL;

    // Main FSM states
    localparam FSM_IDLE        = 5'd0;
    localparam FSM_LOAD_ACT    = 5'd1;
    localparam FSM_CF_START    = 5'd2;
    localparam FSM_PRE_COMP    = 5'd3;
    localparam FSM_CIN_START   = 5'd4;
    localparam FSM_CIN_LOAD_WGT= 5'd5;
    localparam FSM_CIN_LOAD_DONE=5'd6;
    localparam FSM_LOAD_ARRAY  = 5'd7;
    localparam FSM_WGT_LD      = 5'd8;
    localparam FSM_COMPUTE     = 5'd9;
    localparam FSM_CIN_NEXT    = 5'd10;
    localparam FSM_STORE       = 5'd11;
    localparam FSM_BLK_CHECK   = 5'd12;
    localparam FSM_BLK_DONE    = 5'd13;
    localparam FSM_CIN_RESTART = 5'd16;
    localparam FSM_FC_TILE_PREP= 5'd17;
    localparam FSM_FC_LOAD_WGT = 5'd18;
    localparam FSM_FC_LOAD_WAIT= 5'd19;
    localparam FSM_REQUANT_COMPUTE = 5'd21;
    localparam FSM_REQUANT_DRAIN   = 5'd30;
    localparam FSM_TASK_SETUP  = 5'd22;
    localparam FSM_LOAD_BIAS   = 5'd23;
    localparam FSM_BIAS_WAIT   = 5'd24;
    localparam FSM_BIAS_EXTRACT= 5'd25;
    localparam FSM_LOAD_ADD_SRC1 = 5'd26;
    localparam FSM_ADD_SRC1_WAIT = 5'd27;
    localparam FSM_ADD_COMPUTE   = 5'd28;
    localparam FSM_GAP_COMPUTE   = 5'd29;
    localparam FSM_ADD_DRAIN     = 5'd31;
    localparam FSM_VEC_RELU_PROC = 5'd20;
    localparam FSM_PIPE_RUN    = 6'd32;
    localparam FSM_PIPE_DONE   = 6'd33;
    localparam FSM_DONE        = 5'd15;

    function [7:0] hb_beat_byte;
        input [BUF_DATA_W-1:0] beat;
        input [HB_BEAT_BYTE_BITS-1:0] byte_sel;
        begin
            hb_beat_byte = beat[byte_sel * 8 +: 8];
        end
    endfunction

    function [31:0] hb_beat_word;
        input [BUF_DATA_W-1:0] beat;
        input [2:0] word_sel;
        begin
            hb_beat_word = beat[word_sel * 32 +: 32];
        end
    endfunction

    function [15:0] conv_out_dim;
        input [15:0] in_dim;
        input [15:0] kernel;
        input [15:0] stride;
        input        same_pad;
        begin
            if (same_pad)
                conv_out_dim = (stride == 16'd2) ? ((in_dim + 16'd1) >> 1) : in_dim;
            else if (in_dim >= kernel)
                conv_out_dim = ((in_dim - kernel) / stride) + 16'd1;
            else
                conv_out_dim = 16'd0;
        end
    endfunction
    localparam FSM_ERROR       = 5'd14;
    localparam FSM_GEMM_STREAM_PREP   = 6'd34;
    localparam FSM_GEMM_STREAM_LOAD_A = 6'd35;
    localparam FSM_GEMM_STREAM_RUN    = 6'd36;
    localparam FSM_GEMM_STREAM_DONE   = 6'd37;
    localparam FSM_GEMM_STREAM_STORE   = 6'd38;
    localparam FSM_GEMM_STREAM_ACCUM   = 6'd40;  // Phase 3a: K-chunk loop check

    // Phase 3c: input-tile-loader micro-sequencer within FSM_GEMM_STREAM_LOAD_A
    // Currently GEMM-scoped (gemm_a_load_*); intended to become common
    // input_tile_loader in Phase 4.
    localparam A_LOAD_IDLE    = 2'd0;
    localparam A_LOAD_REQ     = 2'd1;
    localparam A_LOAD_WAIT    = 2'd2;
    localparam A_LOAD_CAPTURE = 2'd3;

    // COMPUTE sub-states
    localparam CP_WAIT_WIN = 3'd0;
    localparam CP_FEED_ACT = 3'd1;
    localparam CP_DRAIN    = 3'd2;
    localparam CP_COLLECT  = 3'd3;
    localparam CP_NEXT     = 3'd4;

    reg [5:0]  fsm_state;

    // P3: helper — compute FSM active in either FSM_COMPUTE or FSM_PIPE_RUN
    wire compute_fsm_active = (fsm_state == FSM_COMPUTE) || (fsm_state == FSM_PIPE_RUN);

    reg [2:0]  comp_sub_state;
    reg [15:0] comp_total_wins;
    reg [15:0] comp_win_idx;
    reg [6:0]  comp_feed_cnt;
    reg [15:0] comp_drain_cnt;
    reg [WGT_REG_BITS-1:0] wgt_load_reg;
    reg [31:0] wgt_load_phase;
    reg        wgt_load_wait;

    // Phase 2: FC shadow weight register — loaded during compute,
    // then swapped into wgt_load_reg after chunk completes
    reg [WGT_REG_BITS-1:0] wgt_load_reg_shadow;
    reg        fc_shadow_active;
    reg [31:0] fc_shadow_phase;
    reg [15:0] fc_shadow_in_base;
    reg [15:0] fc_shadow_chunk_inputs;
    reg        fc_shadow_wait;

    // ============================================================
    // npu_ctrl signals
    // ============================================================
    wire        task_start;
    wire [2:0]  task_type;
    wire [31:0] input_addr, weight_addr, output_addr;
    wire [31:0] input_bytes, weight_bytes, output_bytes;
    wire [15:0] input_h, input_w, input_c, output_c;
    wire        relu_en, pool_en;
    wire [1:0]  requant_slot_sel;
    wire [31:0] requant_multiplier;
    wire [5:0]  requant_shift;
    wire [1:0]  cluster_mode_cfg;
    wire [5:0]  cluster_mask_cfg;
    wire [31:0] conv_cfg;
    wire [31:0] bias_addr;
    wire [31:0] bias_bytes;
    wire [31:0] src1_addr;
    wire [31:0] src1_bytes;
    wire [31:0] add_cfg;
    wire [31:0] gap_cfg;
    wire [31:0] postproc_cfg_ext;
    wire [31:0] add_src0_multiplier;
    wire [5:0]  add_src0_shift;
    wire [31:0] add_src1_multiplier;
    wire [5:0]  add_src1_shift;
    wire [31:0] add_out_multiplier;
    wire [5:0]  add_out_shift;
    wire [1:0]  conv_kernel_sel = conv_cfg[1:0];
    wire        conv_stride2 = conv_cfg[2];
    wire        conv_same_pad = conv_cfg[3];
    wire        bias_enabled = conv_cfg[4] && ((task_type == 3'd0) || (task_type == 3'd1));
    wire [15:0] conv_kernel_size =
        (conv_kernel_sel == 2'd1) ? 16'd1 :
        (conv_kernel_sel == 2'd2) ? 16'd3 :
                                    16'd5;
    wire [15:0] conv_stride = conv_stride2 ? 16'd2 : 16'd1;
    wire [15:0] conv_kernel_area = conv_kernel_size * conv_kernel_size;
    wire [15:0] conv_total_out_cols = conv_out_dim(input_w, conv_kernel_size, conv_stride, conv_same_pad);
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
    wire [31:0] perf_write_data_cycles, perf_write_txn_cycles;
    wire [31:0] perf_ar_handshake, perf_aw_handshake, perf_b_handshake, perf_bus_active;
    wire [31:0] perf_cluster_cfg;

    // Enhanced performance counters
    wire [31:0] perf_compute_cycles, perf_load_cycles, perf_store_cycles, perf_collect_cycles;
    wire [31:0] perf_read_valid_bytes, perf_write_valid_bytes;
    wire [31:0] perf_mac_count_lo, perf_mac_count_hi;
    wire [31:0] perf_stall_act, perf_stall_wgt, perf_stall_acc, perf_stall_store;
    wire [31:0] perf_array_fill_drain;
    wire        perf_compute_active, perf_load_active, perf_store_active, perf_collect_active;
    wire [5:0]  perf_read_byte_cnt, perf_write_byte_cnt;
    wire        perf_mac_count_valid;
    wire [15:0] perf_mac_count_add;
    wire        perf_stall_act_evt, perf_stall_wgt_evt, perf_stall_acc_evt, perf_stall_store_evt;
    wire        perf_array_fill_drain_evt;

    wire [31:0] blk_in_addr, blk_wgt_addr, blk_out_addr;
    wire [31:0] blk_in_bytes, blk_wgt_bytes, blk_out_bytes;
    wire [15:0] blk_in_rows, blk_out_rows;
    wire [31:0] blk_wgt_per_cin;
    wire [15:0] blk_cin_total;
    wire [31:0] blk_conv_output_elements =
        {16'd0, blk_out_rows} * {16'd0, conv_total_out_cols} * {16'd0, output_c};

    // ============================================================
    // npu_ctrl
    // ============================================================
    npu_ctrl #(
        .DEFAULT_CLUSTER_MODE(CLUSTER_MODE),
        .DEFAULT_CLUSTER_MASK(CLUSTER_MASK_REQ)
    ) u_ctrl (
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
        .requant_slot_sel(requant_slot_sel), .requant_multiplier(requant_multiplier), .requant_shift(requant_shift),
        .cluster_mode_cfg(cluster_mode_cfg), .cluster_mask_cfg(cluster_mask_cfg),
        .conv_cfg(conv_cfg), .bias_addr(bias_addr), .bias_bytes(bias_bytes),
        .src1_addr(src1_addr), .src1_bytes(src1_bytes), .add_cfg(add_cfg),
        .gap_cfg(gap_cfg), .postproc_cfg_ext(postproc_cfg_ext),
        .add_src0_multiplier(add_src0_multiplier), .add_src0_shift(add_src0_shift),
        .add_src1_multiplier(add_src1_multiplier), .add_src1_shift(add_src1_shift),
        .add_out_multiplier(add_out_multiplier), .add_out_shift(add_out_shift),
        .task_done_i(task_done_fb), .task_error_i(task_error_fb),
        .task_error_code_i(task_error_code_fb),
        .check_done_i(check_done_fb), .checks_pass_i(checks_pass_fb),
        .perf_cycle_lo_i(perf_cycle_lo), .perf_cycle_hi_i(perf_cycle_hi),
        .perf_read_beats_i(perf_read_beats), .perf_write_beats_i(perf_write_beats),
        .perf_read_active_i(perf_read_active), .perf_write_active_i(perf_write_active),
        .perf_mac_lo_i(perf_mac_lo), .perf_mac_hi_i(perf_mac_hi),
        .perf_array_active_i(perf_array_active), .perf_array_stall_i(perf_array_stall),
        .perf_cluster_active_i(perf_cluster_active), .perf_cluster_stall_i(perf_cluster_stall),
        .perf_cluster_cfg_i(perf_cluster_cfg),
        .perf_write_data_cycles_i(perf_write_data_cycles),
        .perf_write_txn_cycles_i(perf_write_txn_cycles),
        .perf_ar_handshake_i(perf_ar_handshake),
        .perf_aw_handshake_i(perf_aw_handshake),
        .perf_b_handshake_i(perf_b_handshake),
        .perf_bus_active_i(perf_bus_active),
        // Enhanced perf counters
        .perf_compute_cycles_i(perf_compute_cycles),
        .perf_load_cycles_i(perf_load_cycles),
        .perf_store_cycles_i(perf_store_cycles),
        .perf_collect_cycles_i(perf_collect_cycles),
        .perf_read_valid_bytes_i(perf_read_valid_bytes),
        .perf_write_valid_bytes_i(perf_write_valid_bytes),
        .perf_mac_count_lo_i(perf_mac_count_lo),
        .perf_mac_count_hi_i(perf_mac_count_hi),
        .perf_stall_act_i(perf_stall_act),
        .perf_stall_wgt_i(perf_stall_wgt),
        .perf_stall_acc_i(perf_stall_acc),
        .perf_stall_store_i(perf_stall_store),
        .perf_array_fill_drain_i(perf_array_fill_drain)
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
        .conv_cfg(conv_cfg),
        .bias_addr(bias_addr), .bias_bytes(bias_bytes),
        .src1_addr(src1_addr), .src1_bytes(src1_bytes),
        .add_cfg(add_cfg), .gap_cfg(gap_cfg), .postproc_cfg_ext(postproc_cfg_ext),
        .requant_multiplier(requant_multiplier), .requant_shift(requant_shift),
        .add_src0_multiplier(add_src0_multiplier), .add_src0_shift(add_src0_shift),
        .add_src1_multiplier(add_src1_multiplier), .add_src1_shift(add_src1_shift),
        .add_out_multiplier(add_out_multiplier), .add_out_shift(add_out_shift),
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

    act_read_path #(.AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DMA_DATA_W),
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
    reg  [4:0]  wgt_dma_byte_offset;
    wire        wgt_dma_done, wgt_dma_error, wgt_dma_busy;
    wire [7:0]  wgt_dma_error_code;
    wire [BUF_ADDR_W-1:0] wgt_buf_wr_addr;
    wire [BUF_DATA_W-1:0] wgt_buf_wr_data;
    wire                  wgt_buf_wr_en;

    weight_read_path #(.AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DMA_DATA_W),
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
    reg         next_blk_prep;        // P3: step1: blk_done pulsed
    reg         next_blk_wait;        // P3: step2: waiting for scheduler update
    reg         next_dma_launched;    // P3: next block DMA launched during STORE
    reg         pipe_mode;            // P3: full pipeline overlap active
    reg         pipe_store_done;      // P3: store finished during pipe mode
    reg  [31:0] dma_wr_addr, dma_wr_bytes;
    wire        dma_wr_done, dma_wr_error, dma_wr_busy, dma_wr_txn_active;
    wire [7:0]  dma_wr_error_code;
    wire [AXI_DMA_DATA_W-1:0] dma_wr_data;
    wire        dma_wr_valid, dma_wr_ready;

    // Write-beat FIFO wires (declared before use in dma_axi_writer)
    wire [255:0] wf_rd_data;
    wire [31:0]  wf_rd_strb;
    wire         wf_rd_last;
    wire         wf_rd_valid, wf_rd_en, wf_rd_empty, wf_wr_full;
    wire [5:0]   wf_rd_level;

    // ============================================================
    // Vector INT8 ReLU 256b — streaming datapath signals
    // ============================================================
    reg  [31:0] vec_relu_beat_idx;     // beats received/processed
    reg  [31:0] vec_relu_total_beats;  // total expected beats = (num_bytes + 31) >> 5
    reg         vec_relu_out_wr_valid; // write_beat_fifo push valid
    reg         vec_relu_read_done;    // act_dma_done latched (phase A complete)
    reg         vec_relu_proc_active;  // phase B: processing beats from act_buffer
    reg  [BUF_ADDR_W-1:0] vec_relu_rd_addr; // phase B: act_buffer read address
    reg         vec_relu_rd_wait;      // 1-cycle buffer read latency wait
    reg         vec_wr_done_latch;     // latch for dma_wr_done 1-cycle pulse
    reg         vec_relu_proc_done;    // Phase B completed; waiting for writer
    wire [255:0] vec_relu_result;      // 32-lane INT8 ReLU result (combinational)

    // === DEBUG counters for vec_relu multi-burst correctness ===
    reg [31:0] dbg_vec_push_count;     // successful FIFO pushes from Phase B
    reg [31:0] dbg_vec_push_skip;      // skipped pushes (FIFO full)
    reg [31:0] dbg_fifo_pop_count;     // FIFO pops (wf_rd_en)
    reg [31:0] dbg_w_hs_count;         // m_axi_wvalid && m_axi_wready
    reg [31:0] dbg_vec_total_beats;    // snapshot of total_beats
    reg        dbg_done_printed;       // only print once
    reg [31:0] dbg_rd_issue_count;     // AR handshakes during vec read (phase A)
    reg [31:0] dbg_rd_data_count;      // R handshakes during vec read (phase A)
    reg [31:0] dbg_fifo_full_stall;    // times Phase B blocked by wf_wr_full
    reg [31:0] dbg_cycle_cnt;          // cycle counter snapshot

    // producer_done: declared here, assigned after store_words_active definition
    wire dma_producer_done;

    dma_axi_writer #(
        .AXI_DATA_WIDTH(AXI_DMA_DATA_W),
        .AXI_ADDR_WIDTH(AXI_ADDR_W)
    ) u_dma_writer (
        .clk(clk), .rst_n(rst_n), .start(dma_wr_start),
        .base_addr(dma_wr_addr), .byte_count(dma_wr_bytes),
        .done(dma_wr_done), .error(dma_wr_error), .error_code(dma_wr_error_code), .busy(dma_wr_busy),
        .write_txn_active(dma_wr_txn_active),
        .fifo_level(wf_rd_level),
        .producer_done(dma_producer_done),
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
    reg  wgt_consume_bank;
    reg  wgt_preload_active, wgt_preload_done, wgt_preload_bank;
    reg  [15:0] wgt_preload_cin;
    reg  [4:0]  wgt_preload_byte_offset;
    reg wgt_buf_flush;
    // FC ping-pong weight DMA preload (Phase 1)
    reg        fc_preload_active;
    reg        fc_preload_done;
    reg        fc_preload_bank;
    reg [15:0] fc_preload_out_start;
    reg [15:0] fc_preload_tile_outputs;
    reg [4:0]  fc_preload_byte_offset;  // P1: sub-beat offset for preload DMA
    reg        fc_use_preload;           // P1: set when consuming preloaded weights
    npu_buffer #(.DATA_WIDTH(BUF_DATA_W), .ENTRIES(BUF_ENTRIES), .ADDR_WIDTH(BUF_ADDR_W))
    u_wgt_buffer (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(wgt_buf_wr_addr), .wr_data(wgt_buf_wr_data), .wr_en(wgt_buf_wr_en), .wr_bank_sel(wgt_load_bank),
        .rd_addr(wgt_rd_addr), .rd_data(wgt_rd_data), .rd_bank_sel(wgt_rd_bank),
        .load_start(wgt_load_start), .load_done(wgt_load_done),
        .comp_start(1'b0), .comp_done(1'b0),
        .load_bank_sel(wgt_load_bank), .comp_bank_sel(wgt_consume_bank),
        .flush(wgt_buf_flush), .load_ready(), .comp_ready(), .comp_active(),
        .bank_a_state(), .bank_b_state()
    );

    wire [BUF_ADDR_W-1:0] acc_wr_addr, acc_rd_addr;
    wire [ACC_DATA_W-1:0] acc_wr_data, acc_rd_data;
    wire                  acc_wr_en, acc_rd_bank, acc_wr_bank;
    reg  acc_load_start, acc_load_done, acc_comp_start, acc_comp_done;
    reg  acc_load_bank, acc_comp_bank;

    npu_buffer #(.DATA_WIDTH(ACC_DATA_W), .ENTRIES(BUF_ENTRIES), .ADDR_WIDTH(BUF_ADDR_W))
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

    // FC formal path state. FC tiles output neurons across the shared
    // single-cluster array and chunks long input vectors across PE rows.
    reg [15:0] fc_out_start;
    reg [15:0] fc_tile_outputs;
    reg [15:0] fc_in_base;
    reg [15:0] fc_chunk_inputs;
    reg [31:0] fc_store_addr;
    reg [31:0] fc_store_bytes;

    // GEMM mode: outer loop over M rows, each row = one FC/GEMV pass
    reg [15:0] gemm_row_idx;     // current GEMM output row (0..M-1)
    wire [15:0] gemm_M_val;      // M = input_h in GEMM mode
    wire [15:0] gemm_N_val;      // N = output_c in GEMM mode
    assign gemm_M_val = input_h;
    assign gemm_N_val = output_c;

    // GEMM weight retention cache
    reg        gemm_weight_valid;
    reg [31:0] gemm_weight_addr_cached;
    reg [15:0] gemm_weight_k_base_cached;
    reg [15:0] gemm_weight_n_base_cached;
    reg [15:0] gemm_weight_k_size_cached;
    reg [15:0] gemm_weight_n_size_cached;

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
        .conv_cfg(conv_cfg),
        .block_out_rows(blk_out_rows), .block_in_rows(blk_in_rows),
        .start(cf_start), .window_hold(cf_window_hold),
        .done(cf_done), .cur_row(cf_cur_row), .cur_col(cf_cur_col)
    );

    // ============================================================
    // Formal single-cluster compute path
    // ============================================================
    wire [(PE_ROWS*8)-1:0]    array_act_in;
    wire [(PE_COLS*32)-1:0]   array_sum_in;
    wire [(N_TILES*16*8)-1:0] array_weight;
    wire                      array_weight_ld;
    wire [(PE_COLS*32)-1:0]   array_sum_out;
    wire [(N_TILES)-1:0]      array_clk_en;
    reg  [(CLUSTER_COUNT*CLUSTER_ACT_W)-1:0] cluster_act_all_flat;
    reg  [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] cluster_sum_all_flat;
    reg  [(CLUSTER_COUNT*CLUSTER_WGT_W)-1:0] cluster_weight_all_flat;
    wire [CLUSTER_COUNT-1:0]                 cluster_weight_ld_all;
    reg  [(CLUSTER_COUNT*CLUSTER_TILE_EN_W)-1:0] cluster_tile_clk_en_all_flat;
    wire [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] cluster_sum_out_all_flat;
    reg  [(CLUSTER_COUNT*CLUSTER_SUM_W)-1:0] cluster_routed_sum_out_all_flat;
    wire [CLUSTER_COUNT-1:0]                 cluster_busy;
    wire [CLUSTER_COUNT-1:0]                 cluster_valid;
    wire [CLUSTER_COUNT-1:0]                 cluster_done;
    wire                                     any_cluster_busy;
    wire                                     all_enabled_done;
    reg  [CLUSTER_COUNT-1:0]                 cluster_arb_valid;
    wire                                     cluster_arb_out_valid;
    wire [(PE_COLS*32)-1:0]                  cluster_arb_sum_out;
    wire [2:0]                               cluster_arb_cluster_id;
    wire                                     cluster_arb_all_done;
    wire [CLUSTER_COUNT-1:0]   perf_cluster_enable;
    wire [2:0]                perf_cluster_count;
    wire                      perf_schedule_valid;
    wire is_fc_mode      = (task_type == 3'd1);
    wire is_pool_mode    = (task_type == 3'd2);
    wire is_conv_mode    = (task_type == 3'd0);
    wire is_requant_mode = (task_type == 3'd3);
    wire is_add_mode     = (task_type == 3'd4);
    wire is_gap_mode     = (task_type == 3'd5);
    wire is_vec_relu_mode = (task_type == 3'd6);
    wire is_gemm_mode    = (task_type == 3'd7);
    wire gemm_row_streaming_en = is_gemm_mode && conv_cfg[5];
    wire gemm_weight_hit = is_gemm_mode && gemm_weight_valid &&
        !gemm_row_streaming_en &&  // Phase 3b: streaming GEMM bypasses legacy cache
        (gemm_weight_k_base_cached == 16'd0) &&
        (gemm_weight_n_base_cached == 16'd0) &&
        (gemm_weight_k_size_cached == ((input_c > PE_ROWS_16) ? PE_ROWS_16 : input_c)) &&
        (gemm_weight_n_size_cached == ((output_c > PE_COLS_16) ? PE_COLS_16 : output_c)) &&
        (gemm_weight_addr_cached == weight_addr);
    wire [15:0] array_active_rows;
    wire [15:0] array_active_cols;

    // Phase 4a-2: double-buffered input tile banks
    reg [7:0]  input_tile_bank0 [0:7][0:63];
    reg [7:0]  input_tile_bank1 [0:7][0:63];
    reg signed [31:0] c_tile [0:7][0:63];
    reg        c_tile_valid [0:7][0:63];
    reg [15:0] stream_cycle;
    reg [15:0] stream_capture_count;
    reg        stream_active;
    reg        stream_a_tile_loaded;
    // Phase 4a-2: bank ownership and metadata
    reg        input_load_bank;          // which bank loader writes
    reg        input_compute_bank;       // which bank compute reads
    reg        input_bank0_valid;        // bank0 has valid loaded data
    reg        input_bank1_valid;        // bank1 has valid loaded data
    reg [15:0] input_bank0_k_base;       // k_base for data in bank0
    reg [15:0] input_bank1_k_base;       // k_base for data in bank1
    reg [15:0] input_bank0_k_tile;       // k_tile for data in bank0
    reg [15:0] input_bank1_k_tile;       // k_tile for data in bank1
    // Phase 4a-3: background input tile prefetch during RUN
    localparam PREF_IDLE    = 2'd0;
    localparam PREF_REQ     = 2'd1;
    localparam PREF_WAIT    = 2'd2;
    localparam PREF_CAPTURE = 2'd3;
    reg        input_prefetch_active;
    reg        input_prefetch_done;
    reg        input_prefetch_bank;       // which bank prefetch writes
    reg [1:0]  input_prefetch_phase;
    reg [2:0]  input_prefetch_row;
    reg [6:0]  input_prefetch_col;
    reg [15:0] input_prefetch_k_base;
    reg [15:0] input_prefetch_k_tile;
    // Prefetch debug counters
    reg [15:0] input_prefetch_start_count;
    reg [15:0] input_prefetch_done_count;
    reg [15:0] input_prefetch_hit_count;
    reg [15:0] input_prefetch_stall_count;
    reg [15:0] input_prefetch_beat_count;
    reg [15:0] input_prefetch_byte_count;
    // Phase 4b: weight staging micro-sequencer (GEMM-scoped)
    localparam WGT_STAGE_IDLE    = 2'd0;
    localparam WGT_STAGE_REQ     = 2'd1;
    localparam WGT_STAGE_WAIT    = 2'd2;
    localparam WGT_STAGE_CAPTURE = 2'd3;
    reg        wgt_stage_active;
    reg        wgt_stage_done;
    reg [1:0]  wgt_stage_phase;
    reg [15:0] wgt_stage_lane_idx;   // byte index within lane (0..k_tile*n_tile-1)
    reg [15:0] wgt_stage_k_base;
    reg [15:0] wgt_stage_k_tile;
    reg [15:0] wgt_stage_n_start;
    reg [15:0] wgt_stage_n_tile;
    reg        wgt_stage_valid;
    reg [15:0] wgt_stage_valid_k_base;
    reg [15:0] wgt_stage_valid_k_tile;
    reg [15:0] wgt_stage_valid_n_start;
    reg [15:0] wgt_stage_valid_n_tile;
    reg [15:0] wgt_stage_beat_count;
    reg [15:0] wgt_stage_byte_count;
    // Phase 4b-2: background weight prefetch during RUN
    localparam WGT_PREF_IDLE    = 2'd0;
    localparam WGT_PREF_REQ     = 2'd1;
    localparam WGT_PREF_WAIT    = 2'd2;
    localparam WGT_PREF_CAPTURE = 2'd3;
    reg        wgt_pref_active;
    reg        wgt_pref_done;
    reg        wgt_pref_valid;
    reg [1:0]  wgt_pref_phase;
    reg [15:0] wgt_pref_lane_idx;
    reg [15:0] wgt_pref_k_base;
    reg [15:0] wgt_pref_k_tile;
    reg [15:0] wgt_pref_n_tile;
    reg [15:0] wgt_pref_n_base;
    reg [15:0] wgt_pref_start_count;
    reg [15:0] wgt_pref_done_count;
    reg [15:0] wgt_pref_hit_count;
    reg [15:0] wgt_pref_stall_count;
    reg [15:0] wgt_pref_beat_count;
    reg [15:0] wgt_pref_byte_count;
    // Phase 4b-2a: FSM entry debug counters
    reg [15:0] dbg_load_array_entry;
    reg [15:0] dbg_wgt_ld_entry;
    reg [15:0] dbg_dual_hit_count;
    reg [15:0] dbg_accum_to_wgtld_direct;
    reg [15:0] dbg_accum_to_load_array;
    reg [15:0] gemm_store_row_idx;
    reg [15:0] gemm_store_beat_idx;
    // Phase 3a: K-chunk streaming accumulation
    reg [15:0] gemm_stream_k_base;        // current K-chunk start offset (0, 64, 128, ...)
    reg [15:0] gemm_stream_k_chunk_idx;   // 0-based chunk index
    reg        gemm_stream_first_chunk;    // 1 during first K-chunk
    reg        gemm_stream_last_chunk;     // 1 during last K-chunk
    localparam GEMM_STREAM_FIXED_DELAY = 1;
    // Phase 5-1: M tile descriptor
    reg [15:0] gemm_tile_m_base;    // global starting row of current M tile
    reg [15:0] gemm_tile_M;         // rows in current M tile (≤ 8)
    // Phase 5-2: N tile descriptor
    reg [15:0] gemm_tile_n_base;    // global starting column of current N tile
    reg [15:0] gemm_tile_N;         // columns in current N tile (≤ 64)
    // Phase 3c: input-tile-loader micro-sequencer (GEMM-scoped, Phase 4→common)
    reg        gemm_a_load_done;     // pulsed when micro-sequencer completes
    reg [1:0]  gemm_a_load_phase;
    reg [2:0]  gemm_a_load_row;     // 0..gemm_tile_M-1
    reg [6:0]  gemm_a_load_col;     // 0..fc_chunk_inputs-1
    // Phase 4a-1: beat-level debug counters
    reg [15:0] gemm_a_load_beat_count;    // beats read in current LOAD_A
    reg [15:0] gemm_a_load_byte_count;    // bytes captured
    reg [5:0]  gemm_a_load_max_beats_per_row;  // max beats for any row
    reg [15:0] gemm_a_load_unaligned_row_count; // rows with non-zero lane_start

    wire [15:0] array_drain_offset;
    integer cluster_bus_idx;
    integer cluster_rank_i;
    integer cluster_count_i;
    integer cluster_base_i;
    integer cluster_end_i;
    integer cluster_sp_i;
    integer cluster_col_i;
    integer cluster_global_col_i;
    integer cluster_target_tile_i;
    integer cluster_target_base_i;
    integer cluster_route_col_i;
    integer arb_bus_idx;
    integer arb_rank_i;
    integer arb_count_i;
    integer arb_base_i;
    integer arb_end_i;
    integer arb_prev_i;
    integer arb_global_col_i;
    integer arb_route_col_i;
    // GEMM mode reuses FC array mapping: PE rows = K (input dim), PE cols = N (output dim)
    wire fc_or_gemm = is_fc_mode || is_gemm_mode;
    wire [15:0] active_k = fc_or_gemm ? fc_chunk_inputs : conv_kernel_area;
    wire [15:0] stream_pipe_offset = PE_ROWS_16 - active_k + GEMM_STREAM_FIXED_DELAY;
    assign array_active_rows = fc_or_gemm ? fc_chunk_inputs : conv_kernel_area;
    wire [15:0] total_global_cols;
    wire [15:0] cluster_active_cols;
    wire [15:0] collect_total_cols;
    assign total_global_cols  = output_c;
    assign cluster_active_cols = (cluster_count_i > 1 && output_c > 16'd0) ?
                                  ((output_c + cluster_count_i - 16'd1) / cluster_count_i) : output_c;
    assign array_active_cols = fc_or_gemm ? fc_tile_outputs :
                                (cluster_count_i > 1) ? cluster_active_cols : output_c;
    assign collect_total_cols = fc_or_gemm ? array_active_cols : total_global_cols;
    // Drain latency is max(PE_ROWS - active_rows, 0) plus the fixed pipeline tail.
    // Conv kernels can use more active rows than the physical PE row count.
    assign array_drain_offset = (PE_ROWS_16 > array_active_rows) ?
                                (PE_ROWS_16 - array_active_rows + 16'd5) :
                                16'd5;

    assign array_sum_in = {PE_COLS{32'h0}};
    assign array_clk_en = {N_TILES{1'b1}};
    assign cluster_weight_ld_all = {CLUSTER_COUNT{array_weight_ld}};
    assign array_sum_out = cluster_arb_out_valid ? cluster_arb_sum_out : {CLUSTER_SUM_W{1'b0}};

    always @(*) begin
        cluster_act_all_flat = {(CLUSTER_COUNT*CLUSTER_ACT_W){1'b0}};
        cluster_sum_all_flat = {(CLUSTER_COUNT*CLUSTER_SUM_W){1'b0}};
        cluster_weight_all_flat = {(CLUSTER_COUNT*CLUSTER_WGT_W){1'b0}};
        cluster_tile_clk_en_all_flat = {(CLUSTER_COUNT*CLUSTER_TILE_EN_W){1'b0}};

            cluster_count_i = (perf_cluster_count == 3'd0) ? 1 : perf_cluster_count;
            for (cluster_bus_idx = 0; cluster_bus_idx < CLUSTER_COUNT; cluster_bus_idx = cluster_bus_idx + 1) begin
            cluster_act_all_flat[cluster_bus_idx*CLUSTER_ACT_W +: CLUSTER_ACT_W] = array_act_in;
            cluster_sum_all_flat[cluster_bus_idx*CLUSTER_SUM_W +: CLUSTER_SUM_W] = array_sum_in;
            cluster_tile_clk_en_all_flat[cluster_bus_idx*CLUSTER_TILE_EN_W +: CLUSTER_TILE_EN_W] = array_clk_en;

            cluster_rank_i = 0;
            for (cluster_col_i = 0; cluster_col_i < cluster_bus_idx; cluster_col_i = cluster_col_i + 1) begin
                if (perf_cluster_enable[cluster_col_i])
                    cluster_rank_i = cluster_rank_i + 1;
            end
            cluster_base_i = (total_global_cols * cluster_rank_i) / cluster_count_i;
            cluster_end_i  = (total_global_cols * (cluster_rank_i + 1)) / cluster_count_i;

            if (perf_cluster_enable[cluster_bus_idx]) begin
                for (cluster_sp_i = 0; cluster_sp_i < PE_ROWS; cluster_sp_i = cluster_sp_i + 1) begin
                    for (cluster_col_i = 0; cluster_col_i < PE_COLS; cluster_col_i = cluster_col_i + 1) begin
                        cluster_global_col_i = cluster_base_i + cluster_col_i;
                        if ((cluster_sp_i < array_active_rows) &&
                            (cluster_global_col_i < cluster_end_i) &&
                            (cluster_global_col_i < total_global_cols)) begin
                            cluster_target_tile_i = (cluster_sp_i / 4) * TILE_COLS + (cluster_col_i / 4);
                            cluster_target_base_i = cluster_target_tile_i * 128 +
                                                    (cluster_sp_i % 4) * 32 +
                                                    (cluster_col_i % 4) * 8;
                            cluster_weight_all_flat[cluster_bus_idx*CLUSTER_WGT_W + cluster_target_base_i +: 8] =
                                wgt_load_reg[(cluster_sp_i * PE_COLS + cluster_global_col_i) * 8 +: 8];
                        end
                    end
                end
            end
        end
    end

    always @(*) begin
        cluster_routed_sum_out_all_flat = {(CLUSTER_COUNT*CLUSTER_SUM_W){1'b0}};
        cluster_arb_valid = {CLUSTER_COUNT{1'b0}};
        arb_count_i = (perf_cluster_count == 3'd0) ? 1 : perf_cluster_count;
        arb_route_col_i = 0;
        cluster_route_col_i = 0;

        // Phase 2b-1: streaming output routing
        if (gemm_row_streaming_en && (fsm_state == FSM_GEMM_STREAM_RUN)) begin
            if (perf_cluster_enable[0]) begin
                integer s_col;
                for (s_col = 0; s_col < PE_COLS; s_col = s_col + 1) begin
                    if (s_col < array_active_cols) begin
                        cluster_arb_valid[0] = 1'b1;
                        cluster_routed_sum_out_all_flat[s_col*32 +: 32] =
                            cluster_sum_out_all_flat[s_col*32 +: 32];
                    end
                end
            end
        end else if (compute_fsm_active && (comp_sub_state == CP_DRAIN) &&
            (comp_drain_cnt >= array_drain_offset)) begin
            arb_route_col_i = comp_drain_cnt - array_drain_offset;
            cluster_route_col_i = arb_route_col_i;
            if ((arb_count_i == 1) && perf_cluster_enable[0]) begin
                if ((arb_route_col_i < array_active_cols) &&
                    (arb_route_col_i < PE_COLS)) begin
                    cluster_arb_valid[0] = 1'b1;
                    cluster_routed_sum_out_all_flat[arb_route_col_i*32 +: 32] =
                        cluster_sum_out_all_flat[arb_route_col_i*32 +: 32];
                end
            end else begin
                for (arb_bus_idx = 0; arb_bus_idx < CLUSTER_COUNT; arb_bus_idx = arb_bus_idx + 1) begin
                    arb_rank_i = 0;
                    for (arb_prev_i = 0; arb_prev_i < arb_bus_idx; arb_prev_i = arb_prev_i + 1) begin
                        if (perf_cluster_enable[arb_prev_i])
                            arb_rank_i = arb_rank_i + 1;
                    end
                    arb_base_i = (total_global_cols * arb_rank_i) / arb_count_i;
                    arb_end_i  = (total_global_cols * (arb_rank_i + 1)) / arb_count_i;
                    arb_global_col_i = arb_base_i + arb_route_col_i;
                    if (perf_cluster_enable[arb_bus_idx] &&
                        (arb_global_col_i < arb_end_i) &&
                        (arb_global_col_i < total_global_cols) &&
                        (arb_route_col_i < PE_COLS)) begin
                        cluster_arb_valid[arb_bus_idx] = 1'b1;
                        cluster_routed_sum_out_all_flat[
                            arb_bus_idx*CLUSTER_SUM_W + arb_global_col_i*32 +: 32
                        ] = cluster_sum_out_all_flat[
                            arb_bus_idx*CLUSTER_SUM_W + arb_route_col_i*32 +: 32
                        ];
                    end
                end
            end
        end
    end

    cluster_scheduler #(.CLUSTER_COUNT(CLUSTER_COUNT)) u_cluster_scheduler (
        .cluster_mode(cluster_mode_cfg),
        .cluster_mask_req(cluster_mask_cfg[CLUSTER_COUNT-1:0]),
        .cluster_enable(perf_cluster_enable),
        .cluster_count(perf_cluster_count),
        .schedule_valid(perf_schedule_valid)
    );

    compute_core #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .TILE_ROWS(TILE_ROWS),
        .TILE_COLS(TILE_COLS)
    ) u_compute_core (
        .clk(clk), .rst_n(rst_n),
        .start(array_weight_ld),
        .cluster_enable(perf_cluster_enable),
        .cluster_act_in_flat(cluster_act_all_flat),
        .cluster_sum_in_flat(cluster_sum_all_flat),
        .cluster_weight_flat(cluster_weight_all_flat),
        .cluster_weight_ld(cluster_weight_ld_all),
        .cluster_tile_clk_en_flat(cluster_tile_clk_en_all_flat),
        .cluster_sum_out_flat(cluster_sum_out_all_flat),
        .cluster_busy(cluster_busy),
        .cluster_valid(cluster_valid),
        .cluster_done(cluster_done),
        .any_cluster_busy(any_cluster_busy),
        .all_enabled_done(all_enabled_done),
        .continuous_mode(gemm_row_streaming_en && (fsm_state == FSM_GEMM_STREAM_RUN)),
        .stream_active(gemm_row_streaming_en && stream_active)
    );

    output_arbiter #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CLUSTER_OUT_W(CLUSTER_SUM_W),
        .AGGREGATE_MODE(1)
    ) u_output_arbiter (
        .clk(clk), .rst_n(rst_n),
        .cluster_enable(perf_cluster_enable),
        .cluster_valid(cluster_arb_valid),
        .cluster_done(cluster_done),
        .cluster_sum_out_flat(cluster_routed_sum_out_all_flat),
        .arb_valid(cluster_arb_out_valid),
        .arb_ready(1'b1),
        .arb_sum_out_flat(cluster_arb_sum_out),
        .arb_cluster_id(cluster_arb_cluster_id),
        .all_done(cluster_arb_all_done)
    );

    // ============================================================
    // postproc
    // ============================================================
    wire [31:0] pp_data_in, pp_data_out;
    wire        pp_data_valid, pp_data_ready, pp_data_valid_o;
    wire        pp_start, pp_done;

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

    // Per-input-channel tracking
    reg [15:0] cin_idx;             // current input channel (0..input_c-1)
    reg [15:0] cin_total;           // total input channels for this task
    reg [31:0] wgt_per_cin;         // padded byte stride per input channel

    // Per-row activation hold: latched during FEED_ACT, driven continuously
    // This allows activation to propagate through all columns (not just col 0)
    reg [7:0] act_held [0:PE_ROWS-1];

    // Accumulation: per-window column accumulator (collect one column per cycle)
    reg [15:0] acc_col_idx;         // which output column to accumulate
    reg        acc_collect_wait;     // wait for synchronous acc_buffer read
    reg        acc_collect_skip_write;
    reg [31:0] col_results [0:PE_COLS-1];  // latched array column results
    reg                 rq_acc_wr_en_r;
    reg [BUF_ADDR_W-1:0] rq_acc_wr_addr_r;
    reg [31:0]          rq_acc_wr_data_r;
    reg [31:0]          rq_src_idx;
    reg [31:0]          rq_total_words;
    reg [1:0]           rq_pack_idx;
    reg [31:0]          rq_pack_word;
    reg [31:0]          rq_store_addr;
    reg [31:0]          rq_store_bytes;
    reg                 rq_src_wait;
    reg                 rq_mode_internal;
    reg                 rq_word_store_mode;
    wire                rq_internal_write_phase =
        ((fsm_state == FSM_REQUANT_COMPUTE) || (fsm_state == FSM_REQUANT_DRAIN)) &&
        rq_mode_internal;
    reg [4:0]           bias_return_state;
    reg [31:0]          bias_load_phase;
    reg [31:0]          bias_load_words;
    reg                 bias_load_wait;
    reg signed [31:0]   bias_reg [0:PE_COLS-1];
    reg [31:0]          add_src_idx;
    reg                 add_src_wait;
    reg [1:0]           add_pack_idx;
    reg [31:0]          add_pack_word;
    reg                 add_acc_wr_en_r;
    reg [BUF_ADDR_W-1:0] add_acc_wr_addr_r;
    reg [31:0]          add_acc_wr_data_r;
    wire                add_write_phase =
        (fsm_state == FSM_ADD_COMPUTE) || (fsm_state == FSM_ADD_DRAIN);
    reg [15:0]          gap_channel_idx;
    reg [5:0]           gap_sp_idx;
    reg signed [31:0]   gap_sum;
    reg                 gap_src_wait;
    reg [1:0]           gap_pack_idx;
    reg [31:0]          gap_pack_word;
    reg                 gap_acc_wr_en_r;
    reg [BUF_ADDR_W-1:0] gap_acc_wr_addr_r;
    reg [31:0]          gap_acc_wr_data_r;

    // ============================================================
    // perf counter
    // ============================================================
    wire perf_freeze, perf_task_active;
    assign perf_conv_array_active =
        is_conv_mode &&
        compute_fsm_active &&
        ((comp_sub_state == CP_FEED_ACT) ||
         (comp_sub_state == CP_DRAIN) ||
         (comp_sub_state == CP_COLLECT));
    assign perf_conv_array_stall =
        is_conv_mode &&
        compute_fsm_active &&
        (comp_sub_state == CP_WAIT_WIN) &&
        !cf_new_window &&
        !cf_done;
    assign perf_fc_array_active =
        (is_fc_mode || is_gemm_mode) &&
        compute_fsm_active &&
        ((comp_sub_state == CP_FEED_ACT) ||
         (comp_sub_state == CP_DRAIN) ||
         (comp_sub_state == CP_COLLECT));
    assign perf_array_active_evt = perf_conv_array_active || perf_fc_array_active;
    assign perf_array_stall_evt = perf_conv_array_stall;
    assign perf_conv_window_count =
        conv_out_dim(input_h, conv_kernel_size, conv_stride, conv_same_pad) *
        conv_out_dim(input_w, conv_kernel_size, conv_stride, conv_same_pad);
    assign perf_conv_channel_work = input_c * output_c;
    assign perf_conv_mac_count = perf_conv_window_count * perf_conv_channel_work * conv_kernel_area;
    assign perf_fc_mac_count = input_bytes * output_c;
    assign perf_mac_lo = is_conv_mode ? perf_conv_mac_count[31:0] :
                         is_fc_mode   ? perf_fc_mac_count[31:0] :
                                        32'd0;
    assign perf_mac_hi = is_conv_mode ? perf_conv_mac_count[63:32] :
                         is_fc_mode   ? perf_fc_mac_count[63:32] :
                                        32'd0;
    assign perf_cluster_cfg = {24'd0, cluster_mode_cfg, perf_cluster_enable};

    perf_counter u_perf (
        .clk(clk), .rst_n(rst_n), .task_active(perf_task_active), .freeze(perf_freeze),
        .read_beat(m_axi_rvalid && m_axi_rready), .write_beat(dma_wr_valid && dma_wr_ready),
        .read_active(act_dma_busy || wgt_dma_busy), .write_active(dma_wr_busy),
        .array_active(perf_array_active_evt), .array_stall(perf_array_stall_evt),
        .cluster_active_inc(perf_array_active_evt ? perf_cluster_count : 3'd0),
        .cluster_stall_inc(perf_array_stall_evt ? perf_cluster_count : 3'd0),
        .write_data_cycle(m_axi_wvalid && m_axi_wready),
        .write_txn_active(dma_wr_txn_active),
        .ar_active(m_axi_arvalid && m_axi_arready),
        .aw_active(m_axi_awvalid && m_axi_awready),
        .b_active(m_axi_bvalid && m_axi_bready),
        .bus_active((m_axi_arvalid && m_axi_arready) || (m_axi_rvalid && m_axi_rready) ||
                    (m_axi_awvalid && m_axi_awready) || (m_axi_wvalid && m_axi_wready) ||
                    (m_axi_bvalid && m_axi_bready)),
        // Enhanced inputs
        .compute_active(perf_compute_active),
        .load_active(perf_load_active),
        .store_active(perf_store_active),
        .collect_active(perf_collect_active),
        .read_byte_cnt(perf_read_byte_cnt),
        .write_byte_cnt(perf_write_byte_cnt),
        .mac_count_valid(perf_mac_count_valid),
        .mac_count_add(perf_mac_count_add),
        .stall_act(perf_stall_act_evt),
        .stall_wgt(perf_stall_wgt_evt),
        .stall_acc(perf_stall_acc_evt),
        .stall_store(perf_stall_store_evt),
        .array_fill_drain(perf_array_fill_drain_evt),
        // Outputs
        .total_cycle_lo(perf_cycle_lo), .total_cycle_hi(perf_cycle_hi),
        .read_beat_count(perf_read_beats), .write_beat_count(perf_write_beats),
        .read_active_cycles(perf_read_active), .write_active_cycles(perf_write_active),
        .array_active_cycles(perf_array_active), .array_stall_cycles(perf_array_stall),
        .cluster_active_cycles(perf_cluster_active), .cluster_stall_cycles(perf_cluster_stall),
        .write_data_cycles(perf_write_data_cycles), .write_txn_cycles(perf_write_txn_cycles),
        .ar_handshake_cycles(perf_ar_handshake), .aw_handshake_cycles(perf_aw_handshake),
        .b_handshake_cycles(perf_b_handshake), .bus_active_cycles(perf_bus_active),
        // Enhanced outputs
        .compute_cycles(perf_compute_cycles),
        .load_cycles(perf_load_cycles),
        .store_cycles(perf_store_cycles),
        .collect_cycles(perf_collect_cycles),
        .read_valid_bytes(perf_read_valid_bytes),
        .write_valid_bytes(perf_write_valid_bytes),
        .mac_count_lo(perf_mac_count_lo),
        .mac_count_hi(perf_mac_count_hi),
        .stall_act_cycles(perf_stall_act),
        .stall_wgt_cycles(perf_stall_wgt),
        .stall_acc_cycles(perf_stall_acc),
        .stall_store_cycles(perf_stall_store),
        .array_fill_drain_cycles(perf_array_fill_drain)
    );

    wire [15:0] fc_tile_capacity_raw = ((BUF_ENTRIES * HB_BEAT_BYTES) / input_c);
    wire [15:0] fc_tile_capacity_buf = (fc_tile_capacity_raw == 16'd0) ? 16'd1 : fc_tile_capacity_raw;
    wire [15:0] fc_tile_capacity = (fc_tile_capacity_buf > PE_COLS_16) ? PE_COLS_16 : fc_tile_capacity_buf;
    wire [15:0] fc_out_remaining = output_c - fc_out_start;
    wire [15:0] fc_tile_outputs_next = (fc_out_remaining > fc_tile_capacity) ? fc_tile_capacity : fc_out_remaining;
    wire [15:0] fc_in_remaining = input_c - fc_in_base;
    wire [15:0] fc_chunk_inputs_next = (fc_in_remaining > PE_ROWS_16) ? PE_ROWS_16 : fc_in_remaining;
    wire [31:0] fc_load_byte_idx = wgt_load_phase;
    wire [31:0] fc_load_out_idx = (fc_chunk_inputs == 16'd0) ? 32'd0 : (fc_load_byte_idx / {16'd0, fc_chunk_inputs});
    wire [31:0] fc_load_row_idx = (fc_chunk_inputs == 16'd0) ? 32'd0 : (fc_load_byte_idx % {16'd0, fc_chunk_inputs});
    wire [31:0] fc_load_buf_byte_idx = fc_load_out_idx * input_c + fc_in_base + fc_load_row_idx;
    wire [31:0] fc_weight_dma_byte_idx = fc_load_buf_byte_idx + {27'd0, wgt_dma_byte_offset};
    wire [31:0] fc_next_load_byte_idx = wgt_load_phase + 32'd1;
    wire [31:0] fc_next_load_out_idx = (fc_chunk_inputs == 16'd0) ? 32'd0 : (fc_next_load_byte_idx / {16'd0, fc_chunk_inputs});
    wire [31:0] fc_next_load_row_idx = (fc_chunk_inputs == 16'd0) ? 32'd0 : (fc_next_load_byte_idx % {16'd0, fc_chunk_inputs});
    wire [31:0] fc_next_load_buf_byte_idx = fc_next_load_out_idx * input_c + fc_in_base + fc_next_load_row_idx;
    wire [31:0] fc_next_weight_dma_byte_idx = fc_next_load_buf_byte_idx + {27'd0, wgt_dma_byte_offset};
    wire [BUF_ADDR_W-1:0] fc_weight_beat_addr = fc_weight_dma_byte_idx[BUF_ADDR_W+4:5];
    wire [BUF_ADDR_W-1:0] fc_next_weight_beat_addr = fc_next_weight_dma_byte_idx[BUF_ADDR_W+4:5];
    wire [HB_BEAT_BYTE_BITS-1:0] fc_weight_byte_sel = fc_weight_dma_byte_idx[4:0];
    wire [31:0] fc_act_byte_idx = (is_gemm_mode ? (gemm_row_idx * {16'd0, input_c}) : 32'd0) + fc_in_base + comp_feed_cnt;
    wire [31:0] fc_act_rd_byte_idx =
        (fc_or_gemm && (fsm_state == FSM_WGT_LD)) ? {16'd0, fc_in_base} :
        (fc_or_gemm && (fsm_state == FSM_COMPUTE) && (comp_sub_state == CP_FEED_ACT)) ?
        (fc_act_byte_idx + 32'd1) : fc_act_byte_idx;
    wire [BUF_ADDR_W-1:0] fc_act_beat_addr = fc_act_rd_byte_idx[BUF_ADDR_W+4:5];
    wire [HB_BEAT_BYTE_BITS-1:0] fc_act_byte_sel = fc_act_byte_idx[4:0];
    // Phase 5-1: input-tile-loader address with M-tile support
    // global_m = gemm_tile_m_base + local_row
    // byte_idx = global_m * input_c + gemm_stream_k_base + col
    wire [31:0] gemm_a_load_global_m = {16'd0, gemm_tile_m_base} + {13'd0, gemm_a_load_row};
    wire [31:0] gemm_a_load_byte_idx =
        gemm_a_load_global_m * {16'd0, input_c} +
        {16'd0, gemm_stream_k_base} +
        {25'd0, gemm_a_load_col};
    wire [BUF_ADDR_W-1:0] gemm_a_load_beat_addr = gemm_a_load_byte_idx[BUF_ADDR_W+4:5];
    wire [HB_BEAT_BYTE_BITS-1:0] gemm_a_load_lane_start = gemm_a_load_byte_idx[4:0];
    // Phase 4a-3: background prefetch byte-level address computation
    wire [31:0] input_prefetch_global_m = {16'd0, gemm_tile_m_base} + {13'd0, input_prefetch_row};
    wire [31:0] input_prefetch_byte_idx =
        input_prefetch_global_m * {16'd0, input_c} +
        {16'd0, input_prefetch_k_base} +
        {25'd0, input_prefetch_col};
    wire [BUF_ADDR_W-1:0] input_prefetch_beat_addr = input_prefetch_byte_idx[BUF_ADDR_W+4:5];
    wire [4:0] input_prefetch_lane_start = input_prefetch_byte_idx[4:0];
    // Phase 4b: weight staging byte-level address computation
    // GEMM streaming: N-major iteration (all N for each K) for strided full-B read.
    // row = idx / n_tile, out = idx % n_tile → contiguous within each K row.
    // FC / legacy: N-major layout W[n][k] at byte_idx = n * K + k
    wire [31:0] wgt_stage_out_idx  = gemm_row_streaming_en ?
        ((wgt_stage_n_tile == 16'd0) ? 32'd0 : (wgt_stage_lane_idx % {16'd0, wgt_stage_n_tile})) :
        ((wgt_stage_k_tile == 16'd0) ? 32'd0 : (wgt_stage_lane_idx / {16'd0, wgt_stage_k_tile}));
    wire [31:0] wgt_stage_row_idx  = gemm_row_streaming_en ?
        ((wgt_stage_n_tile == 16'd0) ? 32'd0 : (wgt_stage_lane_idx / {16'd0, wgt_stage_n_tile})) :
        ((wgt_stage_k_tile == 16'd0) ? 32'd0 : (wgt_stage_lane_idx % {16'd0, wgt_stage_k_tile}));
    wire [31:0] wgt_stage_buf_byte_idx_fc = wgt_stage_out_idx * {16'd0, input_c}
                                           + {16'd0, wgt_stage_k_base}
                                           + wgt_stage_row_idx;
    wire [31:0] wgt_stage_buf_byte_idx_gemm = ({16'd0, wgt_stage_k_base} + wgt_stage_row_idx)
                                             * {16'd0, gemm_N_val}
                                             + {16'd0, gemm_tile_n_base}
                                             + wgt_stage_out_idx;
    wire [31:0] wgt_stage_buf_byte_idx = gemm_row_streaming_en ?
                                          wgt_stage_buf_byte_idx_gemm :
                                          wgt_stage_buf_byte_idx_fc;
    wire [31:0] wgt_stage_abs_byte_idx = wgt_stage_buf_byte_idx
                                        + {27'd0, wgt_dma_byte_offset};
    wire [BUF_ADDR_W-1:0] wgt_stage_beat_addr = wgt_stage_abs_byte_idx[BUF_ADDR_W+4:5];
    wire [4:0] wgt_stage_byte_sel = wgt_stage_abs_byte_idx[4:0];
    // Phase 5-2: background weight prefetch address (N-major for full B strided read)
    wire [31:0] wgt_pref_out_idx = (wgt_pref_n_tile == 16'd0) ? 32'd0 :
                                    (wgt_pref_lane_idx % {16'd0, wgt_pref_n_tile});
    wire [31:0] wgt_pref_row_idx = (wgt_pref_n_tile == 16'd0) ? 32'd0 :
                                    (wgt_pref_lane_idx / {16'd0, wgt_pref_n_tile});
    wire [31:0] wgt_pref_buf_byte_idx = ({16'd0, wgt_pref_k_base} + wgt_pref_row_idx)
                                        * {16'd0, gemm_N_val}
                                        + {16'd0, wgt_pref_n_base}
                                        + wgt_pref_out_idx;
    wire [31:0] wgt_pref_abs_byte_idx = wgt_pref_buf_byte_idx
                                        + {27'd0, wgt_dma_byte_offset};
    wire [BUF_ADDR_W-1:0] wgt_pref_beat_addr = wgt_pref_abs_byte_idx[BUF_ADDR_W+4:5];
    wire [4:0] wgt_pref_byte_sel = wgt_pref_abs_byte_idx[4:0];
    wire [7:0] fc_weight_byte = hb_beat_byte(wgt_rd_data, fc_weight_byte_sel);
    wire [31:0] conv_weight_dma_byte_idx = wgt_load_phase + {27'd0, wgt_dma_byte_offset};
    wire [31:0] add_byte_idx = add_src_idx;
    wire [31:0] add_next_byte_idx = add_src_idx + 32'd1;
    wire [BUF_ADDR_W-1:0] add_src_beat_addr = add_byte_idx[BUF_ADDR_W+4:5];
    wire [BUF_ADDR_W-1:0] add_next_beat_addr = add_next_byte_idx[BUF_ADDR_W+4:5];
    wire [HB_BEAT_BYTE_BITS-1:0] add_byte_sel = add_byte_idx[4:0];
    wire [31:0] gap_byte_idx = ({16'd0, gap_sp_idx} * {16'd0, input_c}) + {16'd0, gap_channel_idx};
    wire [31:0] gap_next_sp_idx = {26'd0, gap_sp_idx} + 32'd1;
    wire [31:0] gap_next_byte_idx =
        (gap_next_sp_idx * {16'd0, input_c}) + {16'd0, gap_channel_idx};
    wire [BUF_ADDR_W-1:0] gap_src_beat_addr = gap_byte_idx[BUF_ADDR_W+4:5];
    wire [BUF_ADDR_W-1:0] gap_next_beat_addr = gap_next_byte_idx[BUF_ADDR_W+4:5];
    wire [HB_BEAT_BYTE_BITS-1:0] gap_byte_sel = gap_byte_idx[4:0];
    wire [BUF_ADDR_W-1:0] rq_src_beat_addr = rq_src_idx[BUF_ADDR_W+2:3];
    wire [2:0] rq_src_word_sel = rq_src_idx[2:0];
    wire [31:0] rq_src_word = hb_beat_word(act_rd_data, rq_src_word_sel);
    wire signed [7:0] rq_q;
    wire signed [7:0] rq_bias_q;
    wire signed [7:0] rq_q_selected = rq_mode_internal ? rq_bias_q : rq_q;
    wire signed [7:0] add_src0_i8 = hb_beat_byte(act_rd_data, add_byte_sel);
    wire signed [7:0] add_src1_i8 = hb_beat_byte(wgt_rd_data, add_byte_sel);
    wire signed [7:0] add_src0_aligned;
    wire signed [7:0] add_src1_aligned;
    wire signed [31:0] add_raw_sum;
    wire signed [31:0] add_relu_sum;
    wire signed [7:0] add_q;
    wire signed [7:0] gap_sample_i8 = hb_beat_byte(act_rd_data, gap_byte_sel);
    wire signed [31:0] gap_sample_i32 = {{24{gap_sample_i8[7]}}, gap_sample_i8};
    wire signed [31:0] gap_sum_next = gap_sum + gap_sample_i32;
    wire signed [31:0] gap_avg_i32;
    wire signed [7:0] gap_q;

    requant_i32_to_i8 u_requant (
        .acc_i($signed(rq_src_word)),
        .multiplier_i(requant_multiplier),
        .shift_i(requant_shift),
        .q_o(rq_q)
    );

    wire [5:0] rq_bias_idx =
        fc_or_gemm ? rq_src_idx[5:0] :
        (output_c == 16'd0) ? 6'd0 : (rq_src_idx % {16'd0, output_c});
    wire signed [31:0] rq_bias_value = bias_reg[rq_bias_idx];
    wire signed [31:0] rq_bias_acc;

    bias_add_requant_i32_to_i8 u_bias_requant (
        .acc_i($signed(acc_rd_data)),
        .bias_i(rq_bias_value),
        .bias_en_i(bias_enabled && rq_mode_internal),
        .relu_en_i(relu_en && rq_mode_internal),
        .multiplier_i(requant_multiplier),
        .shift_i(requant_shift),
        .biased_acc_o(rq_bias_acc),
        .q_o(rq_bias_q)
    );

    residual_add_requant_i8 u_residual_add (
        .src0_i(add_src0_i8),
        .src1_i(add_src1_i8),
        .relu_en_i(add_cfg[2] || postproc_cfg_ext[0]),
        .requant_en_i(add_cfg[3] || postproc_cfg_ext[1]),
        .src0_multiplier_i(add_src0_multiplier),
        .src0_shift_i(add_src0_shift),
        .src1_multiplier_i(add_src1_multiplier),
        .src1_shift_i(add_src1_shift),
        .out_multiplier_i(add_out_multiplier),
        .out_shift_i(add_out_shift),
        .src0_aligned_o(add_src0_aligned),
        .src1_aligned_o(add_src1_aligned),
        .add_raw_o(add_raw_sum),
        .add_relu_o(add_relu_sum),
        .out_o(add_q)
    );

    gap8x8_requant_i8 u_gap8x8 (
        .sum_i(gap_sum_next),
        .avg_shift_i(gap_cfg[25:20]),
        .requant_en_i(postproc_cfg_ext[1]),
        .multiplier_i(requant_multiplier),
        .shift_i(requant_shift),
        .avg_i32_o(gap_avg_i32),
        .out_o(gap_q)
    );

    assign array_weight_ld = (fsm_state == FSM_WGT_LD);
    assign cf_start = (fsm_state == FSM_CF_START) || (fsm_state == FSM_CIN_RESTART);
    assign cf_window_hold = !(fsm_state == FSM_COMPUTE && comp_sub_state == CP_WAIT_WIN && !cf_new_window);

    // Activation feeder
    reg [31:0]           act_feed_ptr;
    reg [1:0]            act_feed_byte;
    reg                  act_feed_wait;
    reg [15:0]           act_feed_done_cnt;
    wire [BUF_ADDR_W-1:0] act_feed_beat_addr = act_feed_ptr[BUF_ADDR_W+4:5];
    wire [BUF_ADDR_W-1:0] act_pool_beat_addr = act_feed_ptr[BUF_ADDR_W+2:3];
    wire [2:0] act_pool_word_sel = act_feed_ptr[2:0];
    wire [31:0] act_pool_word = hb_beat_word(act_rd_data, act_pool_word_sel);
    wire [HB_BEAT_BYTE_BITS-1:0] act_byte_sel = fc_or_gemm ? fc_act_byte_sel : act_feed_ptr[4:0];

    assign cf_act_data  = hb_beat_byte(act_rd_data, act_byte_sel);
    assign act_rd_bank  = act_comp_bank;

    assign act_rd_addr  = (fsm_state == FSM_GEMM_STREAM_LOAD_A) ? gemm_a_load_beat_addr :
                          (input_prefetch_active && (input_prefetch_phase != PREF_IDLE)) ? input_prefetch_beat_addr :
                          is_pool_mode    ? act_pool_beat_addr :
                          fc_or_gemm      ? fc_act_beat_addr :
                          is_add_mode     ? add_src_beat_addr :
                          is_gap_mode     ? gap_src_beat_addr :
                          is_requant_mode ? rq_src_beat_addr :
                          is_vec_relu_mode? vec_relu_rd_addr :
                                            act_feed_beat_addr;

    // Feed activations during WAIT_WIN (conv_frontend consumes them)
    assign cf_act_valid = is_conv_mode && (fsm_state == FSM_COMPUTE) && (comp_sub_state == CP_WAIT_WIN) &&
                          !act_feed_wait && !cf_done && (act_feed_done_cnt < blk_in_bytes[15:0]);

    // Weight buffer read
    wire [BUF_ADDR_W-1:0] wgt_mac_addr;
    wire [31:0] fc_wgt_dma_base = blk_wgt_addr + fc_out_start * input_c;
    // P1: preload next-tile weight base with correct byte alignment
    wire [31:0] fc_preload_wgt_base = blk_wgt_addr + (fc_out_start + fc_tile_outputs) * input_c;
    // P1: combinational preload tile outputs (must be wire — used in same cycle as trigger)
    wire [15:0] fc_preload_out_remaining = output_c - (fc_out_start + fc_tile_outputs);
    wire [15:0] fc_preload_tile_outputs_next = (fc_preload_out_remaining > fc_tile_capacity) ?
                                                fc_tile_capacity : fc_preload_out_remaining;
    wire [31:0] conv_wgt_dma_base = blk_wgt_addr + cin_idx * wgt_per_cin;
    wire [31:0] conv_next_wgt_dma_base = blk_wgt_addr + (cin_idx + 16'd1) * wgt_per_cin;
    wire [31:0] conv_wgt_valid_bytes = {16'd0, conv_kernel_area} * output_c;
    wire [31:0] bias_dma_base = fc_or_gemm ? (bias_addr + fc_out_start * 32'd4) : bias_addr;
    wire [31:0] bias_byte_idx = (bias_load_phase << 2) + {27'd0, wgt_dma_byte_offset};
    wire [31:0] bias_next_byte_idx = bias_byte_idx + 32'd4;
    wire [BUF_ADDR_W-1:0] bias_beat_addr = bias_byte_idx[BUF_ADDR_W+4:5];
    wire [BUF_ADDR_W-1:0] bias_next_beat_addr = bias_next_byte_idx[BUF_ADDR_W+4:5];
    wire [2:0] bias_word_sel = bias_byte_idx[4:2];
    wire [31:0] bias_word = hb_beat_word(wgt_rd_data, bias_word_sel);
    wire [BUF_ADDR_W-1:0] rq_acc_rd_addr = rq_src_idx[BUF_ADDR_W-1:0];

    // Phase 2: shadow-load buffer address (during FC compute)
    wire [31:0] fc_shadow_out_idx_w = (fc_shadow_chunk_inputs == 16'd0) ? 32'd0 :
                                       (fc_shadow_phase / {16'd0, fc_shadow_chunk_inputs});
    wire [31:0] fc_shadow_row_idx_w = (fc_shadow_chunk_inputs == 16'd0) ? 32'd0 :
                                       (fc_shadow_phase % {16'd0, fc_shadow_chunk_inputs});
    wire [31:0] fc_shadow_buf_byte_idx = fc_shadow_out_idx_w * {16'd0, input_c} +
                                          {16'd0, fc_shadow_in_base} + fc_shadow_row_idx_w;
    wire [31:0] fc_shadow_dma_byte_idx = fc_shadow_buf_byte_idx + {27'd0, wgt_dma_byte_offset};
    wire [BUF_ADDR_W-1:0] fc_shadow_beat_addr = fc_shadow_dma_byte_idx[BUF_ADDR_W+4:5];

    assign wgt_rd_addr  = (gemm_row_streaming_en && (fsm_state == FSM_LOAD_ARRAY) && wgt_stage_active) ? wgt_stage_beat_addr :
                          (gemm_row_streaming_en && (fsm_state == FSM_GEMM_STREAM_RUN) && wgt_pref_active && (wgt_pref_phase != WGT_PREF_IDLE)) ? wgt_pref_beat_addr :
                          (fsm_state == FSM_BIAS_EXTRACT) ? bias_beat_addr :
                          (fsm_state == FSM_ADD_COMPUTE) ? add_src_beat_addr :
                          (is_fc_mode && (fsm_state == FSM_LOAD_ARRAY)) ? fc_weight_beat_addr :
                          (fc_shadow_active) ? fc_shadow_beat_addr :
                          wgt_mac_addr;
    assign wgt_rd_bank  = wgt_consume_bank;

    // ============================================================
    // Weight → array mapping (registered, multi-cycle loading)
    // Up to 25*C_out weights loaded per input channel
    // ============================================================
    // wgt_load_reg: sized for full PE array (PE_ROWS x PE_COLS)
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
            assign array_weight[WB_FLAT_BASE +: 8] =
                (WB_GLOBAL_ROW < array_active_rows) ?
                wgt_load_reg[(WB_GLOBAL_ROW * PE_COLS + WB_GLOBAL_COL)*8 +: 8] :
                8'd0;
        end
    endgenerate

    // ============================================================
    // array_act_in: skewed activation feeding with per-row hold
    // During the feeding cycle for row r: drive cf_window[r] directly (combinational)
    // After feeding: drive held value (registered) for column propagation
    // ============================================================
    wire act_feed_en = compute_fsm_active && (comp_sub_state == CP_FEED_ACT);
    wire stream_drive = gemm_row_streaming_en && (fsm_state == FSM_GEMM_STREAM_RUN);
    genvar ai;
    generate
        for (ai = 0; ai < PE_ROWS; ai = ai + 1) begin : act_map
            wire row_active = (ai < array_active_rows);
            wire [7:0] conv_row_feed_val;
            if (ai < KERNEL_SPATIAL) begin : conv_row_active
                assign conv_row_feed_val = cf_window[ai];
            end else begin : conv_row_inactive
                assign conv_row_feed_val = 8'd0;
            end
            wire [7:0] row_feed_val = fc_or_gemm ? cf_act_data : conv_row_feed_val;
            wire array_act_drive = (comp_sub_state == CP_FEED_ACT) || (comp_sub_state == CP_DRAIN);
            // Phase 2b-1: stream skewed activation with row_active gate
            wire signed [31:0] s_m = $signed({16'd0, stream_cycle}) - $signed({26'd0, ai[5:0]});
            wire [7:0] s_act_b0 = input_tile_bank0[s_m[2:0]][ai[5:0]];
            wire [7:0] s_act_b1 = input_tile_bank1[s_m[2:0]][ai[5:0]];
            wire [7:0] s_act = (row_active && !s_m[31] && s_m < gemm_tile_M) ?
                                (input_compute_bank ? s_act_b1 : s_act_b0) : 8'd0;
            assign array_act_in[ai*8 +: 8] =
                stream_drive ? s_act :
                row_active && (is_conv_mode || is_fc_mode || is_gemm_mode) && array_act_drive ?
                ((act_feed_en && comp_feed_cnt == ai) ? row_feed_val : act_held[ai]) :
                8'd0;
        end
    endgenerate

    // Latch per-row activations during FEED_ACT (skewed feeding)
    // Clear on restart to prevent stale values from previous c_in iteration
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            integer ri;
            for (ri = 0; ri < PE_ROWS; ri = ri + 1)
                act_held[ri] <= 8'd0;
        end else if ((fsm_state == FSM_CIN_RESTART) || (fsm_state == FSM_FC_TILE_PREP) ||
                     (fc_or_gemm && fsm_state == FSM_LOAD_ARRAY && wgt_load_phase == 32'd0)) begin
            integer ri;
            for (ri = 0; ri < PE_ROWS; ri = ri + 1)
                act_held[ri] <= 8'd0;
        end else if (act_feed_en) begin
            if ({9'd0, comp_feed_cnt} < array_active_rows) begin
                if (fc_or_gemm)
                    act_held[comp_feed_cnt] <= cf_act_data;
                else
                    act_held[comp_feed_cnt] <= cf_window[comp_feed_cnt];
            end
        end
    end

    // ============================================================
    // postproc connection
    // ============================================================
    reg [31:0] pp_result;

    assign pp_data_in   = is_pool_mode ? act_pool_word : pp_result;
    // Conv: write directly to acc_buffer via acc_partial (bypass postproc)
    // Pool: feed postproc; FC: feed postproc (for ReLU after FC1)
    assign pp_data_valid = is_conv_mode ? 1'b0 :
                           is_pool_mode ? ((fsm_state == FSM_COMPUTE) && (comp_sub_state == CP_WAIT_WIN) &&
                                           !act_feed_wait && !pp_start && (act_feed_done_cnt < blk_in_bytes[15:0])) :
                           (compute_fsm_active && (comp_sub_state == CP_COLLECT));
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
    reg [31:0]           conv_collect_base_next;
    assign acc_wr_addr = (compute_fsm_active &&
                         ((comp_sub_state == CP_COLLECT) || (comp_sub_state == CP_DRAIN)))
                         ? acc_partial_addr
                         : add_write_phase
                         ? add_acc_wr_addr_r
                         : gap_acc_wr_en_r
                         ? gap_acc_wr_addr_r
                         : (rq_internal_write_phase || is_requant_mode)
                         ? rq_acc_wr_addr_r
                         : acc_wr_ptr;
    wire array_first_accum = fc_or_gemm ? (fc_in_base == 16'd0) : (cin_idx == 16'd0);
    wire array_final_accum = fc_or_gemm ? (fc_in_base + fc_chunk_inputs >= input_c) :
                                         (cin_idx + 16'd1 >= cin_total);
    wire [31:0] array_acc_sum =
        array_first_accum ? col_results[acc_col_idx] : (acc_rd_data + col_results[acc_col_idx]);
    wire array_relu_final = relu_en && !bias_enabled && array_final_accum && array_acc_sum[31];
    wire [31:0] array_acc_wr_data = array_relu_final ? 32'd0 : array_acc_sum;
    assign acc_wr_data = add_write_phase ? add_acc_wr_data_r :
                         gap_acc_wr_en_r ? gap_acc_wr_data_r :
                         rq_internal_write_phase ? rq_acc_wr_data_r :
                         (is_conv_mode || is_fc_mode || is_gemm_mode) ? array_acc_wr_data :
                         is_requant_mode ? rq_acc_wr_data_r :
                                           pp_data_out;
    // P0 FIX: During CP_DRAIN, only enable accumulator writes AFTER drain_offset
    // (i.e., when COLLECT has been properly initialized).  Before drain_offset,
    // acc_col_idx is stale (from previous chunk) and acc_partial_addr may not
    // be set correctly, causing spurious writes that corrupt partial sums.
    wire drain_collect_active = (comp_sub_state == CP_DRAIN)
        ? (comp_drain_cnt >= array_drain_offset) : 1'b1;
    assign acc_wr_en   = add_write_phase ? add_acc_wr_en_r :
        gap_acc_wr_en_r ? gap_acc_wr_en_r :
        rq_internal_write_phase ? rq_acc_wr_en_r :
        (is_conv_mode || is_fc_mode || is_gemm_mode)
        ? (compute_fsm_active &&
           ((comp_sub_state == CP_COLLECT) || (comp_sub_state == CP_DRAIN)) &&
           !acc_collect_wait && !acc_collect_skip_write && drain_collect_active &&
           (!is_conv_mode || ((comp_win_idx < comp_total_wins) &&
                              (acc_col_idx < collect_total_cols))))
        : is_requant_mode ? rq_acc_wr_en_r
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
        .conv_cfg(conv_cfg),
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
        else if (fsm_state == FSM_FC_TILE_PREP)
            acc_wr_ptr <= 0;
        else if (acc_wr_en)
            acc_wr_ptr <= acc_wr_ptr + 1;
    end

    // DMA writer: stream from acc_buffer during STORE
    // During CP_COLLECT: read the current column's old partial sum.
    // Pipelined store states (P5: 1 word/cycle sustained)
    localparam SP_IDLE    = 2'd0;  // idle / waiting for store to start
    localparam SP_FIRST   = 2'd1;  // first read issued, data not yet valid
    localparam SP_STREAM  = 2'd2;  // data valid every cycle, issue next read
    localparam SP_PUSH    = 2'd3;  // beat assembled, push to FIFO

    reg [BUF_ADDR_W-1:0] dma_rd_ptr;
    reg [BUF_ADDR_W-1:0] store_rd_prefetch;  // P5: prefetch pointer (1 ahead of dma_rd_ptr for pipelined reads)
    reg [1:0] store_pack_state;

    // ============================================================
    // Enhanced performance counter event signals
    // (placed here because they reference registers declared above)
    // ============================================================

    // --- Enhanced phase-level activity signals ---
    assign perf_compute_active = compute_fsm_active;
    assign perf_load_active = (fsm_state == FSM_LOAD_ACT) || (fsm_state == FSM_CF_START) ||
        (fsm_state == FSM_PRE_COMP) || (fsm_state == FSM_CIN_START) ||
        (fsm_state == FSM_CIN_LOAD_WGT) || (fsm_state == FSM_CIN_LOAD_DONE) ||
        (fsm_state == FSM_LOAD_ARRAY) || (fsm_state == FSM_WGT_LD) ||
        (fsm_state == FSM_TASK_SETUP) || (fsm_state == FSM_LOAD_BIAS) ||
        (fsm_state == FSM_BIAS_WAIT) || (fsm_state == FSM_BIAS_EXTRACT) ||
        (fsm_state == FSM_LOAD_ADD_SRC1) || (fsm_state == FSM_ADD_SRC1_WAIT) ||
        (fsm_state == FSM_FC_TILE_PREP) || (fsm_state == FSM_FC_LOAD_WGT) ||
        (fsm_state == FSM_FC_LOAD_WAIT) || (fsm_state == FSM_CIN_RESTART);
    assign perf_store_active = (fsm_state == FSM_STORE) || (pipe_mode && fsm_state == FSM_PIPE_RUN);
    assign perf_collect_active = compute_fsm_active && (comp_sub_state == CP_COLLECT);

    // --- Read/Write valid byte counts ---
    assign perf_read_byte_cnt = 6'd32;  // all read beats are full 256-bit (32 bytes)
    wire [5:0] wstrb_popcount;
    assign wstrb_popcount =
        {5'd0, m_axi_wstrb[0]}  + {5'd0, m_axi_wstrb[1]}  +
        {5'd0, m_axi_wstrb[2]}  + {5'd0, m_axi_wstrb[3]}  +
        {5'd0, m_axi_wstrb[4]}  + {5'd0, m_axi_wstrb[5]}  +
        {5'd0, m_axi_wstrb[6]}  + {5'd0, m_axi_wstrb[7]}  +
        {5'd0, m_axi_wstrb[8]}  + {5'd0, m_axi_wstrb[9]}  +
        {5'd0, m_axi_wstrb[10]} + {5'd0, m_axi_wstrb[11]} +
        {5'd0, m_axi_wstrb[12]} + {5'd0, m_axi_wstrb[13]} +
        {5'd0, m_axi_wstrb[14]} + {5'd0, m_axi_wstrb[15]} +
        {5'd0, m_axi_wstrb[16]} + {5'd0, m_axi_wstrb[17]} +
        {5'd0, m_axi_wstrb[18]} + {5'd0, m_axi_wstrb[19]} +
        {5'd0, m_axi_wstrb[20]} + {5'd0, m_axi_wstrb[21]} +
        {5'd0, m_axi_wstrb[22]} + {5'd0, m_axi_wstrb[23]} +
        {5'd0, m_axi_wstrb[24]} + {5'd0, m_axi_wstrb[25]} +
        {5'd0, m_axi_wstrb[26]} + {5'd0, m_axi_wstrb[27]} +
        {5'd0, m_axi_wstrb[28]} + {5'd0, m_axi_wstrb[29]} +
        {5'd0, m_axi_wstrb[30]} + {5'd0, m_axi_wstrb[31]};
    assign perf_write_byte_cnt = (m_axi_wvalid && m_axi_wready) ? wstrb_popcount : 6'd0;

    // --- MAC count: count actual MAC operations per cycle ---
    wire mac_event = compute_fsm_active && (comp_sub_state == CP_DRAIN) &&
        cluster_arb_out_valid &&
        (comp_drain_cnt >= array_drain_offset) &&
        (comp_drain_cnt < array_drain_offset + array_active_cols);
    // Each drain cycle: all active PE columns produce results simultaneously.
    // Total MAC per drain cycle = active_rows × active_cols (all active PEs).
    wire [15:0] macs_per_drain_event = array_active_rows * array_active_cols;
    assign perf_mac_count_valid = mac_event;
    assign perf_mac_count_add = macs_per_drain_event;

    // --- Compute stall breakdown ---
    assign perf_stall_act_evt = is_conv_mode && compute_fsm_active &&
        (comp_sub_state == CP_WAIT_WIN) && !cf_new_window && !cf_done;
    assign perf_stall_wgt_evt = (fsm_state == FSM_CIN_LOAD_WGT) ||
        (fsm_state == FSM_CIN_LOAD_DONE) || (fsm_state == FSM_LOAD_ARRAY) ||
        (fsm_state == FSM_FC_LOAD_WGT) || (fsm_state == FSM_FC_LOAD_WAIT);
    assign perf_stall_acc_evt = compute_fsm_active && acc_collect_wait;
    assign perf_stall_store_evt = ((fsm_state == FSM_STORE) || pipe_mode) &&
        (store_pack_state == SP_PUSH) && wf_wr_full;

    // --- Array fill/drain ---
    assign perf_array_fill_drain_evt = compute_fsm_active &&
        ((comp_sub_state == CP_FEED_ACT) ||
         ((comp_sub_state == CP_DRAIN) && (comp_drain_cnt < array_drain_offset)));

    // ============================================================
    reg [2:0] store_pack_lane;
    reg [31:0] store_word_idx;
    reg [AXI_DMA_DATA_W-1:0] store_pack_data;
    reg [AXI_DMA_DATA_W-1:0] dma_wr_data_r;
    reg dma_wr_valid_r;

    // P3: COLLECT acc read during FSM_PIPE_RUN — reads from load_bank (new compute)
    // while store reads from comp_bank (old compute results).
    wire pipe_coll_acc_rd = (fsm_state == FSM_PIPE_RUN) &&
        ((comp_sub_state == CP_DRAIN && comp_drain_cnt > array_drain_offset && acc_collect_wait) ||
         (comp_sub_state == CP_COLLECT && acc_collect_wait));

    // P5: During store, use prefetch pointer for pipelined acc_buffer reads.
    // dma_rd_ptr is the "data valid" index (what's currently on acc_rd_data),
    // store_rd_prefetch is the "next read" index (issued to buffer).
    wire [BUF_ADDR_W-1:0] store_rd_addr;
    assign store_rd_addr = ((fsm_state == FSM_STORE || pipe_mode) &&
                            (store_pack_state == SP_FIRST || store_pack_state == SP_STREAM))
                           ? store_rd_prefetch : dma_rd_ptr;
    assign acc_rd_addr = ((fsm_state == FSM_REQUANT_COMPUTE) && rq_mode_internal)
                         ? rq_acc_rd_addr
                         : (compute_fsm_active &&
                            ((comp_sub_state == CP_COLLECT) || (comp_sub_state == CP_DRAIN)))
                         ? acc_partial_addr
                         : store_rd_addr;
    // P3: During COMPUTE (COLLECT/DRAIN) including PIPE_RUN, COLLECT reads from load_bank.
    // During STORE (and PIPE_RUN store), reads from comp_bank (previous compute's results).
    assign acc_rd_bank = pipe_coll_acc_rd ? acc_load_bank :
                         (fsm_state == FSM_STORE || fsm_state == FSM_PIPE_RUN) ? acc_comp_bank :
                         acc_load_bank;
    assign dma_wr_data  = wf_rd_data;
    assign dma_wr_valid = wf_rd_valid;
    assign wf_rd_en     = dma_wr_ready && wf_rd_valid;
    write_beat_fifo #(64) u_wfifo (
        .clk,.rst_n,.wr_data(dma_wr_data_r),.wr_strb({32{1'b1}}),.wr_last(1'b0),
        .wr_en(dma_wr_valid_r),.wr_full(wf_wr_full),
        .rd_data(wf_rd_data),.rd_strb(wf_rd_strb),.rd_last(wf_rd_last),
        .rd_valid(wf_rd_valid),.rd_en(wf_rd_en),.rd_empty(wf_rd_empty),
        .rd_level(wf_rd_level)
    );
    wire [31:0] store_bytes_active = rq_mode_internal ? rq_store_bytes :
                                     is_add_mode ? output_bytes :
                                     is_gap_mode ? output_bytes :
                                     fc_or_gemm ? fc_store_bytes :
                                     is_requant_mode ? rq_store_bytes :
                                                       blk_out_bytes;
    wire [31:0] store_words_active = (store_bytes_active + 32'd3) >> 2;

    // producer_done: asserted when producer finishes producing all data for the
    // current phase. The DMA writer uses this to avoid hanging in S_WAIT_DATA
    // when the remaining FIFO data is less than the calculated burst size.
    // Covered: store_pack (all task types), vec_relu streaming path.
    assign dma_producer_done = (((fsm_state == FSM_STORE) || (fsm_state == FSM_PIPE_RUN) || pipe_mode) &&
                                 (store_pack_state == SP_IDLE) &&
                                 dma_wr_started &&
                                 (store_word_idx >= store_words_active)) ||
                               ((fsm_state == FSM_VEC_RELU_PROC) &&
                                 dma_wr_started &&
                                 vec_relu_read_done &&
                                 vec_relu_proc_done);

    // ============================================================
    // 32-lane INT8 ReLU: combinational vector postprocess
    // For each byte lane: if signed bit[7]=1 (negative), output 0; else pass through
    // Input: act_rd_data (256-bit beat from act_buffer, Phase B read)
    // ============================================================
    genvar vl;
    generate
        for (vl = 0; vl < 32; vl = vl + 1) begin : gen_vec_relu
            wire signed [7:0] vl_in = act_rd_data[vl*8 +: 8];
            assign vec_relu_result[vl*8 +: 8] = vl_in[7] ? 8'h00 : vl_in;
        end
    endgenerate

    wire [AXI_DMA_DATA_W-1:0] store_lane_word =
        {{(AXI_DMA_DATA_W-ACC_DATA_W){1'b0}}, acc_rd_data} << (store_pack_lane * ACC_DATA_W);
    wire [AXI_DMA_DATA_W-1:0] store_pack_data_next = store_pack_data | store_lane_word;

    // perf control
    reg task_active_r;
    assign perf_task_active = task_active_r;
    assign perf_freeze = (fsm_state == FSM_DONE) || (fsm_state == FSM_ERROR);

    // === DEBUG: vec_relu counters ===
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_fifo_pop_count <= 32'd0;
            dbg_w_hs_count <= 32'd0;
            dbg_rd_issue_count <= 32'd0;
            dbg_rd_data_count <= 32'd0;
            dbg_fifo_full_stall <= 32'd0;
            dbg_cycle_cnt <= 32'd0;
        end else if (task_active_r && is_vec_relu_mode) begin
            if (wf_rd_en)
                dbg_fifo_pop_count <= dbg_fifo_pop_count + 32'd1;
            if (m_axi_wvalid && m_axi_wready)
                dbg_w_hs_count <= dbg_w_hs_count + 32'd1;
            // AR handshakes: count DMA read bursts issued
            if (m_axi_arvalid && m_axi_arready)
                dbg_rd_issue_count <= dbg_rd_issue_count + 32'd1;
            // R handshakes: count actual AXI read data beats
            if (m_axi_rvalid && m_axi_rready)
                dbg_rd_data_count <= dbg_rd_data_count + 32'd1;
            // Phase B stall: push blocked because write_beat_fifo is full
            if (wf_wr_full && vec_relu_proc_active && !vec_relu_proc_done)
                dbg_fifo_full_stall <= dbg_fifo_full_stall + 32'd1;
            dbg_cycle_cnt <= dbg_cycle_cnt + 32'd1;
        end
    end

    // ============================================================
    // Main FSM — sequential
    // ============================================================
    reg        task_done_r, task_error_r;
    reg [7:0]  task_error_code_r;

    // ============================================================
    // Phase 4a-3: background input tile prefetch micro-sequencer.
    // Runs during FSM_GEMM_STREAM_RUN to load next chunk's A tile
    // into the inactive bank while compute reads the active bank.
    // Independent of foreground LOAD_A micro-sequencer.
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_prefetch_active <= 1'b0;
            input_prefetch_done  <= 1'b0;
            input_prefetch_bank  <= 1'b0;
            input_prefetch_phase <= PREF_IDLE;
            input_prefetch_row   <= 3'd0;
            input_prefetch_col   <= 7'd0;
            input_prefetch_k_base <= 16'd0;
            input_prefetch_k_tile <= 16'd0;
        end else if (input_prefetch_active) begin
            case (input_prefetch_phase)
                PREF_IDLE: begin
                    input_prefetch_row   <= 3'd0;
                    input_prefetch_col   <= 7'd0;
                    input_prefetch_phase <= PREF_REQ;
                end
                PREF_REQ: begin
                    input_prefetch_phase <= PREF_WAIT;
                end
                PREF_WAIT: begin
                    input_prefetch_phase <= PREF_CAPTURE;
                end
                PREF_CAPTURE: begin
                    // Beat-level bulk unpack into prefetch bank
                    integer rem_v;
                    integer btb_v;
                    integer lane;
                    integer ls_v;
                    ls_v  = input_prefetch_lane_start;
                    rem_v = input_prefetch_k_tile - input_prefetch_col;
                    btb_v = (rem_v < (32 - ls_v)) ? rem_v : (32 - ls_v);
                    // Write bytes to prefetch bank
                    if (input_prefetch_bank == 1'b0) begin
                        for (lane = 0; lane < 32; lane = lane + 1) begin
                            if ((lane >= ls_v) && ((lane - ls_v) < btb_v)) begin
                                input_tile_bank0[input_prefetch_row]
                                    [input_prefetch_col + (lane - ls_v)]
                                    <= act_rd_data[lane * 8 +: 8];
                            end
                        end
                    end else begin
                        for (lane = 0; lane < 32; lane = lane + 1) begin
                            if ((lane >= ls_v) && ((lane - ls_v) < btb_v)) begin
                                input_tile_bank1[input_prefetch_row]
                                    [input_prefetch_col + (lane - ls_v)]
                                    <= act_rd_data[lane * 8 +: 8];
                            end
                        end
                    end
                    input_prefetch_beat_count <= input_prefetch_beat_count + 16'd1;
                    input_prefetch_byte_count <= input_prefetch_byte_count
                        + {10'd0, btb_v[5:0]};
                    // Advance
                    if (input_prefetch_col + btb_v >= input_prefetch_k_tile) begin
                        // Row done: zero-fill
                        if (input_prefetch_bank == 1'b0) begin
                            for (lane = input_prefetch_k_tile; lane < 64; lane = lane + 1)
                                input_tile_bank0[input_prefetch_row][lane] <= 8'd0;
                        end else begin
                            for (lane = input_prefetch_k_tile; lane < 64; lane = lane + 1)
                                input_tile_bank1[input_prefetch_row][lane] <= 8'd0;
                        end
                        if (input_prefetch_row + 3'd1 < gemm_tile_M) begin
                            input_prefetch_row   <= input_prefetch_row + 3'd1;
                            input_prefetch_col   <= 7'd0;
                            input_prefetch_phase <= PREF_REQ;
                        end else begin
                            // All rows done — mark bank valid
                            if (input_prefetch_bank == 1'b0) begin
                                input_bank0_valid  <= 1'b1;
                                input_bank0_k_base <= input_prefetch_k_base;
                                input_bank0_k_tile <= input_prefetch_k_tile;
                            end else begin
                                input_bank1_valid  <= 1'b1;
                                input_bank1_k_base <= input_prefetch_k_base;
                                input_bank1_k_tile <= input_prefetch_k_tile;
                            end
                            input_prefetch_done  <= 1'b1;
                            input_prefetch_active <= 1'b0;
                            input_prefetch_phase  <= PREF_IDLE;
                            input_prefetch_done_count <= input_prefetch_done_count + 16'd1;
                            $display("[PREFETCH] DONE bank=%0d k_base=%0d k_tile=%0d beats=%0d bytes=%0d",
                                input_prefetch_bank, input_prefetch_k_base,
                                input_prefetch_k_tile,
                                input_prefetch_beat_count, input_prefetch_byte_count);
                        end
                    end else begin
                        input_prefetch_col   <= input_prefetch_col
                            + {1'd0, btb_v[5:0]};
                        input_prefetch_phase <= PREF_REQ;
                    end
                end
                default: input_prefetch_phase <= PREF_IDLE;
            endcase
        end else begin
            input_prefetch_phase <= PREF_IDLE;
        end
    end

    // ============================================================
    // Phase 4b-2: background weight prefetch micro-sequencer.
    // Runs during FSM_GEMM_STREAM_RUN, reads next chunk's B weights
    // from wgt_buffer and writes them into wgt_load_reg.
    // Uses K-major compact B layout: (k_base+kk)*N_tile + n.
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wgt_pref_active  <= 1'b0;
            wgt_pref_done    <= 1'b0;
            wgt_pref_valid   <= 1'b0;
            wgt_pref_phase   <= WGT_PREF_IDLE;
            wgt_pref_lane_idx <= 16'd0;
            wgt_pref_k_base  <= 16'd0;
            wgt_pref_k_tile  <= 16'd0;
            wgt_pref_n_tile  <= 16'd0;
        end else if (wgt_pref_active) begin
            case (wgt_pref_phase)
                WGT_PREF_IDLE: begin
                    wgt_pref_lane_idx <= 16'd0;
                    wgt_pref_beat_count <= 16'd0;
                    wgt_pref_byte_count <= 16'd0;
                    wgt_pref_phase <= WGT_PREF_REQ;
                end
                WGT_PREF_REQ: begin
                    wgt_pref_phase <= WGT_PREF_WAIT;
                end
                WGT_PREF_WAIT: begin
                    wgt_pref_phase <= WGT_PREF_CAPTURE;
                end
                WGT_PREF_CAPTURE: begin
                    integer wp_remain;
                    integer wp_beatsz;
                    integer wp_count;
                    integer wp_lane;
                    wp_remain = (wgt_pref_n_tile * wgt_pref_k_tile) - wgt_pref_lane_idx;
                    wp_beatsz = 32'd32 - {27'd0, wgt_pref_abs_byte_idx[4:0]};
                    wp_count  = (wp_remain > 32'd32) ? 32'd32 : wp_remain;
                    if (wp_beatsz < wp_count) wp_count = wp_beatsz;
                    for (wp_lane = 0; wp_lane < 32; wp_lane = wp_lane + 1) begin
                        if (wp_lane < wp_count) begin
                            reg [31:0] wp_lane_idx;
                            reg [31:0] wp_lane_out;
                            reg [31:0] wp_lane_row;
                            reg [4:0]  wp_lane_bsel;
                            wp_lane_idx  = wgt_pref_lane_idx + wp_lane;
                            // Phase 5-2: N-major for streaming GEMM full-B strided read
                            wp_lane_out  = (wgt_pref_n_tile == 16'd0) ? 32'd0 : (wp_lane_idx % {16'd0, wgt_pref_n_tile});
                            wp_lane_row  = (wgt_pref_n_tile == 16'd0) ? 32'd0 : (wp_lane_idx / {16'd0, wgt_pref_n_tile});
                            wp_lane_bsel = wgt_pref_abs_byte_idx[4:0] + wp_lane;
                            wgt_load_reg[(wp_lane_row * PE_COLS + wp_lane_out)*8 +: 8]
                                <= wgt_rd_data[wp_lane_bsel * 8 +: 8];
                        end
                    end
                    wgt_pref_beat_count <= wgt_pref_beat_count + 16'd1;
                    wgt_pref_byte_count <= wgt_pref_byte_count + {10'd0, wp_count[5:0]};
                    if (wgt_pref_lane_idx + wp_count >= (wgt_pref_n_tile * wgt_pref_k_tile)) begin
                        wgt_pref_valid <= 1'b1;
                        wgt_pref_done  <= 1'b1;
                        wgt_pref_active <= 1'b0;
                        wgt_pref_phase  <= WGT_PREF_IDLE;
                        $display("[WGT_PREF] DONE k_base=%0d n_base=%0d beats=%0d bytes=%0d",
                            wgt_pref_k_base, wgt_pref_n_base,
                            wgt_pref_beat_count, wgt_pref_byte_count);
                    end else begin
                        wgt_pref_lane_idx <= wgt_pref_lane_idx + wp_count;
                        wgt_pref_phase <= WGT_PREF_REQ;
                    end
                end
                default: wgt_pref_phase <= WGT_PREF_IDLE;
            endcase
        end else begin
            wgt_pref_phase <= WGT_PREF_IDLE;
        end
    end

    // ============================================================
    // Phase 4b: sequential weight staging micro-sequencer.
    // Reads B weights from wgt_buffer and unpacks into wgt_load_reg.
    // Phase 4b-1: sequential (runs in FSM_LOAD_ARRAY, not during RUN).
    // Phase 4b-2a: DBG counter increment
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wgt_stage_active  <= 1'b0;
            wgt_stage_done    <= 1'b0;
            wgt_stage_phase   <= WGT_STAGE_IDLE;
            wgt_stage_lane_idx <= 16'd0;
            wgt_stage_k_base  <= 16'd0;
            wgt_stage_k_tile  <= 16'd0;
            wgt_stage_n_start <= 16'd0;
            wgt_stage_n_tile  <= 16'd0;
            wgt_stage_valid   <= 1'b0;
            wgt_stage_valid_k_base  <= 16'd0;
            wgt_stage_valid_k_tile  <= 16'd0;
            wgt_stage_valid_n_start <= 16'd0;
            wgt_stage_valid_n_tile  <= 16'd0;
            wgt_stage_beat_count <= 16'd0;
            wgt_stage_byte_count <= 16'd0;
        end else if (wgt_stage_active) begin
            case (wgt_stage_phase)
                WGT_STAGE_IDLE: begin
                    wgt_stage_lane_idx <= 16'd0;
                    wgt_stage_beat_count <= 16'd0;
                    wgt_stage_byte_count <= 16'd0;
                    wgt_stage_phase <= WGT_STAGE_REQ;
                end
                WGT_STAGE_REQ: begin
                    wgt_stage_phase <= WGT_STAGE_WAIT;
                end
                WGT_STAGE_WAIT: begin
                    wgt_stage_phase <= WGT_STAGE_CAPTURE;
                end
                WGT_STAGE_CAPTURE: begin
                    // Beat-level unpack: up to 32 bytes from wgt_buffer
                    // into wgt_load_reg. Same formula as legacy FC/GEMM path.
                    integer ws_remain;
                    integer ws_beatsz;
                    integer ws_count;
                    integer ws_lane;
                    ws_remain = (wgt_stage_n_tile * wgt_stage_k_tile) - wgt_stage_lane_idx;
                    ws_beatsz = 32'd32 - {27'd0, wgt_stage_abs_byte_idx[4:0]};
                    ws_count  = (ws_remain > 32'd32) ? 32'd32 : ws_remain;
                    if (ws_beatsz < ws_count) ws_count = ws_beatsz;
                    for (ws_lane = 0; ws_lane < 32; ws_lane = ws_lane + 1) begin
                        if (ws_lane < ws_count) begin
                            reg [31:0] ws_lane_idx;
                            reg [31:0] ws_lane_out;
                            reg [31:0] ws_lane_row;
                            reg [4:0]  ws_lane_bsel;
                            ws_lane_idx  = wgt_stage_lane_idx + ws_lane;
                            // Phase 5-2: N-major for streaming GEMM full-B strided read
                            ws_lane_out  = gemm_row_streaming_en ?
                                ((wgt_stage_n_tile == 16'd0) ? 32'd0 : (ws_lane_idx % {16'd0, wgt_stage_n_tile})) :
                                ((wgt_stage_k_tile == 16'd0) ? 32'd0 : (ws_lane_idx / {16'd0, wgt_stage_k_tile}));
                            ws_lane_row  = gemm_row_streaming_en ?
                                ((wgt_stage_n_tile == 16'd0) ? 32'd0 : (ws_lane_idx / {16'd0, wgt_stage_n_tile})) :
                                ((wgt_stage_k_tile == 16'd0) ? 32'd0 : (ws_lane_idx % {16'd0, wgt_stage_k_tile}));
                            ws_lane_bsel = wgt_stage_abs_byte_idx[4:0] + ws_lane;
                            wgt_load_reg[(ws_lane_row * PE_COLS + wgt_stage_n_start + ws_lane_out)*8 +: 8]
                                <= wgt_rd_data[ws_lane_bsel * 8 +: 8];
                        end
                    end
                    wgt_stage_beat_count <= wgt_stage_beat_count + 16'd1;
                    wgt_stage_byte_count <= wgt_stage_byte_count + {10'd0, ws_count[5:0]};
                    if (wgt_stage_lane_idx + ws_count >= (wgt_stage_n_tile * wgt_stage_k_tile)) begin
                        // All bytes staged: mark valid
                        wgt_stage_valid <= 1'b1;
                        wgt_stage_valid_k_base  <= wgt_stage_k_base;
                        wgt_stage_valid_k_tile  <= wgt_stage_k_tile;
                        wgt_stage_valid_n_start <= wgt_stage_n_start;
                        wgt_stage_valid_n_tile  <= wgt_stage_n_tile;
                        wgt_stage_done   <= 1'b1;
                        wgt_stage_active <= 1'b0;
                        wgt_stage_phase  <= WGT_STAGE_IDLE;
                    end else begin
                        wgt_stage_lane_idx <= wgt_stage_lane_idx + ws_count;
                        wgt_stage_phase <= WGT_STAGE_REQ;
                    end
                end
                default: wgt_stage_phase <= WGT_STAGE_IDLE;
            endcase
        end else begin
            wgt_stage_phase <= WGT_STAGE_IDLE;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_state <= FSM_IDLE;  comp_sub_state <= CP_WAIT_WIN;
            comp_total_wins <= 16'd0; comp_win_idx <= 16'd0;
            comp_feed_cnt <= 7'd0; comp_drain_cnt <= 16'd0;
            act_feed_ptr <= 0; act_feed_wait <= 1'b0; act_feed_done_cnt <= 16'd0;
            pp_result <= 32'd0; task_active_r <= 1'b0;
            task_done_r <= 1'b0; task_error_r <= 1'b0; task_error_code_r <= 8'h0;
            act_dma_start <= 1'b0; act_dma_addr <= 32'h0; act_dma_bytes <= 32'h0;
            wgt_dma_start <= 1'b0; wgt_dma_addr <= 32'h0; wgt_dma_bytes <= 32'h0; wgt_dma_byte_offset <= 5'd0;
            dma_wr_start <= 1'b0; dma_wr_started <= 1'b0;
            block_bank <= 1'b0; dma_wr_addr <= 32'h0; dma_wr_bytes <= 32'h0;
            dma_rd_ptr <= 0;
            store_rd_prefetch <= 0;
            store_pack_state <= SP_IDLE;
            store_pack_lane <= 3'd0;
            store_word_idx <= 32'd0;
            store_pack_data <= {AXI_DMA_DATA_W{1'b0}};
            dma_wr_data_r <= {AXI_DMA_DATA_W{1'b0}};
            dma_wr_valid_r <= 1'b0;
            wgt_load_phase <= 32'd0; wgt_load_wait <= 1'b0; wgt_load_done_r <= 1'b0;
            wgt_load_reg <= 0;
            wgt_load_reg_shadow <= 0;
            fc_shadow_active <= 1'b0; fc_shadow_phase <= 32'd0;
            fc_shadow_in_base <= 16'd0; fc_shadow_chunk_inputs <= 16'd0;
            fc_shadow_wait <= 1'b0;
            wgt_buf_flush <= 1'b0;
            act_load_start <= 1'b0; act_load_done <= 1'b0;
            act_comp_start <= 1'b0; act_comp_done <= 1'b0;
            act_load_bank <= 1'b0; act_comp_bank <= 1'b0;
            wgt_load_start <= 1'b0; wgt_load_done <= 1'b0; wgt_load_bank <= 1'b0;
            wgt_consume_bank <= 1'b0;
            wgt_preload_active <= 1'b0; wgt_preload_done <= 1'b0; wgt_preload_bank <= 1'b0;
            wgt_preload_cin <= 16'd0; wgt_preload_byte_offset <= 5'd0;
            fc_preload_active <= 1'b0; fc_preload_done <= 1'b0; fc_preload_bank <= 1'b0;
            fc_preload_out_start <= 16'd0; fc_preload_tile_outputs <= 16'd0;
            fc_preload_byte_offset <= 5'd0;
            fc_use_preload <= 1'b0;
            acc_load_start <= 1'b0; acc_load_done <= 1'b0;
            acc_comp_start <= 1'b0; acc_comp_done <= 1'b0;
            acc_load_bank <= 1'b0; acc_comp_bank <= 1'b0;
            blk_done <= 1'b0;
            next_blk_prep <= 1'b0; next_blk_wait <= 1'b0; next_dma_launched <= 1'b0;
            pipe_mode <= 1'b0; pipe_store_done <= 1'b0;
            cf_last_row <= 16'hFFFF; cf_last_col <= 16'hFFFF;
            cf_channel_sel <= 6'd0;
            cin_idx <= 16'd0; cin_total <= 16'd0;
            wgt_per_cin <= 32'd0;
            acc_col_idx <= 16'd0;
            acc_collect_wait <= 1'b0;
            acc_collect_skip_write <= 1'b0;
            fc_out_start <= 16'd0; fc_tile_outputs <= 16'd0;
            fc_in_base <= 16'd0; fc_chunk_inputs <= 16'd0;
            gemm_row_idx <= 16'd0;
            gemm_weight_valid <= 1'b0;
            stream_cycle <= 16'd0;
            stream_capture_count <= 16'd0;
            stream_active <= 1'b0;
            stream_a_tile_loaded <= 1'b0;
            // Phase 3c: input-tile-loader micro-sequencer
            gemm_a_load_done  <= 1'b0;
            gemm_a_load_phase <= A_LOAD_IDLE;
            gemm_a_load_row   <= 3'd0;
            gemm_a_load_col   <= 7'd0;
            gemm_a_load_beat_count   <= 16'd0;
            gemm_a_load_byte_count   <= 16'd0;
            gemm_a_load_max_beats_per_row <= 6'd0;
            gemm_a_load_unaligned_row_count <= 16'd0;
            // Phase 4a-2: bank ownership and metadata
            input_load_bank    <= 1'b0;
            input_compute_bank <= 1'b0;
            input_bank0_valid  <= 1'b0;
            input_bank1_valid  <= 1'b0;
            input_bank0_k_base <= 16'd0;
            input_bank1_k_base <= 16'd0;
            input_bank0_k_tile <= 16'd0;
            input_bank1_k_tile <= 16'd0;
            // Phase 4a-3: prefetch counters
            input_prefetch_start_count <= 16'd0;
            input_prefetch_done_count  <= 16'd0;
            input_prefetch_hit_count   <= 16'd0;
            input_prefetch_stall_count <= 16'd0;
            input_prefetch_beat_count  <= 16'd0;
            input_prefetch_byte_count  <= 16'd0;
            // Phase 4b: weight staging
            wgt_stage_active  <= 1'b0;
            wgt_stage_done    <= 1'b0;
            wgt_stage_phase   <= WGT_STAGE_IDLE;
            wgt_stage_lane_idx <= 16'd0;
            wgt_stage_valid   <= 1'b0;
            wgt_stage_valid_k_base  <= 16'd0;
            wgt_stage_valid_k_tile  <= 16'd0;
            wgt_stage_valid_n_start <= 16'd0;
            wgt_stage_valid_n_tile  <= 16'd0;
            wgt_stage_beat_count <= 16'd0;
            wgt_stage_byte_count <= 16'd0;
            // Phase 4b-2: weight prefetch
            wgt_pref_active  <= 1'b0;
            wgt_pref_done    <= 1'b0;
            wgt_pref_valid   <= 1'b0;
            wgt_pref_phase   <= WGT_PREF_IDLE;
            wgt_pref_lane_idx <= 16'd0;
            wgt_pref_start_count <= 16'd0;
            wgt_pref_done_count  <= 16'd0;
            wgt_pref_hit_count   <= 16'd0;
            wgt_pref_stall_count <= 16'd0;
            wgt_pref_beat_count  <= 16'd0;
            wgt_pref_byte_count  <= 16'd0;
            wgt_pref_n_base      <= 16'd0;
            // Phase 4b-2a: FSM debug counters
            dbg_load_array_entry     <= 16'd0;
            dbg_wgt_ld_entry         <= 16'd0;
            dbg_dual_hit_count       <= 16'd0;
            dbg_accum_to_wgtld_direct <= 16'd0;
            dbg_accum_to_load_array  <= 16'd0;
            gemm_store_row_idx <= 16'd0;
            gemm_store_beat_idx <= 16'd0;
            gemm_stream_k_base <= 16'd0;
            gemm_stream_k_chunk_idx <= 16'd0;
            gemm_stream_first_chunk <= 1'b0;
            gemm_stream_last_chunk <= 1'b0;
            gemm_tile_m_base <= 16'd0;
            gemm_tile_M      <= 16'd0;
            gemm_tile_n_base <= 16'd0;
            gemm_tile_N      <= 16'd0;
            fc_store_addr <= 32'd0; fc_store_bytes <= 32'd0;
            rq_acc_wr_en_r <= 1'b0; rq_acc_wr_addr_r <= {BUF_ADDR_W{1'b0}}; rq_acc_wr_data_r <= 32'd0;
            rq_src_idx <= 32'd0; rq_src_wait <= 1'b0; rq_total_words <= 32'd0; rq_pack_idx <= 2'd0; rq_pack_word <= 32'd0;
            rq_store_addr <= 32'd0; rq_store_bytes <= 32'd0;
            rq_mode_internal <= 1'b0;
            rq_word_store_mode <= 1'b0;
            bias_return_state <= FSM_IDLE;
            bias_load_phase <= 32'd0; bias_load_words <= 32'd0; bias_load_wait <= 1'b0;
            add_src_idx <= 32'd0; add_src_wait <= 1'b0;
            add_pack_idx <= 2'd0; add_pack_word <= 32'd0;
            add_acc_wr_en_r <= 1'b0;
            add_acc_wr_addr_r <= {BUF_ADDR_W{1'b0}};
            add_acc_wr_data_r <= 32'd0;
            gap_channel_idx <= 16'd0;
            gap_sp_idx <= 6'd0;
            gap_sum <= 32'sd0;
            gap_src_wait <= 1'b0;
            gap_pack_idx <= 2'd0;
            gap_pack_word <= 32'd0;
            gap_acc_wr_en_r <= 1'b0;
            gap_acc_wr_addr_r <= {BUF_ADDR_W{1'b0}};
            gap_acc_wr_data_r <= 32'd0;
            begin
                integer bi;
                for (bi = 0; bi < PE_COLS; bi = bi + 1)
                    bias_reg[bi] <= 32'sd0;
            end
            vec_relu_beat_idx <= 32'd0;
            vec_relu_total_beats <= 32'd0;
            vec_relu_out_wr_valid <= 1'b0;
            vec_relu_read_done <= 1'b0;
            vec_relu_proc_active <= 1'b0;
            vec_relu_rd_addr <= {BUF_ADDR_W{1'b0}};
            vec_relu_rd_wait <= 1'b0;
            vec_wr_done_latch <= 1'b0;
            vec_relu_proc_done <= 1'b0;
            dbg_vec_push_count <= 32'd0;
            dbg_vec_push_skip <= 32'd0;
            dbg_fifo_pop_count <= 32'd0;
            dbg_w_hs_count <= 32'd0;
            dbg_vec_total_beats <= 32'd0;
            dbg_done_printed <= 1'b0;
            dbg_rd_issue_count <= 32'd0;
            dbg_rd_data_count <= 32'd0;
            dbg_fifo_full_stall <= 32'd0;
            dbg_cycle_cnt <= 32'd0;
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
            rq_acc_wr_en_r <= 1'b0;
            add_acc_wr_en_r <= 1'b0;
            gap_acc_wr_en_r <= 1'b0;

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
                        wgt_load_phase <= 32'd0; wgt_load_done_r <= 1'b0;
                        wgt_preload_active <= 1'b0; wgt_preload_done <= 1'b0;
                        wgt_load_reg <= 0; blk_done <= 1'b0;
                        next_blk_prep <= 1'b0; next_blk_wait <= 1'b0; next_dma_launched <= 1'b0;
            pipe_mode <= 1'b0; pipe_store_done <= 1'b0;
                        fc_preload_active <= 1'b0; fc_preload_done <= 1'b0;
                        gemm_weight_valid <= 1'b0;
                        fsm_state <= FSM_TASK_SETUP;
                    end
                end

                FSM_TASK_SETUP: begin
                    if (blk_valid) begin
                        // Capture per-task block parameters after block_scheduler has advanced
                        cin_total <= blk_cin_total;
                        wgt_per_cin <= blk_wgt_per_cin;
                        if (bias_enabled && is_conv_mode) begin
                            bias_load_words <= {16'd0, output_c};
                            bias_return_state <= FSM_LOAD_ACT;
                            wgt_buf_flush <= 1'b1;
                            fsm_state <= FSM_LOAD_BIAS;
                        end else if (is_vec_relu_mode) begin
                            // P0-3 FIX: Vector INT8 ReLU 256b starts DMA ONCE here,
                            // then transitions directly to FSM_VEC_RELU_PROC.
                            // Previously FSM_TASK_SETUP started act_dma_start for all
                            // task types, and FSM_LOAD_ACT (is_vec_relu_mode branch)
                            // started a SECOND act_dma_start on act_dma_done, causing
                            // 2x DMA read (1024 beats instead of 512 for 16KB).
                            act_dma_start <= 1'b1;
                            act_dma_addr <= blk_in_addr;
                            act_dma_bytes <= blk_in_bytes;
                            act_load_start <= 1'b1;
                            act_load_bank <= block_bank;
                            act_comp_bank <= block_bank;
                            vec_relu_beat_idx <= 32'd0;
                            vec_relu_total_beats <= (blk_in_bytes + 32'd31) >> 5;
                            vec_relu_out_wr_valid <= 1'b0;
                            vec_relu_read_done <= 1'b0;
                            vec_relu_proc_active <= 1'b0;
                            vec_relu_rd_addr <= {BUF_ADDR_W{1'b0}};
                            vec_relu_rd_wait <= 1'b0;
                            vec_wr_done_latch <= 1'b0;
                            vec_relu_proc_done <= 1'b0;
                            dma_wr_addr <= blk_out_addr;
                            dma_wr_bytes <= blk_out_bytes;
                            fsm_state <= FSM_VEC_RELU_PROC;
                        end else begin
                            act_dma_start <= 1'b1;
                            act_dma_addr <= blk_in_addr;
                            act_dma_bytes <= blk_in_bytes;
                            act_load_start <= 1'b1;
                            act_load_bank <= block_bank;
                            fsm_state <= FSM_LOAD_ACT;
                        end
                    end
                end

                FSM_LOAD_BIAS: begin
                    wgt_dma_start <= 1'b1;
                    wgt_dma_addr <= {bias_dma_base[31:5], 5'b0};
                    wgt_dma_byte_offset <= bias_dma_base[4:0];
                    wgt_dma_bytes <= (bias_load_words << 2) +
                                     {27'd0, bias_dma_base[4:0]};
                    wgt_load_start <= 1'b1;
                    wgt_load_bank <= block_bank;
                    fsm_state <= FSM_BIAS_WAIT;
                end

                FSM_BIAS_WAIT: begin
                    if (wgt_dma_done) begin
                        wgt_load_done <= 1'b1;
                        wgt_consume_bank <= wgt_load_bank;
                        bias_load_phase <= 32'd0;
                        bias_load_wait <= 1'b1;
                        fsm_state <= FSM_BIAS_EXTRACT;
                    end else if (wgt_dma_error) begin
                        task_error_r <= 1'b1; task_error_code_r <= wgt_dma_error_code;
                        fsm_state <= FSM_ERROR;
                    end
                end

                FSM_BIAS_EXTRACT: begin
                    if (bias_load_wait) begin
                        bias_load_wait <= 1'b0;
                    end else begin
                        if (bias_load_phase < PE_COLS)
                            bias_reg[bias_load_phase[5:0]] <= bias_word;

                        if (bias_load_phase + 32'd1 >= bias_load_words) begin
                            if (bias_return_state == FSM_LOAD_ACT) begin
                                act_dma_start <= 1'b1;
                                act_dma_addr <= blk_in_addr;
                                act_dma_bytes <= blk_in_bytes;
                                act_load_start <= 1'b1;
                                act_load_bank <= block_bank;
                                fsm_state <= FSM_LOAD_ACT;
                            end else begin
                                // P1: restore preload bank after bias extraction
                                if (fc_use_preload)
                                    wgt_consume_bank <= fc_preload_bank;
                                fsm_state <= bias_return_state;
                            end
                        end else begin
                            if (bias_beat_addr != bias_next_beat_addr)
                                bias_load_wait <= 1'b1;
                            bias_load_phase <= bias_load_phase + 32'd1;
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
                        act_feed_wait <= 1'b1;
                        act_feed_done_cnt <= 16'd0;
                        if (is_add_mode) begin
                            wgt_buf_flush <= 1'b1;
                            fsm_state <= FSM_LOAD_ADD_SRC1;
                        end else if (is_gap_mode) begin
                            gap_channel_idx <= 16'd0;
                            gap_sp_idx <= 6'd0;
                            gap_sum <= 32'sd0;
                            gap_src_wait <= 1'b1;
                            gap_pack_idx <= 2'd0;
                            gap_pack_word <= 32'd0;
                            acc_load_start <= 1'b1;
                            fsm_state <= FSM_GAP_COMPUTE;
                        end else if (is_pool_mode) begin
                            fsm_state <= FSM_COMPUTE;
                            comp_sub_state <= CP_WAIT_WIN;
                            comp_total_wins <= 16'd1;
                            comp_win_idx <= 16'd0;
                        end else if (is_requant_mode) begin
                            rq_mode_internal <= 1'b0;
                            rq_word_store_mode <= 1'b0;
                            rq_src_idx <= 32'd0;
                            rq_src_wait <= 1'b1;
                            rq_total_words <= (blk_in_bytes >> 2);
                            rq_pack_idx <= 2'd0;
                            rq_pack_word <= 32'd0;
                            rq_store_addr <= blk_out_addr;
                            rq_store_bytes <= blk_out_bytes;
                            fsm_state <= FSM_REQUANT_COMPUTE;
                        end else if (is_vec_relu_mode) begin
                            // P0-3 FIX: Unreachable — vec_relu now transitions
                            // directly from FSM_TASK_SETUP to FSM_VEC_RELU_PROC.
                            // Keep as defensive dead-code guard.
                            fsm_state <= FSM_ERROR;
                            task_error_r <= 1'b1;
                            task_error_code_r <= 8'hFF;
                        end else if (is_fc_mode) begin
                            fc_out_start <= 16'd0;
                            fc_in_base <= 16'd0;
                            fc_chunk_inputs <= (input_c > PE_ROWS_16) ? PE_ROWS_16 : input_c;
                            fsm_state <= FSM_FC_TILE_PREP;
                        end else if (is_gemm_mode) begin
                            // GEMM: M output rows, each row uses one FC/GEMV pass
                            // Reuse FC infrastructure: PE rows = K (input dim), PE cols = N
                            gemm_row_idx <= 16'd0;
                            fc_out_start <= 16'd0;
                            fc_in_base <= 16'd0;
                            fc_chunk_inputs <= (input_c > PE_ROWS_16) ? PE_ROWS_16 : input_c;
                            fsm_state <= FSM_FC_TILE_PREP;
                        end else begin
                            // Conv: start conv_frontend
                            comp_total_wins <= blk_out_rows * conv_total_out_cols;
                            comp_win_idx <= 16'd0;
                            fsm_state <= FSM_CF_START;
                        end
                    end else if (act_dma_error) begin
                        task_error_r <= 1'b1; task_error_code_r <= act_dma_error_code;
                        fsm_state <= FSM_ERROR;
                    end
                end

                FSM_LOAD_ADD_SRC1: begin
                    wgt_dma_start <= 1'b1;
                    wgt_dma_addr <= {src1_addr[31:5], 5'b0};
                    wgt_dma_byte_offset <= src1_addr[4:0];
                    wgt_dma_bytes <= src1_bytes + {27'd0, src1_addr[4:0]};
                    wgt_load_start <= 1'b1;
                    wgt_load_bank <= block_bank;
                    fsm_state <= FSM_ADD_SRC1_WAIT;
                end

                FSM_ADD_SRC1_WAIT: begin
                    if (wgt_dma_done) begin
                        wgt_load_done <= 1'b1;
                        wgt_consume_bank <= wgt_load_bank;
                        act_comp_start <= 1'b1;
                        act_comp_bank <= act_load_bank;
                        acc_load_bank <= act_load_bank;
                        add_src_idx <= 32'd0;
                        add_src_wait <= 1'b1;
                        add_pack_idx <= 2'd0;
                        add_pack_word <= 32'd0;
                        acc_load_start <= 1'b1;
                        fsm_state <= FSM_ADD_COMPUTE;
                    end else if (wgt_dma_error) begin
                        task_error_r <= 1'b1; task_error_code_r <= wgt_dma_error_code;
                        fsm_state <= FSM_ERROR;
                    end
                end

                FSM_ADD_COMPUTE: begin
                    reg [31:0] add_pack_word_next;
                    if (add_src_wait) begin
                        add_src_wait <= 1'b0;
                    end else begin
                        add_pack_word_next = add_pack_word;
                        case (add_pack_idx)
                            2'd0: add_pack_word_next[7:0]   = add_q;
                            2'd1: add_pack_word_next[15:8]  = add_q;
                            2'd2: add_pack_word_next[23:16] = add_q;
                            default: add_pack_word_next[31:24] = add_q;
                        endcase

                        if ((add_pack_idx == 2'd3) || (add_src_idx + 32'd1 >= input_bytes)) begin
                            add_acc_wr_en_r <= 1'b1;
                            add_acc_wr_addr_r <= add_src_idx[BUF_ADDR_W+1:2];
                            add_acc_wr_data_r <= add_pack_word_next;
                            add_pack_idx <= 2'd0;
                            add_pack_word <= 32'd0;
                        end else begin
                            add_pack_idx <= add_pack_idx + 2'd1;
                            add_pack_word <= add_pack_word_next;
                        end

                        if (add_src_idx + 32'd1 < input_bytes) begin
                            if (add_src_beat_addr != add_next_beat_addr)
                                add_src_wait <= 1'b1;
                            add_src_idx <= add_src_idx + 32'd1;
                        end else begin
                            act_comp_done <= 1'b1;
                            fsm_state <= FSM_ADD_DRAIN;
                        end
                    end
                end

                FSM_ADD_DRAIN: begin
                    // add_acc_wr_en_r is registered; give the final ADD packed
                    // word one cycle to commit before STORE reads acc_buffer.
                    acc_load_start <= 1'b1;
                    fsm_state <= FSM_STORE;
                end

                // ============================================================
                // FSM_VEC_RELU_PROC — 256-bit streaming vector INT8 ReLU
                //
                // Slow pipeline (rd_wait, 0.5 beat/cycle). Verified correct data.
                // Writer partial burst handles tail when Phase B finishes first.
                // ============================================================
                FSM_VEC_RELU_PROC: begin
                    dma_wr_valid_r <= 1'b0;

                    if (!dma_wr_started) begin
                        dma_wr_start <= 1'b1;
                        dma_wr_started <= 1'b1;
                    end

                    if (dma_wr_done)
                        vec_wr_done_latch <= 1'b1;

                    if (!vec_relu_read_done) begin
                        if (act_buf_wr_en)
                            vec_relu_beat_idx <= vec_relu_beat_idx + 32'd1;
                        if (act_dma_done) begin
                            vec_relu_read_done <= 1'b1;
                            vec_relu_beat_idx <= 32'd0;
                            vec_relu_rd_addr <= {BUF_ADDR_W{1'b0}};
                            vec_relu_rd_wait <= 1'b1;
                        end
                    end

                    else if (!vec_relu_proc_done) begin
                        if (vec_relu_rd_wait) begin
                            vec_relu_rd_wait <= 1'b0;
                        end else if (vec_relu_beat_idx < vec_relu_total_beats) begin
                            if (!wf_wr_full) begin
                                dma_wr_data_r <= vec_relu_result;
                                dma_wr_valid_r <= 1'b1;
                                vec_relu_beat_idx <= vec_relu_beat_idx + 32'd1;
                                dbg_vec_push_count <= dbg_vec_push_count + 32'd1;
                                if (vec_relu_beat_idx + 32'd1 < vec_relu_total_beats) begin
                                    vec_relu_rd_addr <= vec_relu_rd_addr +
                                        {{BUF_ADDR_W-1{1'b0}}, 1'b1};
                                    vec_relu_rd_wait <= 1'b1;
                                end
                            end else begin
                                dbg_vec_push_skip <= dbg_vec_push_skip + 32'd1;
                            end
                        end else begin
                            vec_relu_proc_done <= 1'b1;
                        end
                    end

                    if (vec_relu_proc_done && vec_relu_read_done) begin
                        if (vec_wr_done_latch) begin
                            // === DEBUG PRINT ===
                            if (!dbg_done_printed) begin
                                $display("[VEC_COUNT] expected_beats=%0d", vec_relu_total_beats);
                                $display("[VEC_COUNT] vec_fifo_push_count=%0d", dbg_vec_push_count);
                                $display("[VEC_COUNT] vec_fifo_push_skip=%0d", dbg_vec_push_skip);
                                $display("[VEC_COUNT] fifo_pop_count=%0d", dbg_fifo_pop_count);
                                $display("[VEC_COUNT] axi_w_handshake_count=%0d", dbg_w_hs_count);
                                $display("[VEC_COUNT] ar_issue_count=%0d", dbg_rd_issue_count);
                                $display("[VEC_COUNT] r_data_count=%0d", dbg_rd_data_count);
                                $display("[VEC_COUNT] fifo_full_stall_count=%0d", dbg_fifo_full_stall);
                                $display("[VEC_COUNT] cycle_count=%0d", dbg_cycle_cnt);
                                $display("[VEC_COUNT] vec_beat_idx_at_done=%0d", vec_relu_beat_idx);
                                $display("[VEC_COUNT] fifo_rd_level_at_done=%0d", wf_rd_level);
                                $display("[VEC_COUNT] fifo_wr_full_at_done=%0d", wf_wr_full);
                                dbg_done_printed <= 1'b1;
                            end
                            dma_wr_valid_r <= 1'b0;
                            dma_wr_started <= 1'b0;
                            vec_wr_done_latch <= 1'b0;
                            vec_relu_proc_done <= 1'b0;
                            act_comp_done <= 1'b1;
                            blk_done <= 1'b1;
                            fsm_state <= FSM_BLK_DONE;
                        end
                    end

                    if (dma_wr_error) begin
                        task_error_r <= 1'b1;
                        task_error_code_r <= dma_wr_error_code;
                        fsm_state <= FSM_ERROR;
                    end
                end

                FSM_GAP_COMPUTE: begin
                    reg [31:0] gap_pack_word_next;
                    if (gap_src_wait) begin
                        gap_src_wait <= 1'b0;
                    end else begin
                        if (gap_sp_idx == 6'd63) begin
                            gap_pack_word_next = gap_pack_word;
                            case (gap_pack_idx)
                                2'd0: gap_pack_word_next[7:0]   = gap_q;
                                2'd1: gap_pack_word_next[15:8]  = gap_q;
                                2'd2: gap_pack_word_next[23:16] = gap_q;
                                default: gap_pack_word_next[31:24] = gap_q;
                            endcase

                            if ((gap_pack_idx == 2'd3) || (gap_channel_idx + 16'd1 >= output_c)) begin
                                gap_acc_wr_en_r <= 1'b1;
                                gap_acc_wr_addr_r <= gap_channel_idx[BUF_ADDR_W+1:2];
                                gap_acc_wr_data_r <= gap_pack_word_next;
                                gap_pack_idx <= 2'd0;
                                gap_pack_word <= 32'd0;
                            end else begin
                                gap_pack_idx <= gap_pack_idx + 2'd1;
                                gap_pack_word <= gap_pack_word_next;
                            end

                            if (gap_channel_idx + 16'd1 < output_c) begin
                                gap_channel_idx <= gap_channel_idx + 16'd1;
                                gap_sp_idx <= 6'd0;
                                gap_sum <= 32'sd0;
                                gap_src_wait <= 1'b1;
                            end else begin
                                act_comp_done <= 1'b1;
                                acc_load_start <= 1'b1;
                                fsm_state <= FSM_STORE;
                            end
                        end else begin
                            gap_sum <= gap_sum_next;
                            gap_sp_idx <= gap_sp_idx + 6'd1;
                            if (gap_src_beat_addr != gap_next_beat_addr)
                                gap_src_wait <= 1'b1;
                        end
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
                    // GEMM: output columns per tile = min(64,N). Phase 5-2 N-tiling.
                    fc_tile_outputs <= is_gemm_mode ?
                        ((gemm_N_val > PE_COLS_16) ? PE_COLS_16 : gemm_N_val) :
                        fc_tile_outputs_next;
                    fc_in_base <= 16'd0;
                    fc_chunk_inputs <= (input_c > PE_ROWS_16) ? PE_ROWS_16 : input_c;
                    // Phase 3a: init streaming K-chunk state (this state entered once per task)
                    if (gemm_row_streaming_en) begin
                        gemm_stream_k_base       <= 16'd0;
                        gemm_stream_k_chunk_idx  <= 16'd0;
                        gemm_stream_first_chunk  <= 1'b1;
                        gemm_stream_last_chunk   <= (input_c <= PE_ROWS_16);
                        // Phase 5-1: init M tile descriptor
                        gemm_tile_m_base <= 16'd0;
                        gemm_tile_M <= (gemm_M_val > 16'd8) ? 16'd8 : gemm_M_val;
                        // Phase 5-2: init N tile descriptor
                        gemm_tile_n_base <= 16'd0;
                        gemm_tile_N <= (gemm_N_val > PE_COLS_16) ? PE_COLS_16 : gemm_N_val;
                    end
                    dma_rd_ptr <= 0;
                    // Phase 1a+: GEMM weight retention — skip reload
                    if (gemm_weight_hit) begin
                        comp_feed_cnt <= 7'd0;
                        comp_drain_cnt <= 16'd0;
                        comp_sub_state <= CP_WAIT_WIN;
                        fsm_state <= FSM_COMPUTE;
                    end else if (fc_preload_done && (fc_preload_out_start == fc_out_start)) begin
                        // Use preloaded weights — skip DMA, go directly to LOAD_ARRAY
                        // P1: preload hit — use preloaded weights
                        fc_preload_done <= 1'b0;
                        fc_use_preload <= 1'b1;
                        wgt_consume_bank <= fc_preload_bank;
                        wgt_dma_byte_offset <= fc_preload_byte_offset;
                        wgt_load_phase <= 32'd0;
                        wgt_load_wait <= 1'b1;
                        wgt_load_reg <= 0;
                        if (bias_enabled) begin
                            bias_load_words <= {16'd0, fc_tile_outputs_next};
                            bias_return_state <= FSM_LOAD_ARRAY;
                            fsm_state <= FSM_LOAD_BIAS;
                        end else begin
                            fsm_state <= FSM_LOAD_ARRAY;
                        end
                    end else begin
                        // Fresh DMA (first tile or preload not ready)
                        // P1: preload not ready — use fresh DMA
                        fc_use_preload <= 1'b0;
                        fc_preload_active <= 1'b0;
                        fc_preload_done  <= 1'b0;
                        wgt_buf_flush <= 1'b1;
                        if (bias_enabled) begin
                            bias_load_words <= {16'd0, fc_tile_outputs_next};
                            bias_return_state <= FSM_FC_LOAD_WGT;
                            fsm_state <= FSM_LOAD_BIAS;
                        end else begin
                            fsm_state <= FSM_FC_LOAD_WGT;
                        end
                    end
                end

                FSM_FC_LOAD_WGT: begin
                    wgt_dma_start <= 1'b1;
                    wgt_dma_addr <= {fc_wgt_dma_base[31:5], 5'b0};
                    wgt_dma_byte_offset <= fc_wgt_dma_base[4:0];
                    // Phase 5-2: streaming GEMM loads full B[K,N] for N-tiling
                    wgt_dma_bytes <= gemm_row_streaming_en ?
                        (output_c * input_c) + {27'd0, fc_wgt_dma_base[4:0]} :
                        (fc_tile_outputs * input_c) + {27'd0, fc_wgt_dma_base[4:0]};
                    if (gemm_row_streaming_en)
                        $display("[WGT_DMA] full B: K=%0d N=%0d bytes=%0d", input_c, output_c,
                            output_c * input_c);
                    wgt_load_start <= 1'b1;
                    wgt_load_bank <= block_bank;
                    fsm_state <= FSM_FC_LOAD_WAIT;
                end

                FSM_FC_LOAD_WAIT: begin
                    if (wgt_dma_done) begin
                        wgt_load_done <= 1'b1;
                        wgt_consume_bank <= wgt_load_bank;
                        wgt_load_phase <= 32'd0;
                        wgt_load_wait <= 1'b1;
                        wgt_load_reg <= 0;
                        fsm_state <= FSM_LOAD_ARRAY;
                    end else if (wgt_dma_error) begin
                        task_error_r <= 1'b1; task_error_code_r <= wgt_dma_error_code;
                        fsm_state <= FSM_ERROR;
                    end
                end

                FSM_REQUANT_COMPUTE: begin
                    reg [31:0] rq_pack_word_next;
                    if (rq_src_wait) begin
                        rq_src_wait <= 1'b0;
                    end else if (rq_word_store_mode) begin
                        rq_acc_wr_en_r <= 1'b1;
                        rq_acc_wr_addr_r <= rq_src_idx[BUF_ADDR_W-1:0];
                        rq_acc_wr_data_r <= {24'd0, rq_q_selected[7:0]};
                        rq_pack_idx <= 2'd0;
                        rq_pack_word <= 32'd0;

                        if (rq_src_idx + 32'd1 < rq_total_words) begin
                            if (rq_mode_internal)
                                rq_src_wait <= 1'b1;
                            rq_src_idx <= rq_src_idx + 32'd1;
                        end else begin
                            fsm_state <= FSM_REQUANT_DRAIN;
                        end
                    end else begin
                        rq_pack_word_next = rq_pack_word;
                        case (rq_pack_idx)
                            2'd0: rq_pack_word_next[7:0]   = rq_q_selected;
                            2'd1: rq_pack_word_next[15:8]  = rq_q_selected;
                            2'd2: rq_pack_word_next[23:16] = rq_q_selected;
                            default: rq_pack_word_next[31:24] = rq_q_selected;
                        endcase

                        if ((rq_pack_idx == 2'd3) || (rq_src_idx + 32'd1 >= rq_total_words)) begin
                            rq_acc_wr_en_r <= 1'b1;
                            rq_acc_wr_addr_r <= rq_src_idx[BUF_ADDR_W+1:2];
                            rq_acc_wr_data_r <= rq_pack_word_next;
                            rq_pack_idx <= 2'd0;
                            rq_pack_word <= 32'd0;
                        end else begin
                            rq_pack_idx <= rq_pack_idx + 2'd1;
                            rq_pack_word <= rq_pack_word_next;
                        end

                        if (rq_src_idx + 32'd1 < rq_total_words) begin
                            if (rq_mode_internal ||
                                ((rq_src_idx[2:0] == 3'd7) &&
                                 (rq_src_idx + 32'd1 < rq_total_words)))
                                rq_src_wait <= 1'b1;
                            rq_src_idx <= rq_src_idx + 32'd1;
                        end else begin
                            fsm_state <= FSM_REQUANT_DRAIN;
                        end
                    end
                end

                FSM_REQUANT_DRAIN: begin
                    // rq_acc_wr_en_r is registered; give the final requant write
                    // one cycle to commit before STORE starts reading acc_buffer.
                    acc_load_start <= 1'b1;
                    act_comp_done <= 1'b1;
                    fsm_state <= FSM_STORE;
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
                        if (wgt_preload_done && (wgt_preload_cin == cin_idx)) begin
                            wgt_load_bank <= wgt_preload_bank;
                            wgt_consume_bank <= wgt_preload_bank;
                            wgt_dma_byte_offset <= wgt_preload_byte_offset;
                            wgt_preload_done <= 1'b0;
                            wgt_load_phase <= 32'd0;
                            wgt_load_wait <= 1'b1;
                            wgt_load_done_r <= 1'b0;
                            fsm_state <= FSM_LOAD_ARRAY;
                        end else if (wgt_preload_active && (wgt_preload_cin == cin_idx)) begin
                            if (wgt_dma_done) begin
                                wgt_load_done <= 1'b1;
                                wgt_load_bank <= wgt_preload_bank;
                                wgt_consume_bank <= wgt_preload_bank;
                                wgt_dma_byte_offset <= wgt_preload_byte_offset;
                                wgt_preload_active <= 1'b0;
                                wgt_load_phase <= 32'd0;
                                wgt_load_wait <= 1'b1;
                                wgt_load_done_r <= 1'b0;
                                fsm_state <= FSM_LOAD_ARRAY;
                            end else if (wgt_dma_error) begin
                                task_error_r <= 1'b1; task_error_code_r <= wgt_dma_error_code;
                                fsm_state <= FSM_ERROR;
                            end
                        end else begin
                            wgt_dma_start <= 1'b1;
                            wgt_dma_addr <= {conv_wgt_dma_base[31:5], 5'b0};
                            wgt_dma_byte_offset <= conv_wgt_dma_base[4:0];
                            wgt_dma_bytes <= conv_wgt_valid_bytes + {27'd0, conv_wgt_dma_base[4:0]};
                            wgt_load_start <= 1'b1;
                            wgt_load_bank <= block_bank;
                            wgt_load_phase <= 32'd0;
                            wgt_load_done_r <= 1'b0;
                            fsm_state <= FSM_CIN_LOAD_WGT;
                        end
                    end else begin
                        comp_sub_state <= CP_WAIT_WIN;
                        fsm_state <= FSM_COMPUTE;
                    end
                end

                FSM_CIN_LOAD_WGT: begin
                    if (wgt_dma_done) begin
                        wgt_load_done <= 1'b1;
                        wgt_consume_bank <= wgt_load_bank;
                        fsm_state <= FSM_CIN_LOAD_DONE;
                    end else if (wgt_dma_error) begin
                        task_error_r <= 1'b1; task_error_code_r <= wgt_dma_error_code;
                        fsm_state <= FSM_ERROR;
                    end
                end

                FSM_CIN_LOAD_DONE: begin
                    wgt_load_wait <= 1'b1;
                    fsm_state <= FSM_LOAD_ARRAY;
                end

                // ============================================================
                // FSM_LOAD_ARRAY: load weights from wgt_buffer into wgt_load_reg
                // Phase 4b-1: GEMM streaming uses weight staging micro-sequencer.
                // Legacy FC/GEMM/Conv uses original inline unpack.
                // ============================================================
                FSM_LOAD_ARRAY: begin
                    dbg_load_array_entry <= dbg_load_array_entry + 16'd1;
                    if (gemm_row_streaming_en) begin
                        // Phase 4b-1: sequential weight staging
                        if (!wgt_stage_active && !wgt_stage_done) begin
                            wgt_stage_active   <= 1'b1;
                            wgt_stage_done     <= 1'b0;
                            wgt_stage_k_base   <= fc_in_base;
                            wgt_stage_k_tile   <= fc_chunk_inputs;
                            wgt_stage_n_start  <= fc_out_start;
                            wgt_stage_n_tile   <= fc_tile_outputs;
                            wgt_stage_valid    <= 1'b0;
                            // Phase will be set to REQ by micro-sequencer IDLE state
                            $display("[WGT_STG] START k_base=%0d k_tile=%0d n_start=%0d n_tile=%0d",
                                fc_in_base, fc_chunk_inputs, fc_out_start, fc_tile_outputs);
                        end else if (wgt_stage_done) begin
                            // Weight staging complete — verify meta
                            if (!wgt_stage_valid ||
                                (wgt_stage_valid_k_base  != fc_in_base) ||
                                (wgt_stage_valid_k_tile  != fc_chunk_inputs) ||
                                (wgt_stage_valid_n_start != fc_out_start) ||
                                (wgt_stage_valid_n_tile  != fc_tile_outputs)) begin
                                $display("[WGT_STG] META MISMATCH: valid=%0d k(%0d/%0d) n(%0d/%0d)",
                                    wgt_stage_valid,
                                    wgt_stage_valid_k_base, fc_in_base,
                                    wgt_stage_valid_k_tile, fc_chunk_inputs);
                            end
                            $display("[WGT_STG] DONE beats=%0d bytes=%0d wgt[0..3]=%0d,%0d,%0d,%0d n_base=%0d",
                                wgt_stage_beat_count, wgt_stage_byte_count,
                                wgt_load_reg[7:0], wgt_load_reg[15:8],
                                wgt_load_reg[23:16], wgt_load_reg[31:24],
                                gemm_tile_n_base);
                            wgt_stage_done <= 1'b0;
                            wgt_load_done_r <= 1'b1;
                            fsm_state <= FSM_WGT_LD;
                        end
                    end else if (fc_or_gemm) begin
                        if (wgt_load_wait) begin
                            wgt_load_wait <= 1'b0;
                        end else if (wgt_load_phase < (fc_tile_outputs * fc_chunk_inputs)) begin
                            // Performance fix: load up to 32 bytes/cycle from 256-bit
                            // weight buffer (matching buffer native width), instead of
                            // the original 1 byte/cycle.  Uses same for-loop pattern as
                            // the Conv path below.  All 32 bytes in a beat map to the
                            // same output neuron (fc_load_out_idx constant) but different
                            // input rows, so wgt_load_reg write targets are all distinct.
                            reg [31:0] fc_load_remaining;
                            reg [31:0] fc_bytes_in_beat;
                            reg [31:0] fc_load_count;
                            integer fc_load_lane;
                            fc_load_remaining = (fc_tile_outputs * fc_chunk_inputs) - wgt_load_phase;
                            fc_bytes_in_beat  = 32'd32 - {27'd0, fc_weight_dma_byte_idx[4:0]};
                            fc_load_count     = (fc_load_remaining > 32'd32) ? 32'd32 : fc_load_remaining;
                            if (fc_bytes_in_beat < fc_load_count)
                                fc_load_count = fc_bytes_in_beat;
                            for (fc_load_lane = 0; fc_load_lane < 32; fc_load_lane = fc_load_lane + 1) begin
                                if (fc_load_lane < fc_load_count) begin
                                    reg [31:0] fc_lane_idx;
                                    reg [31:0] fc_lane_out_idx;
                                    reg [31:0] fc_lane_row_idx;
                                    reg [4:0]  fc_lane_byte_sel;
                                    fc_lane_idx      = wgt_load_phase + fc_load_lane;
                                    fc_lane_out_idx  = fc_lane_idx / {16'd0, fc_chunk_inputs};
                                    fc_lane_row_idx  = fc_lane_idx % {16'd0, fc_chunk_inputs};
                                    fc_lane_byte_sel = {27'd0, fc_weight_dma_byte_idx} + fc_load_lane;
                                    wgt_load_reg[(fc_lane_row_idx * PE_COLS + fc_lane_out_idx)*8 +: 8] <=
                                        hb_beat_byte(wgt_rd_data, fc_lane_byte_sel);
                                end
                            end
                            if ((wgt_load_phase + fc_load_count < (fc_tile_outputs * fc_chunk_inputs)))
                                wgt_load_wait <= 1'b1;
                            wgt_load_phase <= wgt_load_phase + fc_load_count;
                        end else begin
                            wgt_load_done_r <= 1'b1;
                            fsm_state <= FSM_WGT_LD;
                        end
                    end else if (wgt_load_wait) begin
                        wgt_load_wait <= 1'b0;
                    end else if (wgt_load_phase < conv_wgt_valid_bytes) begin
                        // Map memory byte idx to wgt_load_reg byte idx:
                        // memory: spatial_pos * C_out + out_c  (sequential)
                        // wgt_reg: spatial_pos * PE_COLS + out_c   (strided for array columns)
                        // HB1-B: phase is a byte index; beat address and byte lane
                        // use the same 256-bit extraction rule as FC weights.
                        reg [31:0] load_idx;
                        reg [31:0] load_abs_idx;
                        reg [31:0] load_count;
                        reg [31:0] load_remaining;
                        reg [31:0] bytes_left_in_beat;
                        reg [4:0]  load_byte_sel;
                        reg [15:0] sp0;
                        reg [5:0]  oc0;
                        integer load_lane;
                        load_remaining = conv_wgt_valid_bytes - wgt_load_phase;
                        bytes_left_in_beat = 32'd32 - {27'd0, conv_weight_dma_byte_idx[4:0]};
                        load_count = (load_remaining > 32'd4) ? 32'd4 : load_remaining;
                        if (bytes_left_in_beat < load_count)
                            load_count = bytes_left_in_beat;
                        for (load_lane = 0; load_lane < 4; load_lane = load_lane + 1) begin
                            if (load_lane < load_count) begin
                                load_idx = wgt_load_phase + load_lane;
                                load_abs_idx = conv_weight_dma_byte_idx + load_lane;
                                load_byte_sel = load_abs_idx[4:0];
                                sp0 = load_idx / {16'd0, output_c};
                                oc0 = load_idx % {16'd0, output_c};
                                wgt_load_reg[(sp0 * PE_COLS + oc0)*8 +: 8] <=
                                    hb_beat_byte(wgt_rd_data, load_byte_sel);
                            end
                        end
                        if ((((conv_weight_dma_byte_idx[4:0] + load_count) >= 32'd32) ||
                             (load_count < 32'd4)) &&
                            (wgt_load_phase + load_count < conv_wgt_valid_bytes))
                            wgt_load_wait <= 1'b1;
                        wgt_load_phase <= wgt_load_phase + load_count;
                    end else begin
                        wgt_load_done_r <= 1'b1;
                        fsm_state <= FSM_WGT_LD;
                    end
                end

                FSM_WGT_LD: begin
                    dbg_wgt_ld_entry <= dbg_wgt_ld_entry + 16'd1;
                    // weight_ld pulsed → weights now in array PEs
                    comp_feed_cnt <= 7'd0;
                    comp_drain_cnt <= 16'd0;
                    if (gemm_row_streaming_en) begin
                        fsm_state <= FSM_GEMM_STREAM_PREP;
                    end else begin
                        comp_sub_state <= fc_or_gemm ? CP_FEED_ACT : CP_WAIT_WIN;
                        fsm_state <= FSM_COMPUTE;
                    end
                    fc_use_preload <= 1'b0;  // P1: preload consumed, clear flag
                    if (is_gemm_mode) begin
                        gemm_weight_valid         <= 1'b1;
                        gemm_weight_addr_cached   <= weight_addr;
                        gemm_weight_k_base_cached <= fc_in_base;
                        gemm_weight_n_base_cached <= fc_out_start;
                        gemm_weight_k_size_cached <= fc_chunk_inputs;
                        gemm_weight_n_size_cached <= fc_tile_outputs;
                    end
                    // Phase 2: trigger shadow load for next FC chunk
                    if (is_fc_mode && (fc_in_base + fc_chunk_inputs < input_c)) begin
                        fc_shadow_active  <= 1'b1;
                        fc_shadow_phase   <= 32'd0;
                        fc_shadow_in_base <= fc_in_base + fc_chunk_inputs;
                        fc_shadow_chunk_inputs <= ((input_c - (fc_in_base + fc_chunk_inputs)) > PE_ROWS_16) ?
                                                   PE_ROWS_16 :
                                                   (input_c - (fc_in_base + fc_chunk_inputs));
                        fc_shadow_wait <= 1'b1;
                    end
                    if (!gemm_row_streaming_en)
                        fsm_state <= FSM_COMPUTE;
                end

                // ============================================================
                // FSM_COMPUTE: process all spatial windows for current c_in
                // ============================================================
                FSM_COMPUTE: begin
                    // Conv preload: next channel weight DMA during current compute
                    if (wgt_preload_active && wgt_dma_done) begin
                        wgt_load_done <= 1'b1;
                        wgt_preload_active <= 1'b0;
                        wgt_preload_done <= 1'b1;
                    end else if (wgt_preload_active && wgt_dma_error) begin
                        task_error_r <= 1'b1; task_error_code_r <= wgt_dma_error_code;
                        wgt_preload_active <= 1'b0;
                        fsm_state <= FSM_ERROR;
                    // FC Phase 1: check FC preload DMA completion
                    end else if (fc_preload_active && wgt_dma_done) begin
                        // P1: FC preload DMA complete
                        wgt_load_done <= 1'b1;
                        fc_preload_active <= 1'b0;
                        fc_preload_done  <= 1'b1;
                    end else if (fc_preload_active && wgt_dma_error) begin
                        task_error_r <= 1'b1; task_error_code_r <= wgt_dma_error_code;
                        fc_preload_active <= 1'b0;
                        fsm_state <= FSM_ERROR;
                    end else begin
                    // P2 fix: COLLECT merged into CP_DRAIN (DRAIN+COLLECT overlap).
                    // conv preload must trigger during CP_DRAIN collect phase.
                    if (is_conv_mode && !wgt_preload_active && !wgt_preload_done &&
                        (comp_drain_cnt > array_drain_offset) && !acc_collect_wait &&
                        (cin_idx + 16'd1 < cin_total)) begin
                        wgt_preload_active <= 1'b1;
                        wgt_preload_bank <= ~wgt_consume_bank;
                        wgt_preload_cin <= cin_idx + 16'd1;
                        wgt_preload_byte_offset <= conv_next_wgt_dma_base[4:0];
                        wgt_load_bank <= ~wgt_consume_bank;
                        wgt_dma_start <= 1'b1;
                        wgt_dma_addr <= {conv_next_wgt_dma_base[31:5], 5'b0};
                        wgt_dma_byte_offset <= conv_next_wgt_dma_base[4:0];
                        wgt_dma_bytes <= conv_wgt_valid_bytes + {27'd0, conv_next_wgt_dma_base[4:0]};
                        wgt_load_start <= 1'b1;
                    // P1: FC tile preload trigger — start DMA for next tile
                    // during early compute of current tile.
                    // Uses correct byte_offset (was hardcoded to 0, causing
                    // misaligned preloads when next_tile * input_c not 32B-aligned).
                    end else if (is_fc_mode &&
                                 !fc_preload_active && !fc_preload_done &&
                                 (fc_out_start + fc_tile_outputs < output_c)) begin
                        fc_preload_active  <= 1'b1;
                        fc_preload_bank    <= ~wgt_consume_bank;
                        fc_preload_out_start <= fc_out_start + fc_tile_outputs;
                        fc_preload_tile_outputs <= fc_preload_tile_outputs_next;
                        fc_preload_byte_offset <= fc_preload_wgt_base[4:0];
                        wgt_load_bank <= ~wgt_consume_bank;
                        wgt_dma_start <= 1'b1;
                        wgt_dma_addr <= {fc_preload_wgt_base[31:5], 5'b0};
                        wgt_dma_byte_offset <= fc_preload_wgt_base[4:0];
                        wgt_dma_bytes <= fc_preload_tile_outputs_next * input_c +
                                         {27'd0, fc_preload_wgt_base[4:0]};
                        wgt_load_start <= 1'b1;
                    end
                    case (comp_sub_state)
                        CP_WAIT_WIN: begin
                            if (fc_or_gemm) begin
                                comp_feed_cnt <= 7'd0;
                                comp_sub_state <= CP_FEED_ACT;
                            end else if (is_pool_mode) begin
                                // Pool: feed INT32 words, wait for postproc to finish
                                if (act_feed_wait) begin
                                    act_feed_wait <= 1'b0;
                                end else if (!pp_start && (act_feed_done_cnt < blk_in_bytes[15:0])) begin
                                    if ((act_feed_ptr[2:0] == 3'd7) &&
                                        (act_feed_done_cnt + 16'd4 < blk_in_bytes[15:0]))
                                        act_feed_wait <= 1'b1;
                                    act_feed_ptr <= act_feed_ptr + 1;
                                    act_feed_done_cnt <= act_feed_done_cnt + 16'd4;
                                end
                                if (!pp_start && pp_done) begin
                                    act_comp_done <= 1'b1;
                                    if (pipe_mode) begin
                                        // P3: pipe mode — store already running
                                        if (pipe_store_done) fsm_state <= FSM_BLK_DONE;
                                        else fsm_state <= FSM_PIPE_DONE;
                                    end else begin
                                        acc_load_start <= 1'b1;
                                        fsm_state <= FSM_STORE;
                                    end
                                end
                            end else begin
                                // Conv: feed activations to conv_frontend
                                if (act_feed_wait) begin
                                    act_feed_wait <= 1'b0;
                                end else if (conv_act_ready && (act_feed_done_cnt < blk_in_bytes[15:0])) begin
                                    if ((act_feed_ptr[4:0] == 5'd31) &&
                                        (act_feed_done_cnt + 16'd1 < blk_in_bytes[15:0]))
                                        act_feed_wait <= 1'b1;
                                    act_feed_ptr <= act_feed_ptr + 1;
                                    act_feed_done_cnt <= act_feed_done_cnt + 16'd1;
                                end
                                if (cf_new_window) begin
                                    comp_feed_cnt <= 7'd0;
                                    comp_sub_state <= CP_FEED_ACT;
                                end else if (cf_done) begin
                                    comp_sub_state <= CP_NEXT;
                                end
                            end
                        end

                        CP_FEED_ACT: begin
                            if ({9'd0, comp_feed_cnt} < array_active_rows) begin
                                comp_feed_cnt <= comp_feed_cnt + 7'd1;
                            end else begin
                                comp_drain_cnt <= 16'd0;
                                // P0 FIX: pre-set acc_collect_wait to block spurious writes
                                // before the COLLECT init at drain_offset.  Without this,
                                // the first drain cycles (before drain_offset) and the
                                // init cycle itself (comp_drain_cnt == drain_offset, where
                                // acc_collect_wait NBA hasn't taken effect yet) can write
                                // stale col_results to acc_buffer, corrupting partial sums.
                                acc_collect_wait <= 1'b1;
                                // Set up partial sum address for this window
                                if (is_conv_mode) begin
                                    conv_collect_base_next =
                                        ({16'd0, comp_win_idx} * {16'd0, collect_total_cols});
                                    acc_partial_addr <= conv_collect_base_next[BUF_ADDR_W-1:0];
                                end else if (fc_or_gemm) begin
                                    // GEMM row-by-row: each row stores N outputs to acc[0:N-1]
                                    acc_partial_addr <= {BUF_ADDR_W{1'b0}};
                                end
                                comp_sub_state <= CP_DRAIN;
                            end
                        end

                        // P2: CP_DRAIN with overlapped collect.
                        // Drain captures columns into col_results[].
                        // After first valid column (cnt >= offset), collect starts
                        // in parallel: reads col_results[], accumulates into acc_buffer.
                        // Both advance 1 column/cycle; drain leads by ~offset cycles.
                        CP_DRAIN: begin
                            // === DRAIN: capture column from PE array ===
                            if (cluster_arb_out_valid) begin
                                integer drain_cluster_idx;
                                integer drain_rank_i;
                                integer drain_count_i;
                                integer drain_base_i;
                                integer drain_end_i;
                                integer drain_global_col_i;
                                drain_count_i = (perf_cluster_count == 3'd0) ? 1 : perf_cluster_count;
                                if ((drain_count_i == 1) && perf_cluster_enable[0]) begin
                                    drain_global_col_i = comp_drain_cnt - array_drain_offset;
                                    if ((drain_global_col_i < array_active_cols) &&
                                        (drain_global_col_i < PE_COLS)) begin
                                        col_results[drain_global_col_i] <=
                                            array_sum_out[drain_global_col_i*32 +: 32];
                                    end
                                end else begin
                                    for (drain_cluster_idx = 0; drain_cluster_idx < CLUSTER_COUNT; drain_cluster_idx = drain_cluster_idx + 1) begin
                                        drain_rank_i = 0;
                                        for (drain_base_i = 0; drain_base_i < drain_cluster_idx; drain_base_i = drain_base_i + 1) begin
                                            if (perf_cluster_enable[drain_base_i])
                                                drain_rank_i = drain_rank_i + 1;
                                        end
                                        drain_base_i = (total_global_cols * drain_rank_i) / drain_count_i;
                                        drain_end_i  = (total_global_cols * (drain_rank_i + 1)) / drain_count_i;
                                        drain_global_col_i = drain_base_i + (comp_drain_cnt - array_drain_offset);
                                        if (perf_cluster_enable[drain_cluster_idx] &&
                                            (drain_global_col_i < drain_end_i) &&
                                            (drain_global_col_i < total_global_cols) &&
                                            (drain_global_col_i < PE_COLS)) begin
                                            col_results[drain_global_col_i] <=
                                                array_sum_out[drain_global_col_i*32 +: 32];
                                        end
                                    end
                                end
                            end

                            // === COLLECT: start after first valid column ===
                            if (comp_drain_cnt == array_drain_offset) begin
                                // First valid column captured; init collect
                                acc_col_idx <= 16'd0;
                                if (fc_or_gemm)
                                    acc_partial_addr <= {BUF_ADDR_W{1'b0}};
                                acc_collect_wait <= 1'b1;
                                acc_collect_skip_write <= 1'b0;
                            end else if (comp_drain_cnt > array_drain_offset) begin
                                // Continue collecting in parallel with drain
                                if (acc_collect_wait) begin
                                    acc_collect_wait <= 1'b0;
                                end else if (acc_col_idx + 16'd1 < collect_total_cols) begin
                                    acc_col_idx <= acc_col_idx + 16'd1;
                                    acc_partial_addr <= acc_partial_addr + 1;
                                    if (is_conv_mode) begin
                                        acc_collect_skip_write <=
                                            (comp_total_wins != 16'd1) &&
                                            (comp_win_idx + 16'd1 >= comp_total_wins) &&
                                            (acc_col_idx + 16'd2 >= collect_total_cols) &&
                                            ((acc_partial_addr + {{(BUF_ADDR_W-1){1'b0}}, 1'b1}) == {BUF_ADDR_W{1'b0}});
                                    end
                                end
                            end

                            // === Termination: both drain and collect complete ===
                            // comp_drain_cnt > offset ensures collect has actually started
                            // (previously the termination fired on the same cycle as init).
                            if ((comp_drain_cnt > array_drain_offset) &&
                                (comp_drain_cnt >= (array_drain_offset + array_active_cols - 1)) &&
                                (acc_col_idx + 16'd1 >= collect_total_cols) &&
                                !acc_collect_wait &&
                                (!is_fc_mode ||
                                 !fc_shadow_active ||
                                 (fc_shadow_phase >= (fc_shadow_chunk_inputs * fc_tile_outputs)) ||
                                 !(fc_in_base + fc_chunk_inputs < input_c))) begin
                                acc_collect_skip_write <= 1'b0;
                                if (fc_or_gemm) begin
                                    if (fc_in_base + fc_chunk_inputs < input_c) begin
                                        // P0 FIX: Bypass Phase-2 shadow register.
                                        // Shadow weight preload can fail to complete before
                                        // compute finishes (P2 reduced compute from 261→133
                                        // cycles, shadow needs ~256).  Instead of swapping
                                        // possibly-incomplete wgt_load_reg_shadow, go through
                                        // FSM_LOAD_ARRAY which reloads the next chunk's weights
                                        // directly from wgt_buffer.  Cost: ~128 cycles per
                                        // additional K-chunk.  Correctness > performance.
                                        if (is_gemm_mode)
                                            gemm_weight_valid <= 1'b0;
                                        fc_in_base <= fc_in_base + fc_chunk_inputs;
                                        fc_chunk_inputs <= ((input_c - (fc_in_base + fc_chunk_inputs)) > PE_ROWS_16) ?
                                                           PE_ROWS_16 :
                                                           (input_c - (fc_in_base + fc_chunk_inputs));
                                        wgt_load_phase <= 32'd0;
                                        wgt_load_wait <= 1'b1;
                                        fc_shadow_active <= 1'b0;
                                        fsm_state <= FSM_LOAD_ARRAY;
                                    end else begin
                                        if (is_gemm_mode) begin
                                            // GEMM row-by-row store: 32B-aligned row stride
                                            // Row stride = ceil(N*4/32)*32 to keep DMA addr aligned
                                            fc_store_addr <= blk_out_addr + (gemm_row_idx * ((gemm_N_val * 32'd4 + 32'd31) & 32'hFFFF_FFE0));
                                            fc_store_bytes <= gemm_N_val * 32'd4;
                                            dma_wr_addr <= blk_out_addr + (gemm_row_idx * ((gemm_N_val * 32'd4 + 32'd31) & 32'hFFFF_FFE0));
                                            dma_wr_bytes <= gemm_N_val * 32'd4;
                                            acc_load_start <= 1'b1;
                                            fsm_state <= FSM_STORE;
                                        end else if (bias_enabled) begin
                                            rq_mode_internal <= 1'b1;
                                            rq_word_store_mode <= 1'b0;
                                            rq_src_idx <= 32'd0;
                                            rq_src_wait <= 1'b1;
                                            rq_total_words <= {16'd0, fc_tile_outputs};
                                            rq_pack_idx <= 2'd0;
                                            rq_pack_word <= 32'd0;
                                            rq_store_addr <= blk_out_addr + {16'd0, fc_out_start};
                                            rq_store_bytes <= {16'd0, fc_tile_outputs};
                                            acc_load_start <= 1'b1;
                                            fsm_state <= FSM_REQUANT_COMPUTE;
                                        end else begin
                                            fc_store_addr <= blk_out_addr + fc_out_start * 32'd4;
                                            fc_store_bytes <= fc_tile_outputs * 32'd4;
                                            acc_load_start <= 1'b1;
                                            fsm_state <= FSM_STORE;
                                        end
                                    end
                                    comp_sub_state <= CP_WAIT_WIN;
                                end else begin
                                    comp_sub_state <= CP_NEXT;
                                end
                            end else begin
                                comp_drain_cnt <= comp_drain_cnt + 16'd1;
                            end
                        end

                        CP_COLLECT: begin
                            if (acc_collect_wait) begin
                                acc_collect_wait <= 1'b0;
                            end else if (acc_col_idx + 16'd1 < collect_total_cols) begin
                                acc_col_idx <= acc_col_idx + 16'd1;
                                acc_partial_addr <= acc_partial_addr + 1;
                                // P2: single-cycle per column for FC (removed 2-cycle wait).
                                // Conv already runs 1 cycle/column (acc_collect_wait not set).
                                // Safe because each column writes to different acc_buffer addr.
                                if (is_conv_mode) begin
                                    acc_collect_skip_write <=
                                        (comp_total_wins != 16'd1) &&
                                        (comp_win_idx + 16'd1 >= comp_total_wins) &&
                                        (acc_col_idx + 16'd2 >= collect_total_cols) &&
                                        ((acc_partial_addr + {{(BUF_ADDR_W-1){1'b0}}, 1'b1}) == {BUF_ADDR_W{1'b0}});
                                end
                            end else begin
                                acc_collect_skip_write <= 1'b0;
                                if (is_fc_mode) begin
                                    if (fc_in_base + fc_chunk_inputs < input_c) begin
                                        // P0 FIX: Same as CP_DRAIN path — bypass shadow.
                                        // Reload weights via LOAD_ARRAY for safety.
                                        fc_in_base <= fc_in_base + fc_chunk_inputs;
                                        fc_chunk_inputs <= ((input_c - (fc_in_base + fc_chunk_inputs)) > PE_ROWS_16) ?
                                                           PE_ROWS_16 :
                                                           (input_c - (fc_in_base + fc_chunk_inputs));
                                        wgt_load_phase <= 32'd0;
                                        wgt_load_wait <= 1'b1;
                                        fc_shadow_active <= 1'b0;
                                        fsm_state <= FSM_LOAD_ARRAY;
                                    end else begin
                                        if (bias_enabled) begin
                                            rq_mode_internal <= 1'b1;
                                            rq_word_store_mode <= 1'b0;
                                            rq_src_idx <= 32'd0;
                                            rq_src_wait <= 1'b1;
                                            rq_total_words <= {16'd0, fc_tile_outputs};
                                            rq_pack_idx <= 2'd0;
                                            rq_pack_word <= 32'd0;
                                            rq_store_addr <= blk_out_addr + {16'd0, fc_out_start};
                                            rq_store_bytes <= {16'd0, fc_tile_outputs};
                                            acc_load_start <= 1'b1;
                                            fsm_state <= FSM_REQUANT_COMPUTE;
                                        end else begin
                                            fc_store_addr <= blk_out_addr + fc_out_start * 32'd4;
                                            fc_store_bytes <= fc_tile_outputs * 32'd4;
                                            acc_load_start <= 1'b1;
                                            fsm_state <= FSM_STORE;
                                        end
                                    end
                                    comp_sub_state <= CP_WAIT_WIN;
                                end else begin
                                    comp_sub_state <= CP_NEXT;
                                end
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
                end

                // ============================================================
                // FSM_CIN_NEXT: check if more input channels
                // ============================================================
                FSM_CIN_NEXT: begin
                    if (cin_idx + 16'd1 < cin_total) begin
                        cin_idx <= cin_idx + 16'd1;
                        // Restart conv_frontend and reset feed pointers for next c_in
                        act_feed_ptr <= 0;
                        act_feed_wait <= 1'b1;
                        act_feed_done_cnt <= 16'd0;
                        comp_win_idx <= 16'd0;
                        fsm_state <= FSM_CIN_RESTART;
                    end else begin
                        act_comp_done <= 1'b1;
                        if (bias_enabled) begin
                            rq_mode_internal <= 1'b1;
                            // The scheduler's Conv block byte count is the legacy
                            // 32-bit-word layout. A task that requests fewer bytes
                            // explicitly selects dense INT8 requant packing.
                            rq_word_store_mode <= (output_bytes == blk_out_bytes);
                            rq_src_idx <= 32'd0;
                            rq_src_wait <= 1'b1;
                            rq_total_words <= blk_conv_output_elements;
                            rq_pack_idx <= 2'd0;
                            rq_pack_word <= 32'd0;
                            rq_store_addr <= (output_bytes == blk_out_bytes)
                                             ? blk_out_addr
                                             : output_addr + ((blk_out_addr - output_addr) >> 2);
                            rq_store_bytes <= (output_bytes == blk_out_bytes)
                                              ? blk_out_bytes
                                              : blk_conv_output_elements;
                            acc_load_start <= 1'b1;
                            fsm_state <= FSM_REQUANT_COMPUTE;
                        end else if (pipe_mode) begin
                            // P3: pipe mode — store already running
                            act_comp_done <= 1'b1;
                            if (pipe_store_done) begin
                                fsm_state <= FSM_BLK_DONE;
                            end else begin
                                fsm_state <= FSM_PIPE_DONE;
                            end
                        end else begin
                            acc_load_start <= 1'b1;
                            fsm_state <= FSM_STORE;
                        end
                    end
                end

                FSM_CIN_RESTART: begin
                    // Pulse cf_start, clear tracking for next c_in iteration
                    cf_last_row <= 16'hFFFF;
                    cf_last_col <= 16'hFFFF;
                    // Flush wgt_buffer so it can accept new DMA load for next c_in
                    if (!((wgt_preload_done || wgt_preload_active) && (wgt_preload_cin == cin_idx)))
                        wgt_buf_flush <= 1'b1;
                    fsm_state <= FSM_CIN_START;
                end

                // ============================================================
                // FSM_STORE: DMA write acc_buffer to memory
                // Store-pack state machine moved to shared block (below).
                // ============================================================
                FSM_STORE: begin
                    // P3: lock compute bank at STORE entry so reads come from
                    // the bank with computed results (not the load bank)
                    acc_comp_bank <= acc_load_bank;
                    dma_wr_addr <= rq_mode_internal ? rq_store_addr :
                                   is_add_mode ? output_addr :
                                   is_gap_mode ? output_addr :
                                   fc_or_gemm ? fc_store_addr :
                                   is_requant_mode ? rq_store_addr :
                                                     blk_out_addr;
                    dma_wr_bytes <= rq_mode_internal ? rq_store_bytes :
                                    is_add_mode ? output_bytes :
                                    is_gap_mode ? output_bytes :
                                    fc_or_gemm ? fc_store_bytes :
                                    is_requant_mode ? rq_store_bytes :
                                                      blk_out_bytes;
                    if (!dma_wr_started) begin
                        dma_wr_start <= 1'b1;
                        dma_wr_started <= 1'b1;
                        dma_rd_ptr <= 0;
                        store_rd_prefetch <= 0;
                        store_pack_state <= SP_IDLE;
                        store_pack_lane <= 3'd0;
                        store_word_idx <= 32'd0;
                        store_pack_data <= {AXI_DMA_DATA_W{1'b0}};
                        dma_wr_data_r <= {AXI_DMA_DATA_W{1'b0}};
                        dma_wr_valid_r <= 1'b0;
                    end

                    // P3: start next block's act+wgt DMA during current block STORE.
                    // 3-cycle sequence: (1) pulse blk_done, (2) wait for
                    // block_scheduler update, (3) check blk_all_done & launch.
                    // Gated for Conv/Pool; skipped for FC/requant/add/gap.
                    if (!next_blk_prep && !next_blk_wait && !next_dma_launched &&
                        dma_wr_started &&
                        !is_fc_mode && !is_requant_mode && !is_add_mode && !is_gap_mode) begin
                        next_blk_prep <= 1'b1;
                        blk_done <= 1'b1;
                    end else if (next_blk_prep) begin
                        next_blk_prep <= 1'b0;
                        next_blk_wait <= 1'b1;
                    end else if (next_blk_wait) begin
                        next_blk_wait <= 1'b0;
                        if (blk_valid) begin
                            act_dma_start <= 1'b1;
                            act_dma_addr <= blk_in_addr;
                            act_dma_bytes <= blk_in_bytes;
                            act_load_start <= 1'b1;
                            act_load_bank <= ~block_bank;
                            // P3: also launch wgt DMA for next block's first cin
                            wgt_dma_start <= 1'b1;
                            wgt_dma_addr <= {blk_wgt_addr[31:5], 5'b0};
                            wgt_dma_byte_offset <= blk_wgt_addr[4:0];
                            wgt_dma_bytes <= blk_wgt_bytes + {27'd0, blk_wgt_addr[4:0]};
                            wgt_load_start <= 1'b1;
                            wgt_load_bank <= ~block_bank;
                        end
                        // Set launched regardless to prevent re-firing
                        next_dma_launched <= 1'b1;
                    end

                    // P3: enter full pipeline — store continues (shared block),
                    // compute starts for next block.
                    if (next_dma_launched && act_dma_done && wgt_dma_done && !pipe_mode &&
                        blk_valid && !is_fc_mode && !is_requant_mode &&
                        !is_add_mode && !is_gap_mode && !is_vec_relu_mode) begin
                        pipe_mode <= 1'b1;
                        pipe_store_done <= 1'b0;
                        next_dma_launched <= 1'b0;
                        block_bank <= ~block_bank;
                        act_comp_bank <= ~block_bank;
                        acc_load_bank <= ~block_bank;
                        wgt_consume_bank <= ~block_bank;
                        wgt_load_done <= 1'b1;
                        wgt_preload_done <= 1'b1;
                        wgt_preload_bank <= ~block_bank;
                        wgt_preload_cin <= 16'd0;
                        act_feed_ptr <= 0;
                        act_feed_wait <= 1'b1;
                        act_feed_done_cnt <= 16'd0;
                        cin_idx <= 16'd0;
                        cin_total <= blk_cin_total;
                        wgt_per_cin <= blk_wgt_per_cin;
                        fsm_state <= FSM_PIPE_RUN;
                    end
                end

                // ============================================================
                // FSM_PIPE_RUN: P3 full pipeline — wait for next-block wgt DMA,
                // then launch compute while store runs in background.
                // ============================================================
                FSM_PIPE_RUN: begin
                    // Both DMAs already done (guaranteed by entry condition).
                    // Set up compute for next block and start conv_frontend.
                    comp_win_idx <= 16'd0;
                    comp_total_wins <= blk_out_rows * conv_total_out_cols;
                    comp_sub_state <= CP_WAIT_WIN;
                    cf_last_row <= 16'hFFFF;
                    cf_last_col <= 16'hFFFF;
                    cf_channel_sel <= 6'd0;
                    fsm_state <= FSM_CF_START;
                end

                // ============================================================
                // FSM_PIPE_DONE: compute finished, waiting for store to complete
                // ============================================================
                FSM_PIPE_DONE: begin
                    if (pipe_store_done || dma_wr_done) begin
                        pipe_mode <= 1'b0;
                        pipe_store_done <= 1'b0;
                        wgt_preload_done <= 1'b0;
                        wgt_load_done_r <= 1'b0;
                        wgt_load_phase <= 32'd0;
                        // Clean up old store state
                        dma_wr_valid_r <= 1'b0;
                        dma_wr_started <= 1'b0;
                        dma_rd_ptr <= 0;
                        store_pack_state <= SP_IDLE;
                        store_pack_lane <= 3'd0;
                        store_word_idx <= 32'd0;
                        store_pack_data <= {AXI_DMA_DATA_W{1'b0}};
                        next_dma_launched <= 1'b0;
                        next_blk_prep <= 1'b0;
                        next_blk_wait <= 1'b0;
                        // Enter STORE for the just-computed next block
                        acc_load_start <= 1'b1;
                        fsm_state <= FSM_STORE;
                    end
                end

                FSM_BLK_DONE: begin
                    fsm_state <= FSM_BLK_CHECK;
                end

                FSM_BLK_CHECK: begin
                    // P3: use !blk_valid instead of blk_all_done because
                    // block_scheduler may have already decayed S_DONE→S_IDLE
                    // (task_start=0 after initial validation). Both indicate
                    // no more blocks are available.
                    if (!blk_valid) begin
                        task_done_r <= 1'b1;
                        task_active_r <= 1'b0;
                        next_blk_prep <= 1'b0;
                        next_blk_wait <= 1'b0;
                        next_dma_launched <= 1'b0;
                        fsm_state <= FSM_DONE;
                    end else begin
                        // Next block
                        dma_rd_ptr <= 0;
                        dma_wr_started <= 1'b0;
                        block_bank <= ~block_bank;
                        wgt_load_phase <= 32'd0;
                        wgt_load_done_r <= 1'b0;
                        wgt_load_reg <= 0;
                        cf_last_row <= 16'hFFFF;
                        cf_last_col <= 16'hFFFF;
                        cin_idx <= 16'd0;
                        if (is_pool_mode) begin
                            // P3: skip DMA if already launched during STORE
                            if (!next_dma_launched) begin
                                act_dma_start <= 1'b1;
                                act_dma_addr <= blk_in_addr;
                                act_dma_bytes <= blk_in_bytes;
                                act_load_start <= 1'b1;
                                act_load_bank <= ~block_bank;
                            end
                            fsm_state <= FSM_LOAD_ACT;
                        end else begin
                            // P3: skip DMA if already launched during STORE
                            if (!next_dma_launched) begin
                                act_dma_start <= 1'b1;
                                act_dma_addr <= blk_in_addr;
                                act_dma_bytes <= blk_in_bytes;
                                act_load_start <= 1'b1;
                                act_load_bank <= ~block_bank;
                            end
                            fsm_state <= FSM_LOAD_ACT;
                        end
                        next_dma_launched <= 1'b0;
                        next_blk_wait <= 1'b0;
                    end
                end

                // ============================================================
                // Phase 2b-1: GEMM row-streaming states
                // ============================================================
                FSM_GEMM_STREAM_PREP: begin
                    stream_cycle <= 16'd0;
                    stream_capture_count <= 16'd0;
                    stream_active <= 1'b0;
                    stream_a_tile_loaded <= 1'b0;
                    gemm_a_load_done <= 1'b0;
                    comp_feed_cnt <= 7'd0;
                    // Phase 4a-2: bank selection — toggles per chunk
                    if (gemm_stream_first_chunk) begin
                        integer ci, cj;
                        for (ci = 0; ci < 8; ci = ci + 1)
                            for (cj = 0; cj < 64; cj = cj + 1) begin
                                c_tile[ci][cj] <= 32'sd0;
                                c_tile_valid[ci][cj] <= 1'b0;
                            end
                        // First chunk of new task: clear both banks to prevent
                        // stale data from previous tasks from matching prefetch.
                        input_bank0_valid <= 1'b0;
                        input_bank1_valid <= 1'b0;
                        wgt_stage_valid   <= 1'b0;
                        wgt_pref_valid    <= 1'b0;
                        wgt_pref_done     <= 1'b0;
                        wgt_pref_active   <= 1'b0;
                        // Phase 5-1: M tile descriptor set once per task at FC_TILE_PREP
                        // First chunk: load into bank0, compute from bank0
                        input_load_bank    <= 1'b0;
                        input_compute_bank <= 1'b0;
                        fsm_state <= FSM_GEMM_STREAM_LOAD_A;
                    end else begin
                        // Subsequent chunks: compute from the bank LOAD_A just loaded.
                        // input_load_bank was toggled in ACCUM before LOAD_A.
                        input_compute_bank <= input_load_bank;
                        // Check that the bank LOAD_A loaded has valid metadata
                        if (input_load_bank == 1'b0) begin
                            if (!input_bank0_valid ||
                                (input_bank0_k_base != gemm_stream_k_base) ||
                                (input_bank0_k_tile != fc_chunk_inputs)) begin
                                $display("[BANK_ERR] PREP bank0 mismatch: valid=%0d k_base=%0d/%0d k_tile=%0d/%0d",
                                    input_bank0_valid, input_bank0_k_base, gemm_stream_k_base,
                                    input_bank0_k_tile, fc_chunk_inputs);
                            end
                        end else begin
                            if (!input_bank1_valid ||
                                (input_bank1_k_base != gemm_stream_k_base) ||
                                (input_bank1_k_tile != fc_chunk_inputs)) begin
                                $display("[BANK_ERR] PREP bank1 mismatch: valid=%0d k_base=%0d/%0d k_tile=%0d/%0d",
                                    input_bank1_valid, input_bank1_k_base, gemm_stream_k_base,
                                    input_bank1_k_tile, fc_chunk_inputs);
                            end
                        end
                        // Skip LOAD_A — bank already loaded by ACCUM→LOAD_A
                        fsm_state <= FSM_GEMM_STREAM_RUN;
                    end
                    $display("[KCHUNK] PREP k_base=%0d k_chunk_idx=%0d first=%0d last=%0d load_bank=%0d comp_bank=%0d b0v=%0d b1v=%0d",
                        gemm_stream_k_base, gemm_stream_k_chunk_idx,
                        gemm_stream_first_chunk, gemm_stream_last_chunk,
                        input_load_bank, input_compute_bank,
                        input_bank0_valid, input_bank1_valid);
                end

                // ============================================================
                // Phase 4a-2: beat-level input-tile-loader with double-buffer
                // Reads input_tile_bank[load_bank][row][col] = A[row][k_base+col]
                // from act_buffer: one 256-bit beat per read, unpack up to 32 bytes.
                // Handles unaligned rows: up to 3 beats for 64 bytes.
                // ============================================================
                FSM_GEMM_STREAM_LOAD_A: begin
                    if (gemm_a_load_done) begin
                        // Micro-sequencer finished loading input tile.
                        // Mark loaded bank as valid with metadata.
                        if (input_load_bank == 1'b0) begin
                            input_bank0_valid  <= 1'b1;
                            input_bank0_k_base <= gemm_stream_k_base;
                            input_bank0_k_tile <= fc_chunk_inputs;
                        end else begin
                            input_bank1_valid  <= 1'b1;
                            input_bank1_k_base <= gemm_stream_k_base;
                            input_bank1_k_tile <= fc_chunk_inputs;
                        end
                        $display("[BEAT_LD] done: bank=%0d beats=%0d bytes=%0d unaligned_rows=%0d k_base=%0d k_tile=%0d",
                            input_load_bank, gemm_a_load_beat_count, gemm_a_load_byte_count,
                            gemm_a_load_unaligned_row_count, gemm_stream_k_base, fc_chunk_inputs);
                        // Route: first K-chunk of first M tile → RUN (weights pre-loaded);
                        //        first K-chunk of subsequent M tile → LOAD_ARRAY
                        //        (clear first_chunk so PREP doesn't re-clear c_tile);
                        //        K-chunk1+ → LOAD_ARRAY or WGT_LD if prefetched.
                        if (gemm_stream_first_chunk && (gemm_tile_m_base == 16'd0) && (gemm_tile_n_base == 16'd0))
                            fsm_state <= FSM_GEMM_STREAM_RUN;
                        else if (gemm_stream_first_chunk) begin
                            // New M or N tile: need weight reload, clear first_chunk
                            gemm_stream_first_chunk <= 1'b0;
                            wgt_load_phase <= 32'd0;
                            wgt_load_wait <= 1'b1;
                            fsm_state <= FSM_LOAD_ARRAY;
                        end else if (wgt_pref_valid &&
                                 (wgt_pref_k_base == gemm_stream_k_base) &&
                                 (wgt_pref_k_tile == fc_chunk_inputs) &&
                                 (wgt_pref_n_tile == fc_tile_outputs) && (wgt_pref_n_base == gemm_tile_n_base)) begin
                            // Weight was prefetched during previous RUN
                            wgt_pref_hit_count <= wgt_pref_hit_count + 16'd1;
                            wgt_pref_valid <= 1'b0;
                            wgt_pref_done  <= 1'b0;
                            $display("[WGT_PREF] HIT at LOAD_A done: k_base=%0d → skip LOAD_ARRAY",
                                gemm_stream_k_base);
                            fsm_state <= FSM_WGT_LD;
                        end else
                            fsm_state <= FSM_LOAD_ARRAY;
                    end else begin
                        // Micro-sequencer: 4-phase beat-level load
                        case (gemm_a_load_phase)
                            A_LOAD_IDLE: begin
                                gemm_a_load_row   <= 3'd0;
                                gemm_a_load_col   <= 7'd0;
                                gemm_a_load_beat_count <= 16'd0;
                                gemm_a_load_byte_count <= 16'd0;
                                gemm_a_load_unaligned_row_count <= 16'd0;
                                gemm_a_load_phase <= A_LOAD_REQ;
                            end
                            A_LOAD_REQ: begin
                                // act_rd_addr already driven by combinational mux;
                                // wait one cycle for synchronous buffer read latency.
                                gemm_a_load_phase <= A_LOAD_WAIT;
                            end
                            A_LOAD_WAIT: begin
                                // Data appears next cycle.
                                gemm_a_load_phase <= A_LOAD_CAPTURE;
                            end
                            A_LOAD_CAPTURE: begin
                                // Beat-level bulk unpack: up to 32 bytes from one 256-bit beat.
                                // Writes to input_tile_bank[input_load_bank].
                                integer lane_start_v;
                                integer remaining_v;
                                integer bytes_this_beat_v;
                                integer lane;
                                lane_start_v   = gemm_a_load_lane_start;
                                remaining_v    = fc_chunk_inputs - gemm_a_load_col;
                                bytes_this_beat_v = (remaining_v < (32 - lane_start_v)) ?
                                                      remaining_v : (32 - lane_start_v);

                                // Unpack valid bytes from this beat into load bank
                                if (input_load_bank == 1'b0) begin
                                    for (lane = 0; lane < 32; lane = lane + 1) begin
                                        if ((lane >= lane_start_v) &&
                                            ((lane - lane_start_v) < bytes_this_beat_v)) begin
                                            input_tile_bank0[gemm_a_load_row]
                                                [gemm_a_load_col + (lane - lane_start_v)]
                                                <= act_rd_data[lane * 8 +: 8];
                                        end
                                    end
                                end else begin
                                    for (lane = 0; lane < 32; lane = lane + 1) begin
                                        if ((lane >= lane_start_v) &&
                                            ((lane - lane_start_v) < bytes_this_beat_v)) begin
                                            input_tile_bank1[gemm_a_load_row]
                                                [gemm_a_load_col + (lane - lane_start_v)]
                                                <= act_rd_data[lane * 8 +: 8];
                                        end
                                    end
                                end

                                // Debug counters
                                gemm_a_load_beat_count <= gemm_a_load_beat_count + 16'd1;
                                gemm_a_load_byte_count <= gemm_a_load_byte_count
                                    + {10'd0, bytes_this_beat_v[5:0]};
                                if ((gemm_a_load_col == 7'd0) && (lane_start_v != 0))
                                    gemm_a_load_unaligned_row_count <=
                                        gemm_a_load_unaligned_row_count + 16'd1;

                                // Advance col by bytes captured this beat
                                if (gemm_a_load_col + bytes_this_beat_v >= fc_chunk_inputs) begin
                                    // Row complete: zero-fill in load bank
                                    if (input_load_bank == 1'b0) begin
                                        for (lane = fc_chunk_inputs; lane < 64; lane = lane + 1)
                                            input_tile_bank0[gemm_a_load_row][lane] <= 8'd0;
                                    end else begin
                                        for (lane = fc_chunk_inputs; lane < 64; lane = lane + 1)
                                            input_tile_bank1[gemm_a_load_row][lane] <= 8'd0;
                                    end

                                    if (gemm_a_load_row + 3'd1 < gemm_tile_M) begin
                                        gemm_a_load_row   <= gemm_a_load_row + 3'd1;
                                        gemm_a_load_col   <= 7'd0;
                                        gemm_a_load_phase <= A_LOAD_REQ;
                                    end else begin
                                        // All rows done
                                        gemm_a_load_done  <= 1'b1;
                                        gemm_a_load_phase <= A_LOAD_IDLE;
                                    end
                                end else begin
                                    gemm_a_load_col   <= gemm_a_load_col
                                        + {1'd0, bytes_this_beat_v[5:0]};
                                    gemm_a_load_phase <= A_LOAD_REQ;
                                end
                            end
                            default: gemm_a_load_phase <= A_LOAD_IDLE;
                        endcase
                    end
                end

                FSM_GEMM_STREAM_RUN: begin
                    // Phase 4a-3: on first cycle of RUN, trigger background prefetch
                    // of next chunk's input tile into the inactive bank.
                    if ((stream_cycle == 16'd0) && !gemm_stream_last_chunk &&
                        !input_prefetch_active) begin
                        // Compute next chunk's k_base and k_tile
                        // next_k_base = gemm_stream_k_base + fc_chunk_inputs
                        // next_k_tile = min(64, input_c - next_k_base)
                        automatic integer nk_base;
                        automatic integer nk_tile;
                        nk_base = gemm_stream_k_base + fc_chunk_inputs;
                        nk_tile = (input_c - nk_base > 64) ? 64 : (input_c - nk_base);
                        // Launch prefetch only if bank not already valid with matching meta
                        if (!((input_bank0_valid && (input_bank0_k_base == nk_base) &&
                               (input_bank0_k_tile == nk_tile)) ||
                              (input_bank1_valid && (input_bank1_k_base == nk_base) &&
                               (input_bank1_k_tile == nk_tile)))) begin
                            input_prefetch_active <= 1'b1;
                            input_prefetch_done  <= 1'b0;
                            input_prefetch_bank  <= ~input_compute_bank;
                            input_prefetch_k_base <= nk_base;
                            input_prefetch_k_tile <= nk_tile;
                            input_prefetch_row   <= 3'd0;
                            input_prefetch_col   <= 7'd0;
                            input_prefetch_phase <= PREF_REQ;
                            input_prefetch_beat_count <= 16'd0;
                            input_prefetch_byte_count <= 16'd0;
                            input_prefetch_start_count <= input_prefetch_start_count + 16'd1;
                            $display("[PREFETCH] START bank=%0d k_base=%0d k_tile=%0d comp_bank=%0d",
                                ~input_compute_bank, nk_base, nk_tile, input_compute_bank);
                        end
                        // Phase 4b-2: also trigger background weight prefetch
                        if (1'b0 && !wgt_pref_active && !wgt_pref_done &&
                            !(wgt_pref_valid &&
                              (wgt_pref_k_base == nk_base) &&
                              (wgt_pref_k_tile == nk_tile) &&
                              (wgt_pref_n_tile == fc_tile_outputs) && (wgt_pref_n_base == gemm_tile_n_base))) begin
                            wgt_pref_active   <= 1'b1;
                            wgt_pref_done     <= 1'b0;
                            wgt_pref_valid    <= 1'b0;
                            wgt_pref_k_base   <= nk_base;
                            wgt_pref_k_tile   <= nk_tile;
                            wgt_pref_n_tile   <= fc_tile_outputs;
                            wgt_pref_n_base   <= gemm_tile_n_base;
                            wgt_pref_lane_idx <= 16'd0;
                            wgt_pref_phase    <= WGT_PREF_REQ;
                            wgt_pref_beat_count <= 16'd0;
                            wgt_pref_byte_count <= 16'd0;
                            wgt_pref_start_count <= wgt_pref_start_count + 16'd1;
                            $display("[WGT_PREF] START k_base=%0d k_tile=%0d n_tile=%0d",
                                nk_base, nk_tile, fc_tile_outputs);
                        end
                    end
                    stream_cycle <= stream_cycle + 16'd1;
                    if (cluster_arb_out_valid) begin
                        integer str_n;
                        for (str_n = 0; str_n < PE_COLS; str_n = str_n + 1) begin
                            if (str_n < array_active_cols) begin
                                reg signed [31:0] str_m;
                                str_m = $signed({16'd0, stream_cycle}) - $signed({16'd0, active_k}) - $signed({16'd0, str_n}) - $signed({16'd0, stream_pipe_offset});
                                if (!str_m[31] && str_m < gemm_tile_M && str_n < gemm_N_val) begin
                                    if (gemm_stream_first_chunk) begin
                                        // First K-chunk: write-once (v1 behavior)
                                        if (!c_tile_valid[str_m][str_n]) begin
                                            c_tile[str_m][str_n] <= array_sum_out[str_n*32 +: 32];
                                            c_tile_valid[str_m][str_n] <= 1'b1;
                                        end
                                    end else begin
                                        // Subsequent K-chunk: accumulate
                                        c_tile[str_m][str_n] <= $signed(c_tile[str_m][str_n])
                                                              + $signed(array_sum_out[str_n*32 +: 32]);
                                    end
                                end
                            end
                        end
                    end
                    if (stream_cycle >= (gemm_tile_M + active_k + array_active_cols + stream_pipe_offset + 16'd10)) begin
                        stream_active <= 1'b0;
                        fsm_state <= FSM_GEMM_STREAM_ACCUM;  // Phase 3a: check K-chunk loop
                    end
                end

                // Phase 4a-3: K-chunk loop with prefetch-aware routing
                // If next chunk's input tile was prefetched during RUN,
                // skip foreground LOAD_A and go directly to LOAD_ARRAY.
                FSM_GEMM_STREAM_ACCUM: begin
                    if (fc_in_base + fc_chunk_inputs < input_c) begin
                        // More K-chunks remain
                        automatic integer next_kb;
                        automatic integer next_kt;
                        next_kb = fc_in_base + fc_chunk_inputs;
                        next_kt = (input_c - next_kb > PE_ROWS_16) ? PE_ROWS_16 : (input_c - next_kb);

                        // Phase 4b-2: also check weight prefetch stall
                        if (input_prefetch_active || wgt_pref_active) begin
                            if (input_prefetch_active) begin
                                input_prefetch_stall_count <= input_prefetch_stall_count + 16'd1;
                                $display("[PREFETCH] STALL bank=%0d k_base=%0d",
                                    input_prefetch_bank, input_prefetch_k_base);
                            end
                            if (wgt_pref_active) begin
                                wgt_pref_stall_count <= wgt_pref_stall_count + 16'd1;
                                $display("[WGT_PREF] STALL k_base=%0d", wgt_pref_k_base);
                            end
                        end else if (input_bank0_valid && (input_bank0_k_base == next_kb) &&
                                       (input_bank0_k_tile == next_kt) &&
                                       (1'b0 != input_compute_bank)) begin
                            // Input prefetch HIT: bank0 has next chunk's A data.
                            input_prefetch_hit_count <= input_prefetch_hit_count + 16'd1;
                            gemm_stream_k_base       <= next_kb;
                            gemm_stream_k_chunk_idx  <= gemm_stream_k_chunk_idx + 16'd1;
                            gemm_stream_first_chunk  <= 1'b0;
                            gemm_stream_last_chunk   <= ((next_kb + next_kt) >= input_c);
                            if (is_gemm_mode) gemm_weight_valid <= 1'b0;
                            fc_in_base <= next_kb;
                            fc_chunk_inputs <= next_kt;
                            input_load_bank <= 1'b0;
                            fc_shadow_active <= 1'b0;
                            // Check weight prefetch hit too
                            if (wgt_pref_valid &&
                                (wgt_pref_k_base == next_kb) &&
                                (wgt_pref_k_tile == next_kt) &&
                                (wgt_pref_n_tile == fc_tile_outputs) && (wgt_pref_n_base == gemm_tile_n_base)) begin
                                // Dual HIT: skip both LOAD_A and LOAD_ARRAY
                                wgt_pref_hit_count <= wgt_pref_hit_count + 16'd1;
                                wgt_pref_valid <= 1'b0;
                                wgt_pref_done  <= 1'b0;
                                dbg_dual_hit_count <= dbg_dual_hit_count + 16'd1;
                                dbg_accum_to_wgtld_direct <= dbg_accum_to_wgtld_direct + 16'd1;
                                $display("[DUAL_HIT] bank0 + wgt_pref k_base=%0d (skip LOAD_A+LOAD_ARRAY → WGT_LD)",
                                    next_kb);
                                fsm_state <= FSM_WGT_LD;
                            end else begin
                                // Input hit only: skip LOAD_A, go to LOAD_ARRAY
                                wgt_load_phase <= 32'd0;
                                wgt_load_wait <= 1'b1;
                                $display("[PREFETCH] HIT bank0 k_base=%0d k_chunk=%0d (skip LOAD_A)",
                                    next_kb, gemm_stream_k_chunk_idx + 16'd1);
                                fsm_state <= FSM_LOAD_ARRAY;
                            end
                        end else if (input_bank1_valid && (input_bank1_k_base == next_kb) &&
                                       (input_bank1_k_tile == next_kt) &&
                                       (1'b1 != input_compute_bank)) begin
                            // Input prefetch HIT: bank1 has next chunk's A data
                            input_prefetch_hit_count <= input_prefetch_hit_count + 16'd1;
                            gemm_stream_k_base       <= next_kb;
                            gemm_stream_k_chunk_idx  <= gemm_stream_k_chunk_idx + 16'd1;
                            gemm_stream_first_chunk  <= 1'b0;
                            gemm_stream_last_chunk   <= ((next_kb + next_kt) >= input_c);
                            if (is_gemm_mode) gemm_weight_valid <= 1'b0;
                            fc_in_base <= next_kb;
                            fc_chunk_inputs <= next_kt;
                            input_load_bank <= 1'b1;
                            fc_shadow_active <= 1'b0;
                            // Check weight prefetch hit too
                            if (wgt_pref_valid &&
                                (wgt_pref_k_base == next_kb) &&
                                (wgt_pref_k_tile == next_kt) &&
                                (wgt_pref_n_tile == fc_tile_outputs) && (wgt_pref_n_base == gemm_tile_n_base)) begin
                                // Dual HIT
                                wgt_pref_hit_count <= wgt_pref_hit_count + 16'd1;
                                wgt_pref_valid <= 1'b0;
                                wgt_pref_done  <= 1'b0;
                                dbg_dual_hit_count <= dbg_dual_hit_count + 16'd1;
                                dbg_accum_to_wgtld_direct <= dbg_accum_to_wgtld_direct + 16'd1;
                                $display("[DUAL_HIT] bank1 + wgt_pref k_base=%0d (skip LOAD_A+LOAD_ARRAY → WGT_LD)",
                                    next_kb);
                                fsm_state <= FSM_WGT_LD;
                            end else begin
                                wgt_load_phase <= 32'd0;
                                wgt_load_wait <= 1'b1;
                                dbg_accum_to_load_array <= dbg_accum_to_load_array + 16'd1;
                                $display("[PREFETCH] HIT bank1 k_base=%0d k_chunk=%0d (skip LOAD_A)",
                                    next_kb, gemm_stream_k_chunk_idx + 16'd1);
                                fsm_state <= FSM_LOAD_ARRAY;
                            end
                        end else begin
                            // Fallback: no prefetch data — use foreground LOAD_A
                            // Also handles first chunk after RUN0 (prefetch started but not done)
                            gemm_stream_k_base       <= next_kb;
                            gemm_stream_k_chunk_idx  <= gemm_stream_k_chunk_idx + 16'd1;
                            gemm_stream_first_chunk  <= 1'b0;
                            gemm_stream_last_chunk   <= ((next_kb + next_kt) >= input_c);
                            if (is_gemm_mode) gemm_weight_valid <= 1'b0;
                            fc_in_base <= next_kb;
                            fc_chunk_inputs <= next_kt;
                            input_load_bank <= ~input_load_bank;
                            gemm_a_load_done <= 1'b0;
                            wgt_load_phase <= 32'd0;
                            wgt_load_wait <= 1'b1;
                            fc_shadow_active <= 1'b0;
                            $display("[KCHUNK] ACCUM: advance k_base=%0d k_chunk=%0d k_tile=%0d (fg LOAD_A bank=%0d)",
                                next_kb, gemm_stream_k_chunk_idx + 16'd1, next_kt,
                                ~input_load_bank);
                            fsm_state <= FSM_GEMM_STREAM_LOAD_A;
                        end
                    end else begin
                        // All K-chunks done: proceed to STORE
                        $display("[KCHUNK] ACCUM: all %0d chunks done, starting STORE",
                            gemm_stream_k_chunk_idx + 16'd1);
                        $display("[FSM_DBG] LOAD_ARRAY_entries=%0d WGT_LD_entries=%0d DUAL_HIT=%0d ACCUM→WGT_LD=%0d ACCUM→LOAD_ARRAY=%0d",
                            dbg_load_array_entry, dbg_wgt_ld_entry,
                            dbg_dual_hit_count, dbg_accum_to_wgtld_direct,
                            dbg_accum_to_load_array);
                        fsm_state <= FSM_GEMM_STREAM_DONE;
                    end
                end

                FSM_GEMM_STREAM_DONE: begin
                    // Start direct c_tile → DMA STORE
                    gemm_store_row_idx <= 16'd0;
                    gemm_store_beat_idx <= 16'd0;
                    fsm_state <= FSM_GEMM_STREAM_STORE;
                end

                FSM_GEMM_STREAM_STORE: begin
                    // Pack c_tile[row][base_col +: 8] → 256-bit beat per DMA transaction
                    // Multi-beat: N>8 → multiple beats per row (Scheme B: 1 txn per beat)
                    reg [255:0] beat;
                    reg [31:0]  wstrb_val;
                    reg [15:0]  base_col;
                    reg [15:0]  remaining_cols;
                    reg [15:0]  this_beat_cols;
                    reg [31:0]  row_stride_bytes;
                    integer lane;
                    row_stride_bytes = (gemm_N_val * 32'd4 + 32'd31) & 32'hFFFF_FFE0;
                    base_col = gemm_store_beat_idx << 3;  // * 8
                    remaining_cols = gemm_tile_N - base_col;
                    this_beat_cols = (remaining_cols > 16'd8) ? 16'd8 : remaining_cols;
                    beat = 256'd0;
                    wstrb_val = 32'd0;
                    for (lane = 0; lane < this_beat_cols; lane = lane + 1) begin
                        beat[lane*32 +: 32] = c_tile[gemm_store_row_idx][base_col + lane];
                        wstrb_val[lane*4 +: 4] = 4'hF;
                    end
                    dma_wr_data_r <= beat;
                    dma_wr_valid_r <= 1'b1;
                    // Setup DMA writer (one beat per transaction)
                    if (!dma_wr_started) begin
                        dma_wr_start <= 1'b1;
                        dma_wr_started <= 1'b1;
                        dma_wr_addr <= blk_out_addr
                            + ((gemm_tile_m_base + gemm_store_row_idx) * row_stride_bytes)
                            + {12'd0, gemm_tile_n_base, 2'b0}
                            + ({16'd0, gemm_store_beat_idx} << 5);
                        dma_wr_bytes <= {16'd0, this_beat_cols} << 2;  // this_beat_cols * 4
                    end
                    $display("[DIR_ST] row=%0d beat=%0d base_col=%0d cols=%0d addr=0x%08x bytes=%0d wstrb=0x%08x",
                        gemm_store_row_idx, gemm_store_beat_idx, base_col, this_beat_cols,
                        blk_out_addr + ((gemm_tile_m_base + gemm_store_row_idx) * row_stride_bytes)
                            + (gemm_store_beat_idx * 32),
                        this_beat_cols * 4, wstrb_val);
                    // Wait for DMA write to complete, then next beat or next row
                    fsm_state <= FSM_GEMM_STREAM_STORE + 6'd1;  // 6'd39 wait state
                end

                // Wait for DMA write done (per-beat transaction)
                6'd39: begin
                    dma_wr_valid_r <= 1'b0;
                    if (dma_wr_done) begin
                        $display("[DIR_ST] row=%0d beat=%0d dma_done", gemm_store_row_idx, gemm_store_beat_idx);
                        dma_wr_started <= 1'b0;
                        // beats_per_row = ceil(tile_N / 8)
                        if (gemm_store_beat_idx + 16'd1 < ((gemm_tile_N + 16'd7) >> 3)) begin
                            // More beats in current row
                            gemm_store_beat_idx <= gemm_store_beat_idx + 16'd1;
                            fsm_state <= FSM_GEMM_STREAM_STORE;
                        end else if (gemm_store_row_idx + 16'd1 < gemm_tile_M) begin
                            // Next row
                            gemm_store_row_idx <= gemm_store_row_idx + 16'd1;
                            gemm_store_beat_idx <= 16'd0;
                            fsm_state <= FSM_GEMM_STREAM_STORE;
                        end else begin
                            // All rows of current tile stored
                            // Phase 5-2: N tile loop inside M tile loop
                            if (gemm_tile_n_base + gemm_tile_N < gemm_N_val) begin
                                // More N tiles in current M tile
                                automatic integer next_n_base;
                                next_n_base = gemm_tile_n_base + gemm_tile_N;
                                gemm_tile_n_base <= next_n_base;
                                gemm_tile_N <= (gemm_N_val - next_n_base > PE_COLS_16) ?
                                               PE_COLS_16 : (gemm_N_val - next_n_base);
                                // Also update fc_tile_outputs for PE array sizing
                                fc_tile_outputs <= (gemm_N_val - next_n_base > PE_COLS_16) ?
                                                   PE_COLS_16 : (gemm_N_val - next_n_base);
                                // Reset K-chunk state for new N tile
                                gemm_stream_k_base       <= 16'd0;
                                gemm_stream_k_chunk_idx  <= 16'd0;
                                gemm_stream_first_chunk  <= 1'b1;
                                gemm_stream_last_chunk   <= (input_c <= PE_ROWS_16);
                                fc_in_base <= 16'd0;
                                fc_chunk_inputs <= (input_c > PE_ROWS_16) ?
                                                   PE_ROWS_16 : input_c;
                                input_prefetch_active <= 1'b0;
                                input_prefetch_done  <= 1'b0;
                                wgt_pref_active <= 1'b0;
                                wgt_pref_done  <= 1'b0;
                                wgt_pref_valid <= 1'b0;
                                $display("[N_TILE] next tile: n_base=%0d N=%0d",
                                    next_n_base, gemm_tile_N);
                                fsm_state <= FSM_GEMM_STREAM_PREP;
                            end else if (gemm_tile_m_base + gemm_tile_M < gemm_M_val) begin
                                // More M tiles: reset N base
                                automatic integer next_m_base;
                                next_m_base = gemm_tile_m_base + gemm_tile_M;
                                gemm_tile_m_base <= next_m_base;
                                gemm_tile_M <= (gemm_M_val - next_m_base > 16'd8) ?
                                               16'd8 : (gemm_M_val - next_m_base);
                                gemm_tile_n_base <= 16'd0;
                                gemm_tile_N <= (gemm_N_val > PE_COLS_16) ? PE_COLS_16 : gemm_N_val;
                                fc_tile_outputs <= (gemm_N_val > PE_COLS_16) ? PE_COLS_16 : gemm_N_val;
                                gemm_stream_k_base       <= 16'd0;
                                gemm_stream_k_chunk_idx  <= 16'd0;
                                gemm_stream_first_chunk  <= 1'b1;
                                gemm_stream_last_chunk   <= (input_c <= PE_ROWS_16);
                                fc_in_base <= 16'd0;
                                fc_chunk_inputs <= (input_c > PE_ROWS_16) ?
                                                   PE_ROWS_16 : input_c;
                                input_prefetch_active <= 1'b0;
                                input_prefetch_done  <= 1'b0;
                                wgt_pref_active <= 1'b0;
                                wgt_pref_done  <= 1'b0;
                                wgt_pref_valid <= 1'b0;
                                $display("[M_TILE] next tile: m_base=%0d M=%0d n_reset",
                                    next_m_base, gemm_tile_M);
                                fsm_state <= FSM_GEMM_STREAM_PREP;
                            end else begin
                                // All tiles done
                                task_done_r <= 1'b1;
                                task_active_r <= 1'b0;
                                fsm_state <= FSM_DONE;
                            end
                        end
                    end else if (dma_wr_error) begin
                        task_error_r <= 1'b1;
                        task_error_code_r <= dma_wr_error_code;
                        fsm_state <= FSM_ERROR;
                    end
                end

                FSM_DONE: begin
                    task_done_r <= 1'b0;
                    fsm_state <= FSM_IDLE;
                end

                FSM_ERROR: begin
                    task_active_r <= 1'b0;
                    gemm_weight_valid <= 1'b0;
                    if (!ctrl_busy && !ctrl_error) begin
                        task_error_r <= 1'b0;
                        fsm_state <= FSM_IDLE;
                    end
                end

                default: fsm_state <= FSM_IDLE;
            endcase

            // ================================================================
            // P5: pipelined shared store_pack state machine — runs during FSM_STORE
            // or pipe_mode.  Placed AFTER the fsm_state case so store overrides
            // signals set in FSM_STORE init on the same cycle.
            //
            // Pipelined read: we issue the NEXT read address (store_rd_prefetch)
            // while consuming the CURRENT data (dma_rd_ptr tracks consumed index).
            // This achieves 1 word/cycle sustained throughput (was 1 word/2 cycles
            // due to WAIT state for acc_buffer's 1-cycle read latency).
            // ================================================================
            if (fsm_state == FSM_STORE || pipe_mode) begin
                case (store_pack_state)
                    SP_IDLE: begin
                        dma_wr_valid_r <= 1'b0;
                        if (!dma_wr_started) begin
                            dma_rd_ptr <= 0;
                            store_rd_prefetch <= 0;
                            store_pack_lane <= 3'd0;
                            store_word_idx <= 32'd0;
                            store_pack_data <= {AXI_DMA_DATA_W{1'b0}};
                        end else if (store_word_idx < store_words_active) begin
                            // Issue first read: prefetch addr 0
                            store_rd_prefetch <= 1;
                            store_pack_state <= SP_FIRST;
                        end
                    end

                    SP_FIRST: begin
                        // First data word (addr 0) is now valid on acc_rd_data
                        // Accumulate it and issue next read
                        if (store_word_idx < store_words_active) begin
                            store_pack_data <= store_pack_data_next;
                            store_pack_lane <= store_pack_lane + 3'd1;
                            store_word_idx <= store_word_idx + 32'd1;
                            dma_rd_ptr <= dma_rd_ptr + 1;

                            if ((store_pack_lane == 3'd7) ||
                                (store_word_idx + 32'd1 >= store_words_active)) begin
                                // Last lane of this beat → assemble and push
                                dma_wr_data_r <= store_pack_data_next;
                                dma_wr_valid_r <= 1'b1;
                                store_pack_data <= {AXI_DMA_DATA_W{1'b0}};
                                store_pack_lane <= 3'd0;
                                store_pack_state <= SP_PUSH;
                            end else begin
                                // More lanes in this beat → issue next read
                                if (store_word_idx + 32'd1 < store_words_active)
                                    store_rd_prefetch <= store_rd_prefetch + 1;
                                store_pack_state <= SP_STREAM;
                            end
                        end else begin
                            store_pack_state <= SP_IDLE;
                        end
                    end

                    SP_STREAM: begin
                        // Data from previous read is valid. Accumulate and issue next.
                        if (store_word_idx < store_words_active) begin
                            store_pack_data <= store_pack_data_next;
                            store_pack_lane <= store_pack_lane + 3'd1;
                            store_word_idx <= store_word_idx + 32'd1;
                            dma_rd_ptr <= dma_rd_ptr + 1;

                            if ((store_pack_lane == 3'd7) ||
                                (store_word_idx + 32'd1 >= store_words_active)) begin
                                // Beat complete
                                dma_wr_data_r <= store_pack_data_next;
                                dma_wr_valid_r <= 1'b1;
                                store_pack_data <= {AXI_DMA_DATA_W{1'b0}};
                                store_pack_lane <= 3'd0;
                                store_pack_state <= SP_PUSH;
                            end else begin
                                // Issue next read
                                if (store_word_idx + 32'd1 < store_words_active)
                                    store_rd_prefetch <= store_rd_prefetch + 1;
                                // stay in SP_STREAM
                            end
                        end else begin
                            store_pack_state <= SP_IDLE;
                        end
                    end

                    SP_PUSH: begin
                        // Beat pushed to FIFO; wait for FIFO to accept, then continue.
                        // NOTE: do NOT increment dma_rd_ptr here — no new data was consumed.
                        // dma_rd_ptr already points to the next word to consume (set by
                        // SP_STREAM beat-complete cycle). Only advance store_rd_prefetch
                        // to issue the next buffer read.
                        if (!dma_wr_started) begin
                            store_pack_state <= SP_IDLE;
                        end else if (!wf_wr_full) begin
                            dma_wr_valid_r <= 1'b0;
                            if (store_word_idx < store_words_active) begin
                                // Prefetch next address (dma_rd_ptr is already correct)
                                store_rd_prefetch <= dma_rd_ptr + 1;
                                store_pack_state <= SP_FIRST;
                            end else begin
                                store_pack_state <= SP_IDLE;
                            end
                        end
                    end

                    default: store_pack_state <= SP_IDLE;
                endcase

                // --- dma_wr_done / error handling ---
                if (dma_wr_done) begin
                    if (pipe_mode && fsm_state != FSM_PIPE_DONE) begin
                        // P3: store finished during pipe mode — flag completion
                        pipe_store_done <= 1'b1;
                    end else if (fsm_state == FSM_STORE) begin
                        // Normal STORE completion
                        rq_mode_internal <= 1'b0;
                        rq_word_store_mode <= 1'b0;
                        dma_wr_valid_r <= 1'b0;
                        dma_wr_started <= 1'b0;
                        dma_rd_ptr <= 0;
                        store_pack_state <= SP_IDLE;
                        store_pack_lane <= 3'd0;
                        store_word_idx <= 32'd0;
                        store_pack_data <= {AXI_DMA_DATA_W{1'b0}};
                        if (is_gemm_mode) begin
                            // GEMM row-by-row: store current row, advance to next
                            if (gemm_row_idx + 16'd1 < gemm_M_val) begin
                                gemm_row_idx <= gemm_row_idx + 16'd1;
                                fc_out_start <= 16'd0;
                                fc_in_base <= 16'd0;
                                fc_chunk_inputs <= (input_c > PE_ROWS_16) ? PE_ROWS_16 : input_c;
                                fsm_state <= FSM_FC_TILE_PREP;
                            end else begin
                                act_comp_done <= 1'b1;
                                blk_done <= 1'b1;
                                fsm_state <= FSM_BLK_DONE;
                            end
                        end else if (is_fc_mode) begin
                            if (fc_out_start + fc_tile_outputs < output_c) begin
                                fc_out_start <= fc_out_start + fc_tile_outputs;
                                fsm_state <= FSM_FC_TILE_PREP;
                            end else begin
                                act_comp_done <= 1'b1;
                                blk_done <= 1'b1;
                                fsm_state <= FSM_BLK_DONE;
                            end
                        end else if (is_requant_mode || is_add_mode || is_gap_mode) begin
                            act_comp_done <= 1'b1;
                            blk_done <= 1'b1;
                            fsm_state <= FSM_BLK_DONE;
                        end else begin
                            acc_comp_start <= 1'b1;
                            acc_comp_bank <= acc_load_bank;
                            if (!next_dma_launched) blk_done <= 1'b1;
                            fsm_state <= FSM_BLK_DONE;
                        end
                    end
                end else if (dma_wr_error) begin
                    task_error_r <= 1'b1; task_error_code_r <= dma_wr_error_code;
                    fsm_state <= FSM_ERROR;
                end
            end
        end
    end

    assign task_done_fb = task_done_r;
    assign task_error_fb = task_error_r;
    assign task_error_code_fb = task_error_code_r;

    // weight_mac_addr
    assign wgt_mac_addr = conv_weight_dma_byte_idx[BUF_ADDR_W+4:5];

    // ============================================================
    // Phase 2: FC Shadow Weight Load — loads next chunk's weights
    // into wgt_load_reg_shadow during FEED_ACT+DRAIN+COLLECT.
    // After compute finishes, the main FSM swaps shadow→wgt_load_reg
    // in one cycle, bypassing the 128-cycle FSM_LOAD_ARRAY.
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // reset handled in main block
        end else if (fc_shadow_active) begin
            if (fc_shadow_wait) begin
                fc_shadow_wait <= 1'b0;
            end else if (fc_shadow_phase < (fc_shadow_chunk_inputs * fc_tile_outputs)) begin
                // Same byte-extraction pattern as FSM_LOAD_ARRAY for FC
                reg [31:0] sh_remaining;
                reg [31:0] sh_bytes_in_beat;
                reg [31:0] sh_load_count;
                integer sh_lane;
                sh_remaining  = (fc_shadow_chunk_inputs * fc_tile_outputs) - fc_shadow_phase;
                sh_bytes_in_beat = 32'd32 - fc_shadow_dma_byte_idx[4:0];
                sh_load_count = (sh_remaining > 32'd32) ? 32'd32 : sh_remaining;
                if (sh_bytes_in_beat < sh_load_count)
                    sh_load_count = sh_bytes_in_beat;
                for (sh_lane = 0; sh_lane < 32; sh_lane = sh_lane + 1) begin
                    if (sh_lane < sh_load_count) begin
                        reg [31:0] sh_lane_idx;
                        reg [31:0] sh_lane_out_idx;
                        reg [31:0] sh_lane_row_idx;
                        reg [4:0]  sh_lane_byte_sel;
                        sh_lane_idx      = fc_shadow_phase + sh_lane;
                        sh_lane_out_idx  = sh_lane_idx / {16'd0, fc_shadow_chunk_inputs};
                        sh_lane_row_idx  = sh_lane_idx % {16'd0, fc_shadow_chunk_inputs};
                        sh_lane_byte_sel = fc_shadow_dma_byte_idx[4:0] + sh_lane[4:0];
                        wgt_load_reg_shadow[(sh_lane_row_idx * PE_COLS + sh_lane_out_idx)*8 +: 8] <=
                            hb_beat_byte(wgt_rd_data, sh_lane_byte_sel);
                    end
                end
                if ((fc_shadow_phase + sh_load_count <
                     (fc_shadow_chunk_inputs * fc_tile_outputs)))
                    fc_shadow_wait <= 1'b1;
                fc_shadow_phase <= fc_shadow_phase + sh_load_count;
            end
            // fc_shadow_active stays 1 after load completion;
            // it is cleared at CP_COLLECT done after the swap into wgt_load_reg.
            // Clearing it here would cause the swap to miss the shadow data
            // and load zero weights for the next K-chunk.
        end
    end

endmodule
