// fc_frontend: legacy/debug 全连接流格式化器。
// P0-3 正式 FC 执行直接在 npu_top 的
// cluster_scheduler -> compute_core -> output_arbiter 路径上实现。
// 将激活值以 1D 向量流形式传递，用于向量-矩阵乘法。
// 支持分块：若输出神经元 > 阵列列数，则迭代列块。
// 输出列 j 的权重送至阵列列 j；激活值在行方向流动。
`timescale 1ns / 1ps

module fc_frontend #(
    parameter MAX_COLS = 64    // FC 权重可用的最大阵列列数
) (
    input  wire        clk,
    input  wire        rst_n,

    // 输入：来自 act_buffer 的流式激活数据
    input  wire [7:0]  act_data,
    input  wire        act_valid,
    output wire        act_ready,

    // 输出：激活流（1D 向量，相同数据，由状态门控）
    output wire [7:0]  act_out,
    output wire        act_valid_o,

    // 控制
    input  wire [15:0] input_size,   // 输入激活总数 (N)
    input  wire [15:0] output_size,  // 输出神经元总数 (M)
    input  wire [15:0] block_start,  // 本块的起始输出列
    input  wire        start,
    output wire        done,
    output wire        block_done    // 当前块完成时脉冲，需要下一块
);

    // ============================================================
    // 状态机
    // ============================================================
    localparam S_IDLE     = 2'd0;
    localparam S_STREAM   = 2'd1;  // 为当前块流式传输激活值
    localparam S_BLOCK_DONE = 2'd2;
    localparam S_DONE     = 2'd3;

    reg [1:0]  state;
    reg [15:0] count;           // 当前块已送入的激活数
    reg [15:0] block_col;       // 当前块的起始输出列
    reg [15:0] total_blocks;    // ceil(output_size / MAX_COLS)

    // ============================================================
    // 时序逻辑
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
    // 输出
    // ============================================================
    assign act_ready  = (state == S_STREAM);
    assign act_out    = act_data;
    assign act_valid_o = (state == S_STREAM) && act_valid;
    assign done       = (state == S_DONE);
    assign block_done = (state == S_BLOCK_DONE);

endmodule
