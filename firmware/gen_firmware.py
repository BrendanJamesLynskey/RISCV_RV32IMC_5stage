#!/usr/bin/env python3
"""Generate a test firmware hex file for BRV32 MCU with correct RV32I encodings."""

def r_type(funct7, rs2, rs1, funct3, rd, opcode=0x33):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def i_type(imm, rs1, funct3, rd, opcode=0x13):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def s_type(imm, rs2, rs1, funct3, opcode=0x23):
    imm11_5 = (imm >> 5) & 0x7F
    imm4_0 = imm & 0x1F
    return (imm11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm4_0 << 7) | opcode

def b_type(imm, rs2, rs1, funct3, opcode=0x63):
    imm12   = (imm >> 12) & 1
    imm10_5 = (imm >> 5) & 0x3F
    imm4_1  = (imm >> 1) & 0xF
    imm11   = (imm >> 11) & 1
    return (imm12 << 31) | (imm10_5 << 25) | (rs2 << 20) | (rs1 << 15) | \
           (funct3 << 12) | (imm4_1 << 8) | (imm11 << 7) | opcode

def u_type(imm, rd, opcode=0x37):
    return (imm & 0xFFFFF000) | (rd << 7) | opcode

def j_type(imm, rd, opcode=0x6F):
    imm20   = (imm >> 20) & 1
    imm10_1 = (imm >> 1) & 0x3FF
    imm11   = (imm >> 11) & 1
    imm19_12 = (imm >> 12) & 0xFF
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) | (imm19_12 << 12) | (rd << 7) | opcode

# Aliases
x0, x1, x2, x3, x4, x5, x6, x7 = 0, 1, 2, 3, 4, 5, 6, 7
x8, x9, x10, x11, x12, x13, x14, x15 = 8, 9, 10, 11, 12, 13, 14, 15
x16, x17, x18, x19, x20, x21, x22, x23 = 16, 17, 18, 19, 20, 21, 22, 23

def addi(rd, rs1, imm):  return i_type(imm, rs1, 0, rd, 0x13)
def add(rd, rs1, rs2):   return r_type(0x00, rs2, rs1, 0, rd, 0x33)
def sub(rd, rs1, rs2):   return r_type(0x20, rs2, rs1, 0, rd, 0x33)
def andi(rd, rs1, imm):  return i_type(imm, rs1, 7, rd, 0x13)
def ori(rd, rs1, imm):   return i_type(imm, rs1, 6, rd, 0x13)
def xori(rd, rs1, imm):  return i_type(imm, rs1, 4, rd, 0x13)
def slli(rd, rs1, shamt): return i_type(shamt, rs1, 1, rd, 0x13)
def srli(rd, rs1, shamt): return i_type(shamt, rs1, 5, rd, 0x13)
def srai(rd, rs1, shamt): return i_type(0x400 | shamt, rs1, 5, rd, 0x13)
def slti(rd, rs1, imm):  return i_type(imm, rs1, 2, rd, 0x13)
def slt(rd, rs1, rs2):   return r_type(0x00, rs2, rs1, 2, rd, 0x33)
def lui(rd, imm):        return u_type(imm, rd, 0x37)
def auipc(rd, imm):      return u_type(imm, rd, 0x17)
def sw(rs2, offset, rs1): return s_type(offset, rs2, rs1, 2, 0x23)
def sh(rs2, offset, rs1): return s_type(offset, rs2, rs1, 1, 0x23)
def sb(rs2, offset, rs1): return s_type(offset, rs2, rs1, 0, 0x23)
def lw(rd, offset, rs1):  return i_type(offset, rs1, 2, rd, 0x03)
def lh(rd, offset, rs1):  return i_type(offset, rs1, 1, rd, 0x03)
def lb(rd, offset, rs1):  return i_type(offset, rs1, 0, rd, 0x03)
def lbu(rd, offset, rs1): return i_type(offset, rs1, 4, rd, 0x03)
def lhu(rd, offset, rs1): return i_type(offset, rs1, 5, rd, 0x03)
def beq(rs1, rs2, off):  return b_type(off, rs2, rs1, 0, 0x63)
def bne(rs1, rs2, off):  return b_type(off, rs2, rs1, 1, 0x63)
def blt(rs1, rs2, off):  return b_type(off, rs2, rs1, 4, 0x63)
def bge(rs1, rs2, off):  return b_type(off, rs2, rs1, 5, 0x63)
def jal(rd, off):        return j_type(off, rd, 0x6F)
def jalr(rd, rs1, off):  return i_type(off, rs1, 0, rd, 0x67)
def ecall():             return 0x00000073
def nop():               return addi(x0, x0, 0)
def csrrw(rd, csr, rs1): return (csr << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x73
def csrrs(rd, csr, rs1): return (csr << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x73

program = [
    # ── ALU Tests ────────────────────────────────────────────────
    addi(x1, x0, 42),          # 0x00: x1 = 42
    addi(x2, x0, 10),          # 0x04: x2 = 10
    add(x3, x1, x2),           # 0x08: x3 = 52
    sub(x4, x1, x2),           # 0x0C: x4 = 32
    andi(x5, x3, 0xFF),        # 0x10: x5 = 52
    ori(x6, x0, 0x55),         # 0x14: x6 = 0x55
    xori(x7, x6, 0xFF),        # 0x18: x7 = 0xAA
    slli(x8, x2, 4),           # 0x1C: x8 = 160
    srli(x9, x8, 2),           # 0x20: x9 = 40
    slti(x18, x4, 100),        # 0x24: x18 = 1 (32 < 100)
    slt(x19, x2, x1),          # 0x28: x19 = 1 (10 < 42)

    # ── Load/Store Tests ─────────────────────────────────────────
    lui(x10, 0x10000000),       # 0x2C: x10 = 0x10000000 (DMEM base)
    sw(x3, 0, x10),             # 0x30: DMEM[0] = 52
    lw(x11, 0, x10),            # 0x34: x11 = 52
    sb(x6, 4, x10),             # 0x38: DMEM[4] = 0x55
    lbu(x12, 4, x10),           # 0x3C: x12 = 0x55

    # ── GPIO Test ────────────────────────────────────────────────
    lui(x13, 0x20000000),       # 0x40: x13 = 0x20000000 (GPIO base)
    addi(x14, x0, 0xFF),        # 0x44: x14 = 0xFF
    sw(x14, 8, x13),            # 0x48: GPIO DIR = 0xFF (all outputs)
    sw(x3, 0, x13),             # 0x4C: GPIO OUT = 52

    # ── Branch Tests ─────────────────────────────────────────────
    beq(x11, x3, 8),            # 0x50: Branch if x11 == x3 (yes, both 52) → 0x58
    addi(x15, x0, 0xDE),        # 0x54: DEAD CODE
    addi(x15, x0, 1),           # 0x58: x15 = 1 (branch target)
    bne(x1, x2, 8),             # 0x5C: Branch if x1 != x2 (yes, 42 != 10) → 0x64
    addi(x15, x0, 0xDE),        # 0x60: DEAD CODE
    addi(x15, x0, 2),           # 0x64: x15 = 2 (BNE target)

    # ── JAL / JALR Tests ─────────────────────────────────────────
    jal(x16, 8),                # 0x68: Jump to 0x70, x16 = 0x6C
    addi(x17, x0, 0xDE),        # 0x6C: DEAD CODE
    addi(x17, x0, 3),           # 0x70: x17 = 3 (JAL target)
    jalr(x20, x16, 0),          # 0x74: Jump to x16 (0x6C), x20 = 0x78
    # Falls through to the dead code at 0x6C which will execute addi x17, x0, 0xDE
    # Then continues. Let's adjust: JALR to a forward address instead.

    # ── UART Setup ───────────────────────────────────────────────
    lui(x20, 0x20000000),       # 0x78: x20 = 0x20000000
    addi(x20, x20, 0x10C),      # 0x7C: x20 = 0x2000010C (UART CTRL)
    addi(x21, x0, 8),           # 0x80: divider = 8
    sw(x21, 0, x20),            # 0x84: Write UART divider

    lui(x20, 0x20000000),       # 0x88: x20 = 0x20000000
    addi(x20, x20, 0x100),      # 0x8C: x20 = 0x20000100 (UART TX)
    addi(x22, x0, 0x48),        # 0x90: x22 = 'H'
    sw(x22, 0, x20),            # 0x94: Transmit 'H'

    # ── Wait loop ────────────────────────────────────────────────
    addi(x23, x0, 100),         # 0x98: counter = 100
    addi(x23, x23, -1),         # 0x9C: counter--
    bne(x23, x0, -4),           # 0xA0: loop until zero → 0x9C (offset = -4)

    # ── AUIPC test ───────────────────────────────────────────────
    auipc(x20, 0x00000000),     # 0xA4: x20 = PC (0xA4)

    # ── CSR test ─────────────────────────────────────────────────
    csrrs(x21, 0xB00, x0),      # 0xA8: Read mcycle into x21

    # ── Done: ECALL then spin ────────────────────────────────────
    ecall(),                    # 0xAC: Trap
    nop(),                      # 0xB0: NOP
    jal(x0, -4),                # 0xB4: Spin forever → 0xB0
]

# Fix the JALR: make it jump forward to UART setup instead
# Patch instruction at index 18 (0x74): jalr x20, x16, 0
# x16 will hold 0x6C from the JAL. jalr x20, x16, 12 → 0x6C + 12 = 0x78
program[18] = jalr(x20, x16, 12)  # Jump to 0x78

import os
outpath = os.path.join(os.path.dirname(os.path.abspath(__file__)), "firmware.hex")
with open(outpath, "w") as f:
    for instr in program:
        f.write(f"{instr & 0xFFFFFFFF:08X}\n")

print(f"Generated {len(program)} instructions")
for i, instr in enumerate(program):
    print(f"  0x{i*4:04X}: {instr & 0xFFFFFFFF:08X}")
