/*
 * gf.S — the packed GF(2^8) multiply (Xbrvdsp: gfmul4, gf.cfg, gf.rd).
 *
 * Expected values computed in Python (bit-serial multiply modulo
 * x^8 + poly); the run is also compared with Spike's model in lockstep.
 * Cases: poly's reset value (0x1D); a product in that field; gf.cfg to
 * AES's field and a gfmul4 straight after it (FIPS-197's 0x57 * 0x83 =
 * 0xc1 and 0x57 * 0x13 = 0xfe); gf.cfg keeps only rs1[7:0]; all-ones;
 * a poly with bit 7 set; zero; an inverse pair (0x53 * 0xca = 1); a
 * dependent chain (forwarding); and a gf.cfg behind a load that traps,
 * which must not change poly.
 */

#include "riscv_test.h"
#include "test_macros.h"

#define CUSTOM_0 0x0b
#define GFMUL4(rd, a, b) .insn r CUSTOM_0, 5, 0, rd, a, b
#define GF_CFG(rs)       .insn r CUSTOM_0, 5, 1, x0, rs, x0
#define GF_RD(rd)        .insn r CUSTOM_0, 5, 2, rd, x0, x0

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la      t0, handler
  csrw    mtvec, t0
  li      s2, 0                   # traps taken

  .option push
  .option norvc                   # the handler skips 4-byte instructions

  li      TESTNUM, 2
  GF_RD(a0)
  li      t1, 0x1d
  bne     a0, t1, fail

  li      TESTNUM, 3
  li      s0, 0x8badf00d
  li      s1, 0x01234567
  GFMUL4(a0, s0, s1)
  li      t1, 0x8beec1f9
  bne     a0, t1, fail

  li      TESTNUM, 4
  li      t0, 0xffffff1b
  li      s0, 0x57575757
  li      s1, 0x02011383
  GF_CFG(t0)
  GFMUL4(a0, s0, s1)              # sees the new poly
  li      t1, 0xae57fec1
  bne     a0, t1, fail

  li      TESTNUM, 5
  GF_RD(a0)
  li      t1, 0x1b
  bne     a0, t1, fail

  li      TESTNUM, 6
  li      s0, -1
  GFMUL4(a0, s0, s0)
  li      t1, 0x13131313
  bne     a0, t1, fail

  li      TESTNUM, 7
  li      t0, 0x8d
  GF_CFG(t0)
  li      s0, 0x80c0e0ff
  li      s1, 0x80ff7f02
  GFMUL4(a0, s0, s1)
  li      t1, 0x6c2ce473
  bne     a0, t1, fail

  li      TESTNUM, 8
  GFMUL4(a0, s0, x0)
  bnez    a0, fail

  li      TESTNUM, 9
  li      t0, 0x1b
  GF_CFG(t0)
  li      s0, 0x53535353
  li      s1, 0xcacacaca
  GFMUL4(a0, s0, s1)
  li      t1, 0x01010101
  bne     a0, t1, fail

  li      TESTNUM, 10
  li      t0, 0x1d
  GF_CFG(t0)
  li      a0, 0x02030405
  GFMUL4(a0, a0, a0)
  GFMUL4(a0, a0, a0)
  GFMUL4(a0, a0, a0)
  li      t1, 0x1d1c4c4d
  bne     a0, t1, fail

  # Case 11: a misaligned lw traps in MEM while the gf.cfg behind it is in
  # EX; the handler resumes after both, so the gf.cfg never executes
  li      TESTNUM, 11
  la      t2, tdat
  li      t0, 0x63
  lw      a1, 2(t2)
  GF_CFG(t0)
  li      t1, 1
  bne     s2, t1, fail
  GF_RD(a0)
  li      t1, 0x1d
  bne     a0, t1, fail

  .option pop

  TEST_PASSFAIL

  .align  2
handler:                          # skip the trapping load and the next instruction
  csrr    t6, mepc
  addi    t6, t6, 8
  csrw    mepc, t6
  addi    s2, s2, 1
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
  .align 4
tdat:
  .word 0x11111111
  .word 0x22222222
RVTEST_DATA_END
