//=============================================================================
// tb_array_row_streaming.v — Array-level row-streaming test
// Measure PIPE_OFFSET by feeding skewed activations to a weight-stationary
// 4×4 PE array (TILE_ROWS=1, TILE_COLS=1) with all-1 weights.
// RS0: M=4, K=4, N=4, A all-1, B all-1 → expected C[m,n]=4
//=============================================================================
`timescale 1ns / 1ps

module tb_array_row_streaming;
    localparam TILE_ROWS = 1;
    localparam TILE_COLS = 1;
    localparam PE_ROWS = TILE_ROWS * 4;
    localparam PE_COLS = TILE_COLS * 4;
    localparam ACT_W = PE_ROWS * 8;
    localparam SUM_W = PE_COLS * 32;
    localparam WGT_W = TILE_ROWS * TILE_COLS * 16 * 8;

    localparam M_TILE = 4;
    localparam K_TILE = 4;
    localparam N_TILE = 4;

    reg clk, rst_n;
    reg [ACT_W-1:0] act_in;
    reg [SUM_W-1:0] sum_in;
    reg [WGT_W-1:0] weight_flat;
    reg weight_ld;
    reg [0:0] tile_clk_en;
    wire [SUM_W-1:0] sum_out;

    // A_tile: A[m][k] = 1 for all m,k
    reg [7:0] a_tile [0:M_TILE-1][0:K_TILE-1];

    integer t, k, m, n, wi;
    reg [7:0] act_val [0:PE_ROWS-1];
    integer stream_cycle;
    integer pipe_offset_measured;
    reg pipe_offset_found;

    // DUT
    array_top #(.TILE_ROWS(TILE_ROWS), .TILE_COLS(TILE_COLS)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .act_in_flat(act_in),
        .sum_in_flat(sum_in),
        .weight_flat(weight_flat),
        .weight_ld(weight_ld),
        .sum_out_flat(sum_out),
        .tile_clk_en_flat(tile_clk_en)
    );

    // Clock
    always #5 clk = ~clk;

    initial begin
        clk = 0; rst_n = 0; pipe_offset_found = 0; pipe_offset_measured = -1;
        act_in = {ACT_W{1'b0}}; sum_in = {SUM_W{1'b0}};
        weight_flat = {WGT_W{1'b0}}; weight_ld = 0; tile_clk_en = 1'b1;
        stream_cycle = 0;

        // Initialize A_tile: all 1s
        for (m = 0; m < M_TILE; m = m + 1)
            for (k = 0; k < K_TILE; k = k + 1)
                a_tile[m][k] = 8'd1;

        $display("=== Array Row-Streaming Test: M=%0d K=%0d N=%0d ===", M_TILE, K_TILE, N_TILE);
        $display("PE_ROWS=%0d PE_COLS=%0d", PE_ROWS, PE_COLS);

        // Reset
        #20 rst_n = 1;
        #20;

        // Load weights (all 1s) — WGT_W = 1*1*16*8 = 128 bits = 16 bytes
        $display("[TB] Loading weights...");
        for (wi = 0; wi < WGT_W/8; wi = wi + 1)
            weight_flat[wi*8 +: 8] = 8'h01;
        weight_ld = 1;
        #10;
        weight_ld = 0;
        #10;

        $display("[TB] Starting row-streaming...");
        $display("[TB] cycle | act_in[0..3]                           | sum_out[0..3]");
        $display("[TB] ------|-----------------------------------------|---------------");

        // Stream for M+K+N+20 cycles to capture entire wavefront
        for (t = 0; t < M_TILE + K_TILE + N_TILE + 30; t = t + 1) begin
            stream_cycle = t;

            // Compute skewed activations: act[k] = a_tile[t-k][k] if valid, else 0
            for (k = 0; k < PE_ROWS; k = k + 1) begin
                m = t - k;
                if (m >= 0 && m < M_TILE && k < K_TILE)
                    act_val[k] = a_tile[m][k];
                else
                    act_val[k] = 8'd0;
            end

            // Pack into flat act_in
            act_in = {ACT_W{1'b0}};
            for (k = 0; k < PE_ROWS; k = k + 1)
                act_in[k*8 +: 8] = act_val[k];

            #10; // posedge clk

            // Print trace (every cycle for first 15, then every other)
            if (t < 15 || (t % 4 == 0)) begin
                $write("[TB] %5d |", t);
                for (k = 0; k < 4; k = k + 1)
                    $write(" row%0d=%0d", k, act_val[k]);
                for (k = 0; k < 24 - 4*7; k = k + 1) $write(" ");
                $write("|");
                for (n = 0; n < 4; n = n + 1)
                    $write(" %4d", $signed(sum_out[n*32 +: 32]));
                $write("\n");

                // Check for PIPE_OFFSET: first non-zero sum_out[0]
                if (!pipe_offset_found && $signed(sum_out[0*32 +: 32]) != 0) begin
                    pipe_offset_measured = t - K_TILE;
                    pipe_offset_found = 1;
                    $display("[TB] *** PIPE_OFFSET measured: stream_cycle=%0d, PIPE_OFFSET = %0d - %0d = %0d ***",
                        t, t, K_TILE, pipe_offset_measured);
                end
            end
        end

        // Print final results
        $display("\n[TB] === Final Wavefront Output ===");
        $display("[TB] PIPE_OFFSET = %0d", pipe_offset_measured);
        $display("[TB] Expected: C[m,n] = %0d (all-1 inputs)", K_TILE);

        // Verify: re-scan the trace and check wavefront pattern
        // For now, just report measured offset
        if (pipe_offset_found) begin
            $display("[TB] PASS: PIPE_OFFSET measured successfully");
        end else begin
            $display("[TB] FAIL: PIPE_OFFSET not found (all outputs are zero)");
        end

        #100;
        $finish;
    end

endmodule
