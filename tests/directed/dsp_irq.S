/*
 * dsp_irq.S — an interrupted MAC must not touch the accumulator.
 *
 * Interrupts are taken at the instruction in EX, which is squashed and runs
 * again after MRET. If a MAC squashed that way still added to acc, it would
 * be counted twice. The timer fires every ~40 cycles while a loop of MACs
 * runs; the final accumulator must be exactly the number of MACs times the
 * product. The handler also counts the interrupts taken at a MAC (mepc
 * points at one), and the test requires some, so the case is really hit.
 * (Spike has no timer, so this test checks itself and runs without
 * lockstep.)
 */

#include "riscv_test.h"
#include "test_macros.h"

#define TIMER_BASE  0x20000200
#define MIE_MTIE    (1 << 7)
#define MSTATUS_MIE (1 << 3)

#define MAC(a, b)     .insn r CUSTOM_0, 0, 0, x0, a, b
#define ACC_SET(a)    .insn r CUSTOM_0, 0, 4, x0, a, x0
#define ACC_RD(d, sh) .insn r CUSTOM_0, 1, 0, d, x0, x##sh

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la      t0, handler
  csrw    mtvec, t0
  li      s2, 0                   # interrupts taken
  li      s3, 0                   # interrupts with the wrong mcause
  li      s4, 0                   # interrupts taken at a MAC
  ACC_SET(x0)

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

  # Main loop: 500 iterations of 4 MACs of 3 x 3
  li      TESTNUM, 2
  li      s8, 3
  li      s6, 500
  .option push
  .option norvc                   # 32-bit instructions, so the handler can read them at mepc
1:
  MAC(s8, s8)
  MAC(s8, s8)
  MAC(s8, s8)
  MAC(s8, s8)
  addi    s6, s6, -1
  bnez    s6, 1b
  .option pop

  csrci   mstatus, MSTATUS_MIE    # interrupts off before checking

  li      TESTNUM, 3              # every MAC counted exactly once: 2000 x 9
  ACC_RD(a0, 0)
  li      t1, 18000
  bne     a0, t1, fail

  li      TESTNUM, 4              # interrupts were taken (dozens expected)
  li      t1, 10
  blt     s2, t1, fail

  li      TESTNUM, 5              # some of them at a MAC
  li      t1, 5
  blt     s4, t1, fail

  li      TESTNUM, 6              # all reported mcause = 0x80000007 (timer)
  bnez    s3, fail

  TEST_PASSFAIL

  .align  2
handler:
  csrr    t5, mcause
  li      t6, 0x80000007
  beq     t5, t6, 2f
  addi    s3, s3, 1
2:
  csrr    t5, mepc                # was the interrupted instruction a MAC?
  lw      t5, 0(t5)
  andi    t5, t5, 0x7f
  li      t6, 0x0b                # custom-0
  bne     t5, t6, 3f
  addi    s4, s4, 1
3:
  li      t5, TIMER_BASE
  li      t6, 1
  sw      t6, 16(t5)              # clear the match flag
  addi    s2, s2, 1
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
