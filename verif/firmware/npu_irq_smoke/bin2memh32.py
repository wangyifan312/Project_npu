#!/usr/bin/env python3
"""Minimal RISC-V RV32I hand-assembler for boot/polling firmware.
Generates 32-bit word-per-line .memh from assembly-like input.
Only supports: LUI, ADDI, SW, LW, ANDI, BEQ, BNE, JAL, LI (pseudo).
"""

import sys

def reg_num(name):
    """Convert RISC-V ABI name to register number."""
    regs = {
        'zero':0, 'ra':1, 'sp':2, 'gp':3, 'tp':4,
        't0':5, 't1':6, 't2':7, 's0':8, 's1':9,
        'a0':10, 'a1':11, 'a2':12, 'a3':13, 'a4':14, 'a5':15,
        'x0':0, 'x1':1, 'x2':2, 'x3':3, 'x4':4, 'x5':5, 'x6':6, 'x7':7,
        'x8':8, 'x9':9, 'x10':10, 'x11':11, 'x12':12, 'x13':13, 'x14':14, 'x15':15,
    }
    return regs[name]

def imm12(val):
    """Sign-extend 12-bit immediate."""
    return val & 0xFFF

def imm20(val):
    """Ensure 20-bit immediate."""
    return val & 0xFFFFF

def encode_lui(rd, imm):
    """LUI rd, imm — opcode 0110111"""
    return (imm20(imm) << 12) | (rd << 7) | 0x37

def encode_addi(rd, rs1, imm):
    """ADDI rd, rs1, imm — opcode 0010011, funct3=000"""
    return (imm12(imm) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13

def encode_sw(rs2, rs1, offset):
    """SW rs2, offset(rs1) — opcode 0100011, funct3=010"""
    off = imm12(offset)
    return ((off >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | ((off & 0x1F) << 7) | 0x23

def encode_lw(rd, rs1, offset):
    """LW rd, offset(rs1) — opcode 0000011, funct3=010"""
    off = imm12(offset)
    return (off << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03

def encode_andi(rd, rs1, imm):
    """ANDI rd, rs1, imm — opcode 0010011, funct3=111"""
    return (imm12(imm) << 20) | (rs1 << 15) | (7 << 12) | (rd << 7) | 0x13

def encode_beq(rs1, rs2, offset):
    """BEQ rs1, rs2, offset — opcode 1100011, funct3=000"""
    off = offset & 0x1FFF  # 13-bit signed, 2-byte aligned
    b12 = (off >> 12) & 1
    b10_5 = (off >> 5) & 0x3F
    b4_1 = (off >> 1) & 0xF
    b11 = (off >> 11) & 1
    return (b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (0 << 12) | (b4_1 << 8) | (b11 << 7) | 0x63

def encode_bne(rs1, rs2, offset):
    """BNE rs1, rs2, offset — opcode 1100011, funct3=001"""
    off = offset & 0x1FFF
    b12 = (off >> 12) & 1
    b10_5 = (off >> 5) & 0x3F
    b4_1 = (off >> 1) & 0xF
    b11 = (off >> 11) & 1
    return (b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (1 << 12) | (b4_1 << 8) | (b11 << 7) | 0x63

def encode_jal(rd, offset):
    """JAL rd, offset — opcode 1101111"""
    off = offset & 0x1FFFFF  # 21-bit signed, 2-byte aligned
    b20 = (off >> 20) & 1
    b10_1 = (off >> 1) & 0x3FF
    b11 = (off >> 11) & 1
    b19_12 = (off >> 12) & 0xFF
    return (b20 << 31) | (b10_1 << 21) | (b11 << 20) | (b19_12 << 12) | (rd << 7) | 0x6F

def parse_imm(s):
    """Parse immediate: decimal or 0x hex."""
    s = s.strip()
    if s.startswith('0x') or s.startswith('0X'):
        return int(s, 16)
    return int(s)

def assemble_line(line):
    """Parse one assembly line, return 32-bit instruction word."""
    line = line.strip()
    if not line or line.startswith('#'):
        return None
    # Remove comments
    if '#' in line:
        line = line.split('#')[0].strip()
    if not line:
        return None

    parts = line.replace(',', ' ').split()
    if not parts:
        return None

    op = parts[0].lower()
    if op == 'nop' or op == '':
        return 0x00000013

    if op == 'lui':
        rd = reg_num(parts[1])
        imm = parse_imm(parts[2])
        return encode_lui(rd, imm)

    if op == 'li':
        # Pseudo: LI rd, imm → LUI + ADDI
        # Only handle simple cases — caller must handle this
        rd = reg_num(parts[1])
        val = parse_imm(parts[2])
        hi = (val + 0x800) >> 12  # adjust for sign extension
        lo = val & 0xFFF
        if lo >= 0x800:
            lo -= 0x1000
            hi += 1
        return (encode_lui(rd, hi), encode_addi(rd, rd, lo))

    if op == 'addi':
        rd = reg_num(parts[1])
        rs1 = reg_num(parts[2])
        imm = parse_imm(parts[3])
        return encode_addi(rd, rs1, imm)

    if op == 'sw':
        rs2 = reg_num(parts[1])
        # Parse offset(rs1)
        arg = parts[2]
        off_str, reg_str = arg.split('(')
        offset = int(off_str) if off_str else 0
        rs1 = reg_num(reg_str.rstrip(')'))
        return encode_sw(rs2, rs1, offset)

    if op == 'lw':
        rd = reg_num(parts[1])
        arg = parts[2]
        off_str, reg_str = arg.split('(')
        offset = int(off_str) if off_str else 0
        rs1 = reg_num(reg_str.rstrip(')'))
        return encode_lw(rd, rs1, offset)

    if op == 'andi':
        rd = reg_num(parts[1])
        rs1 = reg_num(parts[2])
        imm = parse_imm(parts[3])
        return encode_andi(rd, rs1, imm)

    if op == 'beq':
        rs1 = reg_num(parts[1])
        rs2 = reg_num(parts[2])
        offset = parse_imm(parts[3])
        return encode_beq(rs1, rs2, offset)

    if op == 'bne':
        rs1 = reg_num(parts[1])
        rs2 = reg_num(parts[2])
        offset = parse_imm(parts[3])
        return encode_bne(rs1, rs2, offset)

    if op == 'beqz':
        rs1 = reg_num(parts[1])
        offset = parse_imm(parts[2])
        return encode_beq(rs1, 0, offset)

    if op == 'bnez':
        rs1 = reg_num(parts[1])
        offset = parse_imm(parts[2])
        return encode_bne(rs1, 0, offset)

    if op in ('j', 'jal'):
        if len(parts) > 1 and parts[1] not in ('', ','):
            # JAL with rd
            rd = reg_num(parts[1])
            offset = parse_imm(parts[2]) if len(parts) > 2 else 0
        else:
            rd = 0  # x0 for J
            offset = parse_imm(parts[1]) if len(parts) > 1 else 0
        return encode_jal(rd, offset)

    if op.endswith(':'):
        return None  # label

    raise ValueError(f"Unknown op: {op} in '{line}'")

def assemble(lines):
    """Two-pass: first collect labels, then assemble with resolved offsets."""
    labels = {}
    instructions = []
    # Pass 1: collect labels and instructions
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if '#' in line:
            line = line.split('#')[0].strip()
        if not line:
            continue
        if line.endswith(':') and not any(c in line for c in '(), '):
            labels[line[:-1]] = len(instructions)
            continue
        result = assemble_line(line)
        if result is None:
            continue
        if isinstance(result, tuple):
            instructions.extend(result)
        else:
            instructions.append(result)

    # Pass 2: resolve branch/jump offsets
    # For simplicity, we pre-compute absolute addresses and use those
    # Branch targets in the input use absolute byte offsets from current PC
    # We need to resolve label references
    return instructions

# Test with boot_magic
def test_boot_magic():
    code = """
_start:
    lui t0, 0x000ff
    lui t1, 0xb007b
    addi t1, t1, 0x007
    sw t1, 0(t0)
    j 0
"""
    insts = assemble(code.split('\n'))
    expected = [0x000FF297, 0xB007B337, 0x00730313, 0x0062A023, 0x0000006F]
    for i, (got, exp) in enumerate(zip(insts, expected)):
        if got != exp:
            print(f"MISMATCH at {i}: got 0x{got:08x} expected 0x{exp:08x}")
            return False
    print("boot_magic test PASS")
    return True

if __name__ == '__main__':
    test_boot_magic()
