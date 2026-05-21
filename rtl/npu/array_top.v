// array_top: systolic array from 4x4 MAC tiles, iverilog-compatible flat ports
// Total: TILE_ROWS*4 MAC rows × TILE_COLS*4 MAC columns
`timescale 1ns / 1ps

module array_top #(
    parameter TILE_ROWS = 2,   // default small for testing
    parameter TILE_COLS = 2
) (
    input  wire        clk,
    input  wire        rst_n,

    // Activations: (TILE_ROWS*4) × 8-bit, flow left→right
    // Packed as flat vector: act_row_r = act_in[r*8 +: 8]
    input  wire [(TILE_ROWS*4*8)-1:0] act_in_flat,

    // Partial sums from top: (TILE_COLS*4) × 32-bit
    input  wire [(TILE_COLS*4*32)-1:0] sum_in_flat,

    // Weights: TILE_ROWS*TILE_COLS*4*4 × 8-bit (flat)
    input  wire [(TILE_ROWS*TILE_COLS*16*8)-1:0] weight_flat,
    input  wire        weight_ld,

    // Output partial sums: (TILE_COLS*4) × 32-bit
    output wire [(TILE_COLS*4*32)-1:0] sum_out_flat,

    // Clock gating per tile (flat enable vector)
    input  wire [(TILE_ROWS*TILE_COLS)-1:0] tile_clk_en_flat
);

    localparam PE_ROWS = TILE_ROWS * 4;
    localparam PE_COLS = TILE_COLS * 4;
    localparam N_TILES = TILE_ROWS * TILE_COLS;

    // Helper function: get tile row, col from flat index
    // Flat index = tr * TILE_COLS + tc

    // Internal wires: horizontal activation between tiles (flat)
    // act_h[(tr*TILE_COLS + tc)*4 + k] = activation at tile(tr,tc) PE row k, entering this tile
    // The +1 offset in tc means "after this tile" = input to next tile
    wire [(TILE_ROWS * (TILE_COLS+1) * 4 * 8)-1:0] act_tile_flat;
    // Vertical sums between tiles
    wire [((TILE_ROWS+1) * TILE_COLS * 4 * 32)-1:0] sum_tile_flat;

    // Gated clocks per tile
    wire [N_TILES-1:0] gated_clk;

    // ============================================================
    // Generate tiles
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

            // Gated clock
            assign gated_clk[ti] = clk && tile_clk_en_flat[ti];

            // Connections: first tile in row gets external activation
            if (tc == 0) begin : act_from_ext
                assign act_tile_flat[act_in_base +: 32] = act_in_flat[tr*4*8 +: 32];
            end

            // Connections: first tile row gets external sum
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

            // Sum output from last tile row
            if (tr == TILE_ROWS - 1) begin : sum_to_ext
                assign sum_out_flat[tc*4*32 +: 128] = sum_tile_flat[sum_out_base +: 128];
            end
        end
    endgenerate

endmodule
