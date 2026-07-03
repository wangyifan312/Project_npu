// PicoRV32 custom instruction macros — extracted from firmware/custom_ops.S
// Used by npu_irq_smoke.S for maskirq and retirq

#define picorv32_maskirq_insn(_rd, _rs) \
    .word 0x0600000b | ((_rd) << 7) | ((_rs) << 15)

#define picorv32_retirq_insn() \
    .word 0x0400000b
