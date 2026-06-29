#!/bin/bash
# migrate_512bit.sh — systematic 256→512 bit AXI data bus migration
set -e

echo "=== 512-bit AXI Migration ==="

# ── 1. Top-level parameters ────────────────────────────────────────
echo "1. Top-level parameters..."
sed -i 's/AXI_DMA_DATA_W = 256/AXI_DMA_DATA_W = 512/g' rtl/soc/top.v
sed -i 's/SHARED_RAM_DEPTH = 32768/SHARED_RAM_DEPTH = 16384/g' rtl/soc/top.v
sed -i 's/@ 256-bit beats/@ 512-bit beats/g' rtl/soc/top.v

sed -i 's/AXI_DMA_DATA_W = 256/AXI_DMA_DATA_W = 512/g' rtl/npu/npu_top.v
sed -i 's/BUF_DATA_W  = 256/BUF_DATA_W  = 512/g' rtl/npu/npu_top.v

sed -i 's/DMA_AXI_DATA_W  = 256/DMA_AXI_DATA_W  = 512/g' rtl/bus/axi_interconnect.v

# ── 2. npu_top internal constants ──────────────────────────────────
echo "2. npu_top internal constants..."
sed -i 's/HB_BEAT_BYTE_BITS = 5/HB_BEAT_BYTE_BITS = 6/g' rtl/npu/npu_top.v
sed -i 's/256-bit beat = 32 byte lanes/512-bit beat = 64 byte lanes/g' rtl/npu/npu_top.v

# ── 3. Beat address calculations (BUF_ADDR_W+4:5 → BUF_ADDR_W+5:6) ─
echo "3. Beat address calculations..."
sed -i 's/\[BUF_ADDR_W+4:5\]/[BUF_ADDR_W+5:6]/g' rtl/npu/npu_top.v

# ── 4. DMA address alignment (31:5→31:6, >>5→>>6) ────────────────
echo "4. DMA address alignment..."
sed -i 's/\[31:5\], 5'\''b0/[31:6], 6'\''b0/g' rtl/npu/npu_top.v
sed -i 's/>> 5), 5'\''b0/>> 6), 6'\''b0/g' rtl/npu/npu_top.v

# ── 5. Byte offset widths ([4:0]→[HB_BEAT_BYTE_BITS-1:0]) ────────
echo "5. Byte offset declarations..."
sed -i 's/reg  \[4:0\]  wgt_dma_byte_offset;/reg  [HB_BEAT_BYTE_BITS-1:0] wgt_dma_byte_offset;/g' rtl/npu/npu_top.v
sed -i 's/reg  \[4:0\]  wgt_preload_byte_offset;/reg  [HB_BEAT_BYTE_BITS-1:0] wgt_preload_byte_offset;/g' rtl/npu/npu_top.v
sed -i 's/reg \[4:0\]  fc_lane_byte_sel;/reg [HB_BEAT_BYTE_BITS-1:0] fc_lane_byte_sel;/g' rtl/npu/npu_top.v
sed -i 's/reg \[4:0\]  load_byte_sel;/reg [HB_BEAT_BYTE_BITS-1:0] load_byte_sel;/g' rtl/npu/npu_top.v
sed -i 's/reg \[4:0\]  sh_lane_byte_sel;/reg [HB_BEAT_BYTE_BITS-1:0] sh_lane_byte_sel;/g' rtl/npu/npu_top.v

# ── 6. Byte select indices [4:0]→[HB_BEAT_BYTE_BITS-1:0] ─────────
echo "6. Byte select indices..."
sed -i 's/idx\[4:0\]/idx[HB_BEAT_BYTE_BITS-1:0]/g' rtl/npu/npu_top.v
sed -i 's/ptr\[4:0\]/ptr[HB_BEAT_BYTE_BITS-1:0]/g' rtl/npu/npu_top.v
sed -i 's/base\[4:0\]/base[HB_BEAT_BYTE_BITS-1:0]/g' rtl/npu/npu_top.v

# ── 7. {27'd0 padding→{26'd0 (6-bit offset) ───────────────────────
echo "7. Padding widths..."
sed -i 's/{27'\''d0, wgt_dma_byte_offset}/{26'\''d0, wgt_dma_byte_offset}/g' rtl/npu/npu_top.v
sed -i 's/{27'\''d0, bias_dma_base/{26'\''d0, bias_dma_base/g' rtl/npu/npu_top.v
sed -i 's/{27'\''d0, conv_wgt_dma_base/{26'\''d0, conv_wgt_dma_base/g' rtl/npu/npu_top.v
sed -i 's/{27'\''d0, fc_wgt_dma_base/{26'\''d0, fc_wgt_dma_base/g' rtl/npu/npu_top.v
sed -i 's/{27'\''d0, conv_next_wgt_dma_base/{26'\''d0, conv_next_wgt_dma_base/g' rtl/npu/npu_top.v
sed -i 's/{27'\''d0, src1_addr/{26'\''d0, src1_addr/g' rtl/npu/npu_top.v

# ── 8. FSM_LOAD_ARRAY 32→64 byte lanes ────────────────────────────
echo "8. FSM_LOAD_ARRAY 32→64..."
sed -i 's/32'\''d32 - {27'\''d0, fc_weight_dma_byte_idx\[4:0\]}/32'\''d64 - {26'\''d0, fc_weight_dma_byte_idx[5:0]}/g' rtl/npu/npu_top.v
sed -i 's/32'\''d32 - {27'\''d0, fc_weight_dma_byte_idx\[5:0\]}/32'\''d64 - {26'\''d0, fc_weight_dma_byte_idx[5:0]}/g' rtl/npu/npu_top.v
sed -i 's/(fc_load_remaining > 32'\''d32) ? 32'\''d32/(fc_load_remaining > 32'\''d64) ? 32'\''d64/g' rtl/npu/npu_top.v
sed -i 's/for (fc_load_lane = 0; fc_load_lane < 32;/for (fc_load_lane = 0; fc_load_lane < 64;/g' rtl/npu/npu_top.v

# ── 9. Conv weight loading bytes_left_in_beat ──────────────────────
echo "9. Conv weight loading..."
sed -i 's/32'\''d32 - {27'\''d0, conv_weight_dma_byte_idx\[4:0\]}/32'\''d64 - {26'\''d0, conv_weight_dma_byte_idx[5:0]}/g' rtl/npu/npu_top.v
sed -i 's/conv_weight_dma_byte_idx\[4:0\] + load_count) >= 32'\''d32/conv_weight_dma_byte_idx[5:0] + load_count) >= 32'\''d64/g' rtl/npu/npu_top.v
sed -i 's/load_abs_idx\[4:0\]/load_abs_idx[HB_BEAT_BYTE_BITS-1:0]/g' rtl/npu/npu_top.v

# ── 10. Shadow weight loading ─────────────────────────────────────
echo "10. Shadow loading..."
sed -i 's/32'\''d32 - fc_shadow_dma_byte_idx\[4:0\]/32'\''d64 - fc_shadow_dma_byte_idx[5:0]/g' rtl/npu/npu_top.v
sed -i 's/fc_shadow_dma_byte_idx\[4:0\]/fc_shadow_dma_byte_idx[HB_BEAT_BYTE_BITS-1:0]/g' rtl/npu/npu_top.v
sed -i 's/sh_lane\[4:0\]/sh_lane[HB_BEAT_BYTE_BITS-1:0]/g' rtl/npu/npu_top.v

# ── 11. vec_relu: 32→64 lanes ─────────────────────────────────────
echo "11. vec_relu lanes..."
sed -i 's/wire \[255:0\] vec_relu_result/wire [BUF_DATA_W-1:0] vec_relu_result/g' rtl/npu/npu_top.v
sed -i 's/for (vl = 0; vl < 32; vl = vl + 1)/for (vl = 0; vl < VEC_RELU_LANES; vl = vl + 1)/g' rtl/npu/npu_top.v
sed -i 's/(blk_in_bytes + 32'\''d31) >> 5/(blk_in_bytes + 32'\''d63) >> 6/g' rtl/npu/npu_top.v

# Add VEC_RELU_LANES localparam before the genvar
sed -i '/genvar vl;/i\    localparam VEC_RELU_LANES = BUF_DATA_W / 8;' rtl/npu/npu_top.v

# ── 12. write_beat_fifo parameterization ───────────────────────────
echo "12. write_beat_fifo..."
cat > rtl/npu/write_beat_fifo.v << 'FIFOEOF'
// write_beat_fifo.v — Parameterized Write Beat FIFO
// Combinational read: rd_data always shows front of queue when not empty.
`timescale 1ns / 1ps

module write_beat_fifo #(
    parameter DEPTH      = 16,
    parameter DATA_WIDTH = 512
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire [(DATA_WIDTH/8)-1:0] wr_strb,
    input  wire         wr_last,
    input  wire         wr_en,
    output wire         wr_full,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire [(DATA_WIDTH/8)-1:0] rd_strb,
    output wire         rd_last,
    output wire         rd_valid,
    input  wire         rd_en,
    output wire         rd_empty,
    output wire [5:0]   rd_level
);
    localparam AW = 6;
    reg [DATA_WIDTH-1:0] mem_d [0:DEPTH-1];
    reg [(DATA_WIDTH/8)-1:0] mem_s [0:DEPTH-1];
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
    assign rd_level = cnt[5:0];
    assign rd_data  = mem_d[rp[AW-2:0]];
    assign rd_strb  = mem_s[rp[AW-2:0]];
    assign rd_last  = mem_l[rp[AW-2:0]];
endmodule
FIFOEOF

# Update instantiation in npu_top
sed -i 's/write_beat_fifo #(64) u_wfifo (/write_beat_fifo #(.DEPTH(64), .DATA_WIDTH(AXI_DMA_DATA_W)) u_wfifo (/g' rtl/npu/npu_top.v
sed -i 's/\.wr_strb({32{1'\''b1}})/.wr_strb({(AXI_DMA_DATA_W\/8){1'\''b1}})/g' rtl/npu/npu_top.v

# ── 13. DMA reader/writer BEAT_BYTES_LOG2 ─────────────────────────
echo "13. DMA reader/writer BEAT_BYTES_LOG2..."
for f in rtl/npu/dma_axi_reader.v rtl/npu/dma_axi_writer.v; do
  sed -i 's/(AXI_DATA_WIDTH == 256) ? 5 : 5;/(AXI_DATA_WIDTH == 256) ? 5 :\n                                 (AXI_DATA_WIDTH == 512) ? 6 : 6;/g' $f
done

# ── 14. shared_ram 512-bit upgrades ───────────────────────────────
echo "14. shared_ram..."
sed -i 's/NPU_AXI_DATA_W = 256/NPU_AXI_DATA_W = 512/g' rtl/soc/shared_ram.v
sed -i 's/RAM_DEPTH      = 32768/RAM_DEPTH      = 16384/g' rtl/soc/shared_ram.v
sed -i 's/@ 256-bit beats/@ 512-bit beats/g' rtl/soc/shared_ram.v
sed -i 's/NPU_BEAT_ADDR_LSB = 5/NPU_BEAT_ADDR_LSB = 6/g' rtl/soc/shared_ram.v
sed -i "s/AXI_SIZE_BEAT = 3'd5/AXI_SIZE_BEAT = 3'd6/g" rtl/soc/shared_ram.v
sed -i 's/addr\[ADDR_BITS+4:5\]/addr[ADDR_BITS+5:6]/g' rtl/soc/shared_ram.v
sed -i "s/addr\[4:0\] == 5'b0/addr[5:0] == 6'b0/g" rtl/soc/shared_ram.v

# CPU word select: [4:2]→[5:2], [2:0]→[3:0], 3'dN→4'dN
sed -i 's/cpu_wr_addr\[4:2\]/cpu_wr_addr[5:2]/g' rtl/soc/shared_ram.v
sed -i 's/cpu_araddr\[4:2\]/cpu_araddr[5:2]/g' rtl/soc/shared_ram.v
sed -i "s/{29'h0, cpu_wr_addr/{28'h0, cpu_wr_addr/g" rtl/soc/shared_ram.v
sed -i 's/input \[2:0\] word_sel/input [3:0] word_sel/g' rtl/soc/shared_ram.v
sed -i "s/3'd0: extract/4'd0:  extract/g" rtl/soc/shared_ram.v
sed -i "s/3'd1: extract/4'd1:  extract/g" rtl/soc/shared_ram.v
sed -i "s/3'd2: extract/4'd2:  extract/g" rtl/soc/shared_ram.v
sed -i "s/3'd3: extract/4'd3:  extract/g" rtl/soc/shared_ram.v
sed -i "s/3'd4: extract/4'd4:  extract/g" rtl/soc/shared_ram.v
sed -i "s/3'd5: extract/4'd5:  extract/g" rtl/soc/shared_ram.v
sed -i "s/3'd6: extract/4'd6:  extract/g" rtl/soc/shared_ram.v
sed -i "s/default: extract_cpu_word = beat\[255:224\]/4'\''d7:  extract_cpu_word = beat[255:224];\\n                4'\''d8:  extract_cpu_word = beat[287:256];\\n                4'\''d9:  extract_cpu_word = beat[319:288];\\n                4'\''d10: extract_cpu_word = beat[351:320];\\n                4'\''d11: extract_cpu_word = beat[383:352];\\n                4'\''d12: extract_cpu_word = beat[415:384];\\n                4'\''d13: extract_cpu_word = beat[447:416];\\n                4'\''d14: extract_cpu_word = beat[479:448];\\n                default: extract_cpu_word = beat[511:480]/g" rtl/soc/shared_ram.v

echo "=== Done ==="
