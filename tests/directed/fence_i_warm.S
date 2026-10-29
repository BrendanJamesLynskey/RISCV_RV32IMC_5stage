/*
 * fence_i_warm.S — FENCE.I must make a store to cached code visible.
 *
 * The upstream fence_i test patches code that has never been fetched, so it
 * passes even without FENCE.I support. Here the routine runs first (so its
 * line is in the I-cache), is then overwritten, and must run the new code
 * after FENCE.I.
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

  # Case 3: overwrite its first instruction with "li a0, 2", then FENCE.I
  li      TESTNUM, 3
  la      t0, patch_me
  li      t1, 0x00200513          # addi a0, zero, 2
  sw      t1, 0(t0)
  fence.i
  jal     ra, patch_me
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
