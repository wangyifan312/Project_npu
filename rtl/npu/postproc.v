// postproc: ReLU + 可选 2x2 MaxPool（stride=2），INT32 域
// 通过 input_c 步长支持多通道 HWC 布局
`timescale 1ns / 1ps

module postproc #(
    parameter DATA_W = 32,
    parameter MAX_OUT_W = 240  // 行缓冲区的最大 (output_w * max_channels)
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [DATA_W-1:0] data_in,
    input  wire              data_valid,
    output wire              data_ready,

    output wire [DATA_W-1:0] data_out,
    output wire              data_valid_o,

    input  wire        relu_en,
    input  wire        pool_en,
    input  wire [15:0] input_w,     // 空间宽度
    input  wire [15:0] input_h,     // 空间高度（每块）
    input  wire [15:0] input_c,     // 通道数（空间相邻元素之间的步长）
    input  wire        start,
    output wire        done
);

    // ReLU（组合逻辑）
    wire [DATA_W-1:0] relu_out;
    assign relu_out = (relu_en && data_in[DATA_W-1]) ? {DATA_W{1'b0}} : data_in;

    // ============================================================
    // MaxPool 状态：跟踪 HWC 流中的位置
    // elem_idx: 每行内 0..W*C-1，空间列 = elem_idx / C
    // ============================================================
    reg [15:0]  elem_idx;       // 每行内 0..W*C-1
    reg         row_parity;     // 0=first of pair, 1=second
    reg [31:0]  processed;
    reg [31:0]  total_out;
    reg         done_r, bypass_done_r;

    // 每通道偶数列存储
    reg [DATA_W-1:0] curr_even [0:63];
    // 行缓冲区: (W/2)*C 项，用于存储上一行的 h_max
    reg [DATA_W-1:0] line_buf [0:MAX_OUT_W-1];
    integer ii;

    wire [15:0] row_width = input_w * input_c;
    wire [15:0] out_col_w = input_w >> 1;  // 每行输出空间列数
    wire [5:0]  ch_sub = elem_idx % input_c;
    wire [15:0] spatial_col = elem_idx / input_c;
    wire        is_even_col = ~spatial_col[0];
    wire        is_odd_col  = spatial_col[0];
    wire        is_last_ch  = (ch_sub + 6'd1 == input_c[5:0]);
    wire [15:0] out_col = spatial_col >> 1;
    wire [15:0] lb_index = out_col * input_c + {11'd0, ch_sub};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            elem_idx    <= 16'd0;
            row_parity  <= 1'b0;
            processed   <= 32'd0;
            total_out   <= 32'd0;
            done_r      <= 1'b0;
            bypass_done_r <= 1'b0;
        end else if (start) begin
            elem_idx    <= 16'd0;
            row_parity  <= 1'b0;
            processed   <= 32'd0;
            done_r      <= 1'b0;
            bypass_done_r <= 1'b0;
            for (ii = 0; ii < 64; ii = ii + 1)
                curr_even[ii] <= {DATA_W{1'b0}};
            for (ii = 0; ii < MAX_OUT_W; ii = ii + 1)
                line_buf[ii] <= {DATA_W{1'b0}};
            if (pool_en)
                total_out <= (input_h >> 1) * out_col_w * input_c;
            else
                total_out <= input_h * input_w * input_c;
        end else if (pool_en && data_valid && !done_r) begin
            // 锁存每通道的偶数列值
            if (is_even_col)
                curr_even[ch_sub] <= relu_out;

            // 按 HWC 顺序计数每个池化输出元素。
            if (is_odd_col && row_parity)
                processed <= processed + 32'd1;

            // 每周期前进一个 HWC 元素。
            if (elem_idx + 16'd1 == row_width) begin
                elem_idx   <= 16'd0;
                row_parity <= ~row_parity;
            end else begin
                elem_idx <= elem_idx + 16'd1;
            end
        end else if (!pool_en && data_valid) begin
            processed <= processed + 32'd1;
        end

        // 完成检测
        if (pool_en)
            done_r <= (processed >= total_out) && (total_out > 0);
        else
            bypass_done_r <= (processed >= total_out) && (total_out > 0);
    end

    // 水平最大值：前一空间列的偶数值 vs 当前奇数值
    wire [DATA_W-1:0] h_max;
    assign h_max = ($signed(curr_even[ch_sub]) > $signed(relu_out))
                   ? curr_even[ch_sub] : relu_out;

    // 垂直最大值：当前 h_max vs 上一行存储的值
    wire [DATA_W-1:0] v_max;
    assign v_max = ($signed(h_max) > $signed(line_buf[lb_index]))
                   ? h_max : line_buf[lb_index];

    // 在奇数列为每个通道更新行缓冲区，使垂直池化
    // 看到完整的 HWC 流，而非仅最后一个通道。
    always @(posedge clk) begin
        if (pool_en && data_valid && is_odd_col)
            line_buf[lb_index] <= h_max;
    end

    wire pool_valid;
    assign pool_valid = pool_en && data_valid && is_odd_col && row_parity;

    wire [DATA_W-1:0] bypass_data;
    wire bypass_valid;
    assign bypass_data  = relu_out;
    assign bypass_valid = data_valid && !pool_en;

    assign data_out     = pool_en ? v_max : bypass_data;
    assign data_valid_o = pool_en ? pool_valid : bypass_valid;
    assign data_ready   = 1'b1;
    assign done         = pool_en ? done_r : bypass_done_r;

endmodule
