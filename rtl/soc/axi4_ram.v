// axi4_ram: AXI4-capable RAM for DMA burst read/write
// Supports INCR bursts up to 256 beats, 32-bit data width
`timescale 1ns / 1ps

module axi4_ram #(
    parameter AXI_ADDR_W = 32,
    parameter AXI_DATA_W = 32,
    parameter RAM_DEPTH   = 16384  // 64 KB
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4 Write Address
    input  wire                        s_axi_awvalid,
    output wire                        s_axi_awready,
    input  wire [AXI_ADDR_W-1:0]       s_axi_awaddr,
    input  wire [7:0]                  s_axi_awlen,
    input  wire [2:0]                  s_axi_awsize,
    input  wire [1:0]                  s_axi_awburst,

    // AXI4 Write Data
    input  wire                        s_axi_wvalid,
    output wire                        s_axi_wready,
    input  wire [AXI_DATA_W-1:0]       s_axi_wdata,
    input  wire [3:0]                  s_axi_wstrb,
    input  wire                        s_axi_wlast,

    // AXI4 Write Response
    output wire                        s_axi_bvalid,
    input  wire                        s_axi_bready,
    output wire [1:0]                  s_axi_bresp,

    // AXI4 Read Address
    input  wire                        s_axi_arvalid,
    output wire                        s_axi_arready,
    input  wire [AXI_ADDR_W-1:0]       s_axi_araddr,
    input  wire [7:0]                  s_axi_arlen,
    input  wire [2:0]                  s_axi_arsize,
    input  wire [1:0]                  s_axi_arburst,

    // AXI4 Read Data
    output wire                        s_axi_rvalid,
    input  wire                        s_axi_rready,
    output wire [AXI_DATA_W-1:0]       s_axi_rdata,
    output wire                        s_axi_rlast,
    output wire [1:0]                  s_axi_rresp
);

    localparam BYTES_PER_BEAT = AXI_DATA_W / 8;
    localparam ADDR_BITS = $clog2(RAM_DEPTH);  // word address bits

    reg [AXI_DATA_W-1:0] ram [0:RAM_DEPTH-1];

    // ============================================================
    // Write path
    // ============================================================
    reg         aw_valid_r;
    reg  [31:0] aw_addr_r;
    reg  [7:0]  aw_len_r;
    reg  [7:0]  w_beat_cnt;
    reg         w_active;

    wire w_hs = s_axi_wvalid && s_axi_wready;

    assign s_axi_awready = !aw_valid_r && !w_active;
    assign s_axi_wready  = w_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_valid_r <= 1'b0;
            w_active   <= 1'b0;
            w_beat_cnt <= 8'h0;
        end else begin
            // Latch AW
            if (s_axi_awvalid && s_axi_awready) begin
                aw_valid_r <= 1'b1;
                aw_addr_r  <= s_axi_awaddr;
                aw_len_r   <= s_axi_awlen;
                w_beat_cnt <= 8'h0;
                w_active   <= 1'b1;
            end

            // Write data beats
            if (w_hs) begin
                // Write to RAM
                if (s_axi_wstrb[0]) ram[aw_addr_r[ADDR_BITS+1:2] + w_beat_cnt][ 7: 0] <= s_axi_wdata[ 7: 0];
                if (s_axi_wstrb[1]) ram[aw_addr_r[ADDR_BITS+1:2] + w_beat_cnt][15: 8] <= s_axi_wdata[15: 8];
                if (s_axi_wstrb[2]) ram[aw_addr_r[ADDR_BITS+1:2] + w_beat_cnt][23:16] <= s_axi_wdata[23:16];
                if (s_axi_wstrb[3]) ram[aw_addr_r[ADDR_BITS+1:2] + w_beat_cnt][31:24] <= s_axi_wdata[31:24];

                if (s_axi_wlast || w_beat_cnt == aw_len_r) begin
                    w_active   <= 1'b0;
                    aw_valid_r <= 1'b0;
                end else begin
                    w_beat_cnt <= w_beat_cnt + 8'h1;
                end
            end
        end
    end

    // BVALID: asserted after last write beat (when w_active drops)
    reg bvalid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bvalid <= 1'b0;
        end else if (w_hs && (s_axi_wlast || w_beat_cnt == aw_len_r)) begin
            bvalid <= 1'b1;
        end else if (s_axi_bready) begin
            bvalid <= 1'b0;
        end
    end
    assign s_axi_bvalid = bvalid;
    assign s_axi_bresp  = 2'b00;

    // ============================================================
    // Read path
    // ============================================================
    reg         ar_valid_r;
    reg  [31:0] ar_addr_r;
    reg  [7:0]  ar_len_r;
    reg  [7:0]  r_beat_cnt;
    reg         r_active;

    assign s_axi_arready = !ar_valid_r && !r_active;

    wire r_hs = s_axi_rvalid && s_axi_rready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_valid_r  <= 1'b0;
            r_active    <= 1'b0;
            r_beat_cnt  <= 8'h0;
        end else begin
            // Latch AR
            if (s_axi_arvalid && s_axi_arready) begin
                ar_valid_r <= 1'b1;
                ar_addr_r  <= s_axi_araddr;
                ar_len_r   <= s_axi_arlen;
                r_beat_cnt <= 8'h0;
                r_active   <= 1'b1;
            end

            // Read data handshake
            if (r_hs) begin
                if (r_beat_cnt == ar_len_r) begin
                    r_active   <= 1'b0;
                    ar_valid_r <= 1'b0;
                end else begin
                    r_beat_cnt <= r_beat_cnt + 8'h1;
                end
            end
        end
    end

    // RVALID: asserted while active (data available next cycle after AR)
    reg rvalid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rvalid <= 1'b0;
        end else if (s_axi_arvalid && s_axi_arready) begin
            rvalid <= 1'b1;
        end else if (r_hs && (r_beat_cnt == ar_len_r)) begin
            rvalid <= 1'b0;
        end
    end

    assign s_axi_rvalid = rvalid;

    // Pre-compute next read address (use incoming AR during handshake, latched + incremented otherwise)
    wire        ar_hs_sig = s_axi_arvalid && s_axi_arready;
    wire [31:0] rd_base   = ar_hs_sig ? s_axi_araddr : ar_addr_r;
    wire [7:0]  rd_beat   = ar_hs_sig ? 8'h0 :
                            (r_hs ? (r_beat_cnt + 8'h1) : r_beat_cnt);

    // Read data (registered)
    reg [AXI_DATA_W-1:0] rdata_r;
    always @(posedge clk) begin
        if (r_active || ar_hs_sig) begin
            rdata_r <= ram[rd_base[ADDR_BITS+1:2] + rd_beat];
        end
    end
    assign s_axi_rdata = rdata_r;
    assign s_axi_rlast = (r_beat_cnt == ar_len_r);
    assign s_axi_rresp = 2'b00;

endmodule
