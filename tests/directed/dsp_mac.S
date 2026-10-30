/*
 * dsp_mac.S — Xbrvdsp step 1: the multiply-accumulate unit.
 *
 * Each case sets the 40-bit accumulator, runs MAC instructions and reads
 * the result back with acc.rd or acc.rdh. Expected values were computed
 * with Python; the run is also compared with Spike (libxbrvdsp.so).
 * Covered: mac, dmac, msu, acc.set; rounding; 32- and 16-bit saturation;
 * the 8 guard bits (sums beyond 32 bits, and wrapping at 40 bits);
 * operands that arrive by forwarding and after a load-use bubble; sadd and
 * ssub at and across both saturation limits (step 5).
 */

#include "riscv_test.h"
#include "test_macros.h"

#define MAC(a, b)      .insn r CUSTOM_0, 0, 0, x0, a, b
#define DMAC(a, b)     .insn r CUSTOM_0, 0, 1, x0, a, b
#define MSU(a, b)      .insn r CUSTOM_0, 0, 2, x0, a, b
#define ACC_SET(a)     .insn r CUSTOM_0, 0, 4, x0, a, x0
#define ACC_RD(d, sh)  .insn r CUSTOM_0, 1, 0, d, x0, x##sh
#define ACC_RDH(d, sh) .insn r CUSTOM_0, 2, 0, d, x0, x##sh
#define ACC_SETH(a)    .insn r CUSTOM_0, 0, 5, x0, a, x0
#define ACC_RDL(d)     .insn r CUSTOM_0, 3, 0, d, x0, x0
#define ACC_RDX(d)     .insn r CUSTOM_0, 3, 1, d, x0, x0
#define SADD(d, a, b)  .insn r CUSTOM_0, 4, 0, d, a, b
#define SSUB(d, a, b)  .insn r CUSTOM_0, 4, 1, d, a, b

#define CHECK(n, reg, value) \
  li TESTNUM, n; li t6, value; bne reg, t6, fail

RVTEST_RV32U
RVTEST_CODE_BEGIN

  # 2: mac, from zero
  ACC_SET(x0)
  li      t0, 3
  li      t1, -4
  MAC(t0, t1)
  ACC_RD(a0, 0)
  CHECK(2, a0, -12)

  # 3: guard bits: 4 x 32767^2 + 100 = 4294705256 needs 33 bits.
  #    Read whole it saturates; shifted by 8 (rounded) it fits.
  li      t0, 100
  ACC_SET(t0)
  li      t0, 32767
  MAC(t0, t0)
  MAC(t0, t0)
  MAC(t0, t0)
  MAC(t0, t0)
  ACC_RD(a0, 0)
  CHECK(3, a0, 0x7fffffff)
  ACC_RD(a1, 8)
  CHECK(3, a1, 0x00fffc00)

  # 4: dmac: (2, 3) . (-5, 7) = 2*-5 + 3*7 = 11 (high and low halves)
  ACC_SET(x0)
  li      t0, 0x00020003
  li      t1, 0xfffb0007
  DMAC(t0, t1)
  ACC_RD(a0, 0)
  CHECK(4, a0, 11)

  # 5: msu: 50 - 6*7 = 8
  li      t0, 50
  ACC_SET(t0)
  li      t0, 6
  li      t1, 7
  MSU(t0, t1)
  ACC_RD(a0, 0)
  CHECK(5, a0, 8)

  # 6: acc.rdh saturates to 16 bits, both ways; and rounds when shifting
  li      t0, 0x12345678
  ACC_SET(t0)
  ACC_RDH(a0, 0)
  CHECK(6, a0, 0x7fff)
  li      t0, -100000
  ACC_SET(t0)
  ACC_RDH(a0, 0)
  CHECK(6, a0, 0xffff8000)
  ACC_RDH(a1, 4)
  CHECK(6, a1, 0xffffe796)          # (-100000 + 8) >> 4 = -6250

  # 7: rounding is round-half-up: (5 + 1) >> 1 = 3, (-5 + 1) >> 1 = -2
  li      t0, 5
  ACC_SET(t0)
  ACC_RD(a0, 1)
  CHECK(7, a0, 3)
  li      t0, -5
  ACC_SET(t0)
  ACC_RD(a0, 1)
  CHECK(7, a0, -2)

  # 8: operands straight from the instructions before (forwarding from MEM
  #    and WB), then from a load just before (a load-use bubble)
  ACC_SET(x0)
  li      t0, 1000
  li      t1, -3
  MAC(t0, t1)                       # -3000
  la      t2, operand
  lw      t3, 0(t2)                 # 25
  MAC(t3, t3)                       # +625
  ACC_RD(a0, 0)
  CHECK(8, a0, -2375)

  # 9: 600 x 32767^2 on top of 0x7fffffff wraps at 40 bits: the sum is
  #    -453158370729. Read whole it saturates low; shifted by 8 it fits.
  li      t0, 0x7fffffff
  ACC_SET(t0)
  li      t0, 32767
  li      t1, 600
1:
  MAC(t0, t0)
  addi    t1, t1, -1
  bnez    t1, 1b
  ACC_RD(a0, 0)
  CHECK(9, a0, 0x80000000)
  ACC_RD(a1, 8)
  CHECK(9, a1, 0x967da802)
  ACC_RDL(a2)                       # all 40 bits: -453158370729 = 0x96_7DA8_0257
  CHECK(9, a2, 0x7da80257)
  ACC_RDX(a3)
  CHECK(9, a3, 0xffffff96)

  # 11: save and restore all 40 bits: set the low 32, then the guard bits
  li      t0, 0x7da80257
  ACC_SET(t0)
  li      t0, 0x96
  ACC_SETH(t0)
  ACC_RDL(a0)
  CHECK(11, a0, 0x7da80257)
  ACC_RDX(a1)
  CHECK(11, a1, 0xffffff96)
  ACC_RD(a2, 8)
  CHECK(11, a2, 0x967da802)

  # 10: back-to-back: each MAC sees the one before, and acc.rd sees both
  ACC_SET(x0)
  li      t0, 2
  MAC(t0, t0)
  MAC(t0, t0)
  ACC_RD(a0, 0)
  CHECK(10, a0, 8)

  # 12: sadd: in range, exactly at the limit, and beyond it both ways
  li      t0, 1000
  li      t1, -3000
  SADD(a0, t0, t1)
  CHECK(12, a0, -2000)
  li      t0, 0x7ffffffe
  li      t1, 1
  SADD(a0, t0, t1)
  CHECK(12, a0, 0x7fffffff)
  SADD(a0, a0, t1)                # 0x7fffffff + 1: saturates
  CHECK(12, a0, 0x7fffffff)
  li      t0, 0x80000000
  li      t1, -1
  SADD(a0, t0, t1)
  CHECK(12, a0, 0x80000000)
  li      t0, 0x80000000
  SADD(a0, t0, t0)                # -2^31 + -2^31
  CHECK(12, a0, 0x80000000)

  # 13: ssub, including 0 - (-2^31), which overflows
  li      t0, 5
  li      t1, 7
  SSUB(a0, t0, t1)
  CHECK(13, a0, -2)
  li      t1, 0x80000000
  SSUB(a0, zero, t1)
  CHECK(13, a0, 0x7fffffff)
  li      t0, 0x80000000
  li      t1, 1
  SSUB(a0, t0, t1)
  CHECK(13, a0, 0x80000000)
  li      t0, 0x7fffffff
  li      t1, -1
  SSUB(a0, t0, t1)
  CHECK(13, a0, 0x7fffffff)

  # 14: the result forwarded straight into another sadd, and to a branch
  li      t0, 0x40000000
  SADD(a0, t0, t0)                # 2^31: saturates
  SADD(a1, a0, a0)
  CHECK(14, a1, 0x7fffffff)
  li      t6, 0x7fffffff
  SADD(a2, t0, t0)
  bne     a2, t6, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
operand: .word 25
RVTEST_DATA_END
