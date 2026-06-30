//=============================================================================
// tb_pe_cluster_row_streaming.v — pe_cluster-level row-streaming debug
// Test 4x4 RS0 through pe_cluster in continuous_mode. If outputs are 0,
// trace PE internals to locate the root cause.
//=============================================================================
`timescale 1ns / 1ps

module tb_pe_cluster_row_streaming;
    localparam TILE_ROWS = 4;
    localparam TILE_COLS = 4;
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
    reg weight_ld, start;
    reg local_enable;
    reg [(TILE_ROWS*TILE_COLS)-1:0] tile_clk_en;
    wire [SUM_W-1:0] sum_out;
    wire cluster_busy, cluster_valid, cluster_done;
    reg continuous_mode, stream_active;

    reg [7:0] a_tile [0:M_TILE-1][0:K_TILE-1];
    integer t, k, m, n, wi;
    reg [7:0] act_val [0:PE_ROWS-1];
    integer pipe_offset_found, first_valid_cycle;
    reg [31:0] c_captured [0:M_TILE-1][0:N_TILE-1];
    reg c_valid [0:M_TILE-1][0:N_TILE-1];

    pe_cluster #(.TILE_ROWS(TILE_ROWS), .TILE_COLS(TILE_COLS)) u_dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .local_enable(local_enable),
        .act_in_flat(act_in), .sum_in_flat(sum_in),
        .weight_flat(weight_flat), .weight_ld(weight_ld),
        .tile_clk_en_flat(tile_clk_en),
        .sum_out_flat(sum_out),
        .cluster_busy(cluster_busy), .cluster_valid(cluster_valid),
        .cluster_done(cluster_done),
        .continuous_mode(continuous_mode),
        .stream_active(stream_active)
    );

    always #5 clk = ~clk;

    //=========================================================================
    // Test sequence
    //=========================================================================
    initial begin
        integer errors;
        clk = 0; rst_n = 0; start = 0; local_enable = 1;
        act_in = {ACT_W{1'b0}}; sum_in = {SUM_W{1'b0}};
        weight_flat = {WGT_W{1'b0}}; weight_ld = 0;
        tile_clk_en = {(TILE_ROWS*TILE_COLS){1'b1}}; continuous_mode = 0; stream_active = 0;
        pipe_offset_found = 0; first_valid_cycle = -1;

        for (m = 0; m < M_TILE; m = m + 1)
            for (k = 0; k < K_TILE; k = k + 1)
                a_tile[m][k] = 8'd1;
        for (m = 0; m < M_TILE; m = m + 1)
            for (n = 0; n < N_TILE; n = n + 1) begin
                c_captured[m][n] = 0; c_valid[m][n] = 0;
            end

        $display("=== pe_cluster Row-Streaming Debug: M=%0d K=%0d N=%0d PE=%0dx%0d ===",
            M_TILE, K_TILE, N_TILE, PE_ROWS, PE_COLS);

        // Reset
        #20 rst_n = 1;
        #20;

        // ---- Phase 1: Load weights in legacy mode ----
        $display("[TB] Phase 1: Loading weights (legacy one-shot mode)...");
        for (wi = 0; wi < WGT_W/8; wi = wi + 1)
            weight_flat[wi*8 +: 8] = 8'h01;
        weight_ld = 1;
        #10;
        weight_ld = 0;
        #10;

        // Verify weight loaded via local_enable gating check
        $display("[TB] local_enable=%0d weight_ld=%0d", local_enable, weight_ld);
        $display("[TB] weight_flat[0]=%0d (expect 1)", weight_flat[7:0]);
        // PE weight check skipped (hierarchical path not supported by iverilog)

        // ---- Phase 2: Enter continuous mode and stream ----
        $display("[TB] Phase 2: Entering continuous mode...");
        continuous_mode = 1;
        stream_active = 1;
        #10;

        $display("[TB] Phase 3: Row-streaming...");
        $display("[TB] t | act[0..3]        | sum[0..3]                     | PE00 internals");
        $display("[TB] --|------------------|-------------------------------|--------------");

        for (t = 0; t < M_TILE + PE_ROWS + N_TILE + 10; t = t + 1) begin
            // Skewed feed
            for (k = 0; k < PE_ROWS; k = k + 1) begin
                m = t - k;
                act_val[k] = (m >= 0 && m < M_TILE && k < K_TILE) ? a_tile[m][k] : 8'd0;
            end
            for (k = 0; k < PE_ROWS; k = k + 1)
                act_in[k*8 +: 8] = act_val[k];

            #10;

            // Print trace
            if (t < 8 || (t >= 8 && $signed(sum_out[0*32 +: 32]) != 0)) begin
                $write("[TB] %0d |", t);
                for (k = 0; k < 4; k = k + 1) $write(" %0d", act_val[k]);
                $write(" |");
                for (n = 0; n < 4; n = n + 1) $write(" %4d", $signed(sum_out[n*32 +: 32]));
                $write(" | busy=%0d valid=%0d", cluster_busy, cluster_valid);
                $write("\n");
            end

            // Check for first non-zero output
            if (!pipe_offset_found && $signed(sum_out[0*32 +: 32]) != 0) begin
                pipe_offset_found = 1;
                first_valid_cycle = t;
                $display("[TB] *** First non-zero output at t=%0d ***", t);
            end

            // Capture wavefront outputs: m = t - K - n - PIPE_OFFSET
            // PIPE_OFFSET = PE_ROWS - K (vertical pipeline through inactive rows)
            for (n = 0; n < N_TILE; n = n + 1) begin
                m = t - K_TILE - n - (PE_ROWS - K_TILE);
                if (m >= 0 && m < M_TILE && !c_valid[m][n] && $signed(sum_out[n*32 +: 32]) == K_TILE) begin
                    c_captured[m][n] = sum_out[n*32 +: 32];
                    c_valid[m][n] = 1;
                end
            end
        end

        // ---- Phase 4: Check results ----
        continuous_mode = 0; stream_active = 0;
        $display("\n[TB] === Results ===");
        $display("[TB] C_collect matrix:");
        for (m = 0; m < M_TILE; m = m + 1) begin
            $write("[TB]   row%0d:", m);
            for (n = 0; n < N_TILE; n = n + 1)
                $write(" %4d", c_captured[m][n]);
            $write("  valid:");
            for (n = 0; n < N_TILE; n = n + 1)
                $write(" %0d", c_valid[m][n]);
            $write("\n");
        end

        // Verify
        errors = 0;
        for (m = 0; m < M_TILE; m = m + 1)
            for (n = 0; n < N_TILE; n = n + 1)
                if (c_captured[m][n] != K_TILE || !c_valid[m][n]) errors = errors + 1;

        if (errors == 0) begin
            $display("[TB] PASS: All %0d outputs = %0d", M_TILE*N_TILE, K_TILE);
        end else begin
            $display("[TB] FAIL: %0d errors, first_valid_cycle=%0d", errors, first_valid_cycle);
            // Diagnostic: check PE[3][0] vs PE[other] if appropriate
            if (first_valid_cycle < 0) begin
                $display("[TB] DIAG: No non-zero outputs detected. Checking PE internals...");
                $display("[TB] DIAG: continuous_mode=%0d stream_active=%0d local_enable=%0d cluster_busy=%0d",
                continuous_mode, stream_active, local_enable, cluster_busy);
            end
        end

        #100;
        $finish;
    end

endmodule
