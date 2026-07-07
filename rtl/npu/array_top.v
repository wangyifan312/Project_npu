// array_top: 由 4x4 MAC tile 构成的脉动阵列，iverilog 兼容的扁平端口
// 总计: TILE_ROWS*4 MAC 行 × TILE_COLS*4 MAC 列
`timescale 1ns / 1ps

module array_top #(
    parameter TILE_ROWS = 2,   // 测试用默认小值
    parameter TILE_COLS = 2
) (
    input  wire        clk,
    input  wire        rst_n,

    // 激活: (TILE_ROWS*4) × 8-bit，从左→右流动
    // 扁平向量打包：act_row_r = act_in[r*8 +: 8]
    input  wire [(TILE_ROWS*4*8)-1:0] act_in_flat,

    // 来自顶部的部分和: (TILE_COLS*4) × 32-bit
    input  wire [(TILE_COLS*4*32)-1:0] sum_in_flat,

    // 权重: TILE_ROWS*TILE_COLS*4*4 × 8-bit（扁平）
    input  wire [(TILE_ROWS*TILE_COLS*16*8)-1:0] weight_flat,
    input  wire        weight_ld,

    // 输出部分和: (TILE_COLS*4) × 32-bit
    output wire [(TILE_COLS*4*32)-1:0] sum_out_flat,

    // 每 tile 时钟门控（扁平使能向量）
    input  wire [(TILE_ROWS*TILE_COLS)-1:0] tile_clk_en_flat
);

    localparam PE_ROWS = TILE_ROWS * 4;
    localparam PE_COLS = TILE_COLS * 4;
    localparam N_TILES = TILE_ROWS * TILE_COLS;

    // 辅助函数：从扁平索引获取 tile 行、列
    // 扁平索引 = tr * TILE_COLS + tc

    // 内部连线：tile 间水平激活（扁平）
    // act_h[(tr*TILE_COLS + tc)*4 + k] = tile(tr,tc) PE 行 k 的激活值，进入本 tile
    // tc 的 +1 偏移表示"本 tile 之后" = 下一 tile 的输入
    wire [(TILE_ROWS * (TILE_COLS+1) * 4 * 8)-1:0] act_tile_flat;
    // tile 间垂直部分和
    wire [((TILE_ROWS+1) * TILE_COLS * 4 * 32)-1:0] sum_tile_flat;

    // 每 tile 门控时钟
    // Phase U6-a: 低相位锁存器实现干净时钟门控。
    // RTL 仿真：模拟标准 ICG 行为，其中使能
    // 在 clk 高电平期间保持稳定。ASIC：替换为库 ICG 单元。
    // FPGA：替换为 BUFGCE 或时钟使能原语。
    wire [N_TILES-1:0] gated_clk;
    reg  [N_TILES-1:0] tile_clk_en_latched;

    always @(*) begin
        if (!clk) begin
            tile_clk_en_latched = tile_clk_en_flat;
        end
    end

    // ============================================================
    // 生成 tile
    // ============================================================
    genvar ti;
    generate
        for (ti = 0; ti < N_TILES; ti = ti + 1) begin : tile_gen
            localparam integer tr = ti / TILE_COLS;
            localparam integer tc = ti % TILE_COLS;
            localparam integer act_in_base  = (tr * (TILE_COLS+1) + tc) * 4 * 8;
            localparam integer act_out_base = (tr * (TILE_COLS+1) + tc + 1) * 4 * 8;
            localparam integer sum_in_base  = (tr * TILE_COLS + tc) * 4 * 32;
            localparam integer sum_out_base = ((tr + 1) * TILE_COLS + tc) * 4 * 32;
            localparam integer wt_base      = ti * 16 * 8;

            // 带锁存使能的门控时钟（ICG 风格）
            assign gated_clk[ti] = clk & tile_clk_en_latched[ti];

            // 连接：行中第一个 tile 接收外部激活
            if (tc == 0) begin : act_from_ext
                assign act_tile_flat[act_in_base +: 32] = act_in_flat[tr*4*8 +: 32];
            end

            // 连接：第一行 tile 接收外部部分和
            if (tr == 0) begin : sum_from_ext
                assign sum_tile_flat[sum_in_base +: 128] = sum_in_flat[tc*4*32 +: 128];
            end

            mac_tile_4x4 u_tile (
                .clk        (gated_clk[ti]),
                .rst_n      (rst_n),
                .act_in_0   (act_tile_flat[act_in_base +  0 +: 8]),
                .act_in_1   (act_tile_flat[act_in_base +  8 +: 8]),
                .act_in_2   (act_tile_flat[act_in_base + 16 +: 8]),
                .act_in_3   (act_tile_flat[act_in_base + 24 +: 8]),
                .sum_in_0   (sum_tile_flat[sum_in_base +   0 +: 32]),
                .sum_in_1   (sum_tile_flat[sum_in_base +  32 +: 32]),
                .sum_in_2   (sum_tile_flat[sum_in_base +  64 +: 32]),
                .sum_in_3   (sum_tile_flat[sum_in_base +  96 +: 32]),
                .weight_00  (weight_flat[wt_base +   0 +: 8]),
                .weight_01  (weight_flat[wt_base +   8 +: 8]),
                .weight_02  (weight_flat[wt_base +  16 +: 8]),
                .weight_03  (weight_flat[wt_base +  24 +: 8]),
                .weight_10  (weight_flat[wt_base +  32 +: 8]),
                .weight_11  (weight_flat[wt_base +  40 +: 8]),
                .weight_12  (weight_flat[wt_base +  48 +: 8]),
                .weight_13  (weight_flat[wt_base +  56 +: 8]),
                .weight_20  (weight_flat[wt_base +  64 +: 8]),
                .weight_21  (weight_flat[wt_base +  72 +: 8]),
                .weight_22  (weight_flat[wt_base +  80 +: 8]),
                .weight_23  (weight_flat[wt_base +  88 +: 8]),
                .weight_30  (weight_flat[wt_base +  96 +: 8]),
                .weight_31  (weight_flat[wt_base + 104 +: 8]),
                .weight_32  (weight_flat[wt_base + 112 +: 8]),
                .weight_33  (weight_flat[wt_base + 120 +: 8]),
                .weight_ld  (weight_ld),
                .act_out_0  (act_tile_flat[act_out_base +  0 +: 8]),
                .act_out_1  (act_tile_flat[act_out_base +  8 +: 8]),
                .act_out_2  (act_tile_flat[act_out_base + 16 +: 8]),
                .act_out_3  (act_tile_flat[act_out_base + 24 +: 8]),
                .sum_out_0  (sum_tile_flat[sum_out_base +   0 +: 32]),
                .sum_out_1  (sum_tile_flat[sum_out_base +  32 +: 32]),
                .sum_out_2  (sum_tile_flat[sum_out_base +  64 +: 32]),
                .sum_out_3  (sum_tile_flat[sum_out_base +  96 +: 32])
            );

            // 最后一行 tile 输出部分和
            if (tr == TILE_ROWS - 1) begin : sum_to_ext
                assign sum_out_flat[tc*4*32 +: 128] = sum_tile_flat[sum_out_base +: 128];
            end
        end
    endgenerate

endmodule
