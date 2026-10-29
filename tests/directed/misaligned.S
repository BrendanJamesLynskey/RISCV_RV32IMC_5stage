/*
 * misaligned.S — misaligned loads and stores raise the standard exceptions.
 *
 * BRV32P does not support misaligned access in hardware; the spec allows
 * this if it traps. A misaligned LH/LHU/LW must trap with mcause 4 (store:
 * 6), mtval = the address, the destination register unchanged and memory
 * unwritten. Aligned accesses must not trap.
 */

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la      t0, handler
  csrw    mtvec, t0
  la      s0, tdat
  li      s2, 0                   # traps taken
  li      t3, 0x5a5a5a5a          # marker that a trapping load must not overwrite

  .option push
  .option norvc                   # the handler skips 4-byte instructions

#define CHECK_TRAP(n, cause, offset)        \
  li      t1, n;                            \
  bne     s2, t1, fail;                     \
  li      t1, cause;                        \
  bne     s3, t1, fail;                     \
  addi    t1, s0, offset;                   \
  bne     s4, t1, fail

  li      TESTNUM, 2              # LW at +1: load misaligned
  mv      t2, t3
  lw      t2, 1(s0)
  bne     t2, t3, fail
  CHECK_TRAP(1, 4, 1)

  li      TESTNUM, 3              # LW at +2
  mv      t2, t3
  lw      t2, 2(s0)
  bne     t2, t3, fail
  CHECK_TRAP(2, 4, 2)

  li      TESTNUM, 4              # LH at +1
  mv      t2, t3
  lh      t2, 1(s0)
  bne     t2, t3, fail
  CHECK_TRAP(3, 4, 1)

  li      TESTNUM, 5              # LHU at +3
  mv      t2, t3
  lhu     t2, 3(s0)
  bne     t2, t3, fail
  CHECK_TRAP(4, 4, 3)

  li      TESTNUM, 6              # SW at +2: store misaligned, memory untouched
  li      t2, -1
  sw      t2, 2(s0)
  CHECK_TRAP(5, 6, 2)
  lw      t2, 0(s0)
  li      t1, 0x04030201
  bne     t2, t1, fail
  lw      t2, 4(s0)
  li      t1, 0x08070605
  bne     t2, t1, fail

  li      TESTNUM, 7              # SH at +1
  li      t2, -1
  sh      t2, 1(s0)
  CHECK_TRAP(6, 6, 1)
  lw      t2, 0(s0)
  li      t1, 0x04030201
  bne     t2, t1, fail

  li      TESTNUM, 8              # aligned LH at +2 and LB at +3: no trap
  lh      t2, 2(s0)
  li      t1, 0x0403
  bne     t2, t1, fail
  lb      t2, 3(s0)
  li      t1, 0x04
  bne     t2, t1, fail
  li      t1, 6
  bne     s2, t1, fail

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
tdat:
  .word 0x04030201
  .word 0x08070605
RVTEST_DATA_END
