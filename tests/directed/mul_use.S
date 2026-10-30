/*
 * mul_use.S — every way an instruction can use a multiply's result at once.
 *
 * A multiply computes in MEM, so its result is not ready to forward from MEM
 * into EX: the hazard unit holds a dependent instruction in ID for one cycle
 * (a mul-use bubble) and the result is forwarded from WB. Each case uses the
 * result in the very next instruction, in a different role: as rs1, as rs2,
 * as a branch operand, as store data, as a load address, as the next
 * multiply's operand, as a JALR target, and as a MAC operand. The high-half
 * multiplies use negative operands, so their sign handling is checked too.
 */

#include "riscv_test.h"
#include "test_macros.h"

#define MAC(a, b)     .insn r CUSTOM_0, 0, 0, x0, a, b
#define ACC_SET(a)    .insn r CUSTOM_0, 0, 4, x0, a, x0
#define ACC_RDL(d)    .insn r CUSTOM_0, 3, 0, d, x0, x0

RVTEST_RV32U
RVTEST_CODE_BEGIN

  .option push
  .option norvc                   # keep each pair adjacent, with no compressed forms

  # Case 2: the product as rs1 of the next instruction
  li      TESTNUM, 2
  li      a1, 7
  li      a2, 6
  mul     a3, a1, a2
  addi    a4, a3, 1
  li      t1, 43
  bne     a4, t1, fail

  # Case 3: as rs2
  li      TESTNUM, 3
  mul     a3, a1, a2
  sub     a4, zero, a3
  li      t1, -42
  bne     a4, t1, fail

  # Case 4: as a branch operand
  li      TESTNUM, 4
  mul     a3, a1, a2
  li      t1, 42
  mul     a3, a1, a2
  bne     a3, t1, fail

  # Case 5: as store data, then read back
  li      TESTNUM, 5
  la      t0, buf
  mul     a3, a1, a2
  sw      a3, 0(t0)
  lw      a4, 0(t0)
  li      t1, 42
  bne     a4, t1, fail

  # Case 6: as a load address
  li      TESTNUM, 6
  la      t0, buf
  li      t2, 1
  mul     a3, t0, t2
  lw      a4, 0(a3)
  li      t1, 42
  bne     a4, t1, fail

  # Case 7: a chain of multiplies, each using the last: 3^5
  li      TESTNUM, 7
  li      a1, 3
  mul     a3, a1, a1
  mul     a3, a3, a1
  mul     a3, a3, a1
  mul     a3, a3, a1
  li      t1, 243
  bne     a3, t1, fail

  # Case 8: the high halves, signed and mixed, with negative operands
  li      TESTNUM, 8
  li      a1, -2
  li      a2, 0x40000000
  mulh    a3, a1, a2              # -2 * 2^30 = -2^31: high word -1
  addi    a4, a3, 1
  bnez    a4, fail
  mulhsu  a3, a1, a1              # -2 * (2^32 - 2): high word -2
  addi    a4, a3, 2
  bnez    a4, fail
  mulhu   a3, a1, a1              # (2^32 - 2)^2: high word 2^32 - 4
  addi    a4, a3, 4
  bnez    a4, fail

  # Case 9: as a JALR target
  li      TESTNUM, 9
  la      t0, target
  li      t2, 1
  mul     a3, t0, t2
  jalr    ra, 0(a3)
  j       fail
target:
  # Case 10: as a MAC operand
  li      TESTNUM, 10
  ACC_SET(zero)
  li      a1, 100
  mul     a3, a1, a1
  MAC(a3, a1)                     # 10000 * 100
  ACC_RDL(a4)
  li      t1, 1000000
  bne     a4, t1, fail

  # Case 11: a load feeding a multiply feeding an add (load-use, then mul-use)
  li      TESTNUM, 11
  la      t0, buf
  lw      a1, 0(t0)
  mul     a3, a1, a1
  addi    a4, a3, -1764
  bnez    a4, fail

  .option pop

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
buf: .word 0
RVTEST_DATA_END
