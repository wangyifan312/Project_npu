// tb_array_top: testbench for array_top with flat ports (iverilog compatible)
`timescale 1ns / 1ps

module tb_array_top;

    localparam T_ROWS = 2;
    localparam T_COLS = 2;
    localparam P_ROWS = T_ROWS * 4;  // 8
    localparam P_COLS = T_COLS * 4;  // 8
    localparam N_TILES = T_ROWS * T_COLS;  // 4

    reg         clk;
    reg         rst_n;
    reg  [(P_ROWS*8)-1:0]     act_in_flat;
    reg  [(P_COLS*32)-1:0]    sum_in_flat;
    reg  [(N_TILES*16*8)-1:0] weight_flat;
    reg         weight_ld;
    wire [(P_COLS*32)-1:0]    sum_out_flat;
    reg  [(N_TILES)-1:0]      tile_clk_en_flat;

    array_top #(
        .TILE_ROWS(T_ROWS),
        .TILE_COLS(T_COLS)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .act_in_flat      (act_in_flat),
        .sum_in_flat      (sum_in_flat),
        .weight_flat      (weight_flat),
        .weight_ld        (weight_ld),
        .sum_out_flat     (sum_out_flat),
        .tile_clk_en_flat (tile_clk_en_flat)
    );

    always #2.5 clk = ~clk;

    // Helper: get signed sum_out from flat vector
    function [31:0] get_sum_out;
        input [3:0] col;
        begin
            get_sum_out = sum_out_flat[col*32 +: 32];
        end
    endfunction

    // Helper: set weight in flat vector
    task set_weight;
        input [3:0] tr, tc, r, c;
        input [7:0] val;
        integer base;
        begin
            base = ((tr*T_COLS + tc)*16 + r*4 + c) * 8;
            weight_flat[base +: 8] = val;
        end
    endtask

    integer tr, tc, r, c;

    initial begin
        $dumpfile("sim/tb_array_top.vcd");
        $dumpvars(0, tb_array_top);

        clk = 0; rst_n = 0;
        weight_ld = 0;
        act_in_flat = 0;
        sum_in_flat = 0;
        tile_clk_en_flat = {N_TILES{1'b1}};

        #10 rst_n = 1;
        #10;

        // ============================================================
        $display("=== Load weights ===");
        for (tr = 0; tr < T_ROWS; tr = tr + 1)
            for (tc = 0; tc < T_COLS; tc = tc + 1)
                for (r = 0; r < 4; r = r + 1)
                    for (c = 0; c < 4; c = c + 1)
                        set_weight(tr[3:0], tc[3:0], r[3:0], c[3:0], (tr + tc) + r*4 + c + 1);

        @(posedge clk);
        weight_ld <= 1;
        @(posedge clk);
        weight_ld <= 0;
        $display("  PASS: weights loaded");

        // ============================================================
        $display("=== Feed act=1, check outputs ===");
        // Set all activations to 1
        for (r = 0; r < P_ROWS; r = r + 1)
            act_in_flat[r*8 +: 8] = 8'd1;

        // Pipeline fill: P_ROWS + P_COLS - 1 + margin = 8+8-1+3 = 18 cycles
        repeat(18) @(posedge clk);
        #1;

        $display("  sum_out[0] = %0d (expect 60)", $signed(get_sum_out(0)));
        $display("  sum_out[3] = %0d (expect 84)", $signed(get_sum_out(3)));
        $display("  sum_out[7] = %0d (expect 92)", $signed(get_sum_out(7)));

        if ($signed(get_sum_out(0)) != 60)
            $error("  FAIL: sum_out[0]");
        if ($signed(get_sum_out(3)) != 84)
            $error("  FAIL: sum_out[3]");
        if ($signed(get_sum_out(7)) != 92)
            $error("  FAIL: sum_out[7]");
        $display("  PASS");

        $display("=== All tests complete ===");
        #20;
        $finish;
    end

endmodule
