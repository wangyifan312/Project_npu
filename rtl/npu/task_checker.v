// task_checker: validate task parameters and addresses before NPU execution
// One-cycle check: registers inputs on task_start, outputs result next cycle
`timescale 1ns / 1ps

module task_checker #(
    parameter [31:0] MEM_BASE  = 32'h0000_0000,  // valid memory region base
    parameter [31:0] MEM_SIZE  = 32'h0010_0000   // valid memory region size (1MB default)
) (
    input  wire        clk,
    input  wire        rst_n,

    // Task trigger from npu_ctrl
    input  wire        task_start,

    // Task parameters (from npu_ctrl latched outputs)
    input  wire [2:0]  task_type,
    input  wire [31:0] input_addr,
    input  wire [31:0] weight_addr,
    input  wire [31:0] output_addr,
    input  wire [31:0] input_bytes,
    input  wire [31:0] weight_bytes,
    input  wire [31:0] output_bytes,
    input  wire [15:0] input_h,
    input  wire [15:0] input_w,
    input  wire [15:0] input_c,
    input  wire [15:0] output_c,
    input  wire        relu_en,
    input  wire        pool_en,
    input  wire [31:0] conv_cfg,
    input  wire [31:0] bias_addr,
    input  wire [31:0] bias_bytes,
    input  wire [31:0] src1_addr,
    input  wire [31:0] src1_bytes,
    input  wire [31:0] add_cfg,
    input  wire [31:0] gap_cfg,
    input  wire [31:0] postproc_cfg_ext,
    input  wire [31:0] requant_multiplier,
    input  wire [5:0]  requant_shift,
    input  wire [31:0] add_src0_multiplier,
    input  wire [5:0]  add_src0_shift,
    input  wire [31:0] add_src1_multiplier,
    input  wire [5:0]  add_src1_shift,
    input  wire [31:0] add_out_multiplier,
    input  wire [5:0]  add_out_shift,

    // Check result
    output wire        checks_pass,
    output wire [7:0]  error_code,
    output wire        check_done    // pulsed when check completes
);

    // ============================================================
    // Error codes
    // ============================================================
    localparam ERR_NONE              = 8'h00;
    localparam ERR_INVALID_TASK_TYPE = 8'h01;
    localparam ERR_ZERO_BYTES        = 8'h02;
    localparam ERR_NULL_ADDR         = 8'h03;
    localparam ERR_ADDR_ALIGN        = 8'h04;
    localparam ERR_ADDR_BOUNDS       = 8'h05;
    localparam ERR_ADDR_OVERFLOW     = 8'h06;
    localparam ERR_CONV_PARAM        = 8'h07;
    localparam ERR_POOL_PARAM        = 8'h08;
    localparam ERR_DIM_RELATION      = 8'h09;
    localparam ERR_UNSUPPORTED_TASK  = 8'h0A;
    localparam ERR_NUMERIC_PARAM     = 8'h0B;
    localparam ERR_BIAS_PARAM        = 8'h0C;

    localparam [2:0] TASK_CONV       = 3'd0;
    localparam [2:0] TASK_FC         = 3'd1;
    localparam [2:0] TASK_POOL       = 3'd2;
    localparam [2:0] TASK_REQUANT    = 3'd3;
    localparam [2:0] TASK_ADD        = 3'd4;
    localparam [2:0] TASK_GAP        = 3'd5;
    localparam [2:0] TASK_VECTOR_RELU = 3'd6;
    localparam [2:0] TASK_GEMM        = 3'd7;

    // ============================================================
    // Internal registers (latch inputs on task_start)
    // ============================================================
    reg         checking;
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
    reg  [31:0] conv_cfg_r;
    reg  [31:0] bias_addr_r;
    reg  [31:0] bias_bytes_r;
    reg  [31:0] src1_addr_r;
    reg  [31:0] src1_bytes_r;
    reg  [31:0] add_cfg_r;
    reg  [31:0] gap_cfg_r;
    reg  [31:0] postproc_cfg_ext_r;
    reg  [31:0] add_src0_multiplier_r;
    reg  [5:0]  add_src0_shift_r;
    reg  [31:0] add_src1_multiplier_r;
    reg  [5:0]  add_src1_shift_r;
    reg  [31:0] add_out_multiplier_r;
    reg  [5:0]  add_out_shift_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            checking       <= 1'b0;
            task_type_r    <= TASK_CONV;
            input_addr_r   <= 32'h0;
            weight_addr_r  <= 32'h0;
            output_addr_r  <= 32'h0;
            input_bytes_r  <= 32'h0;
            weight_bytes_r <= 32'h0;
            output_bytes_r <= 32'h0;
            input_h_r      <= 16'h0;
            input_w_r      <= 16'h0;
            input_c_r      <= 16'h0;
            output_c_r     <= 16'h0;
            conv_cfg_r     <= 32'h0;
            bias_addr_r     <= 32'h0;
            bias_bytes_r    <= 32'h0;
            src1_addr_r     <= 32'h0;
            src1_bytes_r    <= 32'h0;
            add_cfg_r       <= 32'h0;
            gap_cfg_r       <= 32'h0;
            postproc_cfg_ext_r <= 32'h0;
            add_src0_multiplier_r <= 32'd1;
            add_src0_shift_r <= 6'd0;
            add_src1_multiplier_r <= 32'd1;
            add_src1_shift_r <= 6'd0;
            add_out_multiplier_r <= 32'd1;
            add_out_shift_r <= 6'd0;
        end else if (task_start && !checking) begin
            checking       <= 1'b1;
            task_type_r    <= task_type;
            input_addr_r   <= input_addr;
            weight_addr_r  <= weight_addr;
            output_addr_r  <= output_addr;
            input_bytes_r  <= input_bytes;
            weight_bytes_r <= weight_bytes;
            output_bytes_r <= output_bytes;
            input_h_r      <= input_h;
            input_w_r      <= input_w;
            input_c_r      <= input_c;
            output_c_r     <= output_c;
            conv_cfg_r     <= conv_cfg;
            bias_addr_r     <= bias_addr;
            bias_bytes_r    <= bias_bytes;
            src1_addr_r     <= src1_addr;
            src1_bytes_r    <= src1_bytes;
            add_cfg_r       <= add_cfg;
            gap_cfg_r       <= gap_cfg;
            postproc_cfg_ext_r <= postproc_cfg_ext;
            add_src0_multiplier_r <= add_src0_multiplier;
            add_src0_shift_r <= add_src0_shift;
            add_src1_multiplier_r <= add_src1_multiplier;
            add_src1_shift_r <= add_src1_shift;
            add_out_multiplier_r <= add_out_multiplier;
            add_out_shift_r <= add_out_shift;
        end else if (checking) begin
            checking <= 1'b0;  // one cycle check
        end
    end

    // ============================================================
    // Address helper: check if addr is in valid region
    // ============================================================
    function addr_in_bounds;
        input [31:0] addr;
        begin
            addr_in_bounds = (addr >= MEM_BASE) && (addr < MEM_BASE + MEM_SIZE);
        end
    endfunction

    // Address helper: check if addr + bytes doesn't overflow region
    function addr_range_ok;
        input [31:0] addr;
        input [31:0] bytes;
        reg [32:0] sum;
        begin
            sum = {1'b0, addr} + {1'b0, bytes};
            addr_range_ok = !sum[32] && (sum[31:0] <= MEM_BASE + MEM_SIZE);
        end
    endfunction

    // ============================================================
    // Combinational checks (evaluated when checking=1)
    // ============================================================
    reg [7:0]  error_code_comb;

    wire weight_unused = (task_type_r == TASK_POOL) ||
                         (task_type_r == TASK_REQUANT) ||
                         (task_type_r == TASK_ADD) ||
                         (task_type_r == TASK_GAP) ||
                         (task_type_r == TASK_VECTOR_RELU);

    // Alignment: require 64-byte alignment for AXI burst efficiency.
    // Pool/Requant/ADD may leave weight_addr unused.
    wire addr_aligned_ok = (input_addr_r[5:0]  == 6'h00) &&
                           (output_addr_r[5:0] == 6'h00) &&
                           (weight_unused || (weight_addr_r[5:0] == 6'h00));

    // Check that required bytes are non-zero (weight may be unused for Pool/Requant/ADD)
    wire bytes_ok = (input_bytes_r != 32'h0) && (output_bytes_r != 32'h0) &&
                    (weight_unused || (weight_bytes_r != 32'h0));

    // Check that required addresses are non-null (weight may be unused for Pool/Requant/ADD)
    wire addr_non_null = (input_addr_r != 32'h0) && (output_addr_r != 32'h0) &&
                         (weight_unused || (weight_addr_r != 32'h0));

    // Check addresses are in bounds (weight_addr may be 0 for Pool/Requant/ADD)
    wire addr_bounds_ok = addr_in_bounds(input_addr_r) &&
                          addr_in_bounds(output_addr_r) &&
                          (weight_unused || addr_in_bounds(weight_addr_r));

    // Check address ranges (weight may be 0 for Pool/Requant/ADD)
    wire addr_range_ok_sig = addr_range_ok(input_addr_r,  input_bytes_r) &&
                             addr_range_ok(output_addr_r, output_bytes_r) &&
                             (weight_unused || addr_range_ok(weight_addr_r, weight_bytes_r));

    // Check task_type
    wire task_type_known = (task_type_r == TASK_CONV)    ||
                           (task_type_r == TASK_FC)      ||
                           (task_type_r == TASK_POOL)    ||
                           (task_type_r == TASK_REQUANT) ||
                           (task_type_r == TASK_ADD)     ||
                           (task_type_r == TASK_GAP)     ||
                           (task_type_r == TASK_VECTOR_RELU) ||
                           (task_type_r == TASK_GEMM);
    wire task_type_supported = (task_type_r == TASK_CONV)    ||
                               (task_type_r == TASK_FC)      ||
                               (task_type_r == TASK_POOL)    ||
                               (task_type_r == TASK_REQUANT) ||
                               (task_type_r == TASK_ADD)     ||
                               (task_type_r == TASK_GAP)     ||
                               (task_type_r == TASK_VECTOR_RELU) ||
                               (task_type_r == TASK_GEMM);

    wire [1:0] conv_kernel_sel = conv_cfg_r[1:0];
    wire       conv_stride2    = conv_cfg_r[2];
    wire       conv_same_pad   = conv_cfg_r[3];
    wire       conv_bias_en    = conv_cfg_r[4];
    wire       bias_enabled    =
        ((task_type_r == TASK_CONV) || (task_type_r == TASK_FC)) && conv_bias_en;

    wire [15:0] conv_kernel_size =
        (conv_kernel_sel == 2'd1) ? 16'd1 :
        (conv_kernel_sel == 2'd2) ? 16'd3 :
                                    16'd5;

    wire [15:0] conv_out_h_valid =
        ((input_h_r >= conv_kernel_size) ?
            (((input_h_r - conv_kernel_size) >> conv_stride2) + 16'd1) :
            16'd0);
    wire [15:0] conv_out_w_valid =
        ((input_w_r >= conv_kernel_size) ?
            (((input_w_r - conv_kernel_size) >> conv_stride2) + 16'd1) :
            16'd0);
    wire [15:0] conv_out_h_same = conv_stride2 ? ((input_h_r + 16'd1) >> 1) : input_h_r;
    wire [15:0] conv_out_w_same = conv_stride2 ? ((input_w_r + 16'd1) >> 1) : input_w_r;
    wire [15:0] conv_out_h = conv_same_pad ? conv_out_h_same : conv_out_h_valid;
    wire [15:0] conv_out_w = conv_same_pad ? conv_out_w_same : conv_out_w_valid;

    wire conv_mode_legacy_5x5_valid_s1 =
        (conv_kernel_sel == 2'd0) && !conv_stride2 && !conv_same_pad;
    wire conv_mode_3x3_same =
        (conv_kernel_sel == 2'd2) && conv_same_pad;
    wire conv_mode_1x1_valid =
        (conv_kernel_sel == 2'd1) && !conv_same_pad;
    wire conv_mode_3x3_valid =
        (conv_kernel_sel == 2'd2) && !conv_same_pad && !conv_stride2;
    wire conv_mode_3x3_stride2 =
        (conv_kernel_sel == 2'd2) && conv_stride2 && !conv_same_pad;
    wire conv_cfg_supported =
        conv_mode_legacy_5x5_valid_s1 ||
        conv_mode_3x3_same ||
        conv_mode_1x1_valid ||
        conv_mode_3x3_valid ||
        conv_mode_3x3_stride2;

    wire conv_dim_ok =
        conv_cfg_supported &&
        (input_h_r >= 16'd1) &&
        (input_w_r >= 16'd1) &&
        (conv_out_h != 16'd0) &&
        (conv_out_w != 16'd0);

    // Pool: input dimensions must be even (2x2/stride=2)
    wire pool_dim_ok = (input_h_r[0] == 1'b0) && (input_w_r[0] == 1'b0);

    // Conv dimension check (only for Conv task_type)
    wire conv_check = (task_type_r != TASK_CONV) || conv_dim_ok;

    // Pool dimension check (only for Pool task_type)
    wire pool_check = (task_type_r != TASK_POOL) || pool_dim_ok;

    // Input/output channel relationship for Conv/FC
    // Conv: C_in >= 1, C_out >= 1
    // FC: C_in >= 1, C_out >= 1 (mapped to input_c/output_c or input_h/output_c)
    wire dim_relation_ok =
        ((task_type_r == TASK_REQUANT) || (task_type_r == TASK_ADD) || (task_type_r == TASK_GAP) ||
         (task_type_r == TASK_VECTOR_RELU)) ?
        1'b1 : ((input_c_r >= 16'd1) && (output_c_r >= 16'd1));

    // Requant task:
    // - input is INT32 words, so byte count must be 4 * output byte count
    // - no weight payload
    // - multiplier must be non-zero
    wire requant_param_ok =
        (task_type_r != TASK_REQUANT) ||
        ((input_bytes_r[1:0] == 2'b00) &&
         (output_bytes_r == (input_bytes_r >> 2)) &&
         (weight_bytes_r == 32'd0) &&
         (requant_multiplier != 32'd0) &&
         (requant_shift <= 6'd31));

    wire [31:0] bias_min_bytes = {14'd0, output_c_r, 2'b00};
    wire bias_param_ok =
        !bias_enabled ||
        ((bias_addr_r != 32'h0) &&
         (bias_addr_r[5:0] == 6'h00) &&
         addr_in_bounds(bias_addr_r) &&
         addr_range_ok(bias_addr_r, bias_bytes_r) &&
         (bias_bytes_r != 32'h0) &&
         (bias_bytes_r[1:0] == 2'b00) &&
         (bias_bytes_r >= bias_min_bytes));

    wire add_requant_en = add_cfg_r[3] || postproc_cfg_ext_r[1];
    wire add_cfg_ok = (add_cfg_r[1:0] == 2'd0) && (postproc_cfg_ext_r[31:2] == 30'd0);
    wire add_requant_ok =
        !add_requant_en ||
        ((add_src0_multiplier_r != 32'd0) &&
         (add_src0_shift_r <= 6'd31) &&
         (add_src1_multiplier_r != 32'd0) &&
         (add_src1_shift_r <= 6'd31) &&
         (add_out_multiplier_r != 32'd0) &&
         (add_out_shift_r <= 6'd31));
    wire add_param_ok =
        (task_type_r != TASK_ADD) ||
        (add_cfg_ok &&
         (src1_addr_r != 32'h0) &&
         (src1_addr_r[5:0] == 6'h00) &&
         addr_in_bounds(src1_addr_r) &&
         addr_range_ok(src1_addr_r, src1_bytes_r) &&
         (src1_bytes_r != 32'h0) &&
         (input_bytes_r == src1_bytes_r) &&
         (output_bytes_r == input_bytes_r) &&
         add_requant_ok);

    wire gap_post_requant_en = postproc_cfg_ext_r[1];
    wire gap_cfg_ok =
        (gap_cfg_r[1:0] == 2'd0) &&          // INT8 input
        (gap_cfg_r[3:2] == 2'd0) &&          // INT8 output
        (gap_cfg_r[19:4] == 16'd0) &&
        (gap_cfg_r[25:20] == 6'd6) &&        // exact 8x8 divide-by-64 shift
        (gap_cfg_r[31:26] == 6'd0) &&
        ((postproc_cfg_ext_r & 32'hFFFF_FFFD) == 32'd0);
    wire gap_requant_ok =
        !gap_post_requant_en ||
        ((requant_multiplier != 32'd0) && (requant_shift <= 6'd31));
    wire gap_param_ok =
        (task_type_r != TASK_GAP) ||
        (gap_cfg_ok &&
         (input_h_r == 16'd8) &&
         (input_w_r == 16'd8) &&
         (input_c_r >= 16'd1) &&
         (output_c_r == input_c_r) &&
         (input_bytes_r == ({16'd0, input_c_r} << 6)) &&
         (output_bytes_r == {16'd0, input_c_r}) &&
         (weight_bytes_r == 32'd0) &&
         gap_requant_ok);

    // Vector INT8 ReLU 256b task:
    // - input is INT8 array, output is INT8 array (same size)
    // - no weight payload
    // - requires 32B alignment (enforced by addr_aligned_ok)
    wire vec_relu_param_ok =
        (task_type_r != TASK_VECTOR_RELU) ||
        ((input_bytes_r == output_bytes_r) &&
         (weight_bytes_r == 32'd0));

    // Priority-encoded error
    always @(*) begin
        error_code_comb = ERR_NONE;
        if (!task_type_known)
            error_code_comb = ERR_INVALID_TASK_TYPE;
        else if (!task_type_supported)
            error_code_comb = ERR_UNSUPPORTED_TASK;
        else if (!bytes_ok)
            error_code_comb = ERR_ZERO_BYTES;
        else if (!addr_non_null)
            error_code_comb = ERR_NULL_ADDR;
        else if (!addr_aligned_ok)
            error_code_comb = ERR_ADDR_ALIGN;
        else if (!addr_bounds_ok)
            error_code_comb = ERR_ADDR_BOUNDS;
        else if (!addr_range_ok_sig)
            error_code_comb = ERR_ADDR_OVERFLOW;
        else if (!conv_check)
            error_code_comb = ERR_CONV_PARAM;
        else if (!pool_check)
            error_code_comb = ERR_POOL_PARAM;
        else if (!requant_param_ok)
            error_code_comb = ERR_NUMERIC_PARAM;
        else if (!bias_param_ok)
            error_code_comb = ERR_BIAS_PARAM;
        else if (!add_param_ok)
            error_code_comb = ERR_NUMERIC_PARAM;
        else if (!gap_param_ok)
            error_code_comb = ERR_NUMERIC_PARAM;
        else if (!vec_relu_param_ok)
            error_code_comb = ERR_NUMERIC_PARAM;
        else if (!dim_relation_ok)
            error_code_comb = ERR_DIM_RELATION;
        else
            error_code_comb = ERR_NONE;
    end

    wire all_checks_pass = (error_code_comb == ERR_NONE);

    // ============================================================
    // Output registers: valid in the cycle after checking=1
    // ============================================================
    reg         checks_pass_r;
    reg  [7:0]  error_code_r;
    reg         check_done_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            checks_pass_r <= 1'b0;
            error_code_r  <= 8'h00;
            check_done_r  <= 1'b0;
        end else if (checking) begin
            checks_pass_r <= all_checks_pass;
            error_code_r  <= all_checks_pass ? 8'h00 : error_code_comb;
            check_done_r  <= 1'b1;
        end else begin
            check_done_r <= 1'b0;
        end
    end

    assign checks_pass = checks_pass_r;
    assign error_code  = error_code_r;
    assign check_done  = check_done_r;

endmodule
