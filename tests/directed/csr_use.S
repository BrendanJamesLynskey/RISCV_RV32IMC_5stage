/*
 * csr_use.S — every way an instruction can use a CSR instruction's result at once.
 *
 * A CSR is read in MEM, and its value is not forwarded from MEM into EX (it
 * was on a critical path): the hazard unit holds a dependent instruction in
 * ID for one cycle and the value is forwarded from WB. Each case uses the
 * result in the very next instruction, in a different role: as rs1, as rs2,
 * as a branch operand, as store data, as a load address, as a JALR target,
 * and as the next CSR instruction's operand. Also: csrrw swapping, and the
 * immediate forms, whose result is the old value.
 */

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  .option push
  .option norvc                   # keep each pair adjacent

  # Case 2: as rs1
  li      TESTNUM, 2
  li      t0, 41
  csrw    mscratch, t0
  csrr    a0, mscratch
  addi    a1, a0, 1
  li      t1, 42
  bne     a1, t1, fail

  # Case 3: as rs2
  li      TESTNUM, 3
  csrr    a0, mscratch
  sub     a1, zero, a0
  li      t1, -41
  bne     a1, t1, fail

  # Case 4: as a branch operand
  li      TESTNUM, 4
  li      t1, 41
  csrr    a0, mscratch
  bne     a0, t1, fail

  # Case 5: as store data, then read back
  li      TESTNUM, 5
  la      t2, buf
  csrr    a0, mscratch
  sw      a0, 0(t2)
  lw      a1, 0(t2)
  li      t1, 41
  bne     a1, t1, fail

  # Case 6: as a load address
  li      TESTNUM, 6
  la      t2, buf
  csrw    mscratch, t2
  csrr    a0, mscratch
  lw      a1, 0(a0)
  li      t1, 41
  bne     a1, t1, fail

  # Case 7: as a JALR target
  li      TESTNUM, 7
  la      t2, 1f
  csrw    mscratch, t2
  csrr    a0, mscratch
  jalr    ra, 0(a0)
  j       fail
1:

  # Case 8: csrrw swaps, and the old value feeds the next CSR instruction
  li      TESTNUM, 8
  li      t0, 100
  csrw    mscratch, t0
  li      t0, 200
  csrrw   a0, mscratch, t0        # a0 = 100, mscratch = 200
  csrrw   a1, mscratch, a0        # a1 = 200, mscratch = 100
  li      t1, 200
  bne     a1, t1, fail
  csrr    a2, mscratch
  li      t1, 100
  bne     a2, t1, fail

  # Case 9: the immediate forms return the old value
  li      TESTNUM, 9
  csrrsi  a0, mscratch, 3         # a0 = 100, mscratch = 103
  addi    a0, a0, 1
  li      t1, 101
  bne     a0, t1, fail
  csrrci  a0, mscratch, 1         # a0 = 103, mscratch = 102
  addi    a0, a0, -103
  bnez    a0, fail
  csrr    a0, mscratch
  li      t1, 102
  bne     a0, t1, fail

  .option pop

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
buf: .word 41
RVTEST_DATA_END
