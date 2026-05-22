// tb_npu_ctrl: testbench for npu_ctrl module
`timescale 1ns / 1ps

module tb_npu_ctrl;

    reg         clk;
    reg         rst_n;

    // AXI-Lite signals
    reg         awvalid;
    wire        awready;
    reg  [31:0] awaddr;
    reg         wvalid;
    wire        wready;
    reg  [31:0] wdata;
    wire        bvalid;
    reg         bready;
    wire [1:0]  bresp;
    reg         arvalid;
    wire        arready;
    reg  [31:0] araddr;
    wire        rvalid;
    reg         rready;
    wire [31:0] rdata;
    wire [1:0]  rresp;

    // Task outputs
    wire        task_start;
    wire [1:0]  task_type;
    wire [31:0] input_addr;
    wire [31:0] weight_addr;
    wire [31:0] output_addr;
    wire [31:0] input_bytes;
    wire [31:0] weight_bytes;
    wire [31:0] output_bytes;
    wire [15:0] input_h;
    wire [15:0] input_w;
    wire [15:0] input_c;
    wire [15:0] output_c;
    wire        relu_en;
    wire        pool_en;

    // Task status
    reg         task_done;
    reg         task_error;
    reg  [7:0]  task_error_code;
    reg         check_done;
    reg         checks_pass;

    // Perf inputs
    reg [31:0] perf_cycle_lo;
    reg [31:0] perf_cycle_hi;
    reg [31:0] perf_read_beats;
    reg [31:0] perf_write_beats;
    reg [31:0] perf_read_active;
    reg [31:0] perf_write_active;
    reg [31:0] perf_mac_lo;
    reg [31:0] perf_mac_hi;
    reg [31:0] perf_array_active;
    reg [31:0] perf_array_stall;
    reg [31:0] perf_cluster_active;
    reg [31:0] perf_cluster_stall;
    reg [31:0] perf_cluster_cfg;

    // Status outputs from npu_ctrl
    wire        ctrl_busy, ctrl_done, ctrl_error;
    wire [7:0]  ctrl_error_code_out;

    // DUT
    npu_ctrl u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_axi_awvalid   (awvalid),
        .s_axi_awready   (awready),
        .s_axi_awaddr    (awaddr),
        .s_axi_wvalid    (wvalid),
        .s_axi_wready    (wready),
        .s_axi_wdata     (wdata),
        .s_axi_wstrb     (4'hF),
        .s_axi_bvalid    (bvalid),
        .s_axi_bready    (bready),
        .s_axi_bresp     (bresp),
        .s_axi_arvalid   (arvalid),
        .s_axi_arready   (arready),
        .s_axi_araddr    (araddr),
        .s_axi_rvalid    (rvalid),
        .s_axi_rready    (rready),
        .s_axi_rdata     (rdata),
        .s_axi_rresp     (rresp),
        .ctrl_busy       (ctrl_busy),
        .ctrl_done       (ctrl_done),
        .ctrl_error      (ctrl_error),
        .ctrl_error_code (ctrl_error_code_out),
        .task_start      (task_start),
        .task_type       (task_type),
        .input_addr      (input_addr),
        .weight_addr     (weight_addr),
        .output_addr     (output_addr),
        .input_bytes     (input_bytes),
        .weight_bytes    (weight_bytes),
        .output_bytes    (output_bytes),
        .input_h         (input_h),
        .input_w         (input_w),
        .input_c         (input_c),
        .output_c        (output_c),
        .relu_en         (relu_en),
        .pool_en         (pool_en),
        .task_done_i     (task_done),
        .task_error_i    (task_error),
        .task_error_code_i(task_error_code),
        .check_done_i    (check_done),
        .checks_pass_i   (checks_pass),
        .perf_cycle_lo_i (perf_cycle_lo),
        .perf_cycle_hi_i (perf_cycle_hi),
        .perf_read_beats_i(perf_read_beats),
        .perf_write_beats_i(perf_write_beats),
        .perf_read_active_i(perf_read_active),
        .perf_write_active_i(perf_write_active),
        .perf_mac_lo_i(perf_mac_lo),
        .perf_mac_hi_i(perf_mac_hi),
        .perf_array_active_i(perf_array_active),
        .perf_array_stall_i(perf_array_stall),
        .perf_cluster_active_i(perf_cluster_active),
        .perf_cluster_stall_i(perf_cluster_stall),
        .perf_cluster_cfg_i(perf_cluster_cfg)
    );

    // Clock: 200 MHz -> 5ns period
    always #2.5 clk = ~clk;

    // AXI write helper task
    // DUT timing: cycle 0 accept AW+W, cycle 1 assert BVALID
    task axi_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);  // sync to clock edge
            awvalid = 1; awaddr = addr;
            wvalid  = 1; wdata  = data;
            @(posedge clk);  // DUT accepts, aw_stored/w_stored <= 1
            awvalid = 0; wvalid = 0;
            @(posedge clk);  // write_handshake=1, bvalid <= 1
            bready = 1;
            @(posedge clk);  // bvalid <= 0
            bready = 0;
        end
    endtask

    // AXI read helper task
    // DUT timing: cycle 0 accept AR, cycle 1 assert RVALID, cycle 2 handshake
    task axi_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);  // sync to clock edge
            arvalid = 1; araddr = addr;
            @(posedge clk);  // DUT accepts, ar_stored <= 1
            arvalid = 0;
            @(posedge clk);  // rvalid <= 1, rdata ready
            data = rdata;
            rready = 1;
            @(posedge clk);  // rvalid <= 0, ar_stored <= 0
            rready = 0;
        end
    endtask

    reg  [31:0] rd_val;
    integer     i;

    // Helper: pulse check_done after a start to simulate task_checker passing
    task checker_pass;
        begin
            @(posedge clk);  // wait one cycle for task_checker to respond
            check_done  = 1;
            checks_pass = 1;
            @(posedge clk);
            check_done  = 0;
            checks_pass = 0;
        end
    endtask

    initial begin
        $dumpfile("sim/tb_npu_ctrl.vcd");
        $dumpvars(0, tb_npu_ctrl);

        // Init
        clk    = 0;
        rst_n  = 0;
        awvalid = 0; wvalid = 0; bready = 0;
        arvalid = 0; rready = 0;
        task_done = 0; task_error = 0; task_error_code = 0;
        check_done = 0; checks_pass = 0;
        perf_cycle_lo = 32'h0000_1234;
        perf_cycle_hi = 32'h0;
        perf_read_beats = 32'd19;
        perf_write_beats = 32'd7;
        perf_read_active = 32'd23;
        perf_write_active = 32'd9;
        perf_mac_lo = 32'd288000;
        perf_mac_hi = 32'd0;
        perf_array_active = 32'd41;
        perf_array_stall = 32'd5;
        perf_cluster_active = 32'd41;
        perf_cluster_stall = 32'd5;
        perf_cluster_cfg = 32'h0000_0001;

        #10 rst_n = 1;
        #10;

        $display("=== Test 1: Reset state check ===");
        axi_read(32'h00, rd_val);
        $display("  CTRL after reset = 0x%08h (expect 0x00000000)", rd_val);
        if (rd_val != 32'h0) $error("  FAIL: CTRL not zero after reset");

        $display("=== Test 2: Write config registers ===");
        axi_write(32'h08, 32'h0);           // TASK_TYPE = Conv
        axi_write(32'h0C, 32'h00001000);    // input_addr
        axi_write(32'h10, 32'h00002000);    // weight_addr
        axi_write(32'h14, 32'h00003000);    // output_addr
        axi_write(32'h18, 32'h00000400);    // input_bytes = 1024
        axi_write(32'h1C, 32'h00000800);    // weight_bytes = 2048
        axi_write(32'h20, 32'h00000100);    // output_bytes = 256
        axi_write(32'h24, 32'h001C001C);    // H=28, W=28
        axi_write(32'h28, 32'h00060001);    // C_IN=1, C_OUT=6
        axi_write(32'h2C, 32'h00000001);    // relu_en=1
        $display("  Config registers written");

        // Read-back check
        axi_read(32'h0C, rd_val);
        $display("  Readback input_addr = 0x%08h (expect 0x00001000)", rd_val);
        if (rd_val != 32'h00001000) $error("  FAIL: input_addr mismatch");

        $display("=== Test 3: Start task (normal flow with checker) ===");
        axi_write(32'h00, 32'h00000001);    // start=1
        checker_pass;  // simulate task_checker passing

        // Check that task outputs are latched after checker pass
        axi_read(32'h00, rd_val);
        $display("  CTRL after start+check = 0x%08h (expect busy=1)", rd_val);
        if (rd_val[1] != 1'b1) $error("  FAIL: busy not set after checker pass");

        // Verify latched outputs
        #1;
        $display("  Latched outputs:");
        $display("    input_addr  = 0x%08h (expect 0x00001000)", input_addr);
        $display("    input_h     = %0d (expect 28)", input_h);
        $display("    relu_en     = %0d (expect 1)", relu_en);

        $display("=== Test 4: Start during busy (should error) ===");
        axi_write(32'h00, 32'h00000001);    // try start again while busy
        axi_read(32'h00, rd_val);
        $display("  CTRL = 0x%08h (expect error=1, busy=0)", rd_val);
        if (rd_val[3] != 1'b1) $error("  FAIL: error not set on busy restart");
        axi_read(32'h04, rd_val);
        $display("  STATUS (error_code) = 0x%08h (expect 0x10)", rd_val);
        if (rd_val[7:0] != 8'h10) $error("  FAIL: error_code not ERR_BUSY_RESTART");

        $display("=== Test 5: Write registers during busy (should error) ===");
        rst_n = 0; #10; rst_n = 1; #10;
        axi_write(32'h08, 32'h0);
        axi_write(32'h0C, 32'h00001000);
        axi_write(32'h10, 32'h00002000);
        axi_write(32'h14, 32'h00003000);
        axi_write(32'h18, 32'h100);
        axi_write(32'h1C, 32'h200);
        axi_write(32'h20, 32'h040);
        axi_write(32'h24, 32'h001C001C);
        axi_write(32'h28, 32'h00060001);
        axi_write(32'h2C, 32'h1);
        axi_write(32'h00, 32'h1);
        checker_pass;
        // Try to write during busy
        axi_write(32'h0C, 32'hDEADBEEF);
        axi_read(32'h00, rd_val);
        $display("  CTRL = 0x%08h (expect error=1)", rd_val);
        if (rd_val[3] != 1'b1) $error("  FAIL: error not set on busy write violation");
        axi_read(32'h04, rd_val);
        $display("  STATUS (error_code) = 0x%08h (expect 0x11)", rd_val);
        if (rd_val[7:0] != 8'h11) $error("  FAIL: error_code not ERR_BUSY_WRITE");

        $display("=== Test 6: Normal task completion ===");
        rst_n = 0; #10; rst_n = 1; #10;
        axi_write(32'h08, 32'h0);
        axi_write(32'h0C, 32'h00001000);
        axi_write(32'h10, 32'h00002000);
        axi_write(32'h14, 32'h00003000);
        axi_write(32'h18, 32'h400);
        axi_write(32'h1C, 32'h800);
        axi_write(32'h20, 32'h180);
        axi_write(32'h24, 32'h001C001C);
        axi_write(32'h28, 32'h00060001);
        axi_write(32'h2C, 32'h3);
        axi_write(32'h00, 32'h1);
        checker_pass;

        #1;
        $display("  task_type=%0d, input_h=%0d, pool_en=%0d",
            task_type, input_h, pool_en);

        // Simulate completion
        #100;
        task_done = 1;
        @(posedge clk);
        @(posedge clk);
        task_done = 0;

        axi_read(32'h00, rd_val);
        $display("  CTRL after done = 0x%08h (expect done=1, busy=0)", rd_val);
        if (rd_val[2] != 1'b1) $error("  FAIL: done not set");

        $display("=== Test 7: Write-to-clear done/error ===");
        // Done is still set from Test 6. Clear it via CTRL write with bit[4]=1.
        axi_write(32'h00, 32'h00000010);    // write bit[4]=1 to clear
        axi_read(32'h00, rd_val);
        $display("  CTRL after clear write: 0x%08h (expect done=0)", rd_val);
        if (rd_val[2] != 1'b0) $error("  FAIL: done not cleared on write-to-clear");

        // Re-run to set done again and verify persistence without clear
        axi_write(32'h00, 32'h1);
        checker_pass;
        #100;
        task_done = 1;
        @(posedge clk);
        @(posedge clk);
        task_done = 0;
        // First read: see done=1
        axi_read(32'h00, rd_val);
        $display("  First read: 0x%08h (expect done=1)", rd_val);
        if (rd_val[2] != 1'b1) $error("  FAIL: done not set");
        // Second read: done persists (no read-to-clear)
        axi_read(32'h00, rd_val);
        $display("  Second read: 0x%08h (expect done=1, persists)", rd_val);
        if (rd_val[2] != 1'b1) $error("  FAIL: done incorrectly cleared on read");
        // Clear
        axi_write(32'h00, 32'h00000010);

        $display("=== Test 8: Task checker rejects invalid params ===");
        rst_n = 0; #10; rst_n = 1; #10;
        axi_write(32'h08, 32'h0);
        axi_write(32'h0C, 32'hA000);
        axi_write(32'h10, 32'hB000);
        axi_write(32'h14, 32'hC000);
        axi_write(32'h18, 32'h1000);
        axi_write(32'h1C, 32'h2000);
        axi_write(32'h20, 32'h200);
        axi_write(32'h24, 32'h00100010);
        axi_write(32'h28, 32'h00040004);
        axi_write(32'h2C, 32'h0);
        axi_write(32'h00, 32'h1);

        // Simulate checker failure
        @(posedge clk);
        check_done = 1;
        checks_pass = 0;    // checks failed!
        task_error = 1;
        task_error_code = 8'h03;
        @(posedge clk);
        check_done = 0;
        task_error = 0;

        axi_read(32'h00, rd_val);
        $display("  CTRL after checker fail = 0x%08h (expect error=1, busy=0)", rd_val);
        if (rd_val[3] != 1'b1) $error("  FAIL: error not set on checker fail");
        if (rd_val[1] != 1'b0) $error("  FAIL: busy should be 0 after checker fail");
        axi_read(32'h04, rd_val);
        $display("  STATUS = 0x%08h (expect error_code=0x03)", rd_val);
        if (rd_val[7:0] != 8'h03) $error("  FAIL: error_code mismatch");

        $display("=== Test 9: Performance register map ===");
        axi_read(32'h30, rd_val);
        if (rd_val !== perf_cycle_lo) $error("  FAIL: perf_cycle_lo mismatch");
        axi_read(32'h38, rd_val);
        if (rd_val !== perf_read_beats) $error("  FAIL: perf_read_beats mismatch");
        axi_read(32'h50, rd_val);
        if (rd_val !== perf_mac_lo) $error("  FAIL: perf_mac_lo mismatch");
        axi_read(32'h58, rd_val);
        if (rd_val !== perf_cluster_active) $error("  FAIL: perf_cluster_active mismatch");
        axi_read(32'h60, rd_val);
        if (rd_val !== perf_cluster_cfg) $error("  FAIL: perf_cluster_cfg mismatch");

        $display("=== All tests complete ===");
        #20;
        $finish;
    end

endmodule
