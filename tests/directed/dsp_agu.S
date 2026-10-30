/*
 * dsp_agu.S — Xbrvdsp address generators (step 2).
 *
 * Each address register arN holds an address and a signed 16-bit stride in
 * bytes. lw.a / lh.a / lhu.a load from addr and then add the stride. Cases:
 * readback of both fields (the stride sign-extended); loads walking forward
 * and backward; sign and zero extension; the four registers independent;
 * back-to-back loads on one register, and a load's result used at once
 * (load-use); ar.set from a just-computed value, used by the very next
 * load; stride 0; and a misaligned load, which must trap with the standard
 * cause and address and leave its address register unchanged. Bit-reversed
 * mode (step 5b): 8 halfwords in bit-reversed order and the wrap back to the
 * start; the mode bit read back and cleared; and all 1024 points of a
 * 1024-element table against a bit reversal computed in software.
 */

#include "riscv_test.h"
#include "test_macros.h"

#define AR_SET(n, rs)  .insn r CUSTOM_1, 0, 0, x##n, rs, x0
#define AR_CFG(n, rs)  .insn r CUSTOM_1, 0, 1, x##n, rs, x0
#define LH_A(rd, n)    .insn i CUSTOM_1, 1, rd, x0, n
#define LW_A(rd, n)    .insn i CUSTOM_1, 2, rd, x0, n
#define LHU_A(rd, n)   .insn i CUSTOM_1, 5, rd, x0, n
#define AR_RD(rd, n)   .insn i CUSTOM_1, 3, rd, x0, n
#define AR_RDS(rd, n)  .insn i CUSTOM_1, 3, rd, x0, (n + 4)
#define AR_RDM(rd, n)  .insn i CUSTOM_1, 3, rd, x0, (n + 12)
#define AR_MODE(n, rs) .insn r CUSTOM_1, 0, 3, x##n, rs, x0

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la      t0, handler
  csrw    mtvec, t0
  li      s2, 0                   # traps taken
  la      s0, words
  la      s1, halves

  .option push
  .option norvc                   # the handler skips 4-byte instructions

  # Case 2: readback; the stride reads back sign-extended
  li      TESTNUM, 2
  AR_SET(1, s0)
  li      t0, -6
  AR_CFG(1, t0)
  AR_RD(a0, 1)
  bne     a0, s0, fail
  AR_RDS(a0, 1)
  li      t1, -6
  bne     a0, t1, fail
  li      t0, 0x12340004          # only the low 16 bits are the stride
  AR_CFG(1, t0)
  AR_RDS(a0, 1)
  li      t1, 4
  bne     a0, t1, fail

  # Case 3: lw.a walking forward, back-to-back on one register
  li      TESTNUM, 3
  AR_SET(0, s0)
  li      t0, 4
  AR_CFG(0, t0)
  LW_A(a0, 0)
  LW_A(a1, 0)
  LW_A(a2, 0)
  LW_A(a3, 0)
  li      t1, 0x11111111
  bne     a0, t1, fail
  li      t1, 0x22222222
  bne     a1, t1, fail
  li      t1, 0x33333333
  bne     a2, t1, fail
  li      t1, 0x44444444
  bne     a3, t1, fail
  AR_RD(a0, 0)
  addi    t1, s0, 16
  bne     a0, t1, fail

  # Case 4: walking backward (negative stride)
  li      TESTNUM, 4
  addi    t0, s0, 12
  AR_SET(2, t0)
  li      t0, -4
  AR_CFG(2, t0)
  LW_A(a0, 2)
  LW_A(a1, 2)
  li      t1, 0x44444444
  bne     a0, t1, fail
  li      t1, 0x33333333
  bne     a1, t1, fail
  AR_RD(a0, 2)
  addi    t1, s0, 4
  bne     a0, t1, fail

  # Case 5: lh.a sign-extends, lhu.a zero-extends; the result used at once
  li      TESTNUM, 5
  AR_SET(3, s1)
  li      t0, 2
  AR_CFG(3, t0)
  LH_A(a0, 3)                     # 0x8001
  addi    a0, a0, 1               # load-use: -32767 + 1
  li      t1, -32766
  bne     a0, t1, fail
  LHU_A(a1, 3)                    # 0xfffe
  li      t1, 0xfffe
  bne     a1, t1, fail
  LH_A(a2, 3)                     # 0x7fff
  li      t1, 0x7fff
  bne     a2, t1, fail

  # Case 6: the four registers are independent
  li      TESTNUM, 6
  AR_RD(a0, 0)
  addi    t1, s0, 16
  bne     a0, t1, fail
  AR_RD(a0, 1)
  bne     a0, s0, fail
  AR_RD(a0, 2)
  addi    t1, s0, 4
  bne     a0, t1, fail
  AR_RD(a0, 3)
  addi    t1, s1, 6
  bne     a0, t1, fail

  # Case 7: ar.set from a value computed the cycle before, used by the next load
  li      TESTNUM, 7
  addi    t0, s0, 8
  AR_SET(0, t0)
  LW_A(a0, 0)
  li      t1, 0x33333333
  bne     a0, t1, fail

  # Case 8: stride 0 reads the same word again
  li      TESTNUM, 8
  AR_SET(1, s0)
  AR_CFG(1, zero)
  LW_A(a0, 1)
  LW_A(a1, 1)
  bne     a0, a1, fail
  AR_RD(a0, 1)
  bne     a0, s0, fail

  # Case 9: a misaligned lw.a traps (mcause 4, mtval = the address), leaves
  # rd and the address register unchanged
  li      TESTNUM, 9
  addi    t0, s0, 2
  AR_SET(2, t0)
  li      t2, 4
  AR_CFG(2, t2)
  li      a0, 0x5a5a5a5a
  LW_A(a0, 2)
  li      t1, 1
  bne     s2, t1, fail
  li      t1, 4
  bne     s3, t1, fail
  bne     s4, t0, fail
  li      t1, 0x5a5a5a5a
  bne     a0, t1, fail
  AR_RD(a1, 2)
  bne     a1, t0, fail

  # Case 10: and a misaligned lh.a likewise
  li      TESTNUM, 10
  addi    t0, s1, 1
  AR_SET(3, t0)
  LH_A(a0, 3)
  li      t1, 2
  bne     s2, t1, fail
  bne     s4, t0, fail
  AR_RD(a1, 3)
  bne     a1, t0, fail

  # Case 11: bit-reversed, 8 halfwords (stride = 4 elements = 8 bytes):
  # values 0..7 read in the order 0 4 2 6 1 5 3 7, then 0 again
  li      TESTNUM, 11
  la      t0, br8
  AR_SET(0, t0)
  li      t1, 8                   # stride 8 bytes
  AR_CFG(0, t1)
  li      t1, 1
  AR_MODE(0, t1)
  li      s5, 0
  li      s6, 0x73516240          # expected order, a nibble each, low first
1:
  LH_A(a0, 0)
  andi    t2, s6, 15
  bne     a0, t2, fail
  srli    s6, s6, 4
  addi    s5, s5, 1
  li      t2, 8
  bne     s5, t2, 1b
  LH_A(a0, 0)                     # wrapped round to element 0
  bnez    a0, fail
  AR_RD(a1, 0)                    # and the address is element 4
  addi    t2, t0, 8
  bne     a1, t2, fail

  # Case 14: lw.a, bit-reversed over 4 words (stride 2 words = 8 bytes):
  # 0 2 1 3, then back to 0 (the carry stops above bits 1:0)
  li      TESTNUM, 14
  la      t0, words
  AR_SET(3, t0)
  li      t1, 8
  AR_CFG(3, t1)
  li      t1, 1
  AR_MODE(3, t1)
  LW_A(a0, 3)
  LW_A(a1, 3)
  LW_A(a2, 3)
  LW_A(a3, 3)
  LW_A(a4, 3)
  li      t2, 0x11111111
  bne     a0, t2, fail
  li      t2, 0x33333333
  bne     a1, t2, fail
  li      t2, 0x22222222
  bne     a2, t2, fail
  li      t2, 0x44444444
  bne     a3, t2, fail
  li      t2, 0x11111111
  bne     a4, t2, fail
  AR_MODE(3, zero)

  # Case 12: the mode reads back, apart from the stride; ar.cfg leaves it
  # (even with a negative stride), ar.mode 0 clears it
  li      TESTNUM, 12
  AR_RDM(a0, 0)
  li      t2, 1
  bne     a0, t2, fail
  AR_RDS(a0, 0)
  li      t2, 8
  bne     a0, t2, fail
  li      t1, -2
  AR_CFG(0, t1)
  AR_RDM(a0, 0)
  li      t2, 1
  bne     a0, t2, fail
  AR_MODE(0, zero)
  AR_RDM(a0, 0)
  bnez    a0, fail
  AR_RDM(a0, 1)                   # the other registers were never set
  bnez    a0, fail

  # Case 13: 1024 points: the i-th load is element rev10(i)
  li      TESTNUM, 13
  la      t0, br1024
  AR_SET(1, t0)
  li      t1, 1024                # stride 512 elements = 1024 bytes
  AR_CFG(1, t1)
  li      t1, 1
  AR_MODE(1, t1)
  li      s5, 0                   # i
2:
  LHU_A(a0, 1)
  li      a1, 0                   # rev10(i)
  mv      a2, s5
  li      a3, 10
3:
  slli    a1, a1, 1
  andi    a4, a2, 1
  or      a1, a1, a4
  srli    a2, a2, 1
  addi    a3, a3, -1
  bnez    a3, 3b
  bne     a0, a1, fail
  addi    s5, s5, 1
  li      t2, 1024
  bne     s5, t2, 2b

  .option pop

  TEST_PASSFAIL

  .align  2
handler:                          # record the trap and skip the instruction
  csrr    s3, mcause
  csrr    s4, mtval
  csrr    t6, mepc
  addi    t6, t6, 4
  csrw    mepc, t6
  addi    s2, s2, 1
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
  .align 4
words:
  .word 0x11111111
  .word 0x22222222
  .word 0x33333333
  .word 0x44444444
halves:
  .half 0x8001
  .half 0xfffe
  .half 0x7fff
  .half 0x0000
  .align 4
br8:
  .half 0, 1, 2, 3, 4, 5, 6, 7
  .align 11
br1024:
  .set k, 0
  .rept 1024
  .half k
  .set k, k + 1
  .endr
RVTEST_DATA_END
