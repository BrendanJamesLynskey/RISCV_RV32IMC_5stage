/*
 * fence_i_fill.S — FENCE.I must take effect when it acts in the cycle an
 * instruction-cache fill completes.
 *
 * FENCE.I acts in EX. Here it sits in the third word of a 16-byte line, so
 * when it reaches EX the fetch stage is on the first word of the next line,
 * which has never been fetched: an I-cache miss. The pipeline waits for the
 * fill, and FENCE.I acts in the cycle the filled word is delivered. The
 * invalidate must not be lost in that cycle, or the routine patched before
 * the fence (already in the I-cache) runs its old code.
 */

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  # Case 2: run the routine once, so its line is in the I-cache
  li      TESTNUM, 2
  jal     ra, patch_me
  li      t1, 1
  bne     a0, t1, fail

  # Case 3: overwrite its first instruction with "li a0, 2"
  li      TESTNUM, 3
  la      t0, patch_me
  li      t1, 0x00200513          # addi a0, zero, 2
  sw      t1, 0(t0)

  .option push
  .option norvc                   # fixed sizes, so the line offsets are known
  .align  4
  nop                             # line + 0
  nop                             # line + 4
  fence.i                         # line + 8: in EX while IF misses on the next line
  nop                             # line + 12
  jal     ra, patch_me            # next line + 0: never fetched before
  .option pop
  li      t1, 2
  bne     a0, t1, fail

  TEST_PASSFAIL

  .option push
  .option norvc                   # the patched instruction must be 32-bit
  .align  4
patch_me:
  addi    a0, zero, 1
  ret
  .option pop

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
