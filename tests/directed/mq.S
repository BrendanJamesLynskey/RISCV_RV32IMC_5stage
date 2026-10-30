/*
 * mq.S — packed modular arithmetic (Xbrvdsp: mqmul2, mqadd2, mqsub2,
 * ctadd2, ctsub2, gsmul2, mq.cfg, mq.zeta, mq.rd, mq.rdz).
 *
 * Expected values computed in Python (mq_unit.v's definitions); the run is
 * also compared with Spike's model in lockstep. Cases: the reset state
 * (ML-KEM's q = 3329, qp = 3327; zeta 0); a Montgomery product; add and
 * subtract with wrap-around; mq.zeta and a ctadd2 straight after it, then
 * ctsub2 and gsmul2; a dependent chain (each result used by the next instruction, and
 * stored and branched on straight away); lanes at 0xFFFF, outside the
 * field, which still have defined results; an mqmul2 straight before an
 * mq.cfg (it must reduce with the old q) and one straight after (the new
 * q, Falcon's 12289), and mq.cfg clearing zeta; a multiply and an mqmul2
 * feeding each other; an mq.cfg and an mq.zeta behind loads that trap,
 * which must not take effect; and mqmul2's second MEM cycle with a ctadd2,
 * a dependent mqmul2, a load that misses and a store right behind it.
 */

#include "riscv_test.h"
#include "test_macros.h"

#define CUSTOM_0 0x0b
#define MQMUL2(rd, a, b) .insn r CUSTOM_0, 6, 0, rd, a, b
#define MQADD2(rd, a, b) .insn r CUSTOM_0, 6, 1, rd, a, b
#define MQSUB2(rd, a, b) .insn r CUSTOM_0, 6, 2, rd, a, b
#define CTADD2(rd, a, b) .insn r CUSTOM_0, 6, 3, rd, a, b
#define CTSUB2(rd, a, b) .insn r CUSTOM_0, 6, 4, rd, a, b
#define GSMUL2(rd, a, b) .insn r CUSTOM_0, 6, 9, rd, a, b
#define MQ_CFG(rs)       .insn r CUSTOM_0, 6, 5, x0, rs, x0
#define MQ_ZETA(rs)      .insn r CUSTOM_0, 6, 6, x0, rs, x0
#define MQ_RD(rd)        .insn r CUSTOM_0, 6, 7, rd, x0, x0
#define MQ_RDZ(rd)       .insn r CUSTOM_0, 6, 8, rd, x0, x0

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la      t0, handler
  csrw    mtvec, t0
  li      s2, 0                   # traps taken

  .option push
  .option norvc                   # the handler skips 4-byte instructions

  li      TESTNUM, 2
  MQ_RD(a0)
  li      t1, 0x0cff0d01
  bne     a0, t1, fail
  MQ_RDZ(a0)
  bnez    a0, fail

  li      TESTNUM, 3
  li      s0, 0x0abc0123
  li      s1, 0x05550cff
  MQMUL2(a0, s0, s1)
  li      t1, 0x037405e8
  bne     a0, t1, fail

  li      TESTNUM, 4
  li      s0, 0x0cff0001
  li      s1, 0x00050cff
  MQADD2(a0, s0, s1)
  MQSUB2(a1, s0, s1)
  li      t1, 0x00030d00
  bne     a0, t1, fail
  li      t1, 0x0cfa0003
  bne     a1, t1, fail

  li      TESTNUM, 5
  li      t0, 2226                # 17 in Montgomery form (17 * 2^16 mod q)
  li      s0, 0x00640c80
  li      s1, 0x0bcd0007
  MQ_ZETA(t0)
  CTADD2(a0, s0, s1)              # sees the new zeta
  CTSUB2(a1, s0, s1)
  li      t1, 0x05f20cf7
  bne     a0, t1, fail
  li      t1, 0x07d70c09
  bne     a1, t1, fail
  GSMUL2(a0, s0, s1)              # zeta * (s1 - s0)
  li      t1, 0x0beb0908
  bne     a0, t1, fail
  MQ_RDZ(a0)
  bne     a0, t0, fail

  li      TESTNUM, 6
  la      t2, tdat
  li      a0, 0x02030405
  MQMUL2(a0, a0, a0)
  MQMUL2(a0, a0, a0)
  MQADD2(a0, a0, a0)
  sw      a0, 0(t2)               # store data straight from the unit
  li      t1, 0x03e30a8f
  bne     a0, t1, fail
  lw      a1, 0(t2)
  bne     a1, t1, fail

  li      TESTNUM, 7
  li      s0, -1
  li      t0, 0xffff
  MQ_ZETA(t0)
  MQMUL2(a0, s0, s0)
  li      t1, 0xf3a6f3a6
  bne     a0, t1, fail
  MQADD2(a0, s0, s0)
  li      t1, 0xf2fdf2fd
  bne     a0, t1, fail
  li      s1, 0xffff0000
  MQSUB2(a0, t0, s1)
  li      t1, 0x0d02ffff
  bne     a0, t1, fail
  CTADD2(a0, s0, s0)
  li      t1, 0xe6a4e6a4
  bne     a0, t1, fail
  CTSUB2(a0, x0, s0)
  li      t1, 0x195b195b
  bne     a0, t1, fail
  GSMUL2(a0, s0, x0)
  li      t1, 0x0c590c59
  bne     a0, t1, fail

  li      TESTNUM, 8
  li      t0, 0x2fff3001          # q = 12289, qp = -q^-1 mod 2^16
  li      s0, 0x0abc0123
  li      s1, 0x05550cff
  MQMUL2(a0, s0, s1)              # reduced in MEM while mq.cfg is in EX: old q
  MQ_CFG(t0)
  MQMUL2(a1, s0, s1)              # new q
  li      t1, 0x037405e8
  bne     a0, t1, fail
  li      t1, 0x00e51ff6
  bne     a1, t1, fail
  MQ_RD(a0)
  bne     a0, t0, fail
  MQ_RDZ(a0)                      # mq.cfg cleared zeta
  bnez    a0, fail

  li      TESTNUM, 9
  li      t0, 0x0cff0d01
  MQ_CFG(t0)
  li      s0, 0x0abc0123
  li      s1, 0x05550cff
  mul     a0, s0, s1
  MQMUL2(a0, a0, s1)              # from the multiply, straight away
  mul     a0, a0, a0              # and back
  MQMUL2(a1, s0, s1)
  mul     a1, a1, s1
  MQMUL2(a1, a1, s1)
  mul     a1, a1, a1
  li      t1, 0x1f9bb129
  bne     a0, t1, fail
  li      t1, 0xfd930a19
  bne     a1, t1, fail

  # Case 10: a misaligned lw traps in MEM while the mq.cfg (then the
  # mq.zeta) behind it is in EX; the handler resumes after both, so neither
  # executes
  li      TESTNUM, 10
  la      t2, tdat
  li      t0, 0x63
  lw      a1, 2(t2)
  MQ_CFG(t0)
  lw      a1, 2(t2)
  MQ_ZETA(t0)
  li      t1, 2
  bne     s2, t1, fail
  MQ_RD(a0)
  li      t1, 0x0cff0d01
  bne     a0, t1, fail
  MQ_RDZ(a0)
  bnez    a0, fail

  # Case 11: mqmul2 holds the pipeline for its second MEM cycle
  li      TESTNUM, 11
  li      t0, 2226
  MQ_ZETA(t0)
  li      s0, 0x02030405
  MQMUL2(a0, s0, s0)
  CTADD2(a1, s0, s0)              # independent, straight behind
  MQMUL2(a2, a0, a0)              # dependent, straight behind
  la      t2, tdat2
  MQMUL2(a4, s0, s0)
  lw      a3, 0(t2)               # a D-cache miss straight behind
  sw      a4, 4(t2)               # the result stored straight away
  li      t1, 0x05590188
  bne     a0, t1, fail
  li      t1, 0x0a340755
  bne     a1, t1, fail
  li      t1, 0x08720bc8
  bne     a2, t1, fail
  li      t1, 0x33333333
  bne     a3, t1, fail
  lw      a5, 4(t2)
  li      t1, 0x05590188
  bne     a5, t1, fail

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
  .align 6
tdat2:
  .word 0x33333333
  .word 0x44444444
RVTEST_DATA_END
