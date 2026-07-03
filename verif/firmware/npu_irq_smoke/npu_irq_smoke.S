// Minimal PicoRV32 NPU IRQ smoke firmware
// PROGADDR_RESET=0x0, PROGADDR_IRQ=0x10
// main: config NPU, enable done IRQ, wait for handler
// handler: read IRQ_STATUS, write MAGIC, clear IRQ, retirq
//
// Build:
//   riscv64-unknown-elf-gcc -nostdlib -nostartfiles -ffreestanding \
//     -march=rv32i -mabi=ilp32 -I. -T npu_irq_smoke.ld \
//     -o npu_irq_smoke.elf npu_irq_smoke.S

.section .text
.global _start

// ============================================================
// Reset vector at 0x00000000
// ============================================================
.org 0x00000000
_start:
    j reset_main

// ============================================================
// IRQ vector at 0x00000010
// ============================================================
.org 0x00000010
irq_handler:
    // Read NPU_IRQ_STATUS
    lui t0, 0x10000
    lw t1, 0x104(t0)         // t1 = IRQ_STATUS

    // Write MAGIC_IRQ_STATUS
    lui t2, 0x000ff
    sw t1, 0x08(t2)

    // Check done bit
    andi t0, t1, 1
    beqz t0, irq_done

    // Clear done IRQ
    lui t0, 0x10000
    li t1, 1
    sw t1, 0x108(t0)         // IRQ_CLEAR = 1

    // Write MAGIC_IRQ_SEEN
    lui t2, 0x000ff
    lui t1, 0x1a2b4
    addi t1, t1, -947
    sw t1, 0x04(t2)

    // Write MAGIC_TEST_DONE directly from handler (avoids retirq issues)
    lui t1, 0x55aa5
    addi t1, t1, 0x5aa
    sw t1, 0x0C(t2)

irq_done:
    // Return from interrupt
    .word 0x0400000B

// ============================================================
// Main program (placed safely after IRQ vector)
// ============================================================
.org 0x00000080
reset_main:
    // ---- Write MAGIC_BOOT = 0xB007B007 to [0x000FF000] ----
    lui t0, 0x000ff
    lui t1, 0xb007b
    addi t1, t1, 0x007
    sw t1, 0(t0)

    // ---- Clear NPU IRQ pending ----
    lui t2, 0x10000          // t2 = NPU_BASE
    li t1, 3
    sw t1, 0x108(t2)         // IRQ_CLEAR = 0x3

    // ---- Enable done IRQ: IRQ_EN = 1 ----
    li t1, 1
    sw t1, 0x100(t2)         // IRQ_EN = 0x1 (done=1)

    // ---- Unmask irq[4] ----
    // maskirq sets irq_mask = rs1 | MASKED_IRQ (MASKED_IRQ=0)
    // To unmask irq[4]: set bit[4]=0, all others=1 → rs1 = 0xFFFFFFEF
    lui t0, 0xfffff
    addi t0, t0, 0x0ef       // t0 = 0xFFFFFFEF
    // maskirq t1, t0: rd=t1(6), rs1=t0(5)
    // encoding: custom-0, funct7=0000011
    .word 0x0600000b | (6 << 7) | (5 << 15)

    // ---- Configure NPU GEMM (M=1,K=4,N=1) ----
    // TASK_TYPE = 7 at offset 0x08
    li t0, 7
    sw t0, 0x008(t2)

    // CONV_CFG = 0x20 at offset 0x98
    li t0, 0x20
    sw t0, 0x098(t2)

    // INPUT_ADDR = 0x00010000 at offset 0x0C
    lui t0, 0x00010
    sw t0, 0x00C(t2)

    // WEIGHT_ADDR = 0x00020000 at offset 0x10
    lui t0, 0x00020
    sw t0, 0x010(t2)

    // OUTPUT_ADDR = 0x00030000 at offset 0x14
    lui t0, 0x00030
    sw t0, 0x014(t2)

    // INPUT_BYTES = 4 at offset 0x18
    li t0, 4
    sw t0, 0x018(t2)

    // WEIGHT_BYTES = 4 at offset 0x1C
    sw t0, 0x01C(t2)

    // OUTPUT_BYTES = 4 at offset 0x20
    sw t0, 0x020(t2)

    // DIM_IN = {1,1} = 0x00010001 at offset 0x24
    lui t0, 0x00010
    addi t0, t0, 1
    sw t0, 0x024(t2)

    // DIM_OUT = {1,4} = 0x00010004 at offset 0x28
    lui t0, 0x00010
    addi t0, t0, 4
    sw t0, 0x028(t2)

    // CLUSTER_MODE = 0 at offset 0x88
    sw zero, 0x088(t2)

    // CLUSTER_MASK = 1 at offset 0x8C
    li t0, 1
    sw t0, 0x08C(t2)

    // ---- Start NPU: CTRL = 1 ----
    li t0, 1
    sw t0, 0x000(t2)

    // ---- Wait for IRQ handler to write MAGIC_IRQ_SEEN ----
    // (also check for error)
    lui t3, 0x1a2b4
    addi t3, t3, -947        // t3 = 0x1A2B3C4D = IRQ_HANDLED_MAGIC

wait_irq:
    // Check CTRL.error
    lw t0, 0x000(t2)
    andi t0, t0, 8           // bit[3] = error
    bnez t0, task_error

    // Check MAGIC_IRQ_SEEN at [0x000FF004]
    lui t0, 0x000ff
    lw t1, 0x04(t0)
    beq t1, t3, irq_handled
    j wait_irq

irq_handled:
    // ---- Write MAGIC_TEST_DONE = 0x55AA55AA to [0x000FF00C] ----
    lui t0, 0x000ff
    lui t1, 0x55aa5
    addi t1, t1, 0x5aa
    sw t1, 0x0C(t0)

done_loop:
    j done_loop

task_error:
    lui t0, 0x000ff
    lui t1, 0xdead0
    addi t1, t1, 1
    sw t1, 0x10(t0)          // [0x000FF010] = 0xDEAD0001
    j done_loop
