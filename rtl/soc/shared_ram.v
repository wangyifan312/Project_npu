// shared_ram: unified 1MB memory with CPU AXI-Lite + NPU 256-bit AXI4 DMA ports
// CPU and NPU access the same physical 32768 x 256-bit beat array.
`timescale 1ns / 1ps

module shared_ram #(
    parameter AXI_ADDR_W     = 32,
    parameter CPU_AXI_DATA_W = 32,
    parameter NPU_AXI_DATA_W = 256,
    parameter RAM_DEPTH      = 32768   // 1 MB @ 256-bit beats
) (
    input  wire        clk,
    input  wire        rst_n,

    // === CPU AXI-Lite port (32-bit word lane in a 256-bit beat) ===
    input  wire                        cpu_awvalid,
    output wire                        cpu_awready,
    input  wire [AXI_ADDR_W-1:0]       cpu_awaddr,
    input  wire                        cpu_wvalid,
    output wire                        cpu_wready,
    input  wire [CPU_AXI_DATA_W-1:0]   cpu_wdata,
    input  wire [3:0]                  cpu_wstrb,
    output wire                        cpu_bvalid,
    input  wire                        cpu_bready,
    output wire [1:0]                  cpu_bresp,
    input  wire                        cpu_arvalid,
    output wire                        cpu_arready,
    input  wire [AXI_ADDR_W-1:0]       cpu_araddr,
    output wire                        cpu_rvalid,
    input  wire                        cpu_rready,
    output wire [CPU_AXI_DATA_W-1:0]   cpu_rdata,
    output wire [1:0]                  cpu_rresp,

    // === NPU DMA AXI4 port (256-bit beat) ===
    input  wire                        npu_awvalid,
    output wire                        npu_awready,
    input  wire [AXI_ADDR_W-1:0]       npu_awaddr,
    input  wire [7:0]                  npu_awlen,
    input  wire [2:0]                  npu_awsize,
    input  wire [1:0]                  npu_awburst,
    input  wire                        npu_wvalid,
    output wire                        npu_wready,
    input  wire [NPU_AXI_DATA_W-1:0]   npu_wdata,
    input  wire                        npu_wlast,
    input  wire [(NPU_AXI_DATA_W/8)-1:0] npu_wstrb,
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
    output wire [NPU_AXI_DATA_W-1:0]   npu_rdata,
    output wire                        npu_rlast,
    output wire [1:0]                  npu_rresp
);

    localparam NPU_STRB_W = NPU_AXI_DATA_W / 8;
    localparam ADDR_BITS  = $clog2(RAM_DEPTH);

    // Address split follows HB_256BIT_REFACTOR_SPEC.md:
    // beat_addr=addr[19:5], word_in_beat=addr[4:2], byte_in_word=addr[1:0].
    reg [NPU_AXI_DATA_W-1:0] ram [0:RAM_DEPTH-1];

    function [ADDR_BITS-1:0] beat_index;
        input [AXI_ADDR_W-1:0] addr;
        begin
            beat_index = addr[ADDR_BITS+4:5];
        end
    endfunction

    function [CPU_AXI_DATA_W-1:0] extract_cpu_word;
        input [NPU_AXI_DATA_W-1:0] beat;
        input [2:0] word_sel;
        begin
            case (word_sel)
                3'd0: extract_cpu_word = beat[ 31:  0];
                3'd1: extract_cpu_word = beat[ 63: 32];
                3'd2: extract_cpu_word = beat[ 95: 64];
                3'd3: extract_cpu_word = beat[127: 96];
                3'd4: extract_cpu_word = beat[159:128];
                3'd5: extract_cpu_word = beat[191:160];
                3'd6: extract_cpu_word = beat[223:192];
                default: extract_cpu_word = beat[255:224];
            endcase
        end
    endfunction

    // ============================================================
    // CPU AXI-Lite write path
    // ============================================================
    reg         cpu_aw_valid_r;
    reg  [AXI_ADDR_W-1:0] cpu_aw_addr_r;

    wire cpu_aw_hs = cpu_awvalid && cpu_awready;
    wire cpu_w_hs  = cpu_wvalid  && cpu_wready;

    assign cpu_awready = !cpu_aw_valid_r;
    assign cpu_wready  = cpu_aw_valid_r;

    integer cpu_byte_i;
    integer cpu_byte_lane;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_aw_valid_r <= 1'b0;
            cpu_aw_addr_r  <= {AXI_ADDR_W{1'b0}};
        end else begin
            if (cpu_aw_hs) begin
                cpu_aw_valid_r <= 1'b1;
                cpu_aw_addr_r  <= cpu_awaddr;
            end else if (cpu_w_hs) begin
                cpu_aw_valid_r <= 1'b0;
            end

            if (cpu_w_hs) begin
                for (cpu_byte_i = 0; cpu_byte_i < 4; cpu_byte_i = cpu_byte_i + 1) begin
                    if (cpu_wstrb[cpu_byte_i]) begin
                        cpu_byte_lane = ({29'h0, cpu_aw_addr_r[4:2]} << 2) + cpu_byte_i;
                        ram[beat_index(cpu_aw_addr_r)][cpu_byte_lane*8 +: 8] <= cpu_wdata[cpu_byte_i*8 +: 8];
                    end
                end
            end
        end
    end

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

    // ============================================================
    // CPU AXI-Lite read path
    // ============================================================
    reg         cpu_ar_valid_r;
    reg         cpu_rvalid_r;
    reg [CPU_AXI_DATA_W-1:0] cpu_rdata_r;

    wire cpu_ar_hs = cpu_arvalid && cpu_arready;
    assign cpu_arready = !cpu_ar_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_ar_valid_r <= 1'b0;
            cpu_rvalid_r   <= 1'b0;
            cpu_rdata_r    <= {CPU_AXI_DATA_W{1'b0}};
        end else begin
            if (cpu_ar_hs) begin
                cpu_ar_valid_r <= 1'b1;
                cpu_rdata_r    <= extract_cpu_word(ram[beat_index(cpu_araddr)], cpu_araddr[4:2]);
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
    // NPU AXI4 write path
    // ============================================================
    reg         npu_aw_valid_r;
    reg  [AXI_ADDR_W-1:0] npu_aw_addr_r;
    reg  [7:0]  npu_aw_len_r;
    reg  [7:0]  npu_w_beat_cnt;
    reg         npu_w_active;

    wire npu_w_hs = npu_wvalid && npu_wready;

    assign npu_awready = !npu_aw_valid_r && !npu_w_active;
    assign npu_wready  = npu_w_active;

    integer npu_byte_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_aw_valid_r <= 1'b0;
            npu_aw_addr_r  <= {AXI_ADDR_W{1'b0}};
            npu_aw_len_r   <= 8'h0;
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
                for (npu_byte_i = 0; npu_byte_i < NPU_STRB_W; npu_byte_i = npu_byte_i + 1) begin
                    if (npu_wstrb[npu_byte_i]) begin
                        ram[beat_index(npu_aw_addr_r) + npu_w_beat_cnt][npu_byte_i*8 +: 8] <=
                            npu_wdata[npu_byte_i*8 +: 8];
                    end
                end
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

    // ============================================================
    // NPU AXI4 read path
    // ============================================================
    reg         npu_ar_valid_r;
    reg  [AXI_ADDR_W-1:0] npu_ar_addr_r;
    reg  [7:0]  npu_ar_len_r;
    reg  [7:0]  npu_r_beat_cnt;
    reg         npu_r_active;
    reg         npu_rvalid_r;
    reg [NPU_AXI_DATA_W-1:0] npu_rdata_r;

    wire npu_ar_hs = npu_arvalid && npu_arready;
    wire npu_r_hs  = npu_rvalid && npu_rready;
    wire [AXI_ADDR_W-1:0] npu_rd_base = npu_ar_hs ? npu_araddr : npu_ar_addr_r;
    wire [7:0] npu_rd_beat = npu_ar_hs ? 8'h0 :
                              (npu_r_hs ? (npu_r_beat_cnt + 8'h1) : npu_r_beat_cnt);

    assign npu_arready = !npu_ar_valid_r && !npu_r_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_ar_valid_r <= 1'b0;
            npu_ar_addr_r  <= {AXI_ADDR_W{1'b0}};
            npu_ar_len_r   <= 8'h0;
            npu_r_active   <= 1'b0;
            npu_r_beat_cnt <= 8'h0;
        end else begin
            if (npu_ar_hs) begin
                npu_ar_valid_r <= 1'b1;
                npu_ar_addr_r  <= npu_araddr;
                npu_ar_len_r   <= npu_arlen;
                npu_r_beat_cnt <= 8'h0;
                npu_r_active   <= 1'b1;
            end

            if (npu_r_hs) begin
                if (npu_r_beat_cnt == npu_ar_len_r) begin
                    npu_r_active   <= 1'b0;
                    npu_ar_valid_r <= 1'b0;
                end else begin
                    npu_r_beat_cnt <= npu_r_beat_cnt + 8'h1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_rvalid_r <= 1'b0;
            npu_rdata_r  <= {NPU_AXI_DATA_W{1'b0}};
        end else if (npu_ar_hs) begin
            npu_rvalid_r <= 1'b1;
            npu_rdata_r  <= ram[beat_index(npu_araddr)];
        end else begin
            if (npu_r_hs && (npu_r_beat_cnt == npu_ar_len_r))
                npu_rvalid_r <= 1'b0;
            if (npu_r_active || (npu_r_hs && (npu_r_beat_cnt != npu_ar_len_r)))
                npu_rdata_r <= ram[beat_index(npu_rd_base) + npu_rd_beat];
        end
    end

    assign npu_rvalid = npu_rvalid_r;
    assign npu_rdata  = npu_rdata_r;
    assign npu_rlast  = (npu_r_beat_cnt == npu_ar_len_r);
    assign npu_rresp  = 2'b00;

endmodule
