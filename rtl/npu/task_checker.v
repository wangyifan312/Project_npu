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
    input  wire [1:0]  task_type,
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
    localparam ERR_FC_NOT_SUPPORTED  = 8'h0A;

    // ============================================================
    // Internal registers (latch inputs on task_start)
    // ============================================================
    reg         checking;
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            checking       <= 1'b0;
            task_type_r    <= 2'b00;
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

    // Alignment: require 64-byte alignment for AXI burst efficiency
    // For Pool, weight_addr may be unused (0), skip its alignment check
    wire addr_aligned_ok = (input_addr_r[5:0]  == 6'h00) &&
                           (output_addr_r[5:0] == 6'h00) &&
                           ((task_type_r == 2'd2) || (weight_addr_r[5:0] == 6'h00));

    // Check that required bytes are non-zero (weight may be unused for Pool)
    wire bytes_ok = (input_bytes_r != 32'h0) && (output_bytes_r != 32'h0) &&
                    ((task_type_r == 2'd2) || (weight_bytes_r != 32'h0));

    // Check that required addresses are non-null (weight may be unused for Pool)
    wire addr_non_null = (input_addr_r != 32'h0) && (output_addr_r != 32'h0) &&
                         ((task_type_r == 2'd2) || (weight_addr_r != 32'h0));

    // Check addresses are in bounds (weight_addr may be 0 for Pool)
    wire addr_bounds_ok = addr_in_bounds(input_addr_r) &&
                          addr_in_bounds(output_addr_r) &&
                          ((task_type_r == 2'd2) || addr_in_bounds(weight_addr_r));

    // Check address ranges (weight may be 0 for Pool)
    wire addr_range_ok_sig = addr_range_ok(input_addr_r,  input_bytes_r) &&
                             addr_range_ok(output_addr_r, output_bytes_r) &&
                             ((task_type_r == 2'd2) || addr_range_ok(weight_addr_r, weight_bytes_r));

    // Check task_type: FC (2'd1) is not supported in current version
    wire task_type_ok = (task_type_r == 2'd0) ||  // Conv
                        (task_type_r == 2'd1) ||  // FC
                        (task_type_r == 2'd2);    // Pool

    // Conv: input must be >= 5x5 (kernel size)
    wire conv_dim_ok = (input_h_r >= 16'd5) && (input_w_r >= 16'd5);

    // Pool: input dimensions must be even (2x2/stride=2)
    wire pool_dim_ok = (input_h_r[0] == 1'b0) && (input_w_r[0] == 1'b0);

    // Conv dimension check (only for Conv task_type)
    wire conv_check = (task_type_r != 2'd0) || conv_dim_ok;

    // Pool dimension check (only for Pool task_type)
    wire pool_check = (task_type_r != 2'd2) || pool_dim_ok;

    // Input/output channel relationship for Conv/FC
    // Conv: C_in >= 1, C_out >= 1
    // FC: C_in >= 1, C_out >= 1 (mapped to input_c/output_c or input_h/output_c)
    wire dim_relation_ok = (input_c_r >= 16'd1) && (output_c_r >= 16'd1);

    // Priority-encoded error
    always @(*) begin
        error_code_comb = ERR_NONE;
        if (!task_type_ok)
            error_code_comb = ERR_INVALID_TASK_TYPE;
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
