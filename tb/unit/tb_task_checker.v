// tb_task_checker: testbench for task_checker module
`timescale 1ns / 1ps

module tb_task_checker;

    reg         clk;
    reg         rst_n;
    reg         task_start;
    reg  [1:0]  task_type;
    reg  [31:0] input_addr;
    reg  [31:0] weight_addr;
    reg  [31:0] output_addr;
    reg  [31:0] input_bytes;
    reg  [31:0] weight_bytes;
    reg  [31:0] output_bytes;
    reg  [15:0] input_h;
    reg  [15:0] input_w;
    reg  [15:0] input_c;
    reg  [15:0] output_c;
    reg         relu_en;
    reg         pool_en;

    wire        checks_pass;
    wire [7:0]  error_code;
    wire        check_done;

    task_checker #(
        .MEM_BASE(32'h0000_1000),
        .MEM_SIZE(32'h0001_0000)  // 64KB
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .task_start   (task_start),
        .task_type    (task_type),
        .input_addr   (input_addr),
        .weight_addr  (weight_addr),
        .output_addr  (output_addr),
        .input_bytes  (input_bytes),
        .weight_bytes (weight_bytes),
        .output_bytes (output_bytes),
        .input_h      (input_h),
        .input_w      (input_w),
        .input_c      (input_c),
        .output_c     (output_c),
        .relu_en      (relu_en),
        .pool_en      (pool_en),
        .checks_pass  (checks_pass),
        .error_code   (error_code),
        .check_done   (check_done)
    );

    always #2.5 clk = ~clk;  // 200 MHz

    // Helper: set up default valid Conv params
    task set_conv_valid;
        begin
            task_type    = 2'd0;       // Conv
            input_addr   = 32'h0000_2000;
            weight_addr  = 32'h0000_4000;
            output_addr  = 32'h0000_6000;
            input_bytes  = 32'h0000_0400;
            weight_bytes = 32'h0000_0800;
            output_bytes = 32'h0000_0100;
            input_h      = 16'd28;
            input_w      = 16'd28;
            input_c      = 16'd1;
            output_c     = 16'd6;
        end
    endtask

    // Helper: set up default valid FC params
    task set_fc_valid;
        begin
            task_type    = 2'd1;       // FC
            input_addr   = 32'h0000_2000;
            weight_addr  = 32'h0000_4000;
            output_addr  = 32'h0000_6000;
            input_bytes  = 32'h0000_0100;
            weight_bytes = 32'h0000_0200;
            output_bytes = 32'h0000_0040;
            input_h      = 16'd1;      // FC uses 1x1 spatial
            input_w      = 16'd1;
            input_c      = 16'd64;
            output_c     = 16'd16;
        end
    endtask

    // Helper: set up default valid Pool params
    task set_pool_valid;
        begin
            task_type    = 2'd2;       // Pool
            input_addr   = 32'h0000_2000;
            weight_addr  = 32'h0000_0000;
            output_addr  = 32'h0000_6000;
            input_bytes  = 32'h0000_0400;
            weight_bytes = 32'h0000_0001;  // non-zero even if unused
            output_bytes = 32'h0000_0100;
            input_h      = 16'd24;
            input_w      = 16'd24;
            input_c      = 16'd6;
            output_c     = 16'd6;
        end
    endtask

    // Helper: pulse task_start
    task do_check;
        begin
            @(posedge clk);
            task_start = 1;
            @(posedge clk);
            task_start = 0;
            // wait for check_done
            @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("sim/tb_task_checker.vcd");
        $dumpvars(0, tb_task_checker);

        clk = 0; rst_n = 0;
        task_start = 0;
        set_conv_valid;
        #10 rst_n = 1;
        #10;

        // ============================================================
        $display("=== Test 1: Valid Conv parameters ===");
        set_conv_valid;
        do_check;
        if (!check_done) $error("  FAIL: check_done not asserted");
        if (!checks_pass) $error("  FAIL: valid Conv should pass, got error=%0h", error_code);
        $display("  PASS: checks_pass=%b, error_code=%0h", checks_pass, error_code);

        // ============================================================
        $display("=== Test 2: FC accepted (FC now supported) ===");
        set_fc_valid;
        do_check;
        if (!checks_pass) $error("  FAIL: valid FC should pass, got error=%0h", error_code);
        $display("  PASS: FC checks_pass=%b, error_code=%0h", checks_pass, error_code);

        // ============================================================
        $display("=== Test 3: Valid Pool parameters ===");
        set_pool_valid;
        do_check;
        if (!checks_pass) $error("  FAIL: valid Pool should pass, got error=%0h", error_code);
        $display("  PASS: checks_pass=%b", checks_pass);

        // ============================================================
        $display("=== Test 4: Invalid task_type ===");
        set_conv_valid;
        task_type = 2'd3;  // invalid
        do_check;
        if (checks_pass) $error("  FAIL: invalid task_type should fail");
        if (error_code != 8'h01) $error("  FAIL: expected ERR_INVALID_TASK_TYPE(01), got %0h", error_code);
        $display("  PASS: error_code=%0h", error_code);

        // ============================================================
        $display("=== Test 5: Zero bytes ===");
        set_conv_valid;
        input_bytes = 32'h0;
        do_check;
        if (checks_pass) $error("  FAIL: zero bytes should fail");
        if (error_code != 8'h02) $error("  FAIL: expected ERR_ZERO_BYTES(02), got %0h", error_code);
        $display("  PASS: error_code=%0h", error_code);

        // ============================================================
        $display("=== Test 6: Null address ===");
        set_conv_valid;
        weight_addr = 32'h0;
        do_check;
        if (checks_pass) $error("  FAIL: null addr should fail");
        if (error_code != 8'h03) $error("  FAIL: expected ERR_NULL_ADDR(03), got %0h", error_code);
        $display("  PASS: error_code=%0h", error_code);

        // ============================================================
        $display("=== Test 7: Address misaligned ===");
        set_conv_valid;
        input_addr = 32'h0000_2004;  // not 64-byte aligned
        do_check;
        if (checks_pass) $error("  FAIL: misaligned addr should fail");
        if (error_code != 8'h04) $error("  FAIL: expected ERR_ADDR_ALIGN(04), got %0h", error_code);
        $display("  PASS: error_code=%0h", error_code);

        // ============================================================
        $display("=== Test 8: Address out of bounds ===");
        set_conv_valid;
        input_addr = 32'h0000_0800;  // below MEM_BASE (0x1000)
        do_check;
        if (checks_pass) $error("  FAIL: out-of-bounds addr should fail");
        if (error_code != 8'h05) $error("  FAIL: expected ERR_ADDR_BOUNDS(05), got %0h", error_code);
        $display("  PASS: error_code=%0h", error_code);

        // ============================================================
        $display("=== Test 9: Address overflow ===");
        set_conv_valid;
        input_bytes = 32'h0001_0000;  // addr(0x2000) + bytes(0x10000) = 0x12000 > MEM_BASE+MEM_SIZE(0x11000)
        do_check;
        if (checks_pass) $error("  FAIL: addr overflow should fail");
        if (error_code != 8'h06) $error("  FAIL: expected ERR_ADDR_OVERFLOW(06), got %0h", error_code);
        $display("  PASS: error_code=%0h", error_code);

        // ============================================================
        $display("=== Test 10: Conv dimensions too small ===");
        set_conv_valid;
        input_h = 16'd4;  // too small for 5x5 kernel
        input_w = 16'd4;
        do_check;
        if (checks_pass) $error("  FAIL: small conv dims should fail");
        if (error_code != 8'h07) $error("  FAIL: expected ERR_CONV_PARAM(07), got %0h", error_code);
        $display("  PASS: error_code=%0h", error_code);

        // ============================================================
        $display("=== Test 11: Pool with odd dimensions ===");
        set_pool_valid;
        input_h = 16'd25;  // odd
        input_w = 16'd25;
        do_check;
        if (checks_pass) $error("  FAIL: odd pool dims should fail");
        if (error_code != 8'h08) $error("  FAIL: expected ERR_POOL_PARAM(08), got %0h", error_code);
        $display("  PASS: error_code=%0h", error_code);

        // ============================================================
        $display("=== Test 12: Zero channels ===");
        set_conv_valid;
        output_c = 16'd0;
        do_check;
        if (checks_pass) $error("  FAIL: zero channels should fail");
        if (error_code != 8'h09) $error("  FAIL: expected ERR_DIM_RELATION(09), got %0h", error_code);
        $display("  PASS: error_code=%0h", error_code);

        // ============================================================
        $display("=== Test 13: Minimum valid Conv (5x5 input) ===");
        set_conv_valid;
        input_h = 16'd5;
        input_w = 16'd5;
        do_check;
        if (!checks_pass) $error("  FAIL: minimal valid Conv should pass, got error=%0h", error_code);
        $display("  PASS: checks_pass=%b", checks_pass);

        // ============================================================
        $display("=== Test 14: Pool with weight_bytes=0 is OK ===");
        set_pool_valid;
        weight_bytes = 32'h0;  // pool doesn't need weights
        do_check;
        if (!checks_pass) $error("  FAIL: pool with zero weight_bytes should pass, got error=%0h", error_code);
        $display("  PASS: checks_pass=%b", checks_pass);

        $display("=== All tests complete ===");
        #20;
        $finish;
    end

endmodule
