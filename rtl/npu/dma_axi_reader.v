// dma_axi_reader：AXI4 读主设备，用于连续块 DMA
// Splits large transfers into bursts (max 16 beats per burst)
// Outputs data stream to buffer with backpressure (data_ready)
`timescale 1ns / 1ps

module dma_axi_reader #(
    parameter AXI_DATA_WIDTH = 256,
    parameter AXI_ADDR_WIDTH = 32,
    parameter MAX_BURST_LEN  = 16   // max beats per AXI burst
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

    // === Data output (to buffer) ===
    output wire [AXI_DATA_WIDTH-1:0]   data_out,
    output wire                        data_valid,
    input  wire                        data_ready,

    // === AXI4 读主设备 ===
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
    // Derived parameters
    // ============================================================
    localparam BEAT_BYTES = AXI_DATA_WIDTH / 8;  // bytes per beat
    localparam BEAT_BYTES_LOG2 = (AXI_DATA_WIDTH == 32)  ? 2 :
                                 (AXI_DATA_WIDTH == 64)  ? 3 :
                                 (AXI_DATA_WIDTH == 128) ? 4 :
                                 (AXI_DATA_WIDTH == 256) ? 5 : 5;

    // ============================================================
    // Error codes
    // ============================================================
    localparam ERR_NONE    = 8'h00;
    localparam ERR_RRESP   = 8'h20;  // AXI read response error
    localparam ERR_ALIGN   = 8'h21;  // address misalignment
    localparam ERR_INTERNAL= 8'h22;

    // ============================================================
    // 状态机
    // ============================================================
    localparam S_IDLE    = 3'd0;
    localparam S_AR      = 3'd1;  // issuing read address
    localparam S_DATA    = 3'd2;  // receiving data beats
    localparam S_DONE    = 3'd3;
    localparam S_ERROR   = 3'd4;

    reg [2:0] state;

    // ============================================================
    // 内部寄存器
    // ============================================================
    reg  [31:0] bytes_remaining;
    reg  [31:0] current_addr;
    reg  [7:0]  beats_in_burst;   // total beats in current burst
    reg  [7:0]  beat_counter;     // beats received in current burst
    reg  [7:0]  burst_len;        // ARLEN for current burst (= beats - 1)
    reg         ar_done;          // AR handshake complete

    // Output data stage (registered, handles backpressure)
    reg         data_valid_r;
    reg  [AXI_DATA_WIDTH-1:0] data_out_r;

    // ============================================================
    // Next burst calculation: compute from explicit byte count input
    // Rounds up to whole beats (partial last beat is padded)
    // ============================================================
    function [7:0] calc_burst_beats;
        input [31:0] bytes;
        reg [31:0] raw_beats;
        begin
            if (bytes >= (MAX_BURST_LEN * BEAT_BYTES))
                calc_burst_beats = MAX_BURST_LEN[7:0];
            else begin
                // Round partial byte counts up to whole AXI beats.
                raw_beats = (bytes + BEAT_BYTES - 1) / BEAT_BYTES;
                calc_burst_beats = raw_beats[7:0];
            end
        end
    endfunction

    // Remaining bytes after current burst (clamped to 0 to avoid underflow)
    wire [31:0] burst_byte_count = {24'h0, beats_in_burst} * BEAT_BYTES;
    wire [31:0] remaining_after_burst = (bytes_remaining <= burst_byte_count)
                                        ? 32'h0
                                        : (bytes_remaining - burst_byte_count);
    wire start_misaligned = start && (byte_count != 32'h0) &&
                            (base_addr[BEAT_BYTES_LOG2-1:0] != {BEAT_BYTES_LOG2{1'b0}});

    // ============================================================
    // AXI4 AR 通道
    // ============================================================
    wire ar_hs = m_axi_arvalid && m_axi_arready;

    assign m_axi_araddr  = current_addr;
    assign m_axi_arlen   = burst_len;
    assign m_axi_arsize  = BEAT_BYTES_LOG2[2:0];
    assign m_axi_arburst = 2'b01;  // INCR (incrementing address)
    assign m_axi_arvalid = (state == S_AR) && !ar_done;

    // ============================================================
    // AXI4 R 通道 (read data)
    // ============================================================
    // Accept AXI read data when buffer is ready to receive
    assign m_axi_rready = data_ready;
    wire r_hs = m_axi_rvalid && m_axi_rready;
    wire expected_rlast = (beat_counter == burst_len);

    // ============================================================
    // 状态机: sequential
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
                            // Compute first burst from byte_count (input, stable)
                            beats_in_burst  <= calc_burst_beats(byte_count);
                            burst_len       <= calc_burst_beats(byte_count) - 8'h1;
                            state <= S_AR;
                        end
                    end
                end

                S_AR: begin
                    // Clear any stale data_valid from previous burst boundary
                    if (data_valid_r && data_ready)
                        data_valid_r <= 1'b0;
                    if (ar_hs) begin
                        ar_done <= 1'b1;
                        state <= S_DATA;
                    end
                end

                S_DATA: begin
                    if (r_hs) begin
                        // Check for RRESP error before accepting data
                        if (m_axi_rresp != 2'b00) begin
                            state <= S_ERROR;
                        end else if (m_axi_rlast != expected_rlast) begin
                            state <= S_ERROR;
                        end else begin
                            // Receive a data beat
                            data_valid_r <= 1'b1;
                            data_out_r   <= m_axi_rdata;
                            beat_counter <= beat_counter + 8'h1;

                            // Check if last beat in burst
                            if (expected_rlast) begin
                                // Update for next burst
                                current_addr    <= current_addr + ({24'h0, beats_in_burst} * BEAT_BYTES);
                                bytes_remaining <= remaining_after_burst;

                                if (remaining_after_burst == 32'h0) begin
                                    state <= S_DONE;
                                end else begin
                                    beats_in_burst <= calc_burst_beats(remaining_after_burst);
                                    burst_len      <= calc_burst_beats(remaining_after_burst) - 8'h1;
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
                    // Hold error state, drain any pending data
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
    // Error detection (latched on entering S_ERROR)
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
    // Outputs
    // ============================================================
    // Registered done strobe (only in S_DONE, never in S_ERROR)
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
    assign busy       = (state != S_IDLE);
    assign done       = done_r;
    assign error      = error_r;
    assign error_code = error_code_r;

endmodule
