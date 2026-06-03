// block_scheduler: splits Conv/FC/Pool tasks into blocks that fit in on-chip buffers
// Computes per-block addresses, byte counts, and dimensions
// Conv: splits by output rows (horizontal stripes with kernel overlap)
// Pool: splits by output rows (2 input rows per 1 output row)
// FC: splits by output neurons (column groups)
// Multi-channel: blocks sized by acc_buffer capacity (output bytes bottleneck)
`timescale 1ns / 1ps

module block_scheduler #(
    parameter BUF_ENTRIES = 1024,     // entries per buffer bank
    parameter BUF_ADDR_W  = 10,
    parameter AXI_ADDR_W  = 32
) (
    input  wire        clk,
    input  wire        rst_n,

    // Task parameters (from npu_ctrl)
    input  wire        task_start,
    input  wire [1:0]  task_type,     // 0=Conv, 1=FC, 2=Pool, 3=Requant
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

    // Block request/response
    input  wire        block_done,
    output wire        block_valid,
    output wire        all_blocks_done,

    // Current block parameters
    output wire [31:0] blk_input_addr,
    output wire [31:0] blk_weight_addr,
    output wire [31:0] blk_output_addr,
    output wire [31:0] blk_input_bytes,
    output wire [31:0] blk_weight_bytes,
    output wire [31:0] blk_output_bytes,
    output wire [15:0] blk_input_rows,
    output wire [15:0] blk_output_rows,
    // Per-input-channel weight info (Conv/FC only)
    output wire [31:0] blk_wgt_per_cin,
    output wire [15:0] blk_cin_total
);

    // State
    localparam S_IDLE   = 2'd0;
    localparam S_ACTIVE = 2'd1;
    localparam S_DONE   = 2'd2;

    reg [1:0] state;

    reg [15:0] curr_out_row;
    reg [15:0] rows_per_block;
    reg [15:0] total_out_rows;
    reg [15:0] total_out_cols;
    reg [31:0] bytes_per_in_row;
    reg [31:0] bytes_per_out_row;
    reg [31:0] wgt_bytes_per_cin;

    reg [31:0] blk_input_addr_r;
    reg [31:0] blk_weight_addr_r;
    reg [31:0] blk_output_addr_r;
    reg [31:0] blk_input_bytes_r;
    reg [31:0] blk_weight_bytes_r;
    reg [31:0] blk_output_bytes_r;
    reg [15:0] blk_input_rows_r;
    reg [15:0] blk_output_rows_r;

    wire [15:0] next_total_out_rows =
        (task_type == 2'd2) ? (input_h >> 1) :
        ((task_type == 2'd1) || (task_type == 2'd3)) ? 16'd1 :
                              (input_h - 16'd5 + 16'd1);

    wire [15:0] next_total_out_cols =
        (task_type == 2'd2) ? (input_w >> 1) :
        ((task_type == 2'd1) || (task_type == 2'd3)) ? 16'd1 :
                              (input_w - 16'd5 + 16'd1);

    wire [31:0] next_bytes_per_in_row =
        (task_type == 2'd2) ? (input_w * input_c * 32'd4) :
        (task_type == 2'd3) ? input_bytes :
                              (input_w * input_c);

    wire [15:0] conv_rows_per_block_raw =
        (next_total_out_cols != 16'd0) ? (BUF_ENTRIES / (next_total_out_cols * output_c)) : 16'd0;
    wire [15:0] pool_rows_per_block_out_raw =
        (next_total_out_cols != 16'd0) ? (BUF_ENTRIES / (next_total_out_cols * output_c)) : 16'd0;
    wire [15:0] pool_rows_per_block_in_raw =
        ((2 * input_w * input_c) != 16'd0) ? (BUF_ENTRIES / (2 * input_w * input_c)) : 16'd0;
    wire [15:0] pool_rows_per_block_raw =
        (pool_rows_per_block_out_raw < pool_rows_per_block_in_raw) ? pool_rows_per_block_out_raw : pool_rows_per_block_in_raw;

    wire [15:0] next_rows_per_block =
        ((task_type == 2'd1) || (task_type == 2'd3)) ? 16'd1 :
        (task_type == 2'd0) ?
            ((conv_rows_per_block_raw < 16'd1) ? 16'd1 :
             (conv_rows_per_block_raw > next_total_out_rows) ? next_total_out_rows :
                                                               conv_rows_per_block_raw) :
            ((pool_rows_per_block_raw < 16'd1) ? 16'd1 :
             (pool_rows_per_block_raw > next_total_out_rows) ? next_total_out_rows :
                                                               pool_rows_per_block_raw);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            curr_out_row     <= 16'd0;
            rows_per_block   <= 16'd0;
            total_out_rows   <= 16'd0;
            total_out_cols   <= 16'd0;
            bytes_per_in_row <= 32'd0;
            bytes_per_out_row<= 32'd0;
            wgt_bytes_per_cin<= 32'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (task_start) begin
                        total_out_rows <= next_total_out_rows;
                        total_out_cols <= next_total_out_cols;
                        bytes_per_in_row <= next_bytes_per_in_row;
                        bytes_per_out_row <= next_total_out_cols * output_c * 32'd4;
                        wgt_bytes_per_cin <= ((32'd25 * output_c) + 32'd3) & 32'hFFFF_FFFC;
                        rows_per_block <= next_rows_per_block;
                        curr_out_row <= 16'd0;
                        state <= S_ACTIVE;
                    end
                end

                S_ACTIVE: begin
                    if (block_done) begin
                        if (curr_out_row + rows_per_block >= total_out_rows) begin
                            curr_out_row <= 16'd0;
                            state <= S_DONE;
                        end else begin
                            curr_out_row <= curr_out_row + rows_per_block;
                        end
                    end
                end

                S_DONE: begin
                    if (!task_start)
                        state <= S_IDLE;
                end
            endcase
        end
    end

    // Combinational block parameters
    wire [15:0] this_block_rows;
    wire [15:0] this_in_rows;

    assign this_block_rows = (curr_out_row + rows_per_block > total_out_rows)
                           ? (total_out_rows - curr_out_row)
                           : rows_per_block;
    // Conv: input rows = output rows + 4. Pool: input rows = 2 * output rows. FC: 1
    assign this_in_rows = (task_type == 2'd0) ? (this_block_rows + 16'd4) :
                          (task_type == 2'd2) ? (this_block_rows << 1) :
                          this_block_rows;

    always @(*) begin
        if (task_type == 2'd2) begin  // Pool: per-block slicing
            // Input: INT32, HWC layout. Each output row needs 2 input rows
            blk_input_addr_r  = input_addr  + curr_out_row * 2 * input_w * input_c * 32'd4;
            blk_input_bytes_r = this_in_rows * input_w * input_c * 32'd4;
            blk_weight_addr_r  = weight_addr;
            blk_weight_bytes_r = weight_bytes;
            blk_output_addr_r  = output_addr + curr_out_row * total_out_cols * output_c * 32'd4;
            blk_output_bytes_r = this_block_rows * total_out_cols * output_c * 32'd4;
            blk_input_rows_r   = this_in_rows;
            blk_output_rows_r  = this_block_rows;
        end else if (task_type == 2'd1) begin  // FC: pass through
            blk_input_addr_r   = input_addr;
            blk_input_bytes_r  = input_bytes;
            blk_weight_addr_r  = weight_addr;
            blk_weight_bytes_r = weight_bytes;
            blk_output_addr_r  = output_addr;
            blk_output_bytes_r = output_bytes;
            blk_input_rows_r   = input_h;
            blk_output_rows_r  = input_h;
        end else if (task_type == 2'd3) begin  // Requant: pass through
            blk_input_addr_r   = input_addr;
            blk_input_bytes_r  = input_bytes;
            blk_weight_addr_r  = 32'd0;
            blk_weight_bytes_r = 32'd0;
            blk_output_addr_r  = output_addr;
            blk_output_bytes_r = output_bytes;
            blk_input_rows_r   = 16'd1;
            blk_output_rows_r  = 16'd1;
        end else begin  // Conv: per-block slicing with kernel overlap
            blk_input_addr_r   = input_addr  + curr_out_row * input_w * input_c;
            blk_input_bytes_r  = this_in_rows * input_w * input_c;
            blk_weight_addr_r  = weight_addr;
            blk_weight_bytes_r = weight_bytes;
            blk_output_addr_r  = output_addr + curr_out_row * total_out_cols * output_c * 32'd4;
            blk_output_bytes_r = this_block_rows * total_out_cols * output_c * 32'd4;
            blk_input_rows_r   = this_in_rows;
            blk_output_rows_r  = this_block_rows;
        end
    end

    assign blk_input_addr   = blk_input_addr_r;
    assign blk_weight_addr  = blk_weight_addr_r;
    assign blk_output_addr  = blk_output_addr_r;
    assign blk_input_bytes  = blk_input_bytes_r;
    assign blk_weight_bytes = blk_weight_bytes_r;
    assign blk_output_bytes = blk_output_bytes_r;
    assign blk_input_rows   = blk_input_rows_r;
    assign blk_output_rows  = blk_output_rows_r;

    assign blk_wgt_per_cin  = wgt_bytes_per_cin;
    assign blk_cin_total    = input_c;

    assign block_valid      = (state == S_ACTIVE);
    assign all_blocks_done  = (state == S_DONE);

endmodule
