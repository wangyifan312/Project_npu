// conv_frontend: 5x5/3x3/1x1 模式卷积窗口生成器骨架
// 多通道：行缓冲区在每个空间位置存储 C_in 个通道（HWC 布局）
// 窗口提取：选定输入通道的 25 个空间值
// 滑动窗口：行缓冲区保留 5 行，新行到达时向上移位
`timescale 1ns / 1ps

module conv_frontend #(
    parameter MAX_W    = 32,   // 最大输入特征图宽度
    parameter MAX_C_IN = 64,   // 最大输入通道数
    parameter AW       = 11    // 行缓冲区寻址的 log2(MAX_W * MAX_C_IN)
) (
    input  wire        clk,
    input  wire        rst_n,

    // 输入：来自 act_buffer 的流式激活数据（HWC 布局，每字节 INT8）
    input  wire [7:0]  act_data,
    input  wire        act_valid,
    output wire        act_ready,

    // 输出：5x5 窗口，表示为 25 元素向量（行优先：w[r*5+c]）
    // 窗口值为当前选定输入通道的值
    output wire [7:0]  window_00, window_01, window_02, window_03, window_04,
    output wire [7:0]  window_10, window_11, window_12, window_13, window_14,
    output wire [7:0]  window_20, window_21, window_22, window_23, window_24,
    output wire [7:0]  window_30, window_31, window_32, window_33, window_34,
    output wire [7:0]  window_40, window_41, window_42, window_43, window_44,
    output wire        window_valid,

    // 通道选择：要提取哪个输入通道（0..C_in-1）
    input  wire [5:0]  channel_sel,   // 选定的输入通道

    // 控制
    input  wire [15:0] input_w,         // 特征图宽度
    input  wire [15:0] input_h,         // 特征图高度（仅供参考）
    input  wire [15:0] input_c,         // 输入通道数（1..MAX_C_IN）
    input  wire [31:0] conv_cfg,        // R1b：卷积核/步长/填充控制
    input  wire [15:0] block_out_rows,  // 本块的输出行数
    input  wire [15:0] block_in_rows,   // 本块的输入行数（= block_out_rows + 4）
    input  wire        start,           // 启动脉冲
    input  wire        window_hold,     // npu_top 忙碌：暂停窗口推进
    output wire        done,            // 本块所有窗口已生成
    output wire [15:0] cur_row,         // 当前窗口行
    output wire [15:0] cur_col          // 当前窗口列
);

    // 最大行宽 = MAX_W * MAX_C_IN 字节每行
    localparam MAX_LINE_W = MAX_W * MAX_C_IN;

    // 行缓冲区：5 行 x MAX_LINE_W x 8 位
    reg [7:0] lb [0:4][0:MAX_LINE_W-1];

    // 状态机
    localparam S_IDLE              = 3'd0;
    localparam S_LOAD_FIRST_5      = 3'd1;
    localparam S_COMPUTE           = 3'd2;
    localparam S_SHIFT             = 3'd5;
    localparam S_SLIDE_AND_COMPUTE = 3'd3;
    localparam S_DONE              = 3'd4;

    reg [2:0]  state;
    reg [15:0] curr_row, curr_col;
    reg [15:0] load_row, load_col;     // 加载位置（行内字节索引）
    reg [15:0] rows_loaded;
    reg [15:0] total_out_rows;
    reg [15:0] total_out_cols;
    reg [15:0] block_in;
    reg [15:0] bytes_per_row;          // input_w * input_c
    reg [15:0] kernel_size_r;
    reg [15:0] stride_r;
    reg [15:0] pad_r;
    reg [15:0] prefill_rows;
    integer    lb_base_row;           // 当前存储在 lb[0] 中的逻辑输入行
    reg        load_phase;
    reg        shift_now;
    reg        flush_lb;
    reg  [3:0] stride_shift_cnt;   // stride>1 行切换时的剩余移位次数
    reg        stride_first_shift;  // 1 = 首次进入 S_SHIFT（推进 curr_row）
    integer    si, sj;

    wire [1:0] conv_kernel_sel = conv_cfg[1:0];
    wire       conv_stride2    = conv_cfg[2];
    wire       conv_same_pad   = conv_cfg[3];
    wire [15:0] conv_kernel_size =
        (conv_kernel_sel == 2'd1) ? 16'd1 :
        (conv_kernel_sel == 2'd2) ? 16'd3 :
                                    16'd5;
    wire [15:0] conv_stride = conv_stride2 ? 16'd2 : 16'd1;
    wire [15:0] conv_pad = conv_same_pad ? (conv_kernel_size >> 1) : 16'd0;
    wire [15:0] prefill_rows_next =
        (block_in_rows < conv_kernel_size) ? block_in_rows : conv_kernel_size;

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
            kernel_size_r   <= 16'd5;
            stride_r        <= 16'd1;
            pad_r           <= 16'd0;
            prefill_rows    <= 16'd5;
            lb_base_row     <= 0;
            load_phase      <= 1'b0;
            shift_now       <= 1'b0;
            flush_lb        <= 1'b0;
            stride_shift_cnt <= 4'd0;
            stride_first_shift <= 1'b0;
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
                if (state != S_LOAD_FIRST_5)
                    lb_base_row <= lb_base_row + 1;
            end

            if (start) begin
                curr_row       <= 16'd0;
                curr_col       <= 16'd0;
                load_row       <= 16'd0;
                load_col       <= 16'd0;
                rows_loaded    <= 16'd0;
                total_out_rows <= block_out_rows;
                total_out_cols <= conv_out_dim(input_w, conv_kernel_size, conv_stride, conv_same_pad);
                block_in       <= block_in_rows;
                bytes_per_row  <= input_w * input_c;
                kernel_size_r  <= conv_kernel_size;
                stride_r       <= conv_stride;
                pad_r          <= conv_pad;
                prefill_rows   <= prefill_rows_next;
                lb_base_row    <= $signed({1'b0, prefill_rows_next}) - 17'sd5;
                load_phase     <= 1'b1;
                flush_lb       <= 1'b1;
                state          <= S_LOAD_FIRST_5;
            end else case (state)
                S_IDLE: begin
                    // start 已在上方优先处理
                end

                S_LOAD_FIRST_5: begin
                    if (act_valid && act_ready && !flush_lb) begin
                        lb[4][load_col] <= act_data;
                        if (load_col + 16'd1 == bytes_per_row) begin
                            load_col <= 16'd0;
                            rows_loaded <= rows_loaded + 16'd1;
                            if (rows_loaded + 16'd1 == prefill_rows) begin
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
                                stride_first_shift <= 1'b1;
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
                    load_col <= 16'd0;
                    load_phase <= 1'b1;
                    if (stride_first_shift) begin
                        curr_row <= curr_row + 16'd1;
                        stride_first_shift <= 1'b0;
                        stride_shift_cnt <= (stride_r > 16'd1) ? (stride_r - 16'd1) : 4'd0;
                    end
                    state <= S_SLIDE_AND_COMPUTE;
                end

                S_SLIDE_AND_COMPUTE: begin
                    if (act_valid && act_ready && load_phase && !shift_now) begin
                        lb[4][load_col] <= act_data;
                        if (load_col + 16'd1 == bytes_per_row) begin
                            load_col <= 16'd0;
                            rows_loaded <= rows_loaded + 16'd1;
                            load_phase <= 1'b0;
                            // 对于 stride>1，可能需要额外移位来覆盖步长间隙
                            if (stride_shift_cnt > 4'd0) begin
                                stride_shift_cnt <= stride_shift_cnt - 4'd1;
                                shift_now <= 1'b1;
                                state <= S_SHIFT;
                            end else begin
                                state <= S_COMPUTE;
                            end
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
    // 紧凑窗口提取。5x5 沿用原有端口 [0:24]。
    // 3x3 使用端口 [0:8]，1x1 使用端口 [0]。stride/same padding
    // 作为控制/前端骨架被接受；same/stride2 的边界行
    // 在 ResNet 数值使用前仍需 R1b+ 数据路径验证。
    // ============================================================
    reg [7:0] compact_window [0:24];
    integer kr;
    integer kc;
    integer idx;
    integer src_col;
    integer logical_src_row;
    integer lb_row;
    integer byte_idx;
    integer wi;

    always @(*) begin
        for (wi = 0; wi < 25; wi = wi + 1)
            compact_window[wi] = 8'd0;

        for (kr = 0; kr < 5; kr = kr + 1) begin
            for (kc = 0; kc < 5; kc = kc + 1) begin
                if ((kr < kernel_size_r) && (kc < kernel_size_r)) begin
                    idx = kr * kernel_size_r + kc;
                    if (conv_same_pad && (input_h <= kernel_size_r)) begin
                        // 保留 R1g 使用的紧凑别名冒烟合约：
                        // 小型 3x3 别名不是完整尺寸 same-padding
                        // 证据，保持 R1h 之前的行缓冲区位置。
                        logical_src_row = kr;
                        lb_row = kr;
                    end else begin
                        logical_src_row = (curr_row * stride_r) + kr - pad_r;
                        lb_row = logical_src_row - lb_base_row;
                    end
                    src_col = (curr_col * stride_r) + kc - pad_r;
                    byte_idx = src_col * input_c + channel_sel;
                    if ((idx < 25) &&
                        (logical_src_row >= 0) && (logical_src_row < input_h) &&
                        (lb_row >= 0) && (lb_row < 5) &&
                        (src_col >= 0) && (src_col < input_w) &&
                        (byte_idx >= 0) && (byte_idx < MAX_LINE_W))
                        compact_window[idx] = lb[lb_row][byte_idx];
                end
            end
        end
    end

    assign window_00 = compact_window[0];  assign window_01 = compact_window[1];  assign window_02 = compact_window[2];  assign window_03 = compact_window[3];  assign window_04 = compact_window[4];
    assign window_10 = compact_window[5];  assign window_11 = compact_window[6];  assign window_12 = compact_window[7];  assign window_13 = compact_window[8];  assign window_14 = compact_window[9];
    assign window_20 = compact_window[10]; assign window_21 = compact_window[11]; assign window_22 = compact_window[12]; assign window_23 = compact_window[13]; assign window_24 = compact_window[14];
    assign window_30 = compact_window[15]; assign window_31 = compact_window[16]; assign window_32 = compact_window[17]; assign window_33 = compact_window[18]; assign window_34 = compact_window[19];
    assign window_40 = compact_window[20]; assign window_41 = compact_window[21]; assign window_42 = compact_window[22]; assign window_43 = compact_window[23]; assign window_44 = compact_window[24];

endmodule
