// npu_ctrl: NPU register file + control state machine
// AXI4-Lite slave for CPU access, controls task lifecycle
`timescale 1ns / 1ps

module npu_ctrl #(
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 32
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
    output wire [1:0]                  task_type,
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
    input  wire [31:0]                 perf_cluster_cfg_i
);

    // ============================================================
    // Register address map (byte offsets)
    // ============================================================
    localparam ADDR_CTRL           = 6'd0;   // 0x00: [0]=start,[1]=busy,[2]=done,[3]=error
    localparam ADDR_STATUS         = 6'd1;   // 0x04: [7:0]=error_code
    localparam ADDR_TASK_TYPE      = 6'd2;   // 0x08: [1:0]=task_type
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
    localparam ADDR_REQUANT_SEL         = 6'd25;  // 0x64: [1:0]=slot select
    localparam ADDR_REQUANT0_MULT       = 6'd26;  // 0x68
    localparam ADDR_REQUANT0_SHIFT      = 6'd27;  // 0x6C: [5:0]=shift
    localparam ADDR_REQUANT1_MULT       = 6'd28;  // 0x70
    localparam ADDR_REQUANT1_SHIFT      = 6'd29;  // 0x74: [5:0]=shift
    localparam ADDR_REQUANT2_MULT       = 6'd30;  // 0x78
    localparam ADDR_REQUANT2_SHIFT      = 6'd31;  // 0x7C: [5:0]=shift
    localparam ADDR_REQUANT3_MULT       = 6'd32;  // 0x80
    localparam ADDR_REQUANT3_SHIFT      = 6'd33;  // 0x84: [5:0]=shift

    // ============================================================
    // AXI-Lite write path: AW+W stored separately, write when both ready
    // ============================================================
    reg         aw_stored;
    reg  [31:0] stored_awaddr;
    reg         w_stored;
    reg  [31:0] stored_wdata;

    wire aw_hs = s_axi_awvalid && s_axi_awready;
    wire w_hs  = s_axi_wvalid  && s_axi_wready;

    assign s_axi_awready = !aw_stored;
    assign s_axi_wready  = !w_stored;

    // Combinational write detection: fires in the SAME cycle as w_hs
    // (aw_stored is already 1 from a previous AW, w_hs latches W this cycle)
    wire write_hs = aw_stored && w_stored;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_stored     <= 1'b0;
            stored_awaddr <= 32'h0;
        end else begin
            if (aw_hs) begin
                aw_stored     <= 1'b1;
                stored_awaddr <= s_axi_awaddr;
            end else if (write_hs) begin
                aw_stored <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_stored     <= 1'b0;
            stored_wdata <= 32'h0;
        end else begin
            if (w_hs) begin
                w_stored     <= 1'b1;
                stored_wdata <= s_axi_wdata;
            end else if (write_hs) begin
                w_stored <= 1'b0;
            end
        end
    end

    // BVALID: fires when write completes
    reg bvalid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bvalid <= 1'b0;
        else if (write_hs)
            bvalid <= 1'b1;
        else if (s_axi_bready)
            bvalid <= 1'b0;
    end
    assign s_axi_bvalid = bvalid;
    assign s_axi_bresp  = 2'b00;

    // ============================================================
    // AXI-Lite read path
    // ============================================================
    reg         ar_stored;
    reg  [31:0] stored_araddr;
    reg         rvalid;
    reg  [31:0] rdata_reg;

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
        end else if (ar_stored && !rvalid) begin
            rvalid    <= 1'b1;
        end else if (rvalid && s_axi_rready) begin
            rvalid <= 1'b0;
        end
    end

    assign s_axi_rvalid = rvalid;
    assign s_axi_rresp  = 2'b00;

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

    // Status registers (HW-managed)
    reg         busy;
    reg         done;
    reg         error;
    reg  [7:0]  error_code;

    // Task latched outputs
    reg         task_start_r;
    reg  [1:0]  task_type_r;
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
    reg  [1:0]  requant_slot_sel_r;
    reg  [31:0] requant_multiplier_r;
    reg  [5:0]  requant_shift_r;

    wire [5:0] wr_addr = stored_awaddr[7:2];
    wire wr_allowed = !busy || error;

    // Register write: use stored_wdata at the moment of write_hs
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
        end else if (write_hs && wr_allowed) begin
            case (wr_addr)
                ADDR_TASK_TYPE:    cfg_task_type    <= stored_wdata;
                ADDR_INPUT_ADDR:   cfg_input_addr   <= stored_wdata;
                ADDR_WEIGHT_ADDR:  cfg_weight_addr  <= stored_wdata;
                ADDR_OUTPUT_ADDR:  cfg_output_addr  <= stored_wdata;
                ADDR_INPUT_BYTES:  cfg_input_bytes  <= stored_wdata;
                ADDR_WEIGHT_BYTES: cfg_weight_bytes <= stored_wdata;
                ADDR_OUTPUT_BYTES: cfg_output_bytes <= stored_wdata;
                ADDR_DIM_IN:       cfg_dim_in       <= stored_wdata;
                ADDR_DIM_OUT:      cfg_dim_out      <= stored_wdata;
                ADDR_POSTPROC:     cfg_postproc     <= stored_wdata;
                ADDR_REQUANT_SEL:   cfg_requant_sel      <= stored_wdata;
                ADDR_REQUANT0_MULT: cfg_requant_mult[0]  <= stored_wdata;
                ADDR_REQUANT0_SHIFT:cfg_requant_shift[0] <= stored_wdata;
                ADDR_REQUANT1_MULT: cfg_requant_mult[1]  <= stored_wdata;
                ADDR_REQUANT1_SHIFT:cfg_requant_shift[1] <= stored_wdata;
                ADDR_REQUANT2_MULT: cfg_requant_mult[2]  <= stored_wdata;
                ADDR_REQUANT2_SHIFT:cfg_requant_shift[2] <= stored_wdata;
                ADDR_REQUANT3_MULT: cfg_requant_mult[3]  <= stored_wdata;
                ADDR_REQUANT3_SHIFT:cfg_requant_shift[3] <= stored_wdata;
                default: ;
            endcase
        end
    end

    // ============================================================
    // Control FSM: start / check / busy / done / error
    // ============================================================
    wire busy_write_violation = write_hs && busy && !error;
    wire busy_start_violation = write_hs && busy && !error && (wr_addr == ADDR_CTRL) && stored_wdata[0];
    wire clear_error_write = write_hs && (wr_addr == ADDR_CTRL) && stored_wdata[4] && !busy;
    wire write_new_start = write_hs && (wr_addr == ADDR_CTRL) && stored_wdata[0] && !done && !busy && !error;

    reg checking;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy       <= 1'b0;
            done       <= 1'b0;
            error      <= 1'b0;
            error_code <= 8'h0;
            checking   <= 1'b0;

            task_start_r    <= 1'b0;
            task_type_r     <= 2'b00;
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
            end else if (task_done_i && busy && !done) begin
                busy  <= 1'b0;
                done  <= 1'b1;
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
                task_type_r     <= cfg_task_type[1:0];
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

    // ============================================================
    // AXI read data generation
    // ============================================================
    wire [5:0] rd_addr = stored_araddr[7:2];

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
        (rd_addr == ADDR_REQUANT0_MULT)      ? cfg_requant_mult[0]   :
        (rd_addr == ADDR_REQUANT0_SHIFT)     ? cfg_requant_shift[0]  :
        (rd_addr == ADDR_REQUANT1_MULT)      ? cfg_requant_mult[1]   :
        (rd_addr == ADDR_REQUANT1_SHIFT)     ? cfg_requant_shift[1]  :
        (rd_addr == ADDR_REQUANT2_MULT)      ? cfg_requant_mult[2]   :
        (rd_addr == ADDR_REQUANT2_SHIFT)     ? cfg_requant_shift[2]  :
        (rd_addr == ADDR_REQUANT3_MULT)      ? cfg_requant_mult[3]   :
        (rd_addr == ADDR_REQUANT3_SHIFT)     ? cfg_requant_shift[3]  :
        32'h0;

    always @(posedge clk) begin
        if (ar_stored && !rvalid)
            rdata_reg <= rd_data_comb;
    end

    assign s_axi_rdata = rdata_reg;

endmodule
