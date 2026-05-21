// shared_ram: unified memory with CPU AXI-Lite port + NPU AXI4 DMA port
// Both ports access the same physical memory array. CPU gets priority.
`timescale 1ns / 1ps

module shared_ram #(
    parameter AXI_ADDR_W = 32,
    parameter AXI_DATA_W = 32,
    parameter RAM_DEPTH   = 16384  // 64 KB
) (
    input  wire        clk,
    input  wire        rst_n,

    // === CPU AXI-Lite port ===
    input  wire                        cpu_awvalid,
    output wire                        cpu_awready,
    input  wire [AXI_ADDR_W-1:0]       cpu_awaddr,
    input  wire                        cpu_wvalid,
    output wire                        cpu_wready,
    input  wire [AXI_DATA_W-1:0]       cpu_wdata,
    input  wire [3:0]                  cpu_wstrb,
    output wire                        cpu_bvalid,
    input  wire                        cpu_bready,
    output wire [1:0]                  cpu_bresp,
    input  wire                        cpu_arvalid,
    output wire                        cpu_arready,
    input  wire [AXI_ADDR_W-1:0]       cpu_araddr,
    output wire                        cpu_rvalid,
    input  wire                        cpu_rready,
    output wire [AXI_DATA_W-1:0]       cpu_rdata,
    output wire [1:0]                  cpu_rresp,

    // === NPU DMA AXI4 port ===
    input  wire                        npu_awvalid,
    output wire                        npu_awready,
    input  wire [AXI_ADDR_W-1:0]       npu_awaddr,
    input  wire [7:0]                  npu_awlen,
    input  wire [2:0]                  npu_awsize,
    input  wire [1:0]                  npu_awburst,
    input  wire                        npu_wvalid,
    output wire                        npu_wready,
    input  wire [AXI_DATA_W-1:0]       npu_wdata,
    input  wire                        npu_wlast,
    input  wire [3:0]                  npu_wstrb,
    output wire                        npu_bvalid,
    input  wire                        npu_bready,
    output wire [1:0]                  npu_bresp,
    input  wire                        npu_arvalid,
    output wire                        npu_arready,
    input  wire [AXI_ADDR_W-1:0]       npu_araddr,
    input  wire [7:0]                  npu_arlen,
    input  wire [2:0]                  npu_arsize,
    input  wire [1:0]                  npu_arburst,
    output wire                        npu_rvalid,
    input  wire                        npu_rready,
    output wire [AXI_DATA_W-1:0]       npu_rdata,
    output wire                        npu_rlast,
    output wire [1:0]                  npu_rresp
);

    localparam ADDR_BITS = $clog2(RAM_DEPTH);

    // Shared memory array
    reg [AXI_DATA_W-1:0] ram [0:RAM_DEPTH-1];

    // ============================================================
    // Arbitration: CPU priority over NPU (per-transaction)
    // CPU write path
    // ============================================================
    reg         cpu_aw_valid_r;
    reg  [31:0] cpu_aw_addr_r;

    wire cpu_aw_hs = cpu_awvalid && cpu_awready;
    wire cpu_w_hs  = cpu_wvalid  && cpu_wready;

    // CPU write: single cycle AW+W (AXI-Lite is non-burst)
    assign cpu_awready = !cpu_aw_valid_r;
    assign cpu_wready  = cpu_aw_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_aw_valid_r <= 1'b0;
        end else begin
            if (cpu_aw_hs) begin
                cpu_aw_valid_r <= 1'b1;
                cpu_aw_addr_r  <= cpu_awaddr;
            end else if (cpu_w_hs) begin
                cpu_aw_valid_r <= 1'b0;
            end
            // CPU write to shared RAM
            if (cpu_w_hs) begin
                if (cpu_wstrb[0]) ram[cpu_aw_addr_r[ADDR_BITS+1:2]][ 7: 0] <= cpu_wdata[ 7: 0];
                if (cpu_wstrb[1]) ram[cpu_aw_addr_r[ADDR_BITS+1:2]][15: 8] <= cpu_wdata[15: 8];
                if (cpu_wstrb[2]) ram[cpu_aw_addr_r[ADDR_BITS+1:2]][23:16] <= cpu_wdata[23:16];
                if (cpu_wstrb[3]) ram[cpu_aw_addr_r[ADDR_BITS+1:2]][31:24] <= cpu_wdata[31:24];
            end
        end
    end

    // CPU B response
    reg cpu_bvalid_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cpu_bvalid_r <= 1'b0;
        else if (cpu_w_hs)
            cpu_bvalid_r <= 1'b1;
        else if (cpu_bready)
            cpu_bvalid_r <= 1'b0;
    end
    assign cpu_bvalid = cpu_bvalid_r;
    assign cpu_bresp  = 2'b00;

    // CPU read
    reg         cpu_ar_valid_r;
    reg  [31:0] cpu_ar_addr_r;
    reg         cpu_rvalid_r;
    reg  [31:0] cpu_rdata_r;

    wire cpu_ar_hs = cpu_arvalid && cpu_arready;
    assign cpu_arready = !cpu_ar_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_ar_valid_r <= 1'b0;
            cpu_rvalid_r   <= 1'b0;
        end else begin
            if (cpu_ar_hs) begin
                cpu_ar_valid_r <= 1'b1;
                cpu_ar_addr_r  <= cpu_araddr;
                cpu_rdata_r    <= ram[cpu_araddr[ADDR_BITS+1:2]];
                cpu_rvalid_r   <= 1'b1;
            end else begin
                cpu_ar_valid_r <= 1'b0;
                if (cpu_rready)
                    cpu_rvalid_r <= 1'b0;
            end
        end
    end
    assign cpu_rvalid = cpu_rvalid_r;
    assign cpu_rdata  = cpu_rdata_r;
    assign cpu_rresp  = 2'b00;

    // ============================================================
    // NPU DMA write path (burst-capable, same as axi4_ram)
    // ============================================================
    reg         npu_aw_valid_r;
    reg  [31:0] npu_aw_addr_r;
    reg  [7:0]  npu_aw_len_r;
    reg  [7:0]  npu_w_beat_cnt;
    reg         npu_w_active;

    wire npu_w_hs = npu_wvalid && npu_wready;

    assign npu_awready = !npu_aw_valid_r && !npu_w_active;
    assign npu_wready  = npu_w_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_aw_valid_r <= 1'b0;
            npu_w_active   <= 1'b0;
            npu_w_beat_cnt <= 8'h0;
        end else begin
            if (npu_awvalid && npu_awready) begin
                npu_aw_valid_r <= 1'b1;
                npu_aw_addr_r  <= npu_awaddr;
                npu_aw_len_r   <= npu_awlen;
                npu_w_beat_cnt <= 8'h0;
                npu_w_active   <= 1'b1;
            end
            if (npu_w_hs) begin
                if (npu_wstrb[0]) ram[npu_aw_addr_r[ADDR_BITS+1:2] + npu_w_beat_cnt][ 7: 0] <= npu_wdata[ 7: 0];
                if (npu_wstrb[1]) ram[npu_aw_addr_r[ADDR_BITS+1:2] + npu_w_beat_cnt][15: 8] <= npu_wdata[15: 8];
                if (npu_wstrb[2]) ram[npu_aw_addr_r[ADDR_BITS+1:2] + npu_w_beat_cnt][23:16] <= npu_wdata[23:16];
                if (npu_wstrb[3]) ram[npu_aw_addr_r[ADDR_BITS+1:2] + npu_w_beat_cnt][31:24] <= npu_wdata[31:24];
                if (npu_wlast || npu_w_beat_cnt == npu_aw_len_r) begin
                    npu_w_active   <= 1'b0;
                    npu_aw_valid_r <= 1'b0;
                end else begin
                    npu_w_beat_cnt <= npu_w_beat_cnt + 8'h1;
                end
            end
        end
    end

    reg npu_bvalid_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            npu_bvalid_r <= 1'b0;
        else if (npu_w_hs && (npu_wlast || npu_w_beat_cnt == npu_aw_len_r))
            npu_bvalid_r <= 1'b1;
        else if (npu_bready)
            npu_bvalid_r <= 1'b0;
    end
    assign npu_bvalid = npu_bvalid_r;
    assign npu_bresp  = 2'b00;

    // NPU read path
    reg         npu_ar_valid_r;
    reg  [31:0] npu_ar_addr_r;
    reg  [7:0]  npu_ar_len_r;
    reg  [7:0]  npu_r_beat_cnt;
    reg         npu_r_active;
    reg         npu_rvalid_r;
    reg  [31:0] npu_rdata_r;

    wire npu_ar_hs = npu_arvalid && npu_arready;
    wire npu_r_hs  = npu_rvalid && npu_rready;

    assign npu_arready = !npu_ar_valid_r && !npu_r_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_ar_valid_r  <= 1'b0;
            npu_r_active    <= 1'b0;
            npu_r_beat_cnt  <= 8'h0;
            npu_rvalid_r    <= 1'b0;
        end else begin
            if (npu_ar_hs) begin
                npu_ar_valid_r <= 1'b1;
                npu_ar_addr_r  <= npu_araddr;
                npu_ar_len_r   <= npu_arlen;
                npu_r_beat_cnt <= 8'h0;
                npu_r_active   <= 1'b1;
            end
            // Read data available next cycle
            if (npu_r_active || npu_ar_hs) begin
                npu_rvalid_r <= 1'b1;
                npu_rdata_r  <= ram[((npu_ar_hs ? npu_araddr : npu_ar_addr_r) >> 2) + npu_r_beat_cnt];
            end
            if (npu_r_hs) begin
                if (npu_r_beat_cnt == npu_ar_len_r) begin
                    npu_r_active   <= 1'b0;
                    npu_ar_valid_r <= 1'b0;
                    npu_rvalid_r   <= 1'b0;
                end else begin
                    npu_r_beat_cnt <= npu_r_beat_cnt + 8'h1;
                end
            end
        end
    end
    assign npu_rvalid = npu_rvalid_r;
    assign npu_rdata  = npu_rdata_r;
    assign npu_rlast  = (npu_r_beat_cnt == npu_ar_len_r);
    assign npu_rresp  = 2'b00;

endmodule
