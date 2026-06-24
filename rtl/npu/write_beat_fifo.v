// write_beat_fifo.v — 256-bit Write Beat FIFO
// Combinational read: rd_data always shows front of queue when not empty.
// Used between store_packer (producer) and dma_axi_writer (consumer).
`timescale 1ns / 1ps

module write_beat_fifo #(parameter DEPTH = 16) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [255:0] wr_data,
    input  wire [31:0]  wr_strb,
    input  wire         wr_last,
    input  wire         wr_en,
    output wire         wr_full,
    output wire [255:0] rd_data,
    output wire [31:0]  rd_strb,
    output wire         rd_last,
    output wire         rd_valid,
    input  wire         rd_en,
    output wire         rd_empty,
    output wire [4:0]   rd_level
);
    localparam AW = 5;
    reg [255:0] mem_d [0:DEPTH-1];
    reg [31:0]  mem_s [0:DEPTH-1];
    reg         mem_l [0:DEPTH-1];
    reg [AW-1:0] wp, rp;
    reg [AW:0]   cnt;

    wire wok = wr_en && !wr_full;
    wire rok = rd_en && rd_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wp <= 0; else if (wok) wp <= wp + 1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rp <= 0; else if (rok) rp <= rp + 1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt <= 0;
        else case ({wok, rok})
            2'b10: cnt <= cnt + 1;
            2'b01: cnt <= cnt - 1;
        endcase
    end
    always @(posedge clk) if (wok) begin
        mem_d[wp[AW-2:0]] <= wr_data;
        mem_s[wp[AW-2:0]] <= wr_strb;
        mem_l[wp[AW-2:0]] <= wr_last;
    end

    assign wr_full  = (cnt == DEPTH);
    assign rd_empty = (cnt == 0);
    assign rd_valid = !rd_empty;
    assign rd_level = cnt[4:0];
    assign rd_data  = mem_d[rp[AW-2:0]];
    assign rd_strb  = mem_s[rp[AW-2:0]];
    assign rd_last  = mem_l[rp[AW-2:0]];
endmodule
