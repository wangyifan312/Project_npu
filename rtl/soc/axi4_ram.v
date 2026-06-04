// axi4_ram: AXI4-capable RAM model for 256-bit DMA burst read/write
// Supports INCR bursts; ARLEN/AWLEN count 256-bit beats.
`timescale 1ns / 1ps

module axi4_ram #(
    parameter AXI_ADDR_W = 32,
    parameter AXI_DATA_W = 256,
    parameter RAM_DEPTH  = 32768   // 1 MB @ 256-bit beats
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
    input  wire [(AXI_DATA_W/8)-1:0]   s_axi_wstrb,
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
    localparam STRB_W         = AXI_DATA_W / 8;
    localparam ADDR_BITS      = $clog2(RAM_DEPTH);
    localparam BEAT_ADDR_LSB  = (AXI_DATA_W == 32)  ? 2 :
                                (AXI_DATA_W == 64)  ? 3 :
                                (AXI_DATA_W == 128) ? 4 :
                                (AXI_DATA_W == 256) ? 5 : 5;

    reg [AXI_DATA_W-1:0] ram [0:RAM_DEPTH-1];

    function [ADDR_BITS-1:0] beat_index;
        input [AXI_ADDR_W-1:0] addr;
        begin
            beat_index = addr[ADDR_BITS+BEAT_ADDR_LSB-1:BEAT_ADDR_LSB];
        end
    endfunction

    // ============================================================
    // Write path
    // ============================================================
    reg         aw_valid_r;
    reg  [AXI_ADDR_W-1:0] aw_addr_r;
    reg  [7:0]  aw_len_r;
    reg  [7:0]  w_beat_cnt;
    reg         w_active;

    wire w_hs = s_axi_wvalid && s_axi_wready;

    assign s_axi_awready = !aw_valid_r && !w_active;
    assign s_axi_wready  = w_active;

    integer byte_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_valid_r <= 1'b0;
            aw_addr_r  <= {AXI_ADDR_W{1'b0}};
            aw_len_r   <= 8'h0;
            w_active   <= 1'b0;
            w_beat_cnt <= 8'h0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_valid_r <= 1'b1;
                aw_addr_r  <= s_axi_awaddr;
                aw_len_r   <= s_axi_awlen;
                w_beat_cnt <= 8'h0;
                w_active   <= 1'b1;
            end

            if (w_hs) begin
                for (byte_i = 0; byte_i < STRB_W; byte_i = byte_i + 1) begin
                    if (s_axi_wstrb[byte_i])
                        ram[beat_index(aw_addr_r) + w_beat_cnt][byte_i*8 +: 8] <= s_axi_wdata[byte_i*8 +: 8];
                end

                if (s_axi_wlast || w_beat_cnt == aw_len_r) begin
                    w_active   <= 1'b0;
                    aw_valid_r <= 1'b0;
                end else begin
                    w_beat_cnt <= w_beat_cnt + 8'h1;
                end
            end
        end
    end

    reg bvalid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bvalid <= 1'b0;
        else if (w_hs && (s_axi_wlast || w_beat_cnt == aw_len_r))
            bvalid <= 1'b1;
        else if (s_axi_bready)
            bvalid <= 1'b0;
    end
    assign s_axi_bvalid = bvalid;
    assign s_axi_bresp  = 2'b00;

    // ============================================================
    // Read path
    // ============================================================
    reg         ar_valid_r;
    reg  [AXI_ADDR_W-1:0] ar_addr_r;
    reg  [7:0]  ar_len_r;
    reg  [7:0]  r_beat_cnt;
    reg         r_active;
    reg         rvalid;
    reg [AXI_DATA_W-1:0] rdata_r;

    assign s_axi_arready = !ar_valid_r && !r_active;

    wire ar_hs = s_axi_arvalid && s_axi_arready;
    wire r_hs  = s_axi_rvalid && s_axi_rready;
    wire [AXI_ADDR_W-1:0] rd_base = ar_hs ? s_axi_araddr : ar_addr_r;
    wire [7:0] rd_beat = ar_hs ? 8'h0 :
                         (r_hs ? (r_beat_cnt + 8'h1) : r_beat_cnt);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_valid_r <= 1'b0;
            ar_addr_r  <= {AXI_ADDR_W{1'b0}};
            ar_len_r   <= 8'h0;
            r_active   <= 1'b0;
            r_beat_cnt <= 8'h0;
        end else begin
            if (ar_hs) begin
                ar_valid_r <= 1'b1;
                ar_addr_r  <= s_axi_araddr;
                ar_len_r   <= s_axi_arlen;
                r_beat_cnt <= 8'h0;
                r_active   <= 1'b1;
            end

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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rvalid  <= 1'b0;
            rdata_r <= {AXI_DATA_W{1'b0}};
        end else if (ar_hs) begin
            rvalid  <= 1'b1;
            rdata_r <= ram[beat_index(s_axi_araddr)];
        end else begin
            if (r_hs && (r_beat_cnt == ar_len_r))
                rvalid <= 1'b0;
            if (r_active || (r_hs && (r_beat_cnt != ar_len_r)))
                rdata_r <= ram[beat_index(rd_base) + rd_beat];
        end
    end

    assign s_axi_rvalid = rvalid;
    assign s_axi_rdata  = rdata_r;
    assign s_axi_rlast  = (r_beat_cnt == ar_len_r);
    assign s_axi_rresp  = 2'b00;

endmodule
