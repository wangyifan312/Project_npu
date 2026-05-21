// tb_mac_tile: testbench for 4x4 MAC systolic tile (updated for registered sum_out)
`timescale 1ns / 1ps

module tb_mac_tile;

    reg         clk;
    reg         rst_n;
    reg  [7:0]  act_in_0, act_in_1, act_in_2, act_in_3;
    reg  [31:0] sum_in_0, sum_in_1, sum_in_2, sum_in_3;
    reg  [7:0]  w00, w01, w02, w03, w10, w11, w12, w13,
                w20, w21, w22, w23, w30, w31, w32, w33;
    reg         weight_ld;
    wire [7:0]  act_out_0, act_out_1, act_out_2, act_out_3;
    wire [31:0] sum_out_0, sum_out_1, sum_out_2, sum_out_3;

    mac_tile_4x4 u_dut (
        .clk       (clk),        .rst_n     (rst_n),
        .act_in_0  (act_in_0),   .act_in_1  (act_in_1),
        .act_in_2  (act_in_2),   .act_in_3  (act_in_3),
        .sum_in_0  (sum_in_0),   .sum_in_1  (sum_in_1),
        .sum_in_2  (sum_in_2),   .sum_in_3  (sum_in_3),
        .weight_00 (w00), .weight_01 (w01), .weight_02 (w02), .weight_03 (w03),
        .weight_10 (w10), .weight_11 (w11), .weight_12 (w12), .weight_13 (w13),
        .weight_20 (w20), .weight_21 (w21), .weight_22 (w22), .weight_23 (w23),
        .weight_30 (w30), .weight_31 (w31), .weight_32 (w32), .weight_33 (w33),
        .weight_ld (weight_ld),
        .act_out_0 (act_out_0), .act_out_1 (act_out_1),
        .act_out_2 (act_out_2), .act_out_3 (act_out_3),
        .sum_out_0 (sum_out_0), .sum_out_1 (sum_out_1),
        .sum_out_2 (sum_out_2), .sum_out_3 (sum_out_3)
    );

    always #2.5 clk = ~clk;

    initial begin
        $dumpfile("sim/tb_mac_tile.vcd");
        $dumpvars(0, tb_mac_tile);

        clk = 0; rst_n = 0;
        weight_ld = 0;
        {act_in_0, act_in_1, act_in_2, act_in_3} = 0;
        {sum_in_0, sum_in_1, sum_in_2, sum_in_3} = 0;

        #10 rst_n = 1;
        #10;

        // ============================================================
        $display("=== Test 1: Load weights ===");
        // w[r][c] = r*4 + c + 1
        {w00, w01, w02, w03} = {8'd1,  8'd2,  8'd3,  8'd4};
        {w10, w11, w12, w13} = {8'd5,  8'd6,  8'd7,  8'd8};
        {w20, w21, w22, w23} = {8'd9,  8'd10, 8'd11, 8'd12};
        {w30, w31, w32, w33} = {8'd13, 8'd14, 8'd15, 8'd16};

        @(posedge clk);
        weight_ld <= 1;
        @(posedge clk);
        weight_ld <= 0;
        $display("  PASS: weights loaded");

        // ============================================================
        // With registered sum_out: pipeline latency = 4 rows + 4 cols = 8 cycles
        // Steady-state column sum for act=1: cols [28, 32, 36, 40]
        $display("=== Test 2: Pipeline fill + steady state ===");
        {act_in_0, act_in_1, act_in_2, act_in_3} <= {8'd1, 8'd1, 8'd1, 8'd1};

        // Wait for pipeline to fill (8+ cycles)
        repeat(10) @(posedge clk);
        #1;
        $display("  Steady-state sum_out = %0d %0d %0d %0d", $signed(sum_out_0), $signed(sum_out_1),
                 $signed(sum_out_2), $signed(sum_out_3));
        if ($signed(sum_out_0) != 28) $error("  FAIL: sum_out_0 = %0d, expect 28", $signed(sum_out_0));
        if ($signed(sum_out_1) != 32) $error("  FAIL: sum_out_1");
        if ($signed(sum_out_2) != 36) $error("  FAIL: sum_out_2");
        if ($signed(sum_out_3) != 40) $error("  FAIL: sum_out_3");
        $display("  PASS: steady state correct");

        // ============================================================
        $display("=== Test 3: Change act to 2 ===");
        {act_in_0, act_in_1, act_in_2, act_in_3} <= {8'd2, 8'd2, 8'd2, 8'd2};
        repeat(10) @(posedge clk);
        #1;
        // Steady state: double the act → double the sum
        if ($signed(sum_out_0) != 56) $error("  FAIL: 2x sum_out_0 = %0d, expect 56", $signed(sum_out_0));
        if ($signed(sum_out_3) != 80) $error("  FAIL: 2x sum_out_3 = %0d, expect 80", $signed(sum_out_3));
        $display("  PASS: sum_out = %0d %0d %0d %0d", $signed(sum_out_0), $signed(sum_out_1),
                 $signed(sum_out_2), $signed(sum_out_3));

        // ============================================================
        $display("=== Test 4: Negative weights ===");
        rst_n <= 0; @(posedge clk); rst_n <= 1; @(posedge clk);

        {w00, w01, w02, w03} = {8'hFF, 8'd1,  8'd1,  8'd1};   // col 0: -1, rest: 1
        {w10, w11, w12, w13} = {8'hFF, 8'd1,  8'd1,  8'd1};
        {w20, w21, w22, w23} = {8'hFF, 8'd1,  8'd1,  8'd1};
        {w30, w31, w32, w33} = {8'hFF, 8'd1,  8'd1,  8'd1};
        weight_ld <= 1; @(posedge clk); weight_ld <= 0;

        {act_in_0, act_in_1, act_in_2, act_in_3} <= {8'd5, 8'd5, 8'd5, 8'd5};
        repeat(10) @(posedge clk);
        #1;
        // col 0: 5*(-1)*4 = -20; cols 1-3: 5*1*4 = 20
        if ($signed(sum_out_0) != -20) $error("  FAIL: negative test sum_out_0 = %0d", $signed(sum_out_0));
        if ($signed(sum_out_1) != 20)  $error("  FAIL: positive test sum_out_1");
        $display("  PASS: sum_out_0=%0d, sum_out_1=%0d", $signed(sum_out_0), $signed(sum_out_1));

        // ============================================================
        $display("=== Test 5: Sum input accumulation ===");
        rst_n <= 0; @(posedge clk); rst_n <= 1; @(posedge clk);
        {w00, w01, w02, w03} = {8'd2, 8'd2, 8'd2, 8'd2};
        {w10, w11, w12, w13} = {8'd2, 8'd2, 8'd2, 8'd2};
        {w20, w21, w22, w23} = {8'd2, 8'd2, 8'd2, 8'd2};
        {w30, w31, w32, w33} = {8'd2, 8'd2, 8'd2, 8'd2};
        weight_ld <= 1; @(posedge clk); weight_ld <= 0;

        {act_in_0, act_in_1, act_in_2, act_in_3} <= {8'd3, 8'd3, 8'd3, 8'd3};
        {sum_in_0, sum_in_1, sum_in_2, sum_in_3} <= {32'd100, 32'd200, 32'd300, 32'd400};
        repeat(10) @(posedge clk);
        #1;
        // sum_out[c] = sum_in[c] + 3*2*4 = sum_in[c] + 24
        if ($signed(sum_out_0) != 124) $error("  FAIL: accum test sum_out_0");
        if ($signed(sum_out_1) != 224) $error("  FAIL: accum test sum_out_1");
        $display("  PASS: %0d %0d %0d %0d", $signed(sum_out_0), $signed(sum_out_1),
                 $signed(sum_out_2), $signed(sum_out_3));

        $display("=== All tests complete ===");
        #20; $finish;
    end

endmodule
