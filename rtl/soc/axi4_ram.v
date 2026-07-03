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
    localparam [2:0] AXI_SIZE_BEAT = (AXI_DATA_W == 32)  ? 3'd2 :
                                     (AXI_DATA_W == 64)  ? 3'd3 :
                                     (AXI_DATA_W == 128) ? 3'd4 :
                                     (AXI_DATA_W == 256) ? 3'd5 : 3'd5;
    localparam [1:0] AXI_RESP_OKAY = 2'b00;
    localparam [1:0] AXI_RESP_SLVERR = 2'b10;
    localparam [1:0] AXI_BURST_INCR = 2'b01;
    localparam integer MEM_BYTES = RAM_DEPTH * BYTES_PER_BEAT;

    reg [AXI_DATA_W-1:0] ram [0:RAM_DEPTH-1];

    function [ADDR_BITS-1:0] beat_index;
        input [AXI_ADDR_W-1:0] addr;
        begin
            beat_index = addr[ADDR_BITS+BEAT_ADDR_LSB-1:BEAT_ADDR_LSB];
        end
    endfunction

    function addr_aligned;
        input [AXI_ADDR_W-1:0] addr;
        begin
            addr_aligned = (addr[BEAT_ADDR_LSB-1:0] == {BEAT_ADDR_LSB{1'b0}});
        end
    endfunction

    function burst_range_ok;
        input [AXI_ADDR_W-1:0] addr;
        input [7:0] len;
        reg [AXI_ADDR_W:0] last_byte_addr;
        reg [31:0] burst_bytes;
        begin
            burst_bytes = ({24'h0, len} + 32'h1) * BYTES_PER_BEAT;
            last_byte_addr = {1'b0, addr} + burst_bytes - 1'b1;
            burst_range_ok = addr_aligned(addr) && (last_byte_addr < MEM_BYTES);
        end
    endfunction

    function axi4_req_ok;
        input [AXI_ADDR_W-1:0] addr;
        input [7:0] len;
        input [2:0] size;
        input [1:0] burst;
        begin
            axi4_req_ok = (burst == AXI_BURST_INCR) &&
                          (size == AXI_SIZE_BEAT) &&
                          burst_range_ok(addr, len);
        end
    endfunction

    // ============================================================
    // 写 path
    // ============================================================
    reg         aw_valid_r;
    reg  [AXI_ADDR_W-1:0] aw_addr_r;
    reg  [7:0]  aw_len_r;
    reg  [7:0]  w_beat_cnt;
    reg         w_active;
    reg         wr_error_r;
    reg         bvalid;
    reg [1:0]   bresp_r;

    wire w_hs = s_axi_wvalid && s_axi_wready;
    wire aw_hs = s_axi_awvalid && s_axi_awready;
    wire wr_expected_last = (w_beat_cnt == aw_len_r);

    assign s_axi_awready = !aw_valid_r && !w_active && !bvalid;
    assign s_axi_wready  = w_active;

    integer byte_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_valid_r <= 1'b0;
            aw_addr_r  <= {AXI_ADDR_W{1'b0}};
            aw_len_r   <= 8'h0;
            w_active   <= 1'b0;
            w_beat_cnt <= 8'h0;
            wr_error_r <= 1'b0;
        end else begin
            if (aw_hs) begin
                aw_valid_r <= 1'b1;
                aw_addr_r  <= s_axi_awaddr;
                aw_len_r   <= s_axi_awlen;
                w_beat_cnt <= 8'h0;
                w_active   <= 1'b1;
                wr_error_r <= !axi4_req_ok(s_axi_awaddr, s_axi_awlen, s_axi_awsize, s_axi_awburst);
            end

            if (w_hs) begin
                if (!wr_error_r && (s_axi_wlast == wr_expected_last)) begin
                    for (byte_i = 0; byte_i < STRB_W; byte_i = byte_i + 1) begin
                        if (s_axi_wstrb[byte_i])
                            ram[beat_index(aw_addr_r) + w_beat_cnt][byte_i*8 +: 8] <= s_axi_wdata[byte_i*8 +: 8];
                    end
                end
                if (s_axi_wlast != wr_expected_last)
                    wr_error_r <= 1'b1;

                if (wr_expected_last) begin
                    w_active   <= 1'b0;
                    aw_valid_r <= 1'b0;
                end else begin
                    w_beat_cnt <= w_beat_cnt + 8'h1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bvalid <= 1'b0;
            bresp_r <= AXI_RESP_OKAY;
        end else if (w_hs && wr_expected_last) begin
            bvalid <= 1'b1;
            bresp_r <= (wr_error_r || (s_axi_wlast != wr_expected_last)) ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
        end else if (bvalid && s_axi_bready) begin
            bvalid <= 1'b0;
        end
    end
    assign s_axi_bvalid = bvalid;
    assign s_axi_bresp  = bresp_r;

    // ============================================================
    // 读 path
    // ============================================================
    reg         ar_valid_r;
    reg  [AXI_ADDR_W-1:0] ar_addr_r;
    reg  [7:0]  ar_len_r;
    reg  [7:0]  r_beat_cnt;
    reg         r_active;
    reg         rvalid;
    reg [AXI_DATA_W-1:0] rdata_r;
    reg [1:0]   rresp_r;
    reg         rlast_r;
    reg         rd_error_r;

    assign s_axi_arready = !ar_valid_r && !r_active && !rvalid;

    wire ar_hs = s_axi_arvalid && s_axi_arready;
    wire r_hs  = s_axi_rvalid && s_axi_rready;
    wire [7:0] rd_next_beat = r_beat_cnt + 8'h1;

    task load_read_beat;
        input [AXI_ADDR_W-1:0] base_addr;
        input [7:0] beat;
        input [7:0] len;
        input       has_error;
        begin
            rdata_r <= has_error ? {AXI_DATA_W{1'b0}} : ram[beat_index(base_addr) + beat];
            rresp_r <= has_error ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
            rlast_r <= (beat == len);
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_valid_r <= 1'b0;
            ar_addr_r  <= {AXI_ADDR_W{1'b0}};
            ar_len_r   <= 8'h0;
            r_active   <= 1'b0;
            r_beat_cnt <= 8'h0;
            rd_error_r <= 1'b0;
        end else begin
            if (ar_hs) begin
                ar_valid_r <= 1'b1;
                ar_addr_r  <= s_axi_araddr;
                ar_len_r   <= s_axi_arlen;
                r_beat_cnt <= 8'h0;
                r_active   <= 1'b1;
                rd_error_r <= !axi4_req_ok(s_axi_araddr, s_axi_arlen, s_axi_arsize, s_axi_arburst);
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
            rresp_r <= AXI_RESP_OKAY;
            rlast_r <= 1'b0;
        end else if (ar_hs) begin
            rvalid  <= 1'b1;
            load_read_beat(s_axi_araddr, 8'h0, s_axi_arlen,
                           !axi4_req_ok(s_axi_araddr, s_axi_arlen, s_axi_arsize, s_axi_arburst));
        end else begin
            if (r_hs && (r_beat_cnt == ar_len_r))
                rvalid <= 1'b0;
            else if (r_hs && (r_beat_cnt != ar_len_r))
                load_read_beat(ar_addr_r, rd_next_beat, ar_len_r, rd_error_r);
        end
    end

    assign s_axi_rvalid = rvalid;
    assign s_axi_rdata  = rdata_r;
    assign s_axi_rlast  = rlast_r;
    assign s_axi_rresp  = rresp_r;

endmodule
