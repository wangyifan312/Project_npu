// npu_buffer: generic double-buffer with bank state machine
// Two banks (A/B) support load/compute overlap via ping-pong
// DMA writes via addr/data/wr_en; compute reads via addr → data
`timescale 1ns / 1ps

module npu_buffer #(
    parameter DATA_WIDTH  = 32,
    parameter ENTRIES     = 256,   // entries per bank
    parameter ADDR_WIDTH  = 8      // log2(ENTRIES)
) (
    input  wire        clk,
    input  wire        rst_n,

    // === DMA write port ===
    input  wire [ADDR_WIDTH-1:0]   wr_addr,
    input  wire [DATA_WIDTH-1:0]   wr_data,
    input  wire                    wr_en,
    input  wire                    wr_bank_sel,  // 0=bank A, 1=bank B

    // === Compute read port (combinational read) ===
    input  wire [ADDR_WIDTH-1:0]   rd_addr,
    output wire [DATA_WIDTH-1:0]   rd_data,
    input  wire                    rd_bank_sel,  // 0=bank A, 1=bank B

    // === Bank control ===
    input  wire                    load_start,    // pulse: begin loading selected bank
    input  wire                    load_done,     // pulse: loading finished
    input  wire                    comp_start,    // pulse: begin compute from selected bank
    input  wire                    comp_done,     // pulse: compute finished
    input  wire                    load_bank_sel, // which bank to load
    input  wire                    comp_bank_sel, // which bank to compute
    input  wire                    flush,         // pulse: reset both banks to EMPTY (error recovery)

    // === Bank status ===
    output wire                    load_ready,    // a bank is ready to receive load
    output wire                    comp_ready,    // a bank has data ready for compute
    output wire                    comp_active,   // compute is in progress
    output wire [1:0]              bank_a_state,  // for debug/status
    output wire [1:0]              bank_b_state
);

    // ============================================================
    // Bank states
    // ============================================================
    localparam B_EMPTY   = 2'd0;
    localparam B_LOADING = 2'd1;
    localparam B_READY   = 2'd2;
    localparam B_USING   = 2'd3;

    // ============================================================
    // Storage arrays (two banks)
    // ============================================================
    reg [DATA_WIDTH-1:0] bank_a [0:ENTRIES-1];
    reg [DATA_WIDTH-1:0] bank_b [0:ENTRIES-1];

    // ============================================================
    // Bank state registers
    // ============================================================
    reg [1:0] state_a, state_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_a <= B_EMPTY;
            state_b <= B_EMPTY;
        end else if (flush) begin
            // Error recovery: force both banks to EMPTY
            state_a <= B_EMPTY;
            state_b <= B_EMPTY;
        end else begin
            // Bank A state transitions
            case (state_a)
                B_EMPTY: begin
                    if (load_start && load_bank_sel == 1'b0)
                        state_a <= B_LOADING;
                end
                B_LOADING: begin
                    if (load_done && load_bank_sel == 1'b0)
                        state_a <= B_READY;
                end
                B_READY: begin
                    if (comp_start && comp_bank_sel == 1'b0)
                        state_a <= B_USING;
                end
                B_USING: begin
                    if (comp_done && comp_bank_sel == 1'b0)
                        state_a <= B_EMPTY;
                end
            endcase

            // Bank B state transitions
            case (state_b)
                B_EMPTY: begin
                    if (load_start && load_bank_sel == 1'b1)
                        state_b <= B_LOADING;
                end
                B_LOADING: begin
                    if (load_done && load_bank_sel == 1'b1)
                        state_b <= B_READY;
                end
                B_READY: begin
                    if (comp_start && comp_bank_sel == 1'b1)
                        state_b <= B_USING;
                end
                B_USING: begin
                    if (comp_done && comp_bank_sel == 1'b1)
                        state_b <= B_EMPTY;
                end
            endcase
        end
    end

    // ============================================================
    // DMA write
    // ============================================================
    always @(posedge clk) begin
        if (wr_en) begin
            if (wr_bank_sel == 1'b0)
                bank_a[wr_addr] <= wr_data;
            else
                bank_b[wr_addr] <= wr_data;
        end
    end

    // ============================================================
    // Compute read (combinational)
    // ============================================================
    reg [DATA_WIDTH-1:0] rd_data_r;

    always @(*) begin
        if (rd_bank_sel == 1'b0)
            rd_data_r = bank_a[rd_addr];
        else
            rd_data_r = bank_b[rd_addr];
    end

    assign rd_data = rd_data_r;

    // ============================================================
    // Status outputs
    // ============================================================
    // load_ready: at least one bank is empty (can accept load)
    assign load_ready = (state_a == B_EMPTY) || (state_b == B_EMPTY);

    // comp_ready: at least one bank is ready (has loaded data)
    assign comp_ready = (state_a == B_READY) || (state_b == B_READY);

    // comp_active: compute is in progress on at least one bank
    assign comp_active = (state_a == B_USING) || (state_b == B_USING);

    assign bank_a_state = state_a;
    assign bank_b_state = state_b;

endmodule
