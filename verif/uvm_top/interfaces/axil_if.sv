`timescale 1ns / 1ps

interface axil_if(input logic clk, input logic rst_n);

  // Write address channel
  logic        awvalid;
  logic        awready;
  logic [31:0] awaddr;

  // Write data channel
  logic        wvalid;
  logic        wready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;

  // Write response channel
  logic        bvalid;
  logic        bready;
  logic [1:0]  bresp;

  // Read address channel
  logic        arvalid;
  logic        arready;
  logic [31:0] araddr;

  // Read data channel
  logic        rvalid;
  logic        rready;
  logic [31:0] rdata;
  logic [1:0]  rresp;

  task automatic idle();
    awvalid <= 1'b0;
    awaddr  <= '0;
    wvalid  <= 1'b0;
    wdata   <= '0;
    wstrb   <= '0;
    bready  <= 1'b0;
    arvalid <= 1'b0;
    araddr  <= '0;
    rready  <= 1'b0;
  endtask

endinterface
