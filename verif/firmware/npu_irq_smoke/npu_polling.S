# Minimal PicoRV32 NPU polling firmware — writes MAGIC_BOOT,
# configures NPU GEMM, starts task, polls CTRL.done, writes MAGICs.
# Build: clang --target=riscv32 -march=rv32i -c -o npu_polling.o npu_polling.S
# Then: python3 makehex.py npu_polling.o <nwords> > npu_polling.memh
#
# Memory map:
#   0x00010000 = input (4 bytes all-1, preloaded by backdoor)
#   0x00020000 = weight (4 bytes all-1, preloaded by backdoor)
#   0x00030000 = output (will be written by NPU)
#   0x000FF000 = magic area
#   0x10000000 = NPU CSR base
#
# Expected NPU output: C[0] = K = 4

.section .text
.global _start
_start:

# === Step 1: Write MAGIC_BOOT = 0xB007B007 ===
    lui t0, 0x000ff          # t0 = 0x000FF000
    lui t1, 0xb007b          # t1 = 0xB007B000
    addi t1, t1, 0x007       # t1 = 0xB007B007
    sw t1, 0(t0)             # [0x000FF000] = BOOT_MAGIC

# === Step 2: Configure NPU GEMM (M=1,K=4,N=1) ===
    lui t2, 0x10000          # t2 = 0x10000000 (NPU_BASE)

    # TASK_TYPE = 7 (GEMM) at offset 0x08
    li t0, 7
    sw t0, 8(t2)

    # CONV_CFG = 0x20 (streaming) at offset 0x98
    li t0, 0x20
    sw t0, 0x98(t2)

    # INPUT_ADDR = 0x00010000 at offset 0x0C
    lui t0, 0x00010
    sw t0, 0x0C(t2)

    # WEIGHT_ADDR = 0x00020000 at offset 0x10
    lui t0, 0x00020
    sw t0, 0x10(t2)

    # OUTPUT_ADDR = 0x00030000 at offset 0x14
    lui t0, 0x00030
    sw t0, 0x14(t2)

    # INPUT_BYTES = 4 at offset 0x18
    li t0, 4
    sw t0, 0x18(t2)

    # WEIGHT_BYTES = 4 at offset 0x1C
    sw t0, 0x1C(t2)

    # OUTPUT_BYTES = 4 at offset 0x20
    sw t0, 0x20(t2)

    # DIM_IN = {1,1} = 0x00010001 at offset 0x24
    lui t0, 0x00010
    addi t0, t0, 1
    sw t0, 0x24(t2)

    # DIM_OUT = {1,4} = 0x00010004 at offset 0x28
    lui t0, 0x00010
    addi t0, t0, 4
    sw t0, 0x28(t2)

    # CLUSTER_MODE = 0 at offset 0x88
    sw zero, 0x88(t2)

    # CLUSTER_MASK = 1 at offset 0x8C
    li t0, 1
    sw t0, 0x8C(t2)

# === Step 3: Start NPU — write CTRL = 1 at offset 0x00 ===
    li t0, 1
    sw t0, 0(t2)

# === Step 4: Poll CTRL for done (bit[2]) or error (bit[3]) ===
poll_loop:
    lw t0, 0(t2)              # read CTRL
    andi t1, t0, 4            # check bit[2] (done)
    bnez t1, task_done
    andi t1, t0, 8            # check bit[3] (error)
    bnez t1, task_error
    j poll_loop

task_error:
    # Write MAGIC_ERROR = 0xDEAD0001 + error_code
    lw t0, 4(t2)              # read STATUS
    andi t0, t0, 0xFF         # error_code[7:0]
    lui t1, 0xdead0
    addi t1, t1, 1            # t1 = 0xDEAD0001
    add t1, t1, t0            # t1 = 0xDEAD0001 + error_code
    lui t0, 0x000ff
    sw t1, 0x0C(t0)           # [0x000FF00C] = MAGIC_ERROR
    j done_loop

task_done:
    # === Step 5: Write MAGIC_POLL_DONE = 0xD00ED00E ===
    lui t1, 0xd00ed
    addi t1, t1, 0x00e
    lui t0, 0x000ff
    sw t1, 4(t0)              # [0x000FF004] = POLL_DONE_MAGIC

    # === Step 6: Write MAGIC_TEST_DONE = 0x55AA55AA ===
    lui t1, 0x55aa5
    addi t1, t1, 0x5aa
    sw t1, 8(t0)              # [0x000FF008] = TEST_DONE_MAGIC

done_loop:
    j done_loop
