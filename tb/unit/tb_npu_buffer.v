// tb_npu_buffer: testbench for npu_buffer double-buffer module
`timescale 1ns / 1ps

module tb_npu_buffer;

    reg         clk;
    reg         rst_n;

    // DMA write port
    reg  [7:0]  wr_addr;
    reg  [31:0] wr_data;
    reg         wr_en;
    reg         wr_bank_sel;

    // Read port
    reg  [7:0]  rd_addr;
    wire [31:0] rd_data;
    reg         rd_bank_sel;

    // Control
    reg         load_start;
    reg         load_done;
    reg         comp_start;
    reg         comp_done;
    reg         load_bank_sel;
    reg         comp_bank_sel;

    // Status
    wire        load_ready;
    wire        comp_ready;
    wire        comp_active;
    wire [1:0]  bank_a_state;
    wire [1:0]  bank_b_state;

    npu_buffer #(
        .DATA_WIDTH(32),
        .ENTRIES(256),
        .ADDR_WIDTH(8)
    ) u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .wr_addr       (wr_addr),
        .wr_data       (wr_data),
        .wr_en         (wr_en),
        .wr_bank_sel   (wr_bank_sel),
        .rd_addr       (rd_addr),
        .rd_data       (rd_data),
        .rd_bank_sel   (rd_bank_sel),
        .load_start    (load_start),
        .load_done     (load_done),
        .comp_start    (comp_start),
        .comp_done     (comp_done),
        .load_bank_sel (load_bank_sel),
        .comp_bank_sel (comp_bank_sel),
        .load_ready    (load_ready),
        .comp_ready    (comp_ready),
        .comp_active   (comp_active),
        .bank_a_state  (bank_a_state),
        .bank_b_state  (bank_b_state)
    );

    always #2.5 clk = ~clk;

    // Helper: pulse a signal for one cycle
    task pulse;
        inout reg sig;
        begin
            @(posedge clk);  // sync
            sig <= 1;
            @(posedge clk);  // sig=1 visible at this edge
            sig <= 0;
            @(posedge clk);  // sig=0 visible, back to idle
        end
    endtask

    // Helper: fill bank via DMA writes
    task fill_bank;
        input bank_sel;
        input [31:0] base_val;
        input [7:0]  count;
        integer i;
        begin
            wr_bank_sel = bank_sel;
            for (i = 0; i < count; i = i + 1) begin
                @(posedge clk);
                wr_addr <= i[7:0];
                wr_data <= base_val + i;
                wr_en   <= 1;
            end
            @(posedge clk);
            wr_en <= 0;
        end
    endtask

    integer i;

    initial begin
        $dumpfile("sim/tb_npu_buffer.vcd");
        $dumpvars(0, tb_npu_buffer);

        clk = 0; rst_n = 0;
        wr_en = 0; load_start = 0; load_done = 0;
        comp_start = 0; comp_done = 0;
        load_bank_sel = 0; comp_bank_sel = 0;

        #10 rst_n = 1;
        #10;

        // ============================================================
        $display("=== Test 1: Reset state check ===");
        $display("  load_ready=%b (expect 1), comp_ready=%b (expect 0)",
            load_ready, comp_ready);
        $display("  bank_a_state=%0d (expect 0=EMPTY), bank_b_state=%0d (expect 0=EMPTY)",
            bank_a_state, bank_b_state);
        if (bank_a_state != 0 || bank_b_state != 0 || !load_ready)
            $error("  FAIL: reset state wrong");

        // ============================================================
        $display("=== Test 2: Load bank A ===");
        load_bank_sel = 0;
        @(posedge clk);
        load_start <= 1;
        @(posedge clk);
        load_start <= 0;
        @(posedge clk);  // wait one extra cycle for state to update
        #1;
        if (bank_a_state != 1) $error("  FAIL: bank A not LOADING (state=%0d)", bank_a_state);
        // Fill bank A with data
        fill_bank(0, 32'hAAAA_0000, 16);
        @(posedge clk);
        load_done <= 1;
        @(posedge clk);
        load_done <= 0;
        @(posedge clk);
        #1;
        if (bank_a_state != 2) $error("  FAIL: bank A not READY (state=%0d)", bank_a_state);
        if (!comp_ready) $error("  FAIL: comp_ready not set");
        $display("  PASS: bank A loaded and ready");

        // ============================================================
        $display("=== Test 3: Read data from bank A ===");
        comp_bank_sel = 0;
        @(posedge clk);
        comp_start <= 1;
        @(posedge clk);
        comp_start <= 0;
        @(posedge clk); #1;
        if (bank_a_state != 3) $error("  FAIL: bank A not USING (state=%0d)", bank_a_state);
        rd_bank_sel = 0;
        rd_addr = 8'd0; #1;
        if (rd_data != 32'hAAAA_0000) $error("  FAIL: rd[0] = 0x%08h", rd_data);
        rd_addr = 8'd5; #1;
        if (rd_data != 32'hAAAA_0005) $error("  FAIL: rd[5] = 0x%08h", rd_data);
        rd_addr = 8'd15; #1;
        if (rd_data != 32'hAAAA_000F) $error("  FAIL: rd[15] = 0x%08h", rd_data);
        $display("  PASS: read data matches written values");

        // ============================================================
        $display("=== Test 4: Load bank B while bank A is being used ===");
        load_bank_sel = 1;
        @(posedge clk);
        load_start <= 1;
        @(posedge clk);
        load_start <= 0;
        @(posedge clk); #1;
        if (bank_b_state != 1) $error("  FAIL: bank B not LOADING (state=%0d)", bank_b_state);
        fill_bank(1, 32'hBBBB_0000, 8);
        @(posedge clk);
        load_done <= 1;
        @(posedge clk);
        load_done <= 0;
        @(posedge clk); #1;
        if (bank_b_state != 2) $error("  FAIL: bank B not READY (state=%0d)", bank_b_state);
        $display("  PASS: bank B loaded while bank A still USING");

        // ============================================================
        $display("=== Test 5: Finish compute on A, start compute on B ===");
        @(posedge clk);
        comp_done <= 1;
        @(posedge clk);
        comp_done <= 0;
        @(posedge clk); #1;
        if (bank_a_state != 0) $error("  FAIL: bank A not EMPTY (state=%0d)", bank_a_state);
        comp_bank_sel = 1;
        @(posedge clk);
        comp_start <= 1;
        @(posedge clk);
        comp_start <= 0;
        @(posedge clk); #1;
        if (bank_b_state != 3) $error("  FAIL: bank B not USING (state=%0d)", bank_b_state);
        rd_bank_sel = 1;
        rd_addr = 8'd0; #1;
        if (rd_data != 32'hBBBB_0000) $error("  FAIL: bank B rd[0] = 0x%08h", rd_data);
        rd_addr = 8'd7; #1;
        if (rd_data != 32'hBBBB_0007) $error("  FAIL: bank B rd[7] = 0x%08h", rd_data);
        @(posedge clk);
        comp_done <= 1;
        @(posedge clk);
        comp_done <= 0;
        @(posedge clk); #1;
        if (bank_b_state != 0) $error("  FAIL: bank B not EMPTY (state=%0d)", bank_b_state);
        $display("  PASS: ping-pong buffer working correctly");

        // ============================================================
        $display("=== Test 6: Reload bank A after emptied ===");
        if (!load_ready) $error("  FAIL: load_ready not set");
        load_bank_sel = 0;
        @(posedge clk);
        load_start <= 1;
        @(posedge clk);
        load_start <= 0;
        @(posedge clk); #1;
        fill_bank(0, 32'hCCCC_0000, 4);
        @(posedge clk);
        load_done <= 1;
        @(posedge clk);
        load_done <= 0;
        @(posedge clk); #1;
        if (bank_a_state != 2) $error("  FAIL: bank A reload failed (state=%0d)", bank_a_state);
        comp_bank_sel = 0;
        @(posedge clk);
        comp_start <= 1;
        @(posedge clk);
        comp_start <= 0;
        @(posedge clk); #1;
        rd_bank_sel = 0;
        rd_addr = 8'd3; #1;
        if (rd_data != 32'hCCCC_0003) $error("  FAIL: reloaded data mismatch");
        @(posedge clk);
        comp_done <= 1;
        @(posedge clk);
        comp_done <= 0;
        @(posedge clk);
        $display("  PASS: bank reload works");

        $display("=== All tests complete ===");
        #20;
        $finish;
    end

endmodule
