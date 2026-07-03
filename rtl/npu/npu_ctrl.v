// npu_ctrl: NPU register file + control state machine
// AXI4-Lite slave for CPU access, controls task lifecycle
`timescale 1ns / 1ps

module npu_ctrl #(
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 32,
    parameter [1:0] DEFAULT_CLUSTER_MODE = 2'd0,
    parameter [5:0] DEFAULT_CLUSTER_MASK = 6'b00_0001
) (
    input  wire        clk,
    input  wire        rst_n,

    // === AXI4-Lite Slave Interface ===
    // Write address channel
    input  wire                        s_axi_awvalid,
    output wire                        s_axi_awready,
    input  wire [AXI_ADDR_WIDTH-1:0]   s_axi_awaddr,
    // Write data channel
    input  wire                        s_axi_wvalid,
    output wire                        s_axi_wready,
    input  wire [AXI_DATA_WIDTH-1:0]   s_axi_wdata,
    input  wire [3:0]                  s_axi_wstrb,
    // Write response channel
    output wire                        s_axi_bvalid,
    input  wire                        s_axi_bready,
    output wire [1:0]                  s_axi_bresp,
    // Read address channel
    input  wire                        s_axi_arvalid,
    output wire                        s_axi_arready,
    input  wire [AXI_ADDR_WIDTH-1:0]   s_axi_araddr,
    // Read data channel
    output wire                        s_axi_rvalid,
    input  wire                        s_axi_rready,
    output wire [AXI_DATA_WIDTH-1:0]   s_axi_rdata,
    output wire [1:0]                  s_axi_rresp,

    // === Task control outputs (latched, to NPU internals) ===
    output wire                        ctrl_busy,
    output wire                        ctrl_done,
    output wire                        ctrl_error,
    output wire [7:0]                  ctrl_error_code,
    output wire                        task_go,      // high only after checks pass
    output wire                        task_start,
    output wire [2:0]                  task_type,
    output wire [31:0]                 input_addr,
    output wire [31:0]                 weight_addr,
    output wire [31:0]                 output_addr,
    output wire [31:0]                 input_bytes,
    output wire [31:0]                 weight_bytes,
    output wire [31:0]                 output_bytes,
    output wire [15:0]                 input_h,
    output wire [15:0]                 input_w,
    output wire [15:0]                 input_c,
    output wire [15:0]                 output_c,
    output wire                        relu_en,
    output wire                        pool_en,
    output wire [1:0]                  requant_slot_sel,
    output wire [31:0]                 requant_multiplier,
    output wire [5:0]                  requant_shift,
    output wire [1:0]                  cluster_mode_cfg,
    output wire [5:0]                  cluster_mask_cfg,
    output wire [31:0]                 conv_cfg,
    output wire [31:0]                 bias_addr,
    output wire [31:0]                 bias_bytes,
    output wire [31:0]                 src1_addr,
    output wire [31:0]                 src1_bytes,
    output wire [31:0]                 add_cfg,
    output wire [31:0]                 gap_cfg,
    output wire [31:0]                 postproc_cfg_ext,
    output wire [31:0]                 add_src0_multiplier,
    output wire [5:0]                  add_src0_shift,
    output wire [31:0]                 add_src1_multiplier,
    output wire [5:0]                  add_src1_shift,
    output wire [31:0]                 add_out_multiplier,
    output wire [5:0]                  add_out_shift,

    // === IRQ output (Phase U8-a) ===
    output wire                        npu_irq,

    // === Task status inputs (from NPU internals) ===
    input  wire                        task_done_i,
    input  wire                        task_error_i,
    input  wire [7:0]                  task_error_code_i,
    input  wire                        check_done_i,    // task_checker result ready
    input  wire                        checks_pass_i,   // task_checker: all checks passed

    // === Performance counter inputs ===
    input  wire [31:0]                 perf_cycle_lo_i,
    input  wire [31:0]                 perf_cycle_hi_i,
    input  wire [31:0]                 perf_read_beats_i,
    input  wire [31:0]                 perf_write_beats_i,
    input  wire [31:0]                 perf_read_active_i,
    input  wire [31:0]                 perf_write_active_i,
    input  wire [31:0]                 perf_mac_lo_i,
    input  wire [31:0]                 perf_mac_hi_i,
    input  wire [31:0]                 perf_array_active_i,
    input  wire [31:0]                 perf_array_stall_i,
    input  wire [31:0]                 perf_cluster_active_i,
    input  wire [31:0]                 perf_cluster_stall_i,
    input  wire [31:0]                 perf_cluster_cfg_i,
    input  wire [31:0]                 perf_write_data_cycles_i,
    input  wire [31:0]                 perf_write_txn_cycles_i,
    input  wire [31:0]                 perf_ar_handshake_i,
    input  wire [31:0]                 perf_aw_handshake_i,
    input  wire [31:0]                 perf_b_handshake_i,
    input  wire [31:0]                 perf_bus_active_i,
    input  wire [31:0]                 perf_compute_cycles_i,
    input  wire [31:0]                 perf_load_cycles_i,
    input  wire [31:0]                 perf_store_cycles_i,
    input  wire [31:0]                 perf_collect_cycles_i,
    input  wire [31:0]                 perf_read_valid_bytes_i,
    input  wire [31:0]                 perf_write_valid_bytes_i,
    input  wire [31:0]                 perf_mac_count_lo_i,
    input  wire [31:0]                 perf_mac_count_hi_i,
    input  wire [31:0]                 perf_stall_act_i,
    input  wire [31:0]                 perf_stall_wgt_i,
    input  wire [31:0]                 perf_stall_acc_i,
    input  wire [31:0]                 perf_stall_store_i,
    input  wire [31:0]                 perf_array_fill_drain_i
);

    // ============================================================
    // Register address map (byte offsets)
    // ============================================================
    localparam ADDR_CTRL           = 6'd0;   // 0x00: [0]=start,[1]=busy,[2]=done,[3]=error
    localparam ADDR_STATUS         = 6'd1;   // 0x04: [7:0]=error_code
    localparam ADDR_TASK_TYPE      = 6'd2;   // 0x08: [2:0]=task_type
    localparam ADDR_INPUT_ADDR     = 6'd3;   // 0x0C
    localparam ADDR_WEIGHT_ADDR    = 6'd4;   // 0x10
    localparam ADDR_OUTPUT_ADDR    = 6'd5;   // 0x14
    localparam ADDR_INPUT_BYTES    = 6'd6;   // 0x18
    localparam ADDR_WEIGHT_BYTES   = 6'd7;   // 0x1C
    localparam ADDR_OUTPUT_BYTES   = 6'd8;   // 0x20
    localparam ADDR_DIM_IN         = 6'd9;   // 0x24: [15:0]=H, [31:16]=W
    localparam ADDR_DIM_OUT        = 6'd10;  // 0x28: [15:0]=C_IN, [31:16]=C_OUT
    localparam ADDR_POSTPROC       = 6'd11;  // 0x2C: [0]=relu_en, [1]=pool_en
    localparam ADDR_PERF_CYCLE_LO  = 6'd12;  // 0x30
    localparam ADDR_PERF_CYCLE_HI  = 6'd13;  // 0x34
    localparam ADDR_PERF_READ_BEATS  = 6'd14;  // 0x38
    localparam ADDR_PERF_WRITE_BEATS = 6'd15;  // 0x3C
    localparam ADDR_PERF_READ_ACTIVE  = 6'd16;  // 0x40
    localparam ADDR_PERF_WRITE_ACTIVE = 6'd17;  // 0x44
    localparam ADDR_PERF_ARRAY_ACTIVE = 6'd18;  // 0x48
    localparam ADDR_PERF_ARRAY_STALL  = 6'd19;  // 0x4C
    localparam ADDR_PERF_MAC_LO         = 6'd20;  // 0x50
    localparam ADDR_PERF_MAC_HI         = 6'd21;  // 0x54
    localparam ADDR_PERF_CLUSTER_ACTIVE = 6'd22;  // 0x58
    localparam ADDR_PERF_CLUSTER_STALL  = 6'd23;  // 0x5C
    localparam ADDR_PERF_CLUSTER_CFG    = 6'd24;  // 0x60
    localparam ADDR_PERF_WRITE_DATA_CYC = 6'd52;  // 0xD0
    localparam ADDR_PERF_WRITE_TXN_CYC  = 6'd53;  // 0xD4
    localparam ADDR_PERF_AR_HANDSHAKE   = 6'd54;  // 0xD8
    localparam ADDR_PERF_AW_HANDSHAKE   = 6'd55;  // 0xDC
    localparam ADDR_PERF_B_HANDSHAKE    = 6'd56;  // 0xE0
    localparam ADDR_PERF_BUS_ACTIVE     = 6'd57;  // 0xE4
    localparam ADDR_PERF_COMPUTE_CYCLES = 6'd58;  // 0xE8
    localparam ADDR_PERF_LOAD_CYCLES    = 6'd59;  // 0xEC
    localparam ADDR_PERF_STORE_CYCLES   = 6'd60;  // 0xF0 (was 60, fix: 6'd60 = 0xF0 correct)
    localparam ADDR_PERF_COLLECT_CYCLES = 6'd61;  // 0xF4
    localparam ADDR_PERF_READ_VALID_BYTES  = 6'd62;  // 0xF8
    localparam ADDR_PERF_WRITE_VALID_BYTES = 6'd63;  // 0xFC (max 6-bit addr)
    localparam ADDR_REQUANT_SEL         = 6'd25;  // 0x64: [1:0]=slot select
    localparam ADDR_REQUANT0_MULT       = 6'd26;  // 0x68
    localparam ADDR_REQUANT0_SHIFT      = 6'd27;  // 0x6C: [5:0]=shift
    localparam ADDR_REQUANT1_MULT       = 6'd28;  // 0x70
    localparam ADDR_REQUANT1_SHIFT      = 6'd29;  // 0x74: [5:0]=shift
    localparam ADDR_REQUANT2_MULT       = 6'd30;  // 0x78
    localparam ADDR_REQUANT2_SHIFT      = 6'd31;  // 0x7C: [5:0]=shift
    localparam ADDR_REQUANT3_MULT       = 6'd32;  // 0x80
    localparam ADDR_REQUANT3_SHIFT      = 6'd33;  // 0x84: [5:0]=shift
    localparam ADDR_CLUSTER_MODE        = 6'd34;  // 0x88: [1:0]=cluster mode (reserved, CLUSTER_COUNT=1)
    localparam ADDR_CLUSTER_MASK        = 6'd35;  // 0x8C: [5:0]=cluster mask (reserved, only bit[0] used)
    localparam ADDR_VERSION             = 6'd36;  // 0x90: R1a register map version
    localparam ADDR_CAPABILITY          = 6'd37;  // 0x94: supported RTL capability bits
    localparam ADDR_CONV_CFG            = 6'd38;  // 0x98: future generalized Conv config
    localparam ADDR_BIAS_ADDR           = 6'd39;  // 0x9C: future folded bias base
    localparam ADDR_BIAS_BYTES          = 6'd40;  // 0xA0: future folded bias bytes
    localparam ADDR_SRC1_ADDR           = 6'd41;  // 0xA4: future residual source1 base
    localparam ADDR_SRC1_BYTES          = 6'd42;  // 0xA8: future residual source1 bytes
    localparam ADDR_ADD_CFG             = 6'd43;  // 0xAC: future residual ADD config
    localparam ADDR_GAP_CFG             = 6'd44;  // 0xB0: future GAP config
    localparam ADDR_POSTPROC_CFG        = 6'd45;  // 0xB4: future extended postproc config

    // Phase U8-a: IRQ registers (extended 7-bit address space, 0x100-0x10C)
    localparam ADDR_IRQ_EN              = 7'd64;  // 0x100: [1:0]=irq_en (bit0=done, bit1=error)
    localparam ADDR_IRQ_STATUS          = 7'd65;  // 0x104: [1:0]=irq_status R/O
    localparam ADDR_IRQ_CLEAR           = 7'd66;  // 0x108: [1:0]=irq_clear W1C

    localparam ADDR_ADD_SRC0_MULT       = 6'd46;  // 0xB8: R1d ADD src0 pre-align multiplier
    localparam ADDR_ADD_SRC0_SHIFT      = 6'd47;  // 0xBC: R1d ADD src0 pre-align shift
    localparam ADDR_ADD_SRC1_MULT       = 6'd48;  // 0xC0: R1d ADD src1 pre-align multiplier
    localparam ADDR_ADD_SRC1_SHIFT      = 6'd49;  // 0xC4: R1d ADD src1 pre-align shift
    localparam ADDR_ADD_OUT_MULT        = 6'd50;  // 0xC8: R1d ADD post-requant multiplier
    localparam ADDR_ADD_OUT_SHIFT       = 6'd51;  // 0xCC: R1d ADD post-requant shift

    localparam [31:0] R1A_VERSION_VALUE = 32'h0001_000A;
    localparam [31:0] CAP_CONV_5X5      = 32'h0000_0001;
    localparam [31:0] CAP_BIAS          = 32'h0000_0020;
    localparam [31:0] CAP_ADD           = 32'h0000_0040;
    localparam [31:0] CAP_GAP           = 32'h0000_0080;
    localparam [31:0] CAP_ADD_RELU      = 32'h0000_0100;
    localparam [31:0] CAP_ADD_REQUANT   = 32'h0000_0200;
    localparam [31:0] CAP_FC            = 32'h0000_0800;
    localparam [31:0] CAP_POOL          = 32'h0000_1000;
    localparam [31:0] CAP_REQUANT       = 32'h0000_2000;
    localparam [31:0] CAP_CLUSTER_CFG   = 32'h0000_4000;
    localparam [31:0] CAPABILITY_VALUE  =
        CAP_CONV_5X5 | CAP_BIAS | CAP_ADD | CAP_GAP | CAP_ADD_RELU | CAP_ADD_REQUANT |
        CAP_FC | CAP_POOL | CAP_REQUANT | CAP_CLUSTER_CFG;

    function [31:0] apply_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0]  strb;
        integer i;
        begin
            apply_wstrb = old_value;
            for (i = 0; i < 4; i = i + 1) begin
                if (strb[i])
                    apply_wstrb[i*8 +: 8] = new_value[i*8 +: 8];
            end
        end
    endfunction

    function is_write_addr_valid;
        input [6:0] addr;
        begin
            case (addr)
                ADDR_CTRL,
                ADDR_TASK_TYPE, ADDR_INPUT_ADDR, ADDR_WEIGHT_ADDR, ADDR_OUTPUT_ADDR,
                ADDR_INPUT_BYTES, ADDR_WEIGHT_BYTES, ADDR_OUTPUT_BYTES,
                ADDR_DIM_IN, ADDR_DIM_OUT, ADDR_POSTPROC,
                ADDR_REQUANT_SEL,
                ADDR_REQUANT0_MULT, ADDR_REQUANT0_SHIFT,
                ADDR_REQUANT1_MULT, ADDR_REQUANT1_SHIFT,
                ADDR_REQUANT2_MULT, ADDR_REQUANT2_SHIFT,
                ADDR_REQUANT3_MULT, ADDR_REQUANT3_SHIFT,
                ADDR_CLUSTER_MODE, ADDR_CLUSTER_MASK,
                ADDR_CONV_CFG, ADDR_BIAS_ADDR, ADDR_BIAS_BYTES,
                ADDR_SRC1_ADDR, ADDR_SRC1_BYTES,
                ADDR_ADD_CFG, ADDR_GAP_CFG, ADDR_POSTPROC_CFG,
                ADDR_ADD_SRC0_MULT, ADDR_ADD_SRC0_SHIFT,
                ADDR_ADD_SRC1_MULT, ADDR_ADD_SRC1_SHIFT,
                ADDR_ADD_OUT_MULT, ADDR_ADD_OUT_SHIFT,
                // Phase U8-a: IRQ registers
                ADDR_IRQ_EN, ADDR_IRQ_CLEAR:
                    is_write_addr_valid = 1'b1;
                default:
                    is_write_addr_valid = 1'b0;
            endcase
        end
    endfunction

    function is_read_addr_valid;
        input [6:0] addr;
        begin
            case (addr)
                ADDR_CTRL, ADDR_STATUS,
                ADDR_TASK_TYPE, ADDR_INPUT_ADDR, ADDR_WEIGHT_ADDR, ADDR_OUTPUT_ADDR,
                ADDR_INPUT_BYTES, ADDR_WEIGHT_BYTES, ADDR_OUTPUT_BYTES,
                ADDR_DIM_IN, ADDR_DIM_OUT, ADDR_POSTPROC,
                ADDR_PERF_CYCLE_LO, ADDR_PERF_CYCLE_HI,
                ADDR_PERF_READ_BEATS, ADDR_PERF_WRITE_BEATS,
                ADDR_PERF_READ_ACTIVE, ADDR_PERF_WRITE_ACTIVE,
                ADDR_PERF_ARRAY_ACTIVE, ADDR_PERF_ARRAY_STALL,
                ADDR_PERF_MAC_LO, ADDR_PERF_MAC_HI,
                ADDR_PERF_CLUSTER_ACTIVE, ADDR_PERF_CLUSTER_STALL, ADDR_PERF_CLUSTER_CFG,
                ADDR_PERF_WRITE_DATA_CYC, ADDR_PERF_WRITE_TXN_CYC,
                ADDR_PERF_AR_HANDSHAKE, ADDR_PERF_AW_HANDSHAKE,
                ADDR_PERF_B_HANDSHAKE, ADDR_PERF_BUS_ACTIVE,
                ADDR_PERF_COMPUTE_CYCLES, ADDR_PERF_LOAD_CYCLES,
                ADDR_PERF_STORE_CYCLES, ADDR_PERF_COLLECT_CYCLES,
                ADDR_PERF_READ_VALID_BYTES, ADDR_PERF_WRITE_VALID_BYTES,
                ADDR_REQUANT_SEL,
                ADDR_REQUANT0_MULT, ADDR_REQUANT0_SHIFT,
                ADDR_REQUANT1_MULT, ADDR_REQUANT1_SHIFT,
                ADDR_REQUANT2_MULT, ADDR_REQUANT2_SHIFT,
                ADDR_REQUANT3_MULT, ADDR_REQUANT3_SHIFT,
                ADDR_CLUSTER_MODE, ADDR_CLUSTER_MASK,
                ADDR_VERSION, ADDR_CAPABILITY,
                ADDR_CONV_CFG, ADDR_BIAS_ADDR, ADDR_BIAS_BYTES,
                ADDR_SRC1_ADDR, ADDR_SRC1_BYTES,
                ADDR_ADD_CFG, ADDR_GAP_CFG, ADDR_POSTPROC_CFG,
                ADDR_ADD_SRC0_MULT, ADDR_ADD_SRC0_SHIFT,
                ADDR_ADD_SRC1_MULT, ADDR_ADD_SRC1_SHIFT,
                ADDR_ADD_OUT_MULT, ADDR_ADD_OUT_SHIFT,
                // Phase U8-a: IRQ registers
                ADDR_IRQ_EN, ADDR_IRQ_STATUS:
                    is_read_addr_valid = 1'b1;
                default:
                    is_read_addr_valid = 1'b0;
            endcase
        end
    endfunction

    // ============================================================
    // AXI-Lite write path: AW+W stored separately, write when both ready
    // ============================================================
    reg         aw_stored;
    reg  [31:0] stored_awaddr;
    reg         w_stored;
    reg  [31:0] stored_wdata;
    reg  [3:0]  stored_wstrb;
    reg         bvalid;
    reg  [1:0]  bresp;

    wire aw_hs = s_axi_awvalid && s_axi_awready;
    wire w_hs  = s_axi_wvalid  && s_axi_wready;

    assign s_axi_awready = !aw_stored && !bvalid;
    assign s_axi_wready  = !w_stored && !bvalid;

    wire write_hs = (aw_stored || aw_hs) && (w_stored || w_hs) && !bvalid;
    wire [31:0] write_addr = aw_hs ? s_axi_awaddr : stored_awaddr;
    wire [31:0] write_data = w_hs  ? s_axi_wdata  : stored_wdata;
    wire [3:0]  write_strb = w_hs  ? s_axi_wstrb  : stored_wstrb;
    wire [6:0]  wr_addr = write_addr[8:2];  // Phase U8-a: extended to 7 bits for IRQ CSRs
    wire [31:0] ctrl_write_data = apply_wstrb(32'h0, write_data, write_strb);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_stored     <= 1'b0;
            stored_awaddr <= 32'h0;
        end else begin
            if (aw_hs) begin
                aw_stored     <= 1'b1;
                stored_awaddr <= s_axi_awaddr;
            end
            if (write_hs) begin
                aw_stored <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_stored     <= 1'b0;
            stored_wdata <= 32'h0;
            stored_wstrb <= 4'h0;
        end else begin
            if (w_hs) begin
                w_stored     <= 1'b1;
                stored_wdata <= s_axi_wdata;
                stored_wstrb <= s_axi_wstrb;
            end
            if (write_hs) begin
                w_stored <= 1'b0;
            end
        end
    end

    // BVALID: fires when write completes
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bvalid <= 1'b0;
            bresp  <= 2'b00;
        end else if (write_hs) begin
            bvalid <= 1'b1;
            bresp  <= is_write_addr_valid(wr_addr) ? 2'b00 : 2'b10;
        end else if (bvalid && s_axi_bready) begin
            bvalid <= 1'b0;
        end
    end
    assign s_axi_bvalid = bvalid;
    assign s_axi_bresp  = bresp;

    // ============================================================
    // AXI-Lite read path
    // ============================================================
    reg         ar_stored;
    reg  [31:0] stored_araddr;
    reg         rvalid;
    reg  [31:0] rdata_reg;
    reg  [1:0]  rresp_reg;
    wire [6:0]  rd_addr = stored_araddr[8:2];  // Phase U8-a: extended to 7 bits for IRQ CSRs

    assign s_axi_arready = !ar_stored;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_stored     <= 1'b0;
            stored_araddr <= 32'h0;
        end else if (s_axi_arvalid && s_axi_arready) begin
            ar_stored     <= 1'b1;
            stored_araddr <= s_axi_araddr;
        end else if (rvalid && s_axi_rready) begin
            ar_stored <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rvalid    <= 1'b0;
            rdata_reg <= 32'h0;
            rresp_reg <= 2'b00;
        end else if (ar_stored && !rvalid) begin
            rvalid    <= 1'b1;
            rresp_reg <= is_read_addr_valid(rd_addr) ? 2'b00 : 2'b10;
        end else if (rvalid && s_axi_rready) begin
            rvalid <= 1'b0;
        end
    end

    assign s_axi_rvalid = rvalid;
    assign s_axi_rresp  = rresp_reg;

    // ============================================================
    // Internal registers
    // ============================================================
    reg  [31:0] cfg_task_type;
    reg  [31:0] cfg_input_addr;
    reg  [31:0] cfg_weight_addr;
    reg  [31:0] cfg_output_addr;
    reg  [31:0] cfg_input_bytes;
    reg  [31:0] cfg_weight_bytes;
    reg  [31:0] cfg_output_bytes;
    reg  [31:0] cfg_dim_in;
    reg  [31:0] cfg_dim_out;
    reg  [31:0] cfg_postproc;
    reg  [31:0] cfg_requant_sel;
    reg  [31:0] cfg_requant_mult [0:3];
    reg  [31:0] cfg_requant_shift [0:3];
    reg  [31:0] cfg_cluster_mode;
    reg  [31:0] cfg_cluster_mask;
    reg  [31:0] cfg_conv_cfg;
    reg  [31:0] cfg_bias_addr;
    reg  [31:0] cfg_bias_bytes;
    reg  [31:0] cfg_src1_addr;
    reg  [31:0] cfg_src1_bytes;
    reg  [31:0] cfg_add_cfg;
    reg  [31:0] cfg_gap_cfg;
    reg  [31:0] cfg_postproc_cfg_ext;
    reg  [31:0] cfg_add_src0_mult;
    reg  [31:0] cfg_add_src0_shift;
    reg  [31:0] cfg_add_src1_mult;
    reg  [31:0] cfg_add_src1_shift;
    reg  [31:0] cfg_add_out_mult;
    reg  [31:0] cfg_add_out_shift;

    // Status registers (HW-managed)
    reg         busy;
    reg         done;
    reg         error;
    reg  [7:0]  error_code;

    // Phase U8-a: IRQ registers
    reg  [1:0]  irq_en;       // bit0=done_irq_en, bit1=error_irq_en
    reg  [1:0]  irq_status;   // bit0=done_pending, bit1=error_pending

    // Task latched outputs
    reg         task_start_r;
    reg  [2:0]  task_type_r;
    reg  [31:0] input_addr_r;
    reg  [31:0] weight_addr_r;
    reg  [31:0] output_addr_r;
    reg  [31:0] input_bytes_r;
    reg  [31:0] weight_bytes_r;
    reg  [31:0] output_bytes_r;
    reg  [15:0] input_h_r;
    reg  [15:0] input_w_r;
    reg  [15:0] input_c_r;
    reg  [15:0] output_c_r;
    reg         relu_en_r;
    reg         pool_en_r;
    reg  [31:0] conv_cfg_r;
    reg  [31:0] bias_addr_r;
    reg  [31:0] bias_bytes_r;
    reg  [31:0] src1_addr_r;
    reg  [31:0] src1_bytes_r;
    reg  [31:0] add_cfg_r;
    reg  [31:0] gap_cfg_r;
    reg  [31:0] postproc_cfg_ext_r;
    reg  [31:0] add_src0_mult_r;
    reg  [5:0]  add_src0_shift_r;
    reg  [31:0] add_src1_mult_r;
    reg  [5:0]  add_src1_shift_r;
    reg  [31:0] add_out_mult_r;
    reg  [5:0]  add_out_shift_r;
    reg  [1:0]  requant_slot_sel_r;
    reg  [31:0] requant_multiplier_r;
    reg  [5:0]  requant_shift_r;

    wire wr_allowed = !busy || error;

    // Register write: use the transaction payload selected from live or stored channels.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_task_type    <= 32'h0;
            cfg_input_addr   <= 32'h0;
            cfg_weight_addr  <= 32'h0;
            cfg_output_addr  <= 32'h0;
            cfg_input_bytes  <= 32'h0;
            cfg_weight_bytes <= 32'h0;
            cfg_output_bytes <= 32'h0;
            cfg_dim_in       <= 32'h0;
            cfg_dim_out      <= 32'h0;
            cfg_postproc     <= 32'h0;
            cfg_requant_sel  <= 32'h0;
            cfg_requant_mult[0] <= 32'd1;
            cfg_requant_mult[1] <= 32'd1;
            cfg_requant_mult[2] <= 32'd1;
            cfg_requant_mult[3] <= 32'd1;
            cfg_requant_shift[0] <= 32'd0;
            cfg_requant_shift[1] <= 32'd0;
            cfg_requant_shift[2] <= 32'd0;
            cfg_requant_shift[3] <= 32'd0;
            cfg_cluster_mode <= {30'd0, DEFAULT_CLUSTER_MODE};
            cfg_cluster_mask <= {26'd0, DEFAULT_CLUSTER_MASK};
            cfg_conv_cfg <= 32'h0;
            cfg_bias_addr <= 32'h0;
            cfg_bias_bytes <= 32'h0;
            cfg_src1_addr <= 32'h0;
            cfg_src1_bytes <= 32'h0;
            cfg_add_cfg <= 32'h0;
            cfg_gap_cfg <= 32'h0;
            cfg_postproc_cfg_ext <= 32'h0;
            cfg_add_src0_mult <= 32'd0;
            cfg_add_src0_shift <= 32'd0;
            cfg_add_src1_mult <= 32'd0;
            cfg_add_src1_shift <= 32'd0;
            cfg_add_out_mult <= 32'd0;
            cfg_add_out_shift <= 32'd0;
        end else if (write_hs && wr_allowed && is_write_addr_valid(wr_addr)) begin
            case (wr_addr)
                ADDR_TASK_TYPE:    cfg_task_type    <= apply_wstrb(cfg_task_type, write_data, write_strb) & 32'h0000_0007;
                ADDR_INPUT_ADDR:   cfg_input_addr   <= apply_wstrb(cfg_input_addr, write_data, write_strb);
                ADDR_WEIGHT_ADDR:  cfg_weight_addr  <= apply_wstrb(cfg_weight_addr, write_data, write_strb);
                ADDR_OUTPUT_ADDR:  cfg_output_addr  <= apply_wstrb(cfg_output_addr, write_data, write_strb);
                ADDR_INPUT_BYTES:  cfg_input_bytes  <= apply_wstrb(cfg_input_bytes, write_data, write_strb);
                ADDR_WEIGHT_BYTES: cfg_weight_bytes <= apply_wstrb(cfg_weight_bytes, write_data, write_strb);
                ADDR_OUTPUT_BYTES: cfg_output_bytes <= apply_wstrb(cfg_output_bytes, write_data, write_strb);
                ADDR_DIM_IN:       cfg_dim_in       <= apply_wstrb(cfg_dim_in, write_data, write_strb);
                ADDR_DIM_OUT:      cfg_dim_out      <= apply_wstrb(cfg_dim_out, write_data, write_strb);
                ADDR_POSTPROC:     cfg_postproc     <= apply_wstrb(cfg_postproc, write_data, write_strb);
                ADDR_REQUANT_SEL:   cfg_requant_sel      <= apply_wstrb(cfg_requant_sel, write_data, write_strb);
                ADDR_REQUANT0_MULT: cfg_requant_mult[0]  <= apply_wstrb(cfg_requant_mult[0], write_data, write_strb);
                ADDR_REQUANT0_SHIFT:cfg_requant_shift[0] <= apply_wstrb(cfg_requant_shift[0], write_data, write_strb);
                ADDR_REQUANT1_MULT: cfg_requant_mult[1]  <= apply_wstrb(cfg_requant_mult[1], write_data, write_strb);
                ADDR_REQUANT1_SHIFT:cfg_requant_shift[1] <= apply_wstrb(cfg_requant_shift[1], write_data, write_strb);
                ADDR_REQUANT2_MULT: cfg_requant_mult[2]  <= apply_wstrb(cfg_requant_mult[2], write_data, write_strb);
                ADDR_REQUANT2_SHIFT:cfg_requant_shift[2] <= apply_wstrb(cfg_requant_shift[2], write_data, write_strb);
                ADDR_REQUANT3_MULT: cfg_requant_mult[3]  <= apply_wstrb(cfg_requant_mult[3], write_data, write_strb);
                ADDR_REQUANT3_SHIFT:cfg_requant_shift[3] <= apply_wstrb(cfg_requant_shift[3], write_data, write_strb);
                ADDR_CLUSTER_MODE:  cfg_cluster_mode      <= apply_wstrb(cfg_cluster_mode, write_data, write_strb) & 32'h0000_0003;
                ADDR_CLUSTER_MASK:  cfg_cluster_mask      <= apply_wstrb(cfg_cluster_mask, write_data, write_strb) & 32'h0000_003f;
                ADDR_CONV_CFG:      cfg_conv_cfg          <= apply_wstrb(cfg_conv_cfg, write_data, write_strb) & 32'h0000_007f; // bit[6]: U4-d INT8 test hook
                ADDR_BIAS_ADDR:     cfg_bias_addr         <= apply_wstrb(cfg_bias_addr, write_data, write_strb);
                ADDR_BIAS_BYTES:    cfg_bias_bytes        <= apply_wstrb(cfg_bias_bytes, write_data, write_strb);
                ADDR_SRC1_ADDR:     cfg_src1_addr         <= apply_wstrb(cfg_src1_addr, write_data, write_strb);
                ADDR_SRC1_BYTES:    cfg_src1_bytes        <= apply_wstrb(cfg_src1_bytes, write_data, write_strb);
                ADDR_ADD_CFG:       cfg_add_cfg           <= apply_wstrb(cfg_add_cfg, write_data, write_strb) & 32'h0000_000f;
                ADDR_GAP_CFG:       cfg_gap_cfg           <= apply_wstrb(cfg_gap_cfg, write_data, write_strb) & 32'h03ff_ffff;
                ADDR_POSTPROC_CFG:  cfg_postproc_cfg_ext  <= apply_wstrb(cfg_postproc_cfg_ext, write_data, write_strb);
                ADDR_ADD_SRC0_MULT: cfg_add_src0_mult     <= apply_wstrb(cfg_add_src0_mult, write_data, write_strb);
                ADDR_ADD_SRC0_SHIFT:cfg_add_src0_shift    <= apply_wstrb(cfg_add_src0_shift, write_data, write_strb) & 32'h0000_003f;
                ADDR_ADD_SRC1_MULT: cfg_add_src1_mult     <= apply_wstrb(cfg_add_src1_mult, write_data, write_strb);
                ADDR_ADD_SRC1_SHIFT:cfg_add_src1_shift    <= apply_wstrb(cfg_add_src1_shift, write_data, write_strb) & 32'h0000_003f;
                ADDR_ADD_OUT_MULT:  cfg_add_out_mult      <= apply_wstrb(cfg_add_out_mult, write_data, write_strb);
                ADDR_ADD_OUT_SHIFT: cfg_add_out_shift     <= apply_wstrb(cfg_add_out_shift, write_data, write_strb) & 32'h0000_003f;
                // Phase U8-a: IRQ registers
                ADDR_IRQ_EN:    irq_en      <= write_data[1:0];
                ADDR_IRQ_CLEAR: irq_status  <= irq_status & ~write_data[1:0];  // W1C
                default: ;
            endcase
        end
    end

    // ============================================================
    // Control FSM: start / check / busy / done / error
    // ============================================================
    wire busy_write_violation = write_hs && busy && !error;
    wire busy_start_violation = write_hs && busy && !error && (wr_addr == ADDR_CTRL) && ctrl_write_data[0];
    wire clear_error_write = write_hs && (wr_addr == ADDR_CTRL) && ctrl_write_data[4] && !busy;
    wire write_new_start = write_hs && (wr_addr == ADDR_CTRL) && ctrl_write_data[0] && !busy && !error;

    reg checking;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy       <= 1'b0;
            done       <= 1'b0;
            error      <= 1'b0;
            error_code <= 8'h0;
            irq_en     <= 2'b00;
            irq_status <= 2'b00;
            checking   <= 1'b0;

            task_start_r    <= 1'b0;
            task_type_r     <= 3'b000;
            input_addr_r    <= 32'h0;
            weight_addr_r   <= 32'h0;
            output_addr_r   <= 32'h0;
            input_bytes_r   <= 32'h0;
            weight_bytes_r  <= 32'h0;
            output_bytes_r  <= 32'h0;
            input_h_r       <= 16'h0;
            input_w_r       <= 16'h0;
            input_c_r       <= 16'h0;
            output_c_r      <= 16'h0;
            relu_en_r       <= 1'b0;
            pool_en_r       <= 1'b0;
            conv_cfg_r      <= 32'h0;
            bias_addr_r      <= 32'h0;
            bias_bytes_r     <= 32'h0;
            src1_addr_r      <= 32'h0;
            src1_bytes_r     <= 32'h0;
            add_cfg_r        <= 32'h0;
            gap_cfg_r        <= 32'h0;
            postproc_cfg_ext_r <= 32'h0;
            add_src0_mult_r  <= 32'd0;
            add_src0_shift_r <= 6'd0;
            add_src1_mult_r  <= 32'd0;
            add_src1_shift_r <= 6'd0;
            add_out_mult_r   <= 32'd0;
            add_out_shift_r  <= 6'd0;
            requant_slot_sel_r <= 2'b00;
            requant_multiplier_r <= 32'd1;
            requant_shift_r <= 6'd0;
        end else begin
            task_start_r <= 1'b0;

            if (clear_error_write) begin
                done  <= 1'b0;
                error <= 1'b0;
            end

            if (task_error_i && !checking) begin
                busy       <= 1'b0;
                error      <= 1'b1;
                error_code <= task_error_code_i;
                irq_status[1] <= 1'b1;  // Phase U8-a: error pending
            end else if (task_done_i && busy && !done) begin
                busy  <= 1'b0;
                done  <= 1'b1;
                irq_status[0] <= 1'b1;  // Phase U8-a: done pending
                error <= 1'b0;
            end else if (checking && check_done_i) begin
                checking <= 1'b0;
                if (checks_pass_i) begin
                    busy         <= 1'b1;
                    done         <= 1'b0;
                    error        <= 1'b0;
                    task_start_r <= 1'b0;
                end else begin
                    busy       <= 1'b0;
                    error      <= 1'b1;
                    error_code <= task_error_code_i;
                end
            end else if (write_new_start) begin
                task_type_r     <= cfg_task_type[2:0];
                input_addr_r    <= cfg_input_addr;
                weight_addr_r   <= cfg_weight_addr;
                output_addr_r   <= cfg_output_addr;
                input_bytes_r   <= cfg_input_bytes;
                weight_bytes_r  <= cfg_weight_bytes;
                output_bytes_r  <= cfg_output_bytes;
                input_h_r       <= cfg_dim_in[15:0];
                input_w_r       <= cfg_dim_in[31:16];
                input_c_r       <= cfg_dim_out[15:0];
                output_c_r      <= cfg_dim_out[31:16];
                relu_en_r       <= cfg_postproc[0];
                pool_en_r       <= cfg_postproc[1];
                conv_cfg_r      <= cfg_conv_cfg;
                bias_addr_r     <= cfg_bias_addr;
                bias_bytes_r    <= cfg_bias_bytes;
                src1_addr_r     <= cfg_src1_addr;
                src1_bytes_r    <= cfg_src1_bytes;
                add_cfg_r       <= cfg_add_cfg;
                gap_cfg_r       <= cfg_gap_cfg;
                postproc_cfg_ext_r <= cfg_postproc_cfg_ext;
                add_src0_mult_r <= cfg_add_src0_mult;
                add_src0_shift_r <= cfg_add_src0_shift[5:0];
                add_src1_mult_r <= cfg_add_src1_mult;
                add_src1_shift_r <= cfg_add_src1_shift[5:0];
                add_out_mult_r <= cfg_add_out_mult;
                add_out_shift_r <= cfg_add_out_shift[5:0];
                requant_slot_sel_r <= cfg_requant_sel[1:0];
                case (cfg_requant_sel[1:0])
                    2'd0: begin
                        requant_multiplier_r <= cfg_requant_mult[0];
                        requant_shift_r <= cfg_requant_shift[0][5:0];
                    end
                    2'd1: begin
                        requant_multiplier_r <= cfg_requant_mult[1];
                        requant_shift_r <= cfg_requant_shift[1][5:0];
                    end
                    2'd2: begin
                        requant_multiplier_r <= cfg_requant_mult[2];
                        requant_shift_r <= cfg_requant_shift[2][5:0];
                    end
                    default: begin
                        requant_multiplier_r <= cfg_requant_mult[3];
                        requant_shift_r <= cfg_requant_shift[3][5:0];
                    end
                endcase
                task_start_r <= 1'b1;
                done         <= 1'b0;
                error        <= 1'b0;
                busy         <= 1'b1;
                checking     <= 1'b1;
            end else if (busy_start_violation) begin
                busy       <= 1'b0;
                error      <= 1'b1;
                error_code <= 8'h10;
                checking   <= 1'b0;
            end else if (busy_write_violation) begin
                busy       <= 1'b0;
                error      <= 1'b1;
                error_code <= 8'h11;
                checking   <= 1'b0;
            end
        end
    end

    assign ctrl_busy       = busy;
    assign ctrl_done       = done;
    assign ctrl_error      = error;
    assign ctrl_error_code = error_code;
    assign task_go         = busy && !checking;

    assign task_start    = task_start_r;
    assign task_type     = task_type_r;
    assign input_addr    = input_addr_r;
    assign weight_addr   = weight_addr_r;
    assign output_addr   = output_addr_r;
    assign input_bytes   = input_bytes_r;
    assign weight_bytes  = weight_bytes_r;
    assign output_bytes  = output_bytes_r;
    assign input_h       = input_h_r;
    assign input_w       = input_w_r;
    assign input_c       = input_c_r;
    assign output_c      = output_c_r;
    assign relu_en       = relu_en_r;
    assign pool_en       = pool_en_r;
    assign requant_slot_sel = requant_slot_sel_r;
    assign requant_multiplier = requant_multiplier_r;
    assign requant_shift = requant_shift_r;
    assign cluster_mode_cfg = cfg_cluster_mode[1:0];
    assign cluster_mask_cfg = cfg_cluster_mask[5:0];
    assign conv_cfg = conv_cfg_r;
    assign bias_addr = bias_addr_r;
    assign bias_bytes = bias_bytes_r;
    assign src1_addr = src1_addr_r;
    assign src1_bytes = src1_bytes_r;
    assign add_cfg = add_cfg_r;
    assign gap_cfg = gap_cfg_r;
    assign postproc_cfg_ext = postproc_cfg_ext_r;
    assign add_src0_multiplier = add_src0_mult_r;
    assign add_src0_shift = add_src0_shift_r;
    assign add_src1_multiplier = add_src1_mult_r;
    assign add_src1_shift = add_src1_shift_r;
    assign add_out_multiplier = add_out_mult_r;
    assign add_out_shift = add_out_shift_r;

    // Phase U8-a: NPU IRQ output
    assign npu_irq = |(irq_status & irq_en);

    // ============================================================
    // AXI read data generation
    // ============================================================
    wire [31:0] ctrl_value = {28'h0, error, done, busy, 1'b0};
    wire [31:0] status_value = {24'h0, error_code};

    wire [31:0] rd_data_comb =
        (rd_addr == ADDR_CTRL)             ? ctrl_value           :
        (rd_addr == ADDR_STATUS)           ? status_value         :
        (rd_addr == ADDR_TASK_TYPE)        ? cfg_task_type        :
        (rd_addr == ADDR_INPUT_ADDR)       ? cfg_input_addr       :
        (rd_addr == ADDR_WEIGHT_ADDR)      ? cfg_weight_addr      :
        (rd_addr == ADDR_OUTPUT_ADDR)      ? cfg_output_addr      :
        (rd_addr == ADDR_INPUT_BYTES)      ? cfg_input_bytes      :
        (rd_addr == ADDR_WEIGHT_BYTES)     ? cfg_weight_bytes     :
        (rd_addr == ADDR_OUTPUT_BYTES)     ? cfg_output_bytes     :
        (rd_addr == ADDR_DIM_IN)           ? cfg_dim_in           :
        (rd_addr == ADDR_DIM_OUT)          ? cfg_dim_out          :
        (rd_addr == ADDR_POSTPROC)         ? cfg_postproc         :
        (rd_addr == ADDR_REQUANT_SEL)      ? cfg_requant_sel      :
        (rd_addr == ADDR_PERF_CYCLE_LO)    ? perf_cycle_lo_i      :
        (rd_addr == ADDR_PERF_CYCLE_HI)    ? perf_cycle_hi_i      :
        (rd_addr == ADDR_PERF_READ_BEATS)  ? perf_read_beats_i    :
        (rd_addr == ADDR_PERF_WRITE_BEATS) ? perf_write_beats_i   :
        (rd_addr == ADDR_PERF_READ_ACTIVE)  ? perf_read_active_i   :
        (rd_addr == ADDR_PERF_WRITE_ACTIVE) ? perf_write_active_i  :
        (rd_addr == ADDR_PERF_ARRAY_ACTIVE) ? perf_array_active_i  :
        (rd_addr == ADDR_PERF_ARRAY_STALL)  ? perf_array_stall_i   :
        (rd_addr == ADDR_PERF_MAC_LO)       ? perf_mac_lo_i        :
        (rd_addr == ADDR_PERF_MAC_HI)       ? perf_mac_hi_i        :
        (rd_addr == ADDR_PERF_CLUSTER_ACTIVE) ? perf_cluster_active_i :
        (rd_addr == ADDR_PERF_CLUSTER_STALL)  ? perf_cluster_stall_i  :
        (rd_addr == ADDR_PERF_CLUSTER_CFG)    ? perf_cluster_cfg_i    :
        (rd_addr == ADDR_PERF_WRITE_DATA_CYC) ? perf_write_data_cycles_i :
        (rd_addr == ADDR_PERF_WRITE_TXN_CYC)  ? perf_write_txn_cycles_i  :
        (rd_addr == ADDR_PERF_AR_HANDSHAKE)   ? perf_ar_handshake_i      :
        (rd_addr == ADDR_PERF_AW_HANDSHAKE)   ? perf_aw_handshake_i      :
        (rd_addr == ADDR_PERF_B_HANDSHAKE)    ? perf_b_handshake_i       :
        (rd_addr == ADDR_PERF_BUS_ACTIVE)     ? perf_bus_active_i        :
        (rd_addr == ADDR_PERF_COMPUTE_CYCLES) ? perf_compute_cycles_i    :
        (rd_addr == ADDR_PERF_LOAD_CYCLES)    ? perf_load_cycles_i       :
        (rd_addr == ADDR_PERF_STORE_CYCLES)   ? perf_store_cycles_i      :
        (rd_addr == ADDR_PERF_COLLECT_CYCLES) ? perf_collect_cycles_i    :
        (rd_addr == ADDR_PERF_READ_VALID_BYTES)  ? perf_read_valid_bytes_i  :
        (rd_addr == ADDR_PERF_WRITE_VALID_BYTES) ? perf_write_valid_bytes_i :
        (rd_addr == ADDR_REQUANT0_MULT)      ? cfg_requant_mult[0]   :
        (rd_addr == ADDR_REQUANT0_SHIFT)     ? cfg_requant_shift[0]  :
        (rd_addr == ADDR_REQUANT1_MULT)      ? cfg_requant_mult[1]   :
        (rd_addr == ADDR_REQUANT1_SHIFT)     ? cfg_requant_shift[1]  :
        (rd_addr == ADDR_REQUANT2_MULT)      ? cfg_requant_mult[2]   :
        (rd_addr == ADDR_REQUANT2_SHIFT)     ? cfg_requant_shift[2]  :
        (rd_addr == ADDR_REQUANT3_MULT)      ? cfg_requant_mult[3]   :
        (rd_addr == ADDR_REQUANT3_SHIFT)     ? cfg_requant_shift[3]  :
        (rd_addr == ADDR_CLUSTER_MODE)        ? cfg_cluster_mode      :
        (rd_addr == ADDR_CLUSTER_MASK)        ? cfg_cluster_mask      :
        (rd_addr == ADDR_VERSION)             ? R1A_VERSION_VALUE     :
        (rd_addr == ADDR_CAPABILITY)          ? CAPABILITY_VALUE      :
        (rd_addr == ADDR_CONV_CFG)            ? cfg_conv_cfg          :
        (rd_addr == ADDR_BIAS_ADDR)           ? cfg_bias_addr         :
        (rd_addr == ADDR_BIAS_BYTES)          ? cfg_bias_bytes        :
        (rd_addr == ADDR_SRC1_ADDR)           ? cfg_src1_addr         :
        (rd_addr == ADDR_SRC1_BYTES)          ? cfg_src1_bytes        :
        (rd_addr == ADDR_ADD_CFG)             ? cfg_add_cfg           :
        (rd_addr == ADDR_GAP_CFG)             ? cfg_gap_cfg           :
        (rd_addr == ADDR_POSTPROC_CFG)        ? cfg_postproc_cfg_ext  :
        (rd_addr == ADDR_ADD_SRC0_MULT)       ? cfg_add_src0_mult     :
        (rd_addr == ADDR_ADD_SRC0_SHIFT)      ? cfg_add_src0_shift    :
        (rd_addr == ADDR_ADD_SRC1_MULT)       ? cfg_add_src1_mult     :
        (rd_addr == ADDR_ADD_SRC1_SHIFT)      ? cfg_add_src1_shift    :
        (rd_addr == ADDR_ADD_OUT_MULT)        ? cfg_add_out_mult      :
        (rd_addr == ADDR_ADD_OUT_SHIFT)       ? cfg_add_out_shift     :
        // Phase U8-a: IRQ registers
        (rd_addr == ADDR_IRQ_EN)              ? {30'h0, irq_en}       :
        (rd_addr == ADDR_IRQ_STATUS)          ? {30'h0, irq_status}   :
        32'h0;

    always @(posedge clk) begin
        if (ar_stored && !rvalid)
            rdata_reg <= is_read_addr_valid(rd_addr) ? rd_data_comb : 32'h0;
    end

    assign s_axi_rdata = rdata_reg;

endmodule
