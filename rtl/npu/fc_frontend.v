// fc_frontend: Fully-Connected layer input formatting for systolic array
// Passes activations through as a 1D vector stream for vector-matrix multiply.
// Supports tiling: if output neurons > array columns, iterates over column blocks.
// Weights for output column j go to array column j; activations stream through rows.
`timescale 1ns / 1ps

module fc_frontend #(
    parameter MAX_COLS = 64    // max array columns available for FC weights
) (
    input  wire        clk,
    input  wire        rst_n,

    // Input: streaming activation data from act_buffer
    input  wire [7:0]  act_data,
    input  wire        act_valid,
    output wire        act_ready,

    // Output: activation stream (1D vector, same data, gated by state)
    output wire [7:0]  act_out,
    output wire        act_valid_o,

    // Control
    input  wire [15:0] input_size,   // total number of input activations (N)
    input  wire [15:0] output_size,  // total number of output neurons (M)
    input  wire [15:0] block_start,  // starting output column for this block
    input  wire        start,
    output wire        done,
    output wire        block_done    // pulsed when current block done, next block needed
);

    // ============================================================
    // State machine
    // ============================================================
    localparam S_IDLE     = 2'd0;
    localparam S_STREAM   = 2'd1;  // streaming activations for current block
    localparam S_BLOCK_DONE = 2'd2;
    localparam S_DONE     = 2'd3;

    reg [1:0]  state;
    reg [15:0] count;           // activations fed in current block
    reg [15:0] block_col;       // current block's starting output column
    reg [15:0] total_blocks;    // ceil(output_size / MAX_COLS)

    // ============================================================
    // Sequential
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            count        <= 16'd0;
            block_col    <= 16'd0;
            total_blocks <= 16'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start) begin
                        count        <= 16'd0;
                        block_col    <= block_start;
                        total_blocks <= (output_size + MAX_COLS - 1) / MAX_COLS;
                        state <= S_STREAM;
                    end
                end

                S_STREAM: begin
                    if (act_valid && act_ready) begin
                        if (count + 16'd1 == input_size) begin
                            count <= 16'd0;
                            state <= S_BLOCK_DONE;
                        end else begin
                            count <= count + 16'd1;
                        end
                    end
                end

                S_BLOCK_DONE: begin
                    if (block_col + MAX_COLS >= output_size) begin
                        state <= S_DONE;
                    end else begin
                        block_col <= block_col + MAX_COLS;
                        count <= 16'd0;
                        state <= S_STREAM;
                    end
                end

                S_DONE: begin
                    if (!start)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ============================================================
    // Outputs
    // ============================================================
    assign act_ready  = (state == S_STREAM);
    assign act_out    = act_data;
    assign act_valid_o = (state == S_STREAM) && act_valid;
    assign done       = (state == S_DONE);
    assign block_done = (state == S_BLOCK_DONE);

endmodule
