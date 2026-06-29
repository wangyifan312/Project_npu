// shared_ram: unified 1MB memory with CPU AXI-Lite + NPU 256-bit AXI4 DMA ports
// CPU and NPU access the same physical 32768 x 256-bit beat array.
`timescale 1ns / 1ps

module shared_ram #(
    parameter AXI_ADDR_W     = 32,
    parameter CPU_AXI_DATA_W = 32,
    parameter NPU_AXI_DATA_W = 256,
    parameter RAM_DEPTH      = 32768   // 1 MB @ 512-bit beats
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
    localparam NPU_BEAT_BYTES = NPU_AXI_DATA_W / 8;
    localparam NPU_BEAT_ADDR_LSB = 5;
    localparam [2:0] AXI_SIZE_BEAT = 3'd5;
    localparam [1:0] AXI_RESP_OKAY = 2'b00;
    localparam [1:0] AXI_RESP_SLVERR = 2'b10;
    localparam [1:0] AXI_BURST_INCR = 2'b01;
    localparam integer MEM_BYTES = RAM_DEPTH * NPU_BEAT_BYTES;

    // Address split: beat_addr=addr[19:5], word_in_beat=addr[4:2]
    reg [NPU_AXI_DATA_W-1:0] ram [0:RAM_DEPTH-1];

    function [ADDR_BITS-1:0] beat_index;
        input [AXI_ADDR_W-1:0] addr;
        begin
            beat_index = addr[ADDR_BITS+4:5];
        end
    endfunction

    function npu_addr_aligned;
        input [AXI_ADDR_W-1:0] addr;
        begin
            npu_addr_aligned = (addr[4:0] == 5'b0);
        end
    endfunction

    function npu_burst_range_ok;
        input [AXI_ADDR_W-1:0] addr;
        input [7:0] len;
        reg [AXI_ADDR_W:0] last_byte_addr;
        reg [31:0] burst_bytes;
        begin
            burst_bytes = ({24'h0, len} + 32'h1) * NPU_BEAT_BYTES;
            last_byte_addr = {1'b0, addr} + burst_bytes - 1'b1;
            npu_burst_range_ok = npu_addr_aligned(addr) && (last_byte_addr < MEM_BYTES);
        end
    endfunction

    function npu_axi4_req_ok;
        input [AXI_ADDR_W-1:0] addr;
        input [7:0] len;
        input [2:0] size;
        input [1:0] burst;
        begin
            npu_axi4_req_ok = (burst == AXI_BURST_INCR) &&
                              (size == AXI_SIZE_BEAT) &&
                              npu_burst_range_ok(addr, len);
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
    reg                         cpu_aw_valid_r;
    reg  [AXI_ADDR_W-1:0]       cpu_aw_addr_r;
    reg                         cpu_w_valid_r;
    reg  [CPU_AXI_DATA_W-1:0]   cpu_w_data_r;
    reg  [3:0]                  cpu_w_strb_r;
    reg                         cpu_bvalid_r;
    reg  [1:0]                  cpu_bresp_r;

    wire cpu_aw_hs = cpu_awvalid && cpu_awready;
    wire cpu_w_hs  = cpu_wvalid  && cpu_wready;
    wire cpu_wr_fire = (cpu_aw_valid_r || cpu_aw_hs) && (cpu_w_valid_r || cpu_w_hs) && !cpu_bvalid_r;
    wire [AXI_ADDR_W-1:0]     cpu_wr_addr = cpu_aw_hs ? cpu_awaddr : cpu_aw_addr_r;
    wire [CPU_AXI_DATA_W-1:0] cpu_wr_data = cpu_w_hs  ? cpu_wdata  : cpu_w_data_r;
    wire [3:0]                cpu_wr_strb = cpu_w_hs  ? cpu_wstrb  : cpu_w_strb_r;

    assign cpu_awready = !cpu_aw_valid_r && !cpu_bvalid_r;
    assign cpu_wready  = !cpu_w_valid_r && !cpu_bvalid_r;

    integer cpu_byte_i;
    integer cpu_byte_lane;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_aw_valid_r <= 1'b0;
            cpu_aw_addr_r  <= {AXI_ADDR_W{1'b0}};
            cpu_w_valid_r  <= 1'b0;
            cpu_w_data_r   <= {CPU_AXI_DATA_W{1'b0}};
            cpu_w_strb_r   <= 4'h0;
        end else begin
            if (cpu_aw_hs) begin
                cpu_aw_valid_r <= 1'b1;
                cpu_aw_addr_r  <= cpu_awaddr;
            end
            if (cpu_w_hs) begin
                cpu_w_valid_r <= 1'b1;
                cpu_w_data_r  <= cpu_wdata;
                cpu_w_strb_r  <= cpu_wstrb;
            end

            if (cpu_wr_fire) begin
                cpu_aw_valid_r <= 1'b0;
                cpu_w_valid_r  <= 1'b0;
            end

            if (cpu_wr_fire) begin
                for (cpu_byte_i = 0; cpu_byte_i < 4; cpu_byte_i = cpu_byte_i + 1) begin
                    if (cpu_wr_strb[cpu_byte_i]) begin
                        cpu_byte_lane = ({29'h0, cpu_wr_addr[4:2]} << 2) + cpu_byte_i;
                        ram[beat_index(cpu_wr_addr)][cpu_byte_lane*8 +: 8] <= cpu_wr_data[cpu_byte_i*8 +: 8];
                    end
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_bvalid_r <= 1'b0;
            cpu_bresp_r  <= 2'b00;
        end else if (cpu_wr_fire) begin
            cpu_bvalid_r <= 1'b1;
            cpu_bresp_r  <= 2'b00;
        end else if (cpu_bvalid_r && cpu_bready) begin
            cpu_bvalid_r <= 1'b0;
        end
    end
    assign cpu_bvalid = cpu_bvalid_r;
    assign cpu_bresp  = cpu_bresp_r;

    // ============================================================
    // CPU AXI-Lite read path
    // ============================================================
    reg         cpu_rvalid_r;
    reg [CPU_AXI_DATA_W-1:0] cpu_rdata_r;
    reg [1:0]   cpu_rresp_r;

    wire cpu_ar_hs = cpu_arvalid && cpu_arready;
    assign cpu_arready = !cpu_rvalid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_rvalid_r <= 1'b0;
            cpu_rdata_r  <= {CPU_AXI_DATA_W{1'b0}};
            cpu_rresp_r  <= 2'b00;
        end else begin
            if (cpu_ar_hs) begin
                cpu_rdata_r  <= extract_cpu_word(ram[beat_index(cpu_araddr)], cpu_araddr[4:2]);
                cpu_rresp_r  <= 2'b00;
                cpu_rvalid_r <= 1'b1;
            end else if (cpu_rvalid_r && cpu_rready) begin
                cpu_rvalid_r <= 1'b0;
            end
        end
    end
    assign cpu_rvalid = cpu_rvalid_r;
    assign cpu_rdata  = cpu_rdata_r;
    assign cpu_rresp  = cpu_rresp_r;

    // ============================================================
    // NPU AXI4 write path
    // ============================================================
    reg         npu_aw_valid_r;
    reg  [AXI_ADDR_W-1:0] npu_aw_addr_r;
    reg  [7:0]  npu_aw_len_r;
    reg  [7:0]  npu_w_beat_cnt;
    reg         npu_w_active;
    reg         npu_wr_error_r;
    reg         npu_bvalid_r;
    reg  [1:0]  npu_bresp_r;

    wire npu_w_hs = npu_wvalid && npu_wready;
    wire npu_aw_hs = npu_awvalid && npu_awready;
    wire npu_wr_expected_last = (npu_w_beat_cnt == npu_aw_len_r);

    assign npu_awready = !npu_aw_valid_r && !npu_w_active && !npu_bvalid_r;
    assign npu_wready  = npu_w_active;

    integer npu_byte_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_aw_valid_r <= 1'b0;
            npu_aw_addr_r  <= {AXI_ADDR_W{1'b0}};
            npu_aw_len_r   <= 8'h0;
            npu_w_active   <= 1'b0;
            npu_w_beat_cnt <= 8'h0;
            npu_wr_error_r <= 1'b0;
        end else begin
            if (npu_aw_hs) begin
                npu_aw_valid_r <= 1'b1;
                npu_aw_addr_r  <= npu_awaddr;
                npu_aw_len_r   <= npu_awlen;
                npu_w_beat_cnt <= 8'h0;
                npu_w_active   <= 1'b1;
                npu_wr_error_r <= !npu_axi4_req_ok(npu_awaddr, npu_awlen, npu_awsize, npu_awburst);
            end
            if (npu_w_hs) begin
                if (!npu_wr_error_r && (npu_wlast == npu_wr_expected_last)) begin
                    for (npu_byte_i = 0; npu_byte_i < NPU_STRB_W; npu_byte_i = npu_byte_i + 1) begin
                        if (npu_wstrb[npu_byte_i]) begin
                            ram[beat_index(npu_aw_addr_r) + npu_w_beat_cnt][npu_byte_i*8 +: 8] <=
                                npu_wdata[npu_byte_i*8 +: 8];
                        end
                    end
                end
                if (npu_wlast != npu_wr_expected_last)
                    npu_wr_error_r <= 1'b1;
                if (npu_wr_expected_last) begin
                    npu_w_active   <= 1'b0;
                    npu_aw_valid_r <= 1'b0;
                end else begin
                    npu_w_beat_cnt <= npu_w_beat_cnt + 8'h1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_bvalid_r <= 1'b0;
            npu_bresp_r  <= AXI_RESP_OKAY;
        end else if (npu_w_hs && npu_wr_expected_last) begin
            npu_bvalid_r <= 1'b1;
            npu_bresp_r  <= (npu_wr_error_r || (npu_wlast != npu_wr_expected_last)) ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
        end else if (npu_bvalid_r && npu_bready) begin
            npu_bvalid_r <= 1'b0;
        end
    end
    assign npu_bvalid = npu_bvalid_r;
    assign npu_bresp  = npu_bresp_r;

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
    reg [1:0]   npu_rresp_r;
    reg         npu_rlast_r;
    reg         npu_rd_error_r;

    wire npu_ar_hs = npu_arvalid && npu_arready;
    wire npu_r_hs  = npu_rvalid && npu_rready;
    wire [7:0] npu_rd_next_beat = npu_r_beat_cnt + 8'h1;

    assign npu_arready = !npu_ar_valid_r && !npu_r_active && !npu_rvalid_r;

    task npu_load_read_beat;
        input [AXI_ADDR_W-1:0] base_addr;
        input [7:0] beat;
        input [7:0] len;
        input       has_error;
        begin
            npu_rdata_r <= has_error ? {NPU_AXI_DATA_W{1'b0}} : ram[beat_index(base_addr) + beat];
            npu_rresp_r <= has_error ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
            npu_rlast_r <= (beat == len);
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_ar_valid_r <= 1'b0;
            npu_ar_addr_r  <= {AXI_ADDR_W{1'b0}};
            npu_ar_len_r   <= 8'h0;
            npu_r_active   <= 1'b0;
            npu_r_beat_cnt <= 8'h0;
            npu_rd_error_r <= 1'b0;
        end else begin
            if (npu_ar_hs) begin
                npu_ar_valid_r <= 1'b1;
                npu_ar_addr_r  <= npu_araddr;
                npu_ar_len_r   <= npu_arlen;
                npu_r_beat_cnt <= 8'h0;
                npu_r_active   <= 1'b1;
                npu_rd_error_r <= !npu_axi4_req_ok(npu_araddr, npu_arlen, npu_arsize, npu_arburst);
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
            npu_rresp_r  <= AXI_RESP_OKAY;
            npu_rlast_r  <= 1'b0;
        end else if (npu_ar_hs) begin
            npu_rvalid_r <= 1'b1;
            npu_load_read_beat(npu_araddr, 8'h0, npu_arlen,
                               !npu_axi4_req_ok(npu_araddr, npu_arlen, npu_arsize, npu_arburst));
        end else begin
            if (npu_r_hs && (npu_r_beat_cnt == npu_ar_len_r))
                npu_rvalid_r <= 1'b0;
            else if (npu_r_hs && (npu_r_beat_cnt != npu_ar_len_r))
                npu_load_read_beat(npu_ar_addr_r, npu_rd_next_beat, npu_ar_len_r, npu_rd_error_r);
        end
    end

    assign npu_rvalid = npu_rvalid_r;
    assign npu_rdata  = npu_rdata_r;
    assign npu_rlast  = npu_rlast_r;
    assign npu_rresp  = npu_rresp_r;

endmodule
