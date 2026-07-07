// axi_ram: 简单 AXI-Lite RAM，用于程序/数据存储
`timescale 1ns / 1ps

module axi_ram #(
    parameter AXI_ADDR_W = 32,
    parameter AXI_DATA_W = 32,
    parameter RAM_DEPTH   = 4096  // 16 KB
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI-Lite 从设备
    input  wire                        s_axi_awvalid,
    output wire                        s_axi_awready,
    input  wire [AXI_ADDR_W-1:0]       s_axi_awaddr,
    input  wire                        s_axi_wvalid,
    output wire                        s_axi_wready,
    input  wire [AXI_DATA_W-1:0]       s_axi_wdata,
    input  wire [3:0]                  s_axi_wstrb,
    output wire                        s_axi_bvalid,
    input  wire                        s_axi_bready,
    output wire [1:0]                  s_axi_bresp,
    input  wire                        s_axi_arvalid,
    output wire                        s_axi_arready,
    input  wire [AXI_ADDR_W-1:0]       s_axi_araddr,
    output wire                        s_axi_rvalid,
    input  wire                        s_axi_rready,
    output wire [AXI_DATA_W-1:0]       s_axi_rdata,
    output wire [1:0]                  s_axi_rresp
);

    reg [AXI_DATA_W-1:0] ram [0:RAM_DEPTH-1];

    // 写路径
    reg         aw_stored;
    reg  [31:0] aw_addr;
    reg         w_stored;
    reg  [31:0] w_data;
    reg  [3:0]  w_strb;

    wire wh = aw_stored && w_stored;

    assign s_axi_awready = !aw_stored;
    assign s_axi_wready  = !w_stored;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_stored <= 0;
            w_stored  <= 0;
        end else begin
            if (s_axi_awvalid && s_axi_awready)
                {aw_stored, aw_addr} <= {1'b1, s_axi_awaddr};
            else if (wh)
                aw_stored <= 0;

            if (s_axi_wvalid && s_axi_wready)
                {w_stored, w_data, w_strb} <= {1'b1, s_axi_wdata, s_axi_wstrb};
            else if (wh)
                w_stored <= 0;
        end
    end

    always @(posedge clk) begin
        if (wh) begin
            if (w_strb[0]) ram[aw_addr[13:2]][ 7: 0] <= w_data[ 7: 0];
            if (w_strb[1]) ram[aw_addr[13:2]][15: 8] <= w_data[15: 8];
            if (w_strb[2]) ram[aw_addr[13:2]][23:16] <= w_data[23:16];
            if (w_strb[3]) ram[aw_addr[13:2]][31:24] <= w_data[31:24];
        end
    end

    reg bvalid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bvalid <= 0;
        else if (wh)
            bvalid <= 1;
        else if (s_axi_bready)
            bvalid <= 0;
    end
    assign s_axi_bvalid = bvalid;
    assign s_axi_bresp  = 2'b00;

    // 读路径
    reg         ar_stored;
    reg  [31:0] ar_addr;
    reg         rvalid;
    reg  [31:0] rdata_r;

    assign s_axi_arready = !ar_stored;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_stored <= 0;
            rvalid    <= 0;
        end else begin
            if (s_axi_arvalid && s_axi_arready)
                {ar_stored, ar_addr} <= {1'b1, s_axi_araddr};
            else if (rvalid && s_axi_rready)
                ar_stored <= 0;

            if (ar_stored && !rvalid) begin
                rvalid  <= 1;
                rdata_r <= ram[ar_addr[13:2]];
            end else if (rvalid && s_axi_rready)
                rvalid <= 0;
        end
    end

    assign s_axi_rvalid = rvalid;
    assign s_axi_rdata  = rdata_r;
    assign s_axi_rresp  = 2'b00;

endmodule
