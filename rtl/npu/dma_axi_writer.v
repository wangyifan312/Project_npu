// dma_axi_writer: AXI4 write master for contiguous block DMA
// Reads data stream from buffer, writes to AXI4 memory in bursts
// Handles burst splitting (max 16 beats per burst)
`timescale 1ns / 1ps

module dma_axi_writer #(
    parameter AXI_DATA_WIDTH = 256,
    parameter AXI_ADDR_WIDTH = 32,
    parameter MAX_BURST_LEN  = 16
) (
    input  wire        clk,
    input  wire        rst_n,

    // === Control interface ===
    input  wire                        start,
    input  wire [AXI_ADDR_WIDTH-1:0]   base_addr,
    input  wire [31:0]                 byte_count,
    output wire                        done,
    output wire                        error,
    output wire [7:0]                  error_code,
    output wire                        busy,
    output wire                        write_txn_active,  // high during S_AW|S_WDATA|S_WAIT_B

    // === FIFO level (delayed AW) ===
    input  wire [4:0]                  fifo_level,

    // === Producer done (no more data will arrive) ===
    input  wire                        producer_done,

    // === Data input ===
    input  wire [AXI_DATA_WIDTH-1:0]   data_in,
    input  wire                        data_valid,
    output wire                        data_ready,

    // === AXI4 Write Master ===
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

    localparam ERR_NONE    = 8'h00;
    localparam ERR_BRESP   = 8'h30;
    localparam ERR_ALIGN   = 8'h31;

    // ============================================================
    // State machine
    // ============================================================
    localparam S_IDLE      = 3'd0;
    localparam S_WAIT_DATA = 3'd6;  // wait for FIFO to fill
    localparam S_AW        = 3'd1;
    localparam S_WDATA     = 3'd2;
    localparam S_WAIT_B    = 3'd3;
    localparam S_DONE      = 3'd4;
    localparam S_ERROR     = 3'd5;

    reg [2:0] state, next_state;

    // ============================================================
    // Burst calculation
    // ============================================================
    function [7:0] calc_burst_beats;
        input [31:0] bytes;
        reg [31:0] raw_beats;
        begin
            if (bytes >= (MAX_BURST_LEN * BEAT_BYTES))
                calc_burst_beats = MAX_BURST_LEN[7:0];
            else begin
                raw_beats = (bytes + BEAT_BYTES - 1) / BEAT_BYTES;
                calc_burst_beats = raw_beats[7:0];
            end
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
    // Internal registers
    // ============================================================
    reg  [31:0] bytes_remaining;
    reg  [31:0] current_addr;
    reg  [7:0]  beats_in_burst;
    reg  [7:0]  burst_len;
    reg  [7:0]  beat_counter;
    reg         aw_done;
    reg         w_done;     // all W beats sent for this burst
    reg         b_valid_r;  // internally latched BVALID-like state

    // ============================================================
    // Remaining bytes after current burst (clamped to avoid underflow)
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
    // AXI4 AW channel
    // ============================================================
    wire aw_hs = m_axi_awvalid && m_axi_awready;

    assign m_axi_awaddr  = current_addr;
    assign m_axi_awlen   = burst_len;
    assign m_axi_awsize  = BEAT_BYTES_LOG2[2:0];
    assign m_axi_awburst = 2'b01;  // INCR
    assign m_axi_awvalid = (state == S_AW) && !aw_done;

    // ============================================================
    // AXI4 W channel
    // ============================================================
    reg [AXI_DATA_WIDTH-1:0] wdata_r;
    reg [STRB_W-1:0]         wstrb_r;
    reg                      wlast_r;
    reg                      wvalid_r;

    // Phase B2: next-beat preload buffer — eliminates 1-cycle bubble
    //   next_valid=1 means next_{data,strb,last} holds the beat after current.
    //   On w_hs: if next_valid, transfer next→wdata_r (wvalid stays 1).
    //   data_ready = !next_valid || w_hs (accept new beat when buffer free or freeing).
    reg                      next_valid;
    reg [AXI_DATA_WIDTH-1:0] next_data;
    reg [STRB_W-1:0]         next_strb;
    reg                      next_last;

    wire w_hs = m_axi_wvalid && m_axi_wready;

    // data_ready: accept upstream data when next buffer is free, OR when w_hs
    // will consume the current beat and free up the pipeline this cycle.
    assign data_ready = (state == S_WDATA) && !w_done && (!next_valid || w_hs);

    // next_ready: combinational — true if next beat is/will-be available.
    // Used by w_hs to decide whether to keep WVALID high after handshake.
    wire next_ready = next_valid || (data_valid && data_ready);

    // Valid bytes for the beat AFTER the current one (used for next wstrb/wlast)
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
    // AXI4 B channel
    // ============================================================
    assign m_axi_bready = 1'b1;  // always ready for response

    // ============================================================
    // State machine
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
                            beats_in_burst  <= calc_burst_beats(byte_count);
                            burst_len       <= calc_burst_beats(byte_count) - 8'h1;
                            state <= S_WAIT_DATA;
                        end
                    end
                end

                S_WAIT_DATA: begin
                    if (fifo_level >= {3'd0, beats_in_burst})
                        state <= S_AW;
                    else if (producer_done && (fifo_level > 5'd0)) begin
                        beats_in_burst <= {3'd0, fifo_level};
                        burst_len      <= {3'd0, fifo_level} - 8'h1;
                        state <= S_AW;
                    end
                end

                S_AW: begin
                    next_valid <= 1'b0;  // discard stale skid from previous burst
                    if (aw_hs) begin
                        aw_done <= 1'b1;
                        state <= S_WDATA;
                    end
                end

                S_WDATA: begin
                    // Phase B2: next-beat preload pipeline -- 1 beat/cycle when FIFO has data.
                    //   next_valid=1 ⇒ next_{data,strb,last} holds beat after current.
                    //   On w_hs: transfer next→wdata_r, keep wvalid continuously high.
                    //   data_ready = !next_valid || w_hs: accept when room or when
                    //   w_hs frees up next this cycle.

                    // Load from FIFO: two-stage check allows loading main+next in 1 cycle.
                    if (data_valid) begin
                        if (!wvalid_r) begin
                            // Main empty: load directly
                            wdata_r  <= data_in;
                            wstrb_r  <= calc_wstrb(valid_bytes_this_beat);
                            wlast_r  <= (beat_counter == burst_len);
                            wvalid_r <= 1'b1;
                        end
                        // Re-check: after first pop, next entry may be available
                        if (data_valid) begin
                            if (wvalid_r && (!next_valid || w_hs)) begin
                                next_data  <= data_in;
                                next_strb  <= calc_wstrb(valid_bytes_next);
                                next_last  <= ((beat_counter + 8'h1) == burst_len);
                                next_valid <= 1'b1;
                            end
                        end
                    end

                    // W channel handshake
                    // next_ready = next_valid || (data_valid && data_ready)
                    //   True when next beat IS or WILL-BE available after this cycle.
                    if (w_hs) begin
                        if (wlast_r) begin
                            // Last beat: end W phase, discard stale next buffer
                            w_done      <= 1'b1;
                            wvalid_r    <= 1'b0;
                            next_valid  <= 1'b0;
                            current_addr    <= current_addr + ({24'h0, beats_in_burst} * BEAT_BYTES);
                            bytes_remaining <= remaining_after_burst;
                            state <= S_WAIT_B;
                        end else if (next_ready) begin
                            // Transfer next→main: use existing next buffer or in-flight load
                            if (next_valid) begin
                                wdata_r <= next_data;
                                wstrb_r <= next_strb;
                                wlast_r <= next_last;
                            end else begin
                                // In-flight: data_in has the next beat
                                wdata_r <= data_in;
                                wstrb_r <= calc_wstrb(valid_bytes_next);
                                wlast_r <= ((beat_counter + 8'h1) == burst_len);
                            end
                            next_valid  <= 1'b0;
                            beat_counter <= beat_counter + 8'h1;
                            // wvalid_r stays 1 (continuous!)
                        end else begin
                            // No preloaded beat: bubble unavoidable
                            wvalid_r <= 1'b0;
                            beat_counter <= beat_counter + 8'h1;
                        end
                    end else if (!wvalid_r && next_valid) begin
                        // Main empty but next has data: promote without handshake
                        wdata_r     <= next_data;
                        wstrb_r     <= next_strb;
                        wlast_r     <= next_last;
                        wvalid_r    <= 1'b1;
                        next_valid  <= 1'b0;
                    end
                end

                S_WAIT_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        // Check for BRESP error
                        if (m_axi_bresp != 2'b00) begin
                            state <= S_ERROR;
                        end else if (bytes_remaining == 32'h0) begin
                            state <= S_DONE;
                        end else begin
                            // Next burst: bytes_remaining already holds remaining count
                            beat_counter    <= 8'h0;
                            beats_in_burst  <= calc_burst_beats(bytes_remaining);
                            burst_len       <= calc_burst_beats(bytes_remaining) - 8'h1;
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
        end else if (state == S_WAIT_B && m_axi_bvalid && m_axi_bready && m_axi_bresp != 2'b00) begin
            error_r      <= 1'b1;
            error_code_r <= ERR_BRESP;
        end
    end

    // ============================================================
    // Done strobe (only in S_DONE, never in S_ERROR)
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
