// tb_array_direct: minimal systolic array skewed-feed test
`timescale 1ns / 1ps
module tb_array_direct;
    localparam T_ROWS = 7;
    localparam T_COLS = 2;
    localparam P_ROWS = T_ROWS * 4;
    localparam P_COLS = T_COLS * 4;
    localparam N_TILES = T_ROWS * T_COLS;

    reg clk, rst_n;
    reg [(P_ROWS*8)-1:0]     act_in;
    reg [(P_COLS*32)-1:0]    sum_in;
    wire [(P_COLS*32)-1:0]   sum_out;
    reg [(N_TILES*16*8)-1:0] wf;
    reg wld;
    reg [(N_TILES)-1:0]      clk_en;

    array_top #(.TILE_ROWS(T_ROWS), .TILE_COLS(T_COLS)) u (
        .clk(clk), .rst_n(rst_n), .act_in_flat(act_in),
        .sum_in_flat(sum_in), .weight_flat(wf), .weight_ld(wld),
        .sum_out_flat(sum_out), .tile_clk_en_flat(clk_en)
    );

    always #2.5 clk = ~clk;

    task set_wgt;
        input [3:0] tr, tc, r, c;
        input [7:0] val;
        integer base;
        begin
            base = ((tr*T_COLS + tc)*16 + r*4 + c) * 8;
            wf[base +: 8] = val;
        end
    endtask

    integer k;

    initial begin
        $dumpfile("sim/tb_array_direct.vcd");
        $dumpvars(0, tb_array_direct);
        clk = 0; rst_n = 0; act_in = 0; sum_in = 0; wf = 0; wld = 0; clk_en = {N_TILES{1'b1}};
        #20 rst_n = 1;
        #20;

        // Load weight=2 into PE(r,0) for r=0..24, others 0
        $display("=== Loading weights ===");
        wf = 0;
        for (k = 0; k < 25; k = k + 1)
            set_wgt(k/4, 0, k%4, 0, 8'd2);
        @(posedge clk);
        wld <= 1;
        @(posedge clk);
        wld <= 0;
        @(posedge clk); // separation cycle

        // Continuous feed: all rows act=1 (same pattern as working test)
        $display("=== Continuous feed act=1 to all rows ===");
        for (k = 0; k < P_ROWS; k = k + 1)
            act_in[k*8 +: 8] = 8'd1;
        repeat(40) @(posedge clk);
        $display("CONT: sum_out[0]=%0d (expect steady-state)", $signed(sum_out[0*32+:32]));

        // Now try skewed feed
        act_in = 0;
        @(posedge clk);
        $display("=== Skewed feeding ===");
        for (k = 0; k < 25; k = k + 1) begin
            act_in <= 0;
            act_in[k*8 +: 8] <= 8'd1;
            @(posedge clk);
        end
        act_in <= 0;
        @(posedge clk);

        // Scan every cycle during drain
        $display("=== Scanning drain ===");
        for (k = 0; k < 50; k = k + 1) begin
            @(posedge clk);
            if ($signed(sum_out[0*32+:32]) != 0)
                $display("  drain[%0d]: sum_out[0] = %0d", k, $signed(sum_out[0*32+:32]));
        end

        $finish;
    end
endmodule
