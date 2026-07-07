// dma_axi_writer: 连续块DMA的AXI4写主端
// 从缓冲区读取数据流，以突发方式写入AXI4内存
// 处理突发分割（每突发最多16拍）
`timescale 1ns / 1ps

module dma_axi_writer #(
    parameter AXI_DATA_WIDTH = 256,
    parameter AXI_ADDR_WIDTH = 32,
    parameter MAX_BURST_LEN  = 16
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
    output wire                        write_txn_active,  // 在S_AW|S_WDATA|S_WAIT_B期间为高

    // === FIFO级别（延迟AW）===
    input  wire [5:0]                  fifo_level,

    // === 生产者完成（不会再有数据到达）===
    input  wire                        producer_done,

    // === 数据输入 ===
    input  wire [AXI_DATA_WIDTH-1:0]   data_in,
    input  wire                        data_valid,
    output wire                        data_ready,

    // === AXI4 写主端 ===
    output wire [AXI_ADDR_WIDTH-1:0]   m_axi_awaddr,
    output wire                        m_axi_awvalid,
    input  wire                        m_axi_awready,
    output wire [7:0]                  m_axi_awlen,
    output wire [2:0]                  m_axi_awsize,
    output wire [1:0]                  m_axi_awburst,

    output wire [AXI_DATA_WIDTH-1:0]   m_axi_wdata,
    output wire                        m_axi_wvalid,
    input  wire                        m_axi_wready,
    output wire                        m_axi_wlast,
    output wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,

    input  wire [1:0]                  m_axi_bresp,
    input  wire                        m_axi_bvalid,
    output wire                        m_axi_bready
);

    localparam BEAT_BYTES = AXI_DATA_WIDTH / 8;
    localparam STRB_W     = AXI_DATA_WIDTH / 8;
    localparam BEAT_BYTES_LOG2 = (AXI_DATA_WIDTH == 32)  ? 2 :
                                 (AXI_DATA_WIDTH == 64)  ? 3 :
                                 (AXI_DATA_WIDTH == 128) ? 4 :
                                 (AXI_DATA_WIDTH == 256) ? 5 : 5;

    localparam ERR_NONE      = 8'h00;
    localparam ERR_BRESP     = 8'h30;
    localparam ERR_ALIGN     = 8'h31;
    localparam ERR_UNDERFLOW = 8'h32;  // 生产者提前停止，数据不足

    // ============================================================
    // 状态机
    // ============================================================
    localparam S_IDLE      = 3'd0;
    localparam S_WAIT_DATA = 3'd6;  // 等待FIFO填满
    localparam S_AW        = 3'd1;
    localparam S_WDATA     = 3'd2;
    localparam S_WAIT_B    = 3'd3;
    localparam S_DONE      = 3'd4;
    localparam S_ERROR     = 3'd5;

    reg [2:0] state, next_state;

    // ============================================================
    // 突发计算，带AXI4 4KB边界分割（U9-a3）
    // burst_beats = min(ceil(bytes/BEAT_BYTES), MAX_BURST_LEN, beats_to_4KB)
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

    // 遗留封装，用于向后兼容
    function [7:0] calc_burst_beats;
        input [31:0] bytes;
        begin
            calc_burst_beats = calc_burst_beats_4kb(bytes, 32'h0);
        end
    endfunction

    function [STRB_W-1:0] calc_wstrb;
        input [31:0] valid_bytes;
        integer i;
        begin
            calc_wstrb = {STRB_W{1'b0}};
            for (i = 0; i < STRB_W; i = i + 1) begin
                if (valid_bytes > i)
                    calc_wstrb[i] = 1'b1;
            end
        end
    endfunction

    // ============================================================
    // 内部寄存器
    // ============================================================
    reg  [31:0] bytes_remaining;
    reg  [31:0] current_addr;
    reg  [7:0]  beats_in_burst;
    reg  [7:0]  burst_len;
    reg  [7:0]  beat_counter;
    reg         aw_done;
    reg         w_done;     // 此突发的所有W拍已发送
    reg         b_valid_r;  // 内部锁存的类BVALID状态

    // ============================================================
    // 当前突发后的剩余字节数（钳位以避免下溢）
    // ============================================================
    wire [31:0] burst_byte_count = {24'h0, beats_in_burst} * BEAT_BYTES;
    wire [31:0] remaining_after_burst = (bytes_remaining <= burst_byte_count)
                                        ? 32'h0
                                        : (bytes_remaining - burst_byte_count);
    wire [31:0] bytes_sent_in_burst = {24'h0, beat_counter} * BEAT_BYTES;
    wire [31:0] bytes_left_for_beat = (bytes_remaining <= bytes_sent_in_burst)
                                      ? 32'h0
                                      : (bytes_remaining - bytes_sent_in_burst);
    wire [31:0] valid_bytes_this_beat = (bytes_left_for_beat >= BEAT_BYTES)
                                        ? BEAT_BYTES
                                        : bytes_left_for_beat;
    wire start_misaligned = start && (byte_count != 32'h0) &&
                            (base_addr[BEAT_BYTES_LOG2-1:0] != {BEAT_BYTES_LOG2{1'b0}});

    // ============================================================
    // AXI4 AW通道
    // ============================================================
    wire aw_hs = m_axi_awvalid && m_axi_awready;

    assign m_axi_awaddr  = current_addr;
    assign m_axi_awlen   = burst_len;
    assign m_axi_awsize  = BEAT_BYTES_LOG2[2:0];
    assign m_axi_awburst = 2'b01;  // INCR（递增）
    assign m_axi_awvalid = (state == S_AW) && !aw_done;

    // ============================================================
    // AXI4 W通道
    // ============================================================
    reg [AXI_DATA_WIDTH-1:0] wdata_r;
    reg [STRB_W-1:0]         wstrb_r;
    reg                      wlast_r;
    reg                      wvalid_r;

    // Phase B2: 下一拍预取缓冲区 — 消除1周期气泡
    //   next_valid=1表示next_{data,strb,last}保存当前拍之后的下一拍。
    //   在w_hs时：如果next_valid，将next传输到wdata_r（wvalid保持1）。
    //   data_ready = !next_valid || w_hs（缓冲区空闲或即将空闲时接受新拍）。
    reg                      next_valid;
    reg [AXI_DATA_WIDTH-1:0] next_data;
    reg [STRB_W-1:0]         next_strb;
    reg                      next_last;

    wire w_hs = m_axi_wvalid && m_axi_wready;

    // data_ready: 当next缓冲区空闲，或w_hs将在本周期消耗当前拍并释放流水线时，
    // 接受上游数据。
    assign data_ready = (state == S_WDATA) && !w_done && (!next_valid || w_hs);

    // next_ready: 组合逻辑 — 当下一拍可用/即将可用时为真。
    // 由w_hs用于决定握手后是否保持WVALID为高。
    wire next_ready = next_valid || (data_valid && data_ready);

    // 当前拍之后下一拍的有效字节数（用于next wstrb/wlast）
    wire [31:0] bytes_sent_next = {24'h0, beat_counter + 8'h1} * BEAT_BYTES;
    wire [31:0] bytes_left_next = (bytes_remaining <= bytes_sent_next)
                                  ? 32'h0
                                  : (bytes_remaining - bytes_sent_next);
    wire [31:0] valid_bytes_next = (bytes_left_next >= BEAT_BYTES)
                                   ? BEAT_BYTES
                                   : bytes_left_next;

    assign m_axi_wdata  = wdata_r;
    assign m_axi_wvalid = wvalid_r;
    assign m_axi_wlast  = wlast_r;
    assign m_axi_wstrb  = wstrb_r;

    // ============================================================
    // AXI4 B通道
    // ============================================================
    assign m_axi_bready = 1'b1;  // 始终准备好接收响应

    // P0-1 FIX: 有效级别包含next_valid中预取的拍。
    // 若无此修正，当next_valid有遗留拍但仅fifo_level不满足阈值时，
    // S_WAIT_DATA会死锁。
    wire [6:0] eff_level = {1'b0, fifo_level} + {6'd0, next_valid};

    wire promote_now = !wvalid_r && next_valid;

    // ============================================================
    // 状态机
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            bytes_remaining <= 32'h0;
            current_addr    <= 32'h0;
            beats_in_burst  <= 8'h0;
            burst_len       <= 8'h0;
            beat_counter    <= 8'h0;
            aw_done         <= 1'b0;
            w_done          <= 1'b0;
            wdata_r         <= {AXI_DATA_WIDTH{1'b0}};
            wstrb_r         <= {STRB_W{1'b0}};
            wlast_r         <= 1'b0;
            wvalid_r        <= 1'b0;
            next_valid      <= 1'b0;
            next_data       <= {AXI_DATA_WIDTH{1'b0}};
            next_strb       <= {STRB_W{1'b0}};
            next_last       <= 1'b0;
        end else begin
            case (state)

                S_IDLE: begin
                    wvalid_r   <= 1'b0;
                    wlast_r    <= 1'b0;
                    next_valid <= 1'b0;
                    if (start) begin
                        if (byte_count == 32'h0) begin
                            state <= S_DONE;
                        end else if (start_misaligned) begin
                            state <= S_ERROR;
                        end else begin
                            bytes_remaining <= byte_count;
                            current_addr    <= base_addr;
                            aw_done         <= 1'b0;
                            w_done          <= 1'b0;
                            beat_counter    <= 8'h0;
                            beats_in_burst  <= calc_burst_beats_4kb(byte_count, base_addr);
                            burst_len       <= calc_burst_beats_4kb(byte_count, base_addr) - 8'h1;
                            state <= S_WAIT_DATA;
                        end
                    end
                end

                S_WAIT_DATA: begin
                    // P1-1: 优先完整突发，其次尾部，最后下溢错误。
                    if (eff_level >= {2'd0, beats_in_burst})
                        state <= S_AW;
                    else if (producer_done && (eff_level > 6'd0)) begin
                        beats_in_burst <= eff_level[7:0];
                        burst_len      <= eff_level[7:0] - 8'h1;
                        state <= S_AW;
                    end
                    else if (producer_done && (bytes_remaining > 32'h0))
                        state <= S_ERROR;
                end

                S_AW: begin
                    // next_valid保留：预取的拍属于下一突发
                    if (aw_hs) begin
                        aw_done <= 1'b1;
                        state <= S_WDATA;
                    end
                end

                S_WDATA: begin
                    // Phase B2: 下一拍预取流水线 — 1拍/周期。
                    // P0-1 FIX: next_last使用条件处理预取与提升之间的竞争。
                    // 当next_valid=1且w_hs=1时，下一拍将在本周期被提升到主寄存器，
                    // 因此新预取对应beat_counter+2，而非beat_counter+1。
                    // P0-1 FIX: 提升步骤使用当前突发的(beat_counter==burst_len)
                    // 而非遗留的next_last，因为next_last是为前一个突发计算的，
                    // 对新突发不正确。
                    if (!wvalid_r && next_valid) begin
                        wdata_r     <= next_data;
                        wstrb_r     <= next_strb;
                        wlast_r     <= (beat_counter == burst_len);
                        wvalid_r    <= 1'b1;
                        next_valid  <= 1'b0;
                    end

                    // 从FIFO加载：两阶段检查允许在1周期内加载main+next。
                    // P0-1 FIX: promote_now门控主加载，防止Step 1刚将next提升到
                    // main时（PRE-NBA中wvalid_r仍为0）发生覆盖。
                    // 预取条件也放宽到(wvalid_r || promote_now)，使新突发的
                    // 首周期预取不会被饿死。
                    if (data_valid) begin
                        if (!wvalid_r && !promote_now) begin
                            wdata_r  <= data_in;
                            wstrb_r  <= calc_wstrb(valid_bytes_this_beat);
                            wlast_r  <= (beat_counter == burst_len);
                            wvalid_r <= 1'b1;
                        end
                        // 再次检查：第一次弹出后，下一个条目可能可用。
                        if (data_valid) begin
                            if ((wvalid_r || promote_now) && (!next_valid || w_hs)) begin
                                next_data  <= data_in;
                                next_strb  <= calc_wstrb(valid_bytes_next);
                                next_last  <= !next_valid ? ((beat_counter + 8'h1) == burst_len) :
                                                            ((beat_counter + 8'h2) == burst_len);
                                next_valid <= 1'b1;
                            end
                        end
                    end

                    // W通道握手
                    if (w_hs) begin
                        if (wlast_r) begin
                            w_done      <= 1'b1;
                            wvalid_r    <= 1'b0;
                            current_addr    <= current_addr + ({24'h0, beats_in_burst} * BEAT_BYTES);
                            bytes_remaining <= remaining_after_burst;
                            state <= S_WAIT_B;
                        end else if (next_valid || (data_valid && data_ready)) begin
                            if (next_valid) begin
                                wdata_r <= next_data;
                                wstrb_r <= next_strb;
                                wlast_r <= next_last;
                            end else begin
                                wdata_r <= data_in;
                                wstrb_r <= calc_wstrb(valid_bytes_next);
                                wlast_r <= ((beat_counter + 8'h1) == burst_len);
                            end
                            next_valid  <= 1'b0;
                            beat_counter <= beat_counter + 8'h1;
                        end else begin
                            wvalid_r <= 1'b0;
                            beat_counter <= beat_counter + 8'h1;
                        end
                    end
                    // P0-1 FIX: 移除了冗余的else-if (!wvalid_r && next_valid)。
                    // Step 1（S_WDATA顶部）已无条件将next提升到main，
                    // 使用正确的(beat_counter==burst_len)计算wlast。
                    // 此处保留重复逻辑会用过时的next_last覆盖wlast_r。
                end

                S_WAIT_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        // 检查BRESP错误
                        if (m_axi_bresp != 2'b00) begin
                            state <= S_ERROR;
                        end else if ((bytes_remaining == 32'h0) && !next_valid) begin
                            state <= S_DONE;
                        end else if (bytes_remaining == 32'h0) begin
                            // P0-1 FIX: next_valid有预取的拍。仅当wlast=1（真正的尾部拍）
                            // 时发送。若wlast=0，该拍属于不存在的下一突发，
                            // 必须丢弃以避免S_WDATA死锁。
                            if (!next_last) begin
                                next_valid <= 1'b0;
                                state <= S_DONE;
                            end else begin
                                aw_done  <= 1'b0;
                                w_done   <= 1'b0;
                                state <= S_WDATA;
                            end
                        end else begin
                            // 下一突发：bytes_remaining已保存剩余计数
                            beat_counter    <= 8'h0;
                            beats_in_burst  <= calc_burst_beats_4kb(bytes_remaining, current_addr);
                            burst_len       <= calc_burst_beats_4kb(bytes_remaining, current_addr) - 8'h1;
                            aw_done         <= 1'b0;
                            w_done          <= 1'b0;
                            state <= S_WAIT_DATA;
                        end
                    end
                end

                S_DONE: begin
                    if (!start)
                        state <= S_IDLE;
                end

                S_ERROR: begin
                    wvalid_r <= 1'b0;
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
    // P1-1: 下溢检测，组合逻辑
    wire underflow_condition = (state == S_WAIT_DATA) && producer_done &&
                               (eff_level == 6'd0) && (bytes_remaining > 32'h0);

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
        end else if (underflow_condition) begin
            error_r      <= 1'b1;
            error_code_r <= ERR_UNDERFLOW;
        end else if (state == S_WAIT_B && m_axi_bvalid && m_axi_bready && m_axi_bresp != 2'b00) begin
            error_r      <= 1'b1;
            error_code_r <= ERR_BRESP;
        end
    end

    // ============================================================
    // Done脉冲（仅在S_DONE，绝不在S_ERROR）
    // ============================================================
    reg done_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            done_r <= 1'b0;
        else if (state == S_DONE && !done_r)
            done_r <= 1'b1;
        else if (state == S_IDLE)
            done_r <= 1'b0;
    end

    assign busy       = (state != S_IDLE);
    assign write_txn_active = (state == S_AW) || (state == S_WDATA) || (state == S_WAIT_B);
    assign done       = done_r;
    assign error      = error_r;
    assign error_code = error_code_r;

endmodule
