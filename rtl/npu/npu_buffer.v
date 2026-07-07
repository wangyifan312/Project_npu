// npu_buffer: 通用双缓冲区，带 bank 状态机
// 两个 bank (A/B) 通过乒乓方式支持加载/计算重叠。
// HB1-B 正式路径使用 256-bit beat 条目和同步读取。
`timescale 1ns / 1ps

module npu_buffer #(
    parameter DATA_WIDTH  = 256,
    parameter ENTRIES     = 256,   // 每个 bank 的条目数
    parameter ADDR_WIDTH  = 8      // log2(ENTRIES)
) (
    input  wire        clk,
    input  wire        rst_n,

    // === DMA 写端口 ===
    input  wire [ADDR_WIDTH-1:0]   wr_addr,
    input  wire [DATA_WIDTH-1:0]   wr_data,
    input  wire                    wr_en,
    input  wire                    wr_bank_sel,  // 0=bank A, 1=bank B

    // === 计算读端口（同步 beat 读取）===
    input  wire [ADDR_WIDTH-1:0]   rd_addr,
    output wire [DATA_WIDTH-1:0]   rd_data,
    input  wire                    rd_bank_sel,  // 0=bank A, 1=bank B

    // === Bank 控制 ===
    input  wire                    load_start,    // 脉冲：开始加载选定 bank
    input  wire                    load_done,     // 脉冲：加载完成
    input  wire                    comp_start,    // 脉冲：开始从选定 bank 计算
    input  wire                    comp_done,     // 脉冲：计算完成
    input  wire                    load_bank_sel, // 要加载哪个 bank
    input  wire                    comp_bank_sel, // 从哪个 bank 计算
    input  wire                    flush,         // 脉冲：将两个 bank 重置为 EMPTY（错误恢复）

    // === Bank 状态 ===
    output wire                    load_ready,    // 有 bank 准备好接收加载
    output wire                    comp_ready,    // 有 bank 数据就绪可供计算
    output wire                    comp_active,   // 计算正在进行中
    output wire [1:0]              bank_a_state,  // 用于调试/状态
    output wire [1:0]              bank_b_state
);

    // ============================================================
    // Bank 状态
    // ============================================================
    localparam B_EMPTY   = 2'd0;
    localparam B_LOADING = 2'd1;
    localparam B_READY   = 2'd2;
    localparam B_USING   = 2'd3;

    // ============================================================
    // 存储数组（两个 bank）
    // ============================================================
    reg [DATA_WIDTH-1:0] bank_a [0:ENTRIES-1];
    reg [DATA_WIDTH-1:0] bank_b [0:ENTRIES-1];

    // ============================================================
    // Bank 状态寄存器
    // ============================================================
    reg [1:0] state_a, state_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_a <= B_EMPTY;
            state_b <= B_EMPTY;
        end else if (flush) begin
            // 错误恢复：强制将两个 bank 置为 EMPTY
            state_a <= B_EMPTY;
            state_b <= B_EMPTY;
        end else begin
            // Bank A 状态转换
            case (state_a)
                B_EMPTY: begin
                    if (load_start && load_bank_sel == 1'b0)
                        state_a <= B_LOADING;
                end
                B_LOADING: begin
                    if (load_done && load_bank_sel == 1'b0)
                        state_a <= B_READY;
                end
                B_READY: begin
                    if (comp_start && comp_bank_sel == 1'b0)
                        state_a <= B_USING;
                end
                B_USING: begin
                    if (comp_done && comp_bank_sel == 1'b0)
                        state_a <= B_EMPTY;
                end
            endcase

            // Bank B 状态转换
            case (state_b)
                B_EMPTY: begin
                    if (load_start && load_bank_sel == 1'b1)
                        state_b <= B_LOADING;
                end
                B_LOADING: begin
                    if (load_done && load_bank_sel == 1'b1)
                        state_b <= B_READY;
                end
                B_READY: begin
                    if (comp_start && comp_bank_sel == 1'b1)
                        state_b <= B_USING;
                end
                B_USING: begin
                    if (comp_done && comp_bank_sel == 1'b1)
                        state_b <= B_EMPTY;
                end
            endcase
        end
    end

    // ============================================================
    // DMA 写
    // ============================================================
    always @(posedge clk) begin
        if (wr_en) begin
            if (wr_bank_sel == 1'b0)
                bank_a[wr_addr] <= wr_data;
            else
                bank_b[wr_addr] <= wr_data;
        end
    end

    // ============================================================
    // 计算读（同步）
    // ============================================================
    reg [DATA_WIDTH-1:0] rd_data_r;

    always @(posedge clk) begin
        if (rd_bank_sel == 1'b0)
            rd_data_r <= bank_a[rd_addr];
        else
            rd_data_r <= bank_b[rd_addr];
    end

    assign rd_data = rd_data_r;

    // ============================================================
    // 状态输出
    // ============================================================
    // load_ready: 至少有一个 bank 为空（可接受加载）
    assign load_ready = (state_a == B_EMPTY) || (state_b == B_EMPTY);

    // comp_ready: 至少有一个 bank 就绪（已加载数据）
    assign comp_ready = (state_a == B_READY) || (state_b == B_READY);

    // comp_active: 至少有一个 bank 正在进行计算
    assign comp_active = (state_a == B_USING) || (state_b == B_USING);

    assign bank_a_state = state_a;
    assign bank_b_state = state_b;

endmodule
