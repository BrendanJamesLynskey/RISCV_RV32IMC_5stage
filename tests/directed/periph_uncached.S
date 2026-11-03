/*
 * periph_uncached.S — loads and stores to the peripheral window bypass the
 * D-cache.
 *
 * The timer counts once per clock. If its registers were cached, the first
 * load would fill a line holding the count and every later load would return
 * that stale value. Here each load must be a fresh bus read: two reads of the
 * count, even back to back, must differ, and a stored count must read back
 * straight away. Sub-word loads go through the same path.
 */

#include "riscv_test.h"
#include "test_macros.h"

#define TIMER_BASE 0x20000200

RVTEST_RV32U
RVTEST_CODE_BEGIN

  # Timer: prescaler 0, compare at the maximum (no match), count from 0, enabled
  li      t0, TIMER_BASE
  sw      zero, 4(t0)
  li      t1, -1
  sw      t1, 8(t0)
  sw      zero, 12(t0)
  li      t1, 1
  sw      t1, 0(t0)

  li      TESTNUM, 2              # the count moves between two reads
  lw      a0, 12(t0)
  li      t2, 20
1:
  addi    t2, t2, -1
  bnez    t2, 1b
  lw      a1, 12(t0)
  bleu    a1, a0, fail

  li      TESTNUM, 3              # and between two back-to-back reads
  lw      a2, 12(t0)
  lw      a3, 12(t0)
  bleu    a3, a2, fail

  li      TESTNUM, 4              # a stored count reads back at once
  li      t1, 1000
  sw      t1, 12(t0)
  lw      a4, 12(t0)
  bltu    a4, t1, fail
  li      t1, 1100
  bgeu    a4, t1, fail

  li      TESTNUM, 5              # a register with no side effects reads back exactly
  li      t1, 0x12345678
  sw      t1, 8(t0)
  lw      a5, 8(t0)
  bne     a5, t1, fail

  li      TESTNUM, 6              # sub-word loads from the uncached word
  lbu     a6, 8(t0)
  li      t1, 0x78
  bne     a6, t1, fail
  lhu     a6, 10(t0)
  li      t1, 0x1234
  bne     a6, t1, fail
  lb      a6, 11(t0)
  li      t1, 0x12
  bne     a6, t1, fail

  li      TESTNUM, 7              # SRAM is still cached and correct around them
  la      s0, scratch
  li      t1, 0xcafe
  sw      t1, 0(s0)
  lw      a7, 12(t0)
  lw      t3, 0(s0)
  bne     t3, t1, fail

  sw      zero, 0(t0)             # timer off
  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
scratch: .word 0

RVTEST_DATA_END
