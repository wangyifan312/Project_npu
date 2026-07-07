// dma_axi_reader: 连续块DMA的AXI4读主端
// 将大传输拆分为多个突发（每突发最多16拍）
// 输出数据流到缓冲区，支持背压（data_ready）
`timescale 1ns / 1ps

module dma_axi_reader #(
    parameter AXI_DATA_WIDTH = 256,
    parameter AXI_ADDR_WIDTH = 32,
    parameter MAX_BURST_LEN  = 16   // 每AXI突发的最大拍数
) (
    input  wire        clk,
    input  wire        rst_n,

    // === 控制接口 ===
    input  wire                        start,
    input  wire [AXI_ADDR_WIDTH-1:0]   base_addr,
    input  wire [31:0]                 byte_count,
    output wire                        done,
    output wire                        error,
    output wire [7:0]                  error_code,
    output wire                        busy,

    // === 数据输出（到缓冲区）===
    output wire [AXI_DATA_WIDTH-1:0]   data_out,
    output wire                        data_valid,
    input  wire                        data_ready,
    output wire [(AXI_DATA_WIDTH/8)-1:0] data_strb,

    // === AXI4 读主端 ===
    output wire [AXI_ADDR_WIDTH-1:0]   m_axi_araddr,
    output wire                        m_axi_arvalid,
    input  wire                        m_axi_arready,
    output wire [7:0]                  m_axi_arlen,
    output wire [2:0]                  m_axi_arsize,
    output wire [1:0]                  m_axi_arburst,

    input  wire [AXI_DATA_WIDTH-1:0]   m_axi_rdata,
    input  wire                        m_axi_rvalid,
    output wire                        m_axi_rready,
    input  wire                        m_axi_rlast,
    input  wire [1:0]                  m_axi_rresp
);

    // ============================================================
    // 派生参数
    // ============================================================
    localparam BEAT_BYTES = AXI_DATA_WIDTH / 8;  // 每拍字节数
    localparam STRB_WIDTH = AXI_DATA_WIDTH / 8;  // 字节使能位宽
    localparam BEAT_BYTES_LOG2 = (AXI_DATA_WIDTH == 32)  ? 2 :
                                 (AXI_DATA_WIDTH == 64)  ? 3 :
                                 (AXI_DATA_WIDTH == 128) ? 4 :
                                 (AXI_DATA_WIDTH == 256) ? 5 : 5;

    // ============================================================
    // 错误码
    // ============================================================
    localparam ERR_NONE    = 8'h00;
    localparam ERR_RRESP   = 8'h20;  // AXI读响应错误
    localparam ERR_ALIGN   = 8'h21;  // 地址未对齐
    localparam ERR_INTERNAL= 8'h22;

    // ============================================================
    // 状态机
    // ============================================================
    localparam S_IDLE    = 3'd0;
    localparam S_AR      = 3'd1;  // 发送读地址
    localparam S_DATA    = 3'd2;  // 接收数据拍
    localparam S_DONE    = 3'd3;
    localparam S_ERROR   = 3'd4;

    reg [2:0] state;

    // ============================================================
    // 内部寄存器
    // ============================================================
    reg  [31:0] bytes_remaining;
    reg  [31:0] current_addr;
    reg  [7:0]  beats_in_burst;   // 当前突发中的总拍数
    reg  [7:0]  beat_counter;     // 当前突发中已接收的拍数
    reg  [7:0]  burst_len;        // 当前突发的ARLEN（= 拍数 - 1）
    reg         ar_done;          // AR握手完成

    // 输出数据级（寄存器输出，处理背压）
    reg         data_valid_r;
    reg  [AXI_DATA_WIDTH-1:0] data_out_r;
    reg  [STRB_WIDTH-1:0]     data_strb_r;

    // ============================================================
    // 字节使能生成 — 传输级，而非突发级
    // bytes_before_beat = 在此拍之前整个传输中剩余的字节数
    // ============================================================
    wire [31:0] bytes_before_beat;
    assign bytes_before_beat = bytes_remaining - ({24'h0, beat_counter} * BEAT_BYTES);

    // 生成strb：完整拍→全1；部分最后拍→仅低N字节
    function [STRB_WIDTH-1:0] gen_strb;
        input [31:0] valid_bytes;
        integer i;
        begin
            gen_strb = {STRB_WIDTH{1'b0}};
            for (i = 0; i < STRB_WIDTH; i = i + 1) begin
                if (i < valid_bytes)
                    gen_strb[i] = 1'b1;
            end
        end
    endfunction

    // ============================================================
    // 下一突发计算，带AXI4 4KB边界分割（U9-a3）
    // burst_beats = min(ceil(bytes/BEAT_BYTES), MAX_BURST_LEN, beats_to_4KB)
    // 向上取整到完整拍（部分最后拍被填充）。
    // ============================================================
    function [7:0] calc_burst_beats_4kb;
        input [31:0] bytes;
        input [AXI_ADDR_WIDTH-1:0] addr;
        reg [31:0] beats_by_bytes;
        reg [31:0] bytes_to_4kb;
        reg [31:0] beats_to_4kb;
        reg [31:0] selected;
        begin
            if (bytes == 32'd0) begin
                calc_burst_beats_4kb = 8'd0;
            end else begin
                // 向上取整(bytes / BEAT_BYTES)
                beats_by_bytes = (bytes + BEAT_BYTES - 1) >> BEAT_BYTES_LOG2;

                // AXI4: 一个突发不能跨越4KB（4096字节）边界
                bytes_to_4kb = 32'd4096 - {20'd0, addr[11:0]};
                beats_to_4kb = bytes_to_4kb >> BEAT_BYTES_LOG2;

                // 安全保护：32B对齐地址下此值>=1；防止为0
                if (beats_to_4kb == 32'd0)
                    beats_to_4kb = 32'd1;

                selected = beats_by_bytes;

                if (selected > MAX_BURST_LEN)
                    selected = MAX_BURST_LEN[31:0];

                if (selected > beats_to_4kb)
                    selected = beats_to_4kb;

                calc_burst_beats_4kb = selected[7:0];
            end
        end
    endfunction

    // 遗留封装，保留用于内部可读性（addr隐含时）。所有新代码直接使用calc_burst_beats_4kb。
    function [7:0] calc_burst_beats;
        input [31:0] bytes;
        begin
            calc_burst_beats = calc_burst_beats_4kb(bytes, 32'h0);
        end
    endfunction

    // 当前突发后的剩余字节数（钳位到0以避免下溢）
    wire [31:0] burst_byte_count = {24'h0, beats_in_burst} * BEAT_BYTES;
    wire [31:0] remaining_after_burst = (bytes_remaining <= burst_byte_count)
                                        ? 32'h0
                                        : (bytes_remaining - burst_byte_count);
    wire start_misaligned = start && (byte_count != 32'h0) &&
                            (base_addr[BEAT_BYTES_LOG2-1:0] != {BEAT_BYTES_LOG2{1'b0}});

    // ============================================================
    // AXI4 AR通道
    // ============================================================
    wire ar_hs = m_axi_arvalid && m_axi_arready;

    assign m_axi_araddr  = current_addr;
    assign m_axi_arlen   = burst_len;
    assign m_axi_arsize  = BEAT_BYTES_LOG2[2:0];
    assign m_axi_arburst = 2'b01;  // INCR（递增地址）
    assign m_axi_arvalid = (state == S_AR) && !ar_done;

    // ============================================================
    // AXI4 R通道（读数据）
    // ============================================================
    // 当缓冲区准备好接收时，接受AXI读数据
    assign m_axi_rready = data_ready;
    wire r_hs = m_axi_rvalid && m_axi_rready;
    wire expected_rlast = (beat_counter == burst_len);

    // ============================================================
    // 状态机：时序逻辑
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            bytes_remaining <= 32'h0;
            current_addr    <= 32'h0;
            beats_in_burst  <= 8'h0;
            beat_counter    <= 8'h0;
            burst_len       <= 8'h0;
            ar_done         <= 1'b0;
            data_valid_r    <= 1'b0;
            data_out_r      <= 0;
            data_strb_r     <= 0;
        end else begin
            case (state)

                S_IDLE: begin
                    data_valid_r <= 1'b0;
                    if (start) begin
                        if (byte_count == 32'h0) begin
                            state <= S_DONE;
                        end else if (start_misaligned) begin
                            state <= S_ERROR;
                        end else begin
                            bytes_remaining <= byte_count;
                            current_addr    <= base_addr;
                            ar_done         <= 1'b0;
                            beat_counter    <= 8'h0;
                            // 计算第一个突发，带4KB边界分割
                            beats_in_burst  <= calc_burst_beats_4kb(byte_count, base_addr);
                            burst_len       <= calc_burst_beats_4kb(byte_count, base_addr) - 8'h1;
                            state <= S_AR;
                        end
                    end
                end

                S_AR: begin
                    // 清除来自前一个突发边界的残留data_valid
                    if (data_valid_r && data_ready)
                        data_valid_r <= 1'b0;
                    if (ar_hs) begin
                        ar_done <= 1'b1;
                        state <= S_DATA;
                    end
                end

                S_DATA: begin
                    if (r_hs) begin
                        // 在接受数据前检查RRESP错误
                        if (m_axi_rresp != 2'b00) begin
                            state <= S_ERROR;
                        end else if (m_axi_rlast != expected_rlast) begin
                            state <= S_ERROR;
                        end else begin
                            // 接收一拍数据
                            data_valid_r <= 1'b1;
                            data_out_r   <= m_axi_rdata;
                            data_strb_r  <= gen_strb(bytes_before_beat);
                            beat_counter <= beat_counter + 8'h1;

                            // 检查是否为突发中的最后一拍
                            if (expected_rlast) begin
                                // 为下一突发更新
                                current_addr    <= current_addr + ({24'h0, beats_in_burst} * BEAT_BYTES);
                                bytes_remaining <= remaining_after_burst;

                                if (remaining_after_burst == 32'h0) begin
                                    state <= S_DONE;
                                end else begin
                                    beats_in_burst <= calc_burst_beats_4kb(remaining_after_burst, current_addr + ({24'h0, beats_in_burst} * BEAT_BYTES));
                                    burst_len      <= calc_burst_beats_4kb(remaining_after_burst, current_addr + ({24'h0, beats_in_burst} * BEAT_BYTES)) - 8'h1;
                                    beat_counter   <= 8'h0;
                                    ar_done        <= 1'b0;
                                    state <= S_AR;
                                end
                            end
                        end
                    end
                    else if (data_valid_r && data_ready) begin
                        data_valid_r <= 1'b0;
                    end
                end

                S_DONE: begin
                    if (data_valid_r && data_ready) begin
                        data_valid_r <= 1'b0;
                    end
                    if (!data_valid_r && !start)
                        state <= S_IDLE;
                end

                S_ERROR: begin
                    // 保持错误状态，排空任何待处理数据
                    if (data_valid_r && data_ready)
                        data_valid_r <= 1'b0;
                    if (!start)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ============================================================
    // 错误检测（进入S_ERROR时锁存）
    // ============================================================
    reg         error_r;
    reg  [7:0]  error_code_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            error_r      <= 1'b0;
            error_code_r <= 8'h00;
        end else if (state == S_IDLE && start_misaligned) begin
            error_r      <= 1'b1;
            error_code_r <= ERR_ALIGN;
        end else if (state == S_IDLE) begin
            error_r      <= 1'b0;
            error_code_r <= 8'h00;
        end else if (state == S_DATA && r_hs && m_axi_rresp != 2'b00) begin
            error_r      <= 1'b1;
            error_code_r <= ERR_RRESP;
        end else if (state == S_DATA && r_hs && m_axi_rlast != expected_rlast) begin
            error_r      <= 1'b1;
            error_code_r <= ERR_INTERNAL;
        end
    end

    // ============================================================
    // 输出
    // ============================================================
    // 寄存的done脉冲（仅在S_DONE，绝不在S_ERROR）
    reg done_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            done_r <= 1'b0;
        else if (state == S_DONE && !data_valid_r && !done_r)
            done_r <= 1'b1;
        else if (state == S_IDLE)
            done_r <= 1'b0;
    end

    assign data_out   = data_out_r;
    assign data_valid = data_valid_r;
    assign data_strb  = data_strb_r;
    assign busy       = (state != S_IDLE);
    assign done       = done_r;
    assign error      = error_r;
    assign error_code = error_code_r;

endmodule
