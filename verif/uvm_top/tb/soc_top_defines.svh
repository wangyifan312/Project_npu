//=============================================================================
// soc_top_defines.svh — NPU Register Address Macros for UVM Verification
//=============================================================================

`ifndef SOC_TOP_DEFINES_SVH
`define SOC_TOP_DEFINES_SVH

//-----------------------------------------------------------------------------
// Base addresses
//-----------------------------------------------------------------------------
`define SOC_SHARED_RAM_BASE  32'h0000_0000
`define SOC_NPU_REG_BASE     32'h1000_0000

//-----------------------------------------------------------------------------
// Control registers (word addresses: byte addr = offset * 4)
// All macros produce 32-bit byte addresses.
//-----------------------------------------------------------------------------

// Offset 0: Control register (RW)
`define NPU_REG_CTRL         (`SOC_NPU_REG_BASE + 32'h00)

// Offset 1: Status register (RO)
`define NPU_REG_STATUS       (`SOC_NPU_REG_BASE + 32'h04)

// Offset 2: Task type (RW)
`define NPU_REG_TASK_TYPE    (`SOC_NPU_REG_BASE + 32'h08)

// Offset 3: Input address (RW)
`define NPU_REG_INPUT_ADDR   (`SOC_NPU_REG_BASE + 32'h0C)

// Offset 4: Weight address (RW)
`define NPU_REG_WEIGHT_ADDR  (`SOC_NPU_REG_BASE + 32'h10)

// Offset 5: Output address (RW)
`define NPU_REG_OUTPUT_ADDR  (`SOC_NPU_REG_BASE + 32'h14)

// Offset 6: Input bytes (RW)
`define NPU_REG_INPUT_BYTES  (`SOC_NPU_REG_BASE + 32'h18)

// Offset 7: Weight bytes (RW)
`define NPU_REG_WEIGHT_BYTES (`SOC_NPU_REG_BASE + 32'h1C)

// Offset 8: Output bytes (RW)
`define NPU_REG_OUTPUT_BYTES (`SOC_NPU_REG_BASE + 32'h20)

// Offset 9: Dimension input (H[15:0], W[31:16]) (RW)
`define NPU_REG_DIM_IN       (`SOC_NPU_REG_BASE + 32'h24)

// Offset 10: Dimension output (C_IN[15:0], C_OUT[31:16]) (RW)
`define NPU_REG_DIM_OUT      (`SOC_NPU_REG_BASE + 32'h28)

// Offset 11: Post-processing config ([0]=relu, [1]=pool) (RW)
`define NPU_REG_POSTPROC     (`SOC_NPU_REG_BASE + 32'h2C)

//-----------------------------------------------------------------------------
// Performance counters (RO)
//-----------------------------------------------------------------------------

// Offset 12: Performance cycle count low (RO)
`define NPU_REG_PERF_CYCLE_LO      (`SOC_NPU_REG_BASE + 32'h30)

// Offset 13: Performance cycle count high (RO)
`define NPU_REG_PERF_CYCLE_HI      (`SOC_NPU_REG_BASE + 32'h34)

// Offset 14: Performance read beats (RO)
`define NPU_REG_PERF_READ_BEATS    (`SOC_NPU_REG_BASE + 32'h38)

// Offset 15: Performance write beats (RO)
`define NPU_REG_PERF_WRITE_BEATS   (`SOC_NPU_REG_BASE + 32'h3C)

// Offset 16: Performance read active cycles (RO)
`define NPU_REG_PERF_READ_ACTIVE   (`SOC_NPU_REG_BASE + 32'h40)

// Offset 17: Performance write active cycles (RO)
`define NPU_REG_PERF_WRITE_ACTIVE  (`SOC_NPU_REG_BASE + 32'h44)

// Offset 18: Performance array active cycles (RO)
`define NPU_REG_PERF_ARRAY_ACTIVE  (`SOC_NPU_REG_BASE + 32'h48)

// Offset 19: Performance array stall cycles (RO)
`define NPU_REG_PERF_ARRAY_STALL   (`SOC_NPU_REG_BASE + 32'h4C)

// Offset 20: Performance MAC count low (RO)
`define NPU_REG_PERF_MAC_LO        (`SOC_NPU_REG_BASE + 32'h50)

// Offset 21: Performance MAC count high (RO)
`define NPU_REG_PERF_MAC_HI        (`SOC_NPU_REG_BASE + 32'h54)

// Offset 22: Performance cluster active cycles (RO)
`define NPU_REG_PERF_CLUSTER_ACTIVE (`SOC_NPU_REG_BASE + 32'h58)

// Offset 23: Performance cluster stall cycles (RO)
`define NPU_REG_PERF_CLUSTER_STALL  (`SOC_NPU_REG_BASE + 32'h5C)

// Offset 24: Performance cluster config (RO)
`define NPU_REG_PERF_CLUSTER_CFG    (`SOC_NPU_REG_BASE + 32'h60)

//-----------------------------------------------------------------------------
// Requantization parameters (RW)
//-----------------------------------------------------------------------------

// Offset 25: Requantization select (RW)
`define NPU_REG_REQUANT_SEL       (`SOC_NPU_REG_BASE + 32'h64)

// Offset 26: Requant 0 multiplier (RW)
`define NPU_REG_REQUANT0_MULT     (`SOC_NPU_REG_BASE + 32'h68)

// Offset 27: Requant 0 shift (RW)
`define NPU_REG_REQUANT0_SHIFT    (`SOC_NPU_REG_BASE + 32'h6C)

// Offset 28: Requant 1 multiplier (RW)
`define NPU_REG_REQUANT1_MULT     (`SOC_NPU_REG_BASE + 32'h70)

// Offset 29: Requant 1 shift (RW)
`define NPU_REG_REQUANT1_SHIFT    (`SOC_NPU_REG_BASE + 32'h74)

// Offset 30: Requant 2 multiplier (RW)
`define NPU_REG_REQUANT2_MULT     (`SOC_NPU_REG_BASE + 32'h78)

// Offset 31: Requant 2 shift (RW)
`define NPU_REG_REQUANT2_SHIFT    (`SOC_NPU_REG_BASE + 32'h7C)

// Offset 32: Requant 3 multiplier (RW)
`define NPU_REG_REQUANT3_MULT     (`SOC_NPU_REG_BASE + 32'h80)

// Offset 33: Requant 3 shift (RW)
`define NPU_REG_REQUANT3_SHIFT    (`SOC_NPU_REG_BASE + 32'h84)

//-----------------------------------------------------------------------------
// Cluster configuration (RW)
//-----------------------------------------------------------------------------

// Offset 34: Cluster mode (RW)
`define NPU_REG_CLUSTER_MODE      (`SOC_NPU_REG_BASE + 32'h88)

// Offset 35: Cluster mask (RW)
`define NPU_REG_CLUSTER_MASK      (`SOC_NPU_REG_BASE + 32'h8C)

//-----------------------------------------------------------------------------
// Version and capability (RO)
//-----------------------------------------------------------------------------

// Offset 36: Version register (RO)
`define NPU_REG_VERSION           (`SOC_NPU_REG_BASE + 32'h90)

// Offset 37: Capability register (RO)
`define NPU_REG_CAPABILITY        (`SOC_NPU_REG_BASE + 32'h94)

//-----------------------------------------------------------------------------
// Extended task parameters (RW)
//-----------------------------------------------------------------------------

// Offset 38: Convolution config (RW)
`define NPU_REG_CONV_CFG          (`SOC_NPU_REG_BASE + 32'h98)

// Offset 39: Bias address (RW)
`define NPU_REG_BIAS_ADDR         (`SOC_NPU_REG_BASE + 32'h9C)

// Offset 40: Bias bytes (RW)
`define NPU_REG_BIAS_BYTES        (`SOC_NPU_REG_BASE + 32'hA0)

// Offset 41: Source-1 address (RW)
`define NPU_REG_SRC1_ADDR         (`SOC_NPU_REG_BASE + 32'hA4)

// Offset 42: Source-1 bytes (RW)
`define NPU_REG_SRC1_BYTES        (`SOC_NPU_REG_BASE + 32'hA8)

// Offset 43: Add config (RW)
`define NPU_REG_ADD_CFG           (`SOC_NPU_REG_BASE + 32'hAC)

// Offset 44: GAP config (RW)
`define NPU_REG_GAP_CFG           (`SOC_NPU_REG_BASE + 32'hB0)

// Offset 45: Post-processing config extended (RW)
`define NPU_REG_POSTPROC_CFG      (`SOC_NPU_REG_BASE + 32'hB4)

//-----------------------------------------------------------------------------
// Residual add requantization parameters (RW)
//-----------------------------------------------------------------------------

// Offset 46: Add source-0 multiplier (RW)
`define NPU_REG_ADD_SRC0_MULT     (`SOC_NPU_REG_BASE + 32'hB8)

// Offset 47: Add source-0 shift (RW)
`define NPU_REG_ADD_SRC0_SHIFT    (`SOC_NPU_REG_BASE + 32'hBC)

// Offset 48: Add source-1 multiplier (RW)
`define NPU_REG_ADD_SRC1_MULT     (`SOC_NPU_REG_BASE + 32'hC0)

// Offset 49: Add source-1 shift (RW)
`define NPU_REG_ADD_SRC1_SHIFT    (`SOC_NPU_REG_BASE + 32'hC4)

// Offset 50: Add output multiplier (RW)
`define NPU_REG_ADD_OUT_MULT      (`SOC_NPU_REG_BASE + 32'hC8)

// Offset 51: Add output shift (RW)
`define NPU_REG_ADD_OUT_SHIFT     (`SOC_NPU_REG_BASE + 32'hCC)

//-----------------------------------------------------------------------------
// Status bit fields (bit positions in npu_status / CTRL register:
//   ctrl_value = {28'h0, error, done, busy, 1'b0})
//-----------------------------------------------------------------------------
`define NPU_STATUS_BUSY   1  // bit[1]
`define NPU_STATUS_DONE   2  // bit[2]
`define NPU_STATUS_ERROR  3  // bit[3]

`endif // SOC_TOP_DEFINES_SVH
