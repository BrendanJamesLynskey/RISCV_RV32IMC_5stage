/*
 * dsp_loop.S — Xbrvdsp hardware loop (step 4).
 *
 * lp.setup rs1 sets the count lc and lp_start (the next instruction). The
 * body's last instruction is marked (lp.end, or mac.lp / dmac.lp / msu.lp):
 * after it, while lc > 1, lc counts down and execution returns to lp_start;
 * then lc becomes 0 and execution falls through. Cases: counts of 0, 1, 2
 * and many; a body of one instruction; a MAC loop over an address register;
 * a taken branch and a mispredicted branch inside the body; compressed code
 * in the body; lp.end outside a loop; readback; and save and restore with
 * lp.set / lp.sets, as a context switch or a nested loop would use them.
 */

#include "riscv_test.h"
#include "test_macros.h"

#define LP_SETUP(rs)  .insn i CUSTOM_1, 6, x0, rs, 0
#define LP_END        .insn i CUSTOM_1, 7, x0, x0, 0
#define LP_SET(rs)    .insn r CUSTOM_1, 0, 2, x0, rs, x0
#define LP_SETS(rs)   .insn r CUSTOM_1, 0, 2, x1, rs, x0
#define LP_RD(rd)     .insn i CUSTOM_1, 3, rd, x0, 8
#define LP_RDS(rd)    .insn i CUSTOM_1, 3, rd, x0, 9
#define MAC_LP(a, b)  .insn r CUSTOM_0, 0, 0x40, x0, a, b
#define DMAC_LP(a, b) .insn r CUSTOM_0, 0, 0x41, x0, a, b
#define MSU_LP(a, b)  .insn r CUSTOM_0, 0, 0x42, x0, a, b
#define ACC_SET(a)    .insn r CUSTOM_0, 0, 4, x0, a, x0
#define ACC_RDL(d)    .insn r CUSTOM_0, 3, 0, d, x0, x0
#define AR_SET(n, rs) .insn r CUSTOM_1, 0, 0, x##n, rs, x0
#define AR_CFG(n, rs) .insn r CUSTOM_1, 0, 1, x##n, rs, x0
#define LW_A(rd, n)   .insn i CUSTOM_1, 2, rd, x0, n

RVTEST_RV32U
RVTEST_CODE_BEGIN

  .option push
  .option norvc

  # Case 2: lp.end, 5 times round; lc reads 0 afterwards
  li      TESTNUM, 2
  li      a0, 0
  li      t0, 5
  LP_SETUP(t0)
  addi    a0, a0, 1
  addi    a0, a0, 10
  LP_END
  li      t1, 55
  bne     a0, t1, fail
  LP_RD(a1)
  bnez    a1, fail

  # Case 3: counts 1 and 0 run the body once; count 2 twice
  li      TESTNUM, 3
  li      a0, 0
  li      t0, 1
  LP_SETUP(t0)
  addi    a0, a0, 1
  LP_END
  LP_SETUP(zero)
  addi    a0, a0, 1
  LP_END
  li      t0, 2
  LP_SETUP(t0)
  addi    a0, a0, 1
  LP_END
  li      t1, 4
  bne     a0, t1, fail

  # Case 4: a body of one instruction: mac.lp, 10 times
  li      TESTNUM, 4
  ACC_SET(zero)
  li      a1, 7
  li      a2, -3
  li      t0, 10
  LP_SETUP(t0)
  MAC_LP(a1, a2)
  ACC_RDL(a0)
  li      t1, -210
  bne     a0, t1, fail

  # Case 5: dmac.lp over an address register: sum of squares of 1..16
  li      TESTNUM, 5
  la      t2, sq
  AR_SET(0, t2)
  li      t0, 4
  AR_CFG(0, t0)
  ACC_SET(zero)
  li      t0, 8                   # 8 words = 16 samples
  LP_SETUP(t0)
  LW_A(a1, 0)
  DMAC_LP(a1, a1)
  ACC_RDL(a0)
  li      t1, 1496
  bne     a0, t1, fail

  # Case 6: msu.lp counts down: 100 - 6 x (5 x 3)
  li      TESTNUM, 6
  li      t0, 100
  ACC_SET(t0)
  li      a1, 5
  li      a2, 3
  li      t0, 6
  LP_SETUP(t0)
  MSU_LP(a1, a2)
  ACC_RDL(a0)
  li      t1, 10
  bne     a0, t1, fail

  # Case 7: branches inside the body: odd passes skip an add (a taken
  # forward branch that alternates, so it mispredicts)
  li      TESTNUM, 7
  li      a0, 0
  li      a1, 0
  li      t0, 9
  LP_SETUP(t0)
  addi    a1, a1, 1
  andi    t2, a1, 1
  bnez    t2, 1f
  addi    a0, a0, 100
1:
  addi    a0, a0, 1
  LP_END
  li      t1, 409                 # 9 + 4 x 100
  bne     a0, t1, fail

  .option pop

  # Case 8: compressed instructions in the body, which starts at 2 mod 4
  li      TESTNUM, 8
  li      a0, 0
  li      t0, 6
  .align  2
  c.nop                           # so lp.setup ends at 2 mod 4
  LP_SETUP(t0)
  c.addi  a0, 1
  .insn i 0x13, 0, a0, a0, 2      # addi a0, a0, 2, kept 32-bit
  c.addi  a0, 3
  LP_END
  li      t1, 36
  bne     a0, t1, fail

  .option push
  .option norvc

  # Case 9: lp.end with no active loop (lc = 0) falls through
  li      TESTNUM, 9
  li      a0, 0
  LP_END
  addi    a0, a0, 1
  li      t1, 1
  bne     a0, t1, fail

  # Case 10: readback during a loop, then save, an inner loop, restore:
  # the outer loop (4 passes) still completes, each pass running 3 inner
  li      TESTNUM, 10
  li      a0, 0
  li      a3, 0
  li      t0, 4
  LP_SETUP(t0)
2:
  LP_RD(s2)                       # save the outer loop
  LP_RDS(s3)
  add     a3, a3, s2              # lc as seen in each pass: 4 + 3 + 2 + 1
  li      t2, 3
  LP_SETUP(t2)
  addi    a0, a0, 1
  LP_END
  LP_SET(s2)                      # restore it
  LP_SETS(s3)
  LP_END
  li      t1, 12
  bne     a0, t1, fail
  li      t1, 10
  bne     a3, t1, fail
  la      t1, 2b                  # lp_start read back as the body's address
  bne     s3, t1, fail

  .option pop

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
  .align 4
sq:
  .half 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
RVTEST_DATA_END
