// conv_frontend: 5x5 convolution window generator (stride=1, valid padding)
// Multi-channel: line buffer stores C_in channels at each spatial position (HWC layout)
// Window extraction: 25 spatial values for a selected input channel
// Sliding window: line buffer holds 5 rows, shifts up as new rows arrive
`timescale 1ns / 1ps

module conv_frontend #(
    parameter MAX_W    = 32,   // max input feature map width
    parameter MAX_C_IN = 64,   // max input channels
    parameter AW       = 11    // log2(MAX_W * MAX_C_IN) for line buffer addressing
) (
    input  wire        clk,
    input  wire        rst_n,

    // Input: streaming activation data from act_buffer (HWC layout, INT8 per byte)
    input  wire [7:0]  act_data,
    input  wire        act_valid,
    output wire        act_ready,

    // Output: 5x5 window as 25-element vector (row-major: w[r*5+c])
    // Window values are for the currently selected input channel
    output wire [7:0]  window_00, window_01, window_02, window_03, window_04,
    output wire [7:0]  window_10, window_11, window_12, window_13, window_14,
    output wire [7:0]  window_20, window_21, window_22, window_23, window_24,
    output wire [7:0]  window_30, window_31, window_32, window_33, window_34,
    output wire [7:0]  window_40, window_41, window_42, window_43, window_44,
    output wire        window_valid,

    // Channel selection: which input channel to extract (0..C_in-1)
    input  wire [5:0]  channel_sel,   // selected input channel

    // Control
    input  wire [15:0] input_w,         // feature map width
    input  wire [15:0] input_h,         // feature map height (informational)
    input  wire [15:0] input_c,         // number of input channels (1..MAX_C_IN)
    input  wire [15:0] block_out_rows,  // output rows for this block
    input  wire [15:0] block_in_rows,   // input rows for this block (= block_out_rows + 4)
    input  wire        start,           // pulse to begin
    input  wire        window_hold,     // npu_top busy: pause window advancement
    output wire        done,            // all windows for this block generated
    output wire [15:0] cur_row,         // current window row
    output wire [15:0] cur_col          // current window column
);

    // Maximum line width = MAX_W * MAX_C_IN bytes per row
    localparam MAX_LINE_W = MAX_W * MAX_C_IN;

    // Line buffer: 5 rows x MAX_LINE_W x 8 bits
    reg [7:0] lb [0:4][0:MAX_LINE_W-1];

    // State machine
    localparam S_IDLE              = 3'd0;
    localparam S_LOAD_FIRST_5      = 3'd1;
    localparam S_COMPUTE           = 3'd2;
    localparam S_SHIFT             = 3'd5;
    localparam S_SLIDE_AND_COMPUTE = 3'd3;
    localparam S_DONE              = 3'd4;

    reg [2:0]  state;
    reg [15:0] curr_row, curr_col;
    reg [15:0] load_row, load_col;     // loading position (byte index within row)
    reg [15:0] rows_loaded;
    reg [15:0] total_out_rows;
    reg [15:0] total_out_cols;
    reg [15:0] block_in;
    reg [15:0] bytes_per_row;          // input_w * input_c
    reg        load_phase;
    reg        shift_now;
    reg        flush_lb;
    integer    si, sj;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            curr_row        <= 16'd0;
            curr_col        <= 16'd0;
            load_row        <= 16'd0;
            load_col        <= 16'd0;
            rows_loaded     <= 16'd0;
            total_out_rows  <= 16'd0;
            total_out_cols  <= 16'd0;
            block_in        <= 16'd0;
            bytes_per_row   <= 16'd0;
            load_phase      <= 1'b0;
            shift_now       <= 1'b0;
            flush_lb        <= 1'b0;
        end else begin
            shift_now <= 1'b0;
            flush_lb  <= 1'b0;

            if (flush_lb) begin
                for (si = 0; si < 5; si = si + 1)
                    for (sj = 0; sj < MAX_LINE_W; sj = sj + 1)
                        lb[si][sj] <= 8'd0;
            end else if (shift_now) begin
                for (si = 0; si < MAX_LINE_W; si = si + 1) begin
                    lb[0][si] <= lb[1][si];
                    lb[1][si] <= lb[2][si];
                    lb[2][si] <= lb[3][si];
                    lb[3][si] <= lb[4][si];
                end
            end

            if (start) begin
                curr_row       <= 16'd0;
                curr_col       <= 16'd0;
                load_row       <= 16'd0;
                load_col       <= 16'd0;
                rows_loaded    <= 16'd0;
                total_out_rows <= block_out_rows;
                total_out_cols <= input_w - 16'd5 + 16'd1;
                block_in       <= block_in_rows;
                bytes_per_row  <= input_w * input_c;
                load_phase     <= 1'b1;
                flush_lb       <= 1'b1;
                state          <= S_LOAD_FIRST_5;
            end else case (state)
                S_IDLE: begin
                    // start handled with priority above
                end

                S_LOAD_FIRST_5: begin
                    if (act_valid && act_ready && !flush_lb) begin
                        lb[4][load_col] <= act_data;
                        if (load_col + 16'd1 == bytes_per_row) begin
                            load_col <= 16'd0;
                            rows_loaded <= rows_loaded + 16'd1;
                            if (rows_loaded + 16'd1 == 16'd5) begin
                                load_phase <= 1'b0;
                                curr_row <= 16'd0;
                                curr_col <= 16'd0;
                                state <= S_COMPUTE;
                            end else begin
                                shift_now <= 1'b1;
                                load_row <= load_row + 16'd1;
                            end
                        end else begin
                            load_col <= load_col + 16'd1;
                        end
                    end
                end

                S_COMPUTE: begin
                    if (!window_hold) begin
                        if (curr_col + 16'd1 == total_out_cols) begin
                            curr_col <= 16'd0;
                            if (curr_row + 16'd1 == total_out_rows) begin
                                state <= S_DONE;
                            end else if (rows_loaded < block_in) begin
                                shift_now <= 1'b1;
                                load_col <= 16'd0;
                                state <= S_SHIFT;
                            end else begin
                                curr_row <= curr_row + 16'd1;
                            end
                        end else begin
                            curr_col <= curr_col + 16'd1;
                        end
                    end
                end

                S_SHIFT: begin
                    curr_row <= curr_row + 16'd1;
                    load_col <= 16'd0;
                    load_phase <= 1'b1;
                    state <= S_SLIDE_AND_COMPUTE;
                end

                S_SLIDE_AND_COMPUTE: begin
                    if (act_valid && act_ready && load_phase && !shift_now) begin
                        lb[4][load_col] <= act_data;
                        if (load_col + 16'd1 == bytes_per_row) begin
                            load_col <= 16'd0;
                            rows_loaded <= rows_loaded + 16'd1;
                            load_phase <= 1'b0;
                            state <= S_COMPUTE;
                        end else begin
                            load_col <= load_col + 16'd1;
                        end
                    end
                end

                S_DONE: begin
                end
            endcase
        end
    end

    assign act_ready    = ((state == S_LOAD_FIRST_5) && load_phase) ||
                          ((state == S_SLIDE_AND_COMPUTE) && load_phase);

    assign window_valid = (state == S_COMPUTE);
    assign cur_row      = curr_row;
    assign cur_col      = curr_col;

    reg done_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            done_r <= 1'b0;
        else if (start)
            done_r <= 1'b0;
        else if (state == S_DONE)
            done_r <= 1'b1;
    end
    assign done = done_r;

    // ============================================================
    // Window extraction (combinational) — for selected channel
    // For spatial position (curr_row + r, curr_col + c), channel channel_sel:
    //   byte offset within row = (curr_col + c) * input_c + channel_sel
    // ============================================================
    wire [AW:0] row_bytes_per_col;  // bytes per column stride
    wire [AW:0] c0_byte, c1_byte, c2_byte, c3_byte, c4_byte;

    // Each column advance adds input_c bytes (stride between consecutive HWC positions)
    assign row_bytes_per_col = {AW{1'b0}} | {5'd0, input_c};

    // Byte address for window top-left corner channel
    wire [AW:0] base_byte = {AW{1'b0}} | ({5'd0, curr_col} * row_bytes_per_col) | {6'd0, channel_sel};
    assign c0_byte = base_byte;
    assign c1_byte = base_byte + row_bytes_per_col;
    assign c2_byte = base_byte + (row_bytes_per_col << 1);
    assign c3_byte = base_byte + (row_bytes_per_col * 16'd3);
    assign c4_byte = base_byte + (row_bytes_per_col << 2);

    assign window_00 = lb[0][c0_byte]; assign window_01 = lb[0][c1_byte]; assign window_02 = lb[0][c2_byte]; assign window_03 = lb[0][c3_byte]; assign window_04 = lb[0][c4_byte];
    assign window_10 = lb[1][c0_byte]; assign window_11 = lb[1][c1_byte]; assign window_12 = lb[1][c2_byte]; assign window_13 = lb[1][c3_byte]; assign window_14 = lb[1][c4_byte];
    assign window_20 = lb[2][c0_byte]; assign window_21 = lb[2][c1_byte]; assign window_22 = lb[2][c2_byte]; assign window_23 = lb[2][c3_byte]; assign window_24 = lb[2][c4_byte];
    assign window_30 = lb[3][c0_byte]; assign window_31 = lb[3][c1_byte]; assign window_32 = lb[3][c2_byte]; assign window_33 = lb[3][c3_byte]; assign window_34 = lb[3][c4_byte];
    assign window_40 = lb[4][c0_byte]; assign window_41 = lb[4][c1_byte]; assign window_42 = lb[4][c2_byte]; assign window_43 = lb[4][c3_byte]; assign window_44 = lb[4][c4_byte];

endmodule
