// npu_clock_gate.v: Simple AND-based clock gate for NPU low-power
// In ASIC flow, this module is replaced with an integrated clock gating cell (ICG).
// For RTL simulation / FPGA, a straightforward AND gate suffices.
//
// Usage:
//   npu_clock_gate u_npu_clk_gate (
//       .clk_in  (sys_clk),
//       .clk_en  (npu_clk_en),
//       .clk_out (npu_clk)
//   );

module npu_clock_gate (
    input  wire clk_in,
    input  wire clk_en,
    output wire clk_out
);

    // AND-based clock gate: passes clk_in only when clk_en is high.
    // In a real ASIC this AND cell would be marked dont_touch / replaced by
    // the physical implementation flow with a latch-based ICG to avoid glitches.
    assign clk_out = clk_in && clk_en;

endmodule
