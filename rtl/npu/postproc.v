// postproc: ReLU + optional 2x2 MaxPool (stride=2), INT32 domain
// Supports multi-channel HWC layout via input_c stride
`timescale 1ns / 1ps

module postproc #(
    parameter DATA_W = 32,
    parameter MAX_OUT_W = 240  // max (output_w * max_channels) for line buffer
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
    input  wire [15:0] input_w,     // spatial width
    input  wire [15:0] input_h,     // spatial height (per block)
    input  wire [15:0] input_c,     // channels (stride between spatial neighbors)
    input  wire        start,
    output wire        done
);

    // ReLU (combinational)
    wire [DATA_W-1:0] relu_out;
    assign relu_out = (relu_en && data_in[DATA_W-1]) ? {DATA_W{1'b0}} : data_in;

    // ============================================================
    // MaxPool state: track position within HWC stream
    // elem_idx: 0..W*C-1 within each row, spatial col = elem_idx / C
    // ============================================================
    reg [15:0]  elem_idx;       // 0..W*C-1 within row
    reg         row_parity;     // 0=first of pair, 1=second
    reg [31:0]  processed;
    reg [31:0]  total_out;
    reg         done_r, bypass_done_r;

    // Per-channel even-column storage
    reg [DATA_W-1:0] curr_even [0:63];
    // Line buffer: (W/2)*C entries for h_max from previous row
    reg [DATA_W-1:0] line_buf [0:MAX_OUT_W-1];
    integer ii;

    wire [15:0] row_width = input_w * input_c;
    wire [15:0] out_col_w = input_w >> 1;  // output spatial columns per row
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
            // Latch even column value per channel
            if (is_even_col)
                curr_even[ch_sub] <= relu_out;

            // Count every pooled output element in HWC order.
            if (is_odd_col && row_parity)
                processed <= processed + 32'd1;

            // Advance one HWC element per cycle.
            if (elem_idx + 16'd1 == row_width) begin
                elem_idx   <= 16'd0;
                row_parity <= ~row_parity;
            end else begin
                elem_idx <= elem_idx + 16'd1;
            end
        end else if (!pool_en && data_valid) begin
            processed <= processed + 32'd1;
        end

        // Done detection
        if (pool_en)
            done_r <= (processed >= total_out) && (total_out > 0);
        else
            bypass_done_r <= (processed >= total_out) && (total_out > 0);
    end

    // Horizontal max: even_val from previous spatial column vs current odd value
    wire [DATA_W-1:0] h_max;
    assign h_max = ($signed(curr_even[ch_sub]) > $signed(relu_out))
                   ? curr_even[ch_sub] : relu_out;

    // Vertical max: current h_max vs stored value from previous row
    wire [DATA_W-1:0] v_max;
    assign v_max = ($signed(h_max) > $signed(line_buf[lb_index]))
                   ? h_max : line_buf[lb_index];

    // Update line buffer for every channel at odd columns so vertical pooling
    // sees a full HWC stream instead of only the last channel.
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
