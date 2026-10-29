/*
 * timer_irq.S — timer interrupts arrive, report the right cause, and are
 * precise: no instruction is skipped or run twice.
 *
 * The timer fires every ~40 cycles while the main loop adds 1 to s5 a
 * thousand times. Each interrupt is taken at some instruction in the loop,
 * and MRET resumes there. If an interrupted instruction were lost or run
 * twice, s5 (and the loop count) would be wrong.
 */

#include "riscv_test.h"
#include "test_macros.h"

#define TIMER_BASE 0x20000200
#define MIE_MTIE   (1 << 7)
#define MSTATUS_MIE (1 << 3)

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la      t0, handler
  csrw    mtvec, t0
  li      s2, 0                   # interrupts taken
  li      s3, 0                   # interrupts with the wrong mcause
  li      s5, 0                   # main-loop accumulator

  # Timer: prescaler 0, compare 40, auto-reload, enabled
  li      t0, TIMER_BASE
  sw      zero, 4(t0)
  li      t1, 40
  sw      t1, 8(t0)
  sw      zero, 12(t0)
  li      t1, 3
  sw      t1, 0(t0)

  li      t1, MIE_MTIE
  csrw    mie, t1
  csrsi   mstatus, MSTATUS_MIE

  # Main loop: 1000 iterations of a mix of ALU work, a load-use and a branch
  li      TESTNUM, 2
  li      s6, 1000
  la      s7, scratch
1:
  addi    s5, s5, 1
  sw      s5, 0(s7)
  lw      t2, 0(s7)
  bne     t2, s5, fail
  addi    s6, s6, -1
  bnez    s6, 1b

  csrci   mstatus, MSTATUS_MIE    # interrupts off before checking

  li      TESTNUM, 3              # every iteration ran exactly once
  li      t1, 1000
  bne     s5, t1, fail

  li      TESTNUM, 4              # interrupts were taken (dozens expected)
  li      t1, 10
  blt     s2, t1, fail

  li      TESTNUM, 5              # all reported mcause = 0x80000007 (timer)
  bnez    s3, fail

  TEST_PASSFAIL

  .align  2
handler:
  csrr    t5, mcause
  li      t6, 0x80000007
  beq     t5, t6, 2f
  addi    s3, s3, 1
2:
  li      t5, TIMER_BASE
  li      t6, 1
  sw      t6, 16(t5)              # clear the match flag
  addi    s2, s2, 1
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
  .align 4
scratch: .word 0
RVTEST_DATA_END
