`timescale 1ns / 1ps

module tb_hb1b_buffer_feeder_256;
    localparam DATA_W = 256;
    localparam ADDR_W = 4;
    localparam ENTRIES = 16;

    reg clk;
    reg rst_n;
    reg [ADDR_W-1:0] wr_addr;
    reg [DATA_W-1:0] wr_data;
    reg wr_en;
    reg wr_bank_sel;
    reg [ADDR_W-1:0] rd_addr;
    wire [DATA_W-1:0] rd_data;
    reg rd_bank_sel;
    reg load_start, load_done, comp_start, comp_done;
    reg load_bank_sel, comp_bank_sel;
    wire load_ready, comp_ready, comp_active;
    wire [1:0] bank_a_state, bank_b_state;

    reg [DATA_W-1:0] beat_shadow [0:ENTRIES-1];

    npu_buffer #(
        .DATA_WIDTH(DATA_W),
        .ENTRIES(ENTRIES),
        .ADDR_WIDTH(ADDR_W)
    ) u_buf (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(wr_addr), .wr_data(wr_data), .wr_en(wr_en), .wr_bank_sel(wr_bank_sel),
        .rd_addr(rd_addr), .rd_data(rd_data), .rd_bank_sel(rd_bank_sel),
        .load_start(load_start), .load_done(load_done),
        .comp_start(comp_start), .comp_done(comp_done),
        .load_bank_sel(load_bank_sel), .comp_bank_sel(comp_bank_sel),
        .flush(1'b0),
        .load_ready(load_ready), .comp_ready(comp_ready), .comp_active(comp_active),
        .bank_a_state(bank_a_state), .bank_b_state(bank_b_state)
    );

    always #5 clk = ~clk;

    function [7:0] beat_byte;
        input [DATA_W-1:0] beat;
        input [4:0] byte_sel;
        begin
            beat_byte = beat[byte_sel * 8 +: 8];
        end
    endfunction

    function [7:0] expected_byte;
        input [31:0] byte_index;
        begin
            expected_byte = beat_byte(beat_shadow[byte_index[8:5]], byte_index[4:0]);
        end
    endfunction

    task write_beat;
        input [ADDR_W-1:0] addr;
        integer i;
        reg [DATA_W-1:0] beat;
        begin
            beat = {DATA_W{1'b0}};
            for (i = 0; i < 32; i = i + 1)
                beat[i*8 +: 8] = (addr * 32 + i) & 8'hff;
            @(posedge clk);
            wr_addr <= addr;
            wr_data <= beat;
            wr_en <= 1'b1;
            beat_shadow[addr] = beat;
            @(posedge clk);
            wr_en <= 1'b0;
        end
    endtask

    task read_beat;
        input [ADDR_W-1:0] addr;
        begin
            @(posedge clk);
            rd_addr <= addr;
            @(posedge clk);
            #1;
        end
    endtask

    task check_byte;
        input [31:0] byte_index;
        input [8*32-1:0] tag;
        reg [7:0] got;
        reg [7:0] exp;
        begin
            read_beat(byte_index[8:5]);
            got = beat_byte(rd_data, byte_index[4:0]);
            exp = expected_byte(byte_index);
            if (got !== exp) begin
                $display("FAIL %0s byte_index=%0d got=%0d exp=%0d", tag, byte_index, got, exp);
                $finish;
            end
        end
    endtask

    integer i;

    initial begin
        clk = 0;
        rst_n = 0;
        wr_addr = 0;
        wr_data = 0;
        wr_en = 0;
        wr_bank_sel = 0;
        rd_addr = 0;
        rd_bank_sel = 0;
        load_start = 0;
        load_done = 0;
        comp_start = 0;
        comp_done = 0;
        load_bank_sel = 0;
        comp_bank_sel = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;

        @(posedge clk);
        load_start <= 1'b1;
        @(posedge clk);
        load_start <= 1'b0;

        for (i = 0; i < ENTRIES; i = i + 1)
            write_beat(i[ADDR_W-1:0]);

        @(posedge clk);
        load_done <= 1'b1;
        @(posedge clk);
        load_done <= 1'b0;
        comp_start <= 1'b1;
        @(posedge clk);
        comp_start <= 1'b0;

        for (i = 0; i < 96; i = i + 1)
            check_byte(i, "wide-buffer-byte");
        $display("HB1B_BUFFER_BYTE_PASS");

        // Conv window crosses 256-bit beat boundary: byte 29..33.
        for (i = 29; i <= 33; i = i + 1)
            check_byte(i, "conv-cross-beat");
        $display("HB1B_CONV_CROSS_BEAT_PASS");

        // FC first chunk, fc_in_base=0, chunk inputs 0..63.
        for (i = 0; i < 64; i = i + 1)
            check_byte(i, "fc-first-chunk");
        $display("HB1B_FC_FIRST_CHUNK_PASS");

        // FC tail chunk, fc_in_base=448, fc_chunk_inputs=52.
        for (i = 448; i < 500; i = i + 1)
            check_byte(i, "fc-tail-chunk");
        $display("HB1B_FC_TAIL_CHUNK_PASS");

        // Weight layout read also crosses beat boundary using the same byte extractor.
        for (i = 30; i < 36; i = i + 1)
            check_byte(i, "weight-cross-beat");
        $display("HB1B_WEIGHT_CROSS_BEAT_PASS");

        $display("HB1B_BUFFER_FEEDER_256_PASS");
        $finish;
    end
endmodule
