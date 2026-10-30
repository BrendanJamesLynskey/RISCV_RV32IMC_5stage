/*
 * zk.S — Zbkb and Zknh (ratified scalar cryptography), one case each.
 *
 * Every instruction on the same operands (rs1 = 0x8badf00d, rs2 =
 * 0x01234567); the expected values were computed in Python from the
 * specification's formulas, and the run is compared with Spike's own
 * implementation in lockstep. Each result is used by the next instruction
 * (forwarding from EX/MEM). The last cases chain results through rd = rs1,
 * and check zip and unzip are inverses.
 */

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  li      s0, 0x8badf00d
  li      s1, 0x01234567

  li      TESTNUM, 2
  ror     a0, s0, s1
  li      t1, 0x1b175be0
  bne     a0, t1, fail

  li      TESTNUM, 3
  rol     a0, s0, s1
  li      t1, 0xd6f806c5
  bne     a0, t1, fail

  li      TESTNUM, 4
  rori    a0, s0, 13
  li      t1, 0x806c5d6f
  bne     a0, t1, fail

  li      TESTNUM, 5
  andn    a0, s0, s1
  li      t1, 0x8a8cb008
  bne     a0, t1, fail

  li      TESTNUM, 6
  orn     a0, s0, s1
  li      t1, 0xfffdfa9d
  bne     a0, t1, fail

  li      TESTNUM, 7
  xnor    a0, s0, s1
  li      t1, 0x75714a95
  bne     a0, t1, fail

  li      TESTNUM, 8
  pack    a0, s0, s1
  li      t1, 0x4567f00d
  bne     a0, t1, fail

  li      TESTNUM, 9
  packh   a0, s0, s1
  li      t1, 0x670d
  bne     a0, t1, fail

  li      TESTNUM, 10
  brev8   a0, s0
  li      t1, 0xd1b50fb0
  bne     a0, t1, fail

  li      TESTNUM, 11
  rev8    a0, s0
  li      t1, 0xdf0ad8b
  bne     a0, t1, fail

  li      TESTNUM, 12
  zip     a0, s0
  li      t1, 0xd58a88f3
  bne     a0, t1, fail

  li      TESTNUM, 13
  unzip   a0, s0
  li      t1, 0xbec213c3
  bne     a0, t1, fail

  li      TESTNUM, 14
  sha256sum0 a0, s0
  li      t1, 0x55471742
  bne     a0, t1, fail

  li      TESTNUM, 15
  sha256sum1 a0, s0
  li      t1, 0xe167c4bb
  bne     a0, t1, fail

  li      TESTNUM, 16
  sha256sig0 a0, s0
  li      t1, 0x7661870a
  bne     a0, t1, fail

  li      TESTNUM, 17
  sha256sig1 a0, s0
  li      t1, 0x46259fdf
  bne     a0, t1, fail

  li      TESTNUM, 18
  sha512sum0r a0, s0, s1
  li      t1, 0x487ec1ab
  bne     a0, t1, fail

  li      TESTNUM, 19
  sha512sum1r a0, s0, s1
  li      t1, 0xc2475dfe
  bne     a0, t1, fail

  li      TESTNUM, 20
  sha512sig0l a0, s0, s1
  li      t1, 0x6d4a0e16
  bne     a0, t1, fail

  li      TESTNUM, 21
  sha512sig0h a0, s0, s1
  li      t1, 0xa34a0e16
  bne     a0, t1, fail

  li      TESTNUM, 22
  sha512sig1l a0, s0, s1
  li      t1, 0xabedc6dd
  bne     a0, t1, fail

  li      TESTNUM, 23
  sha512sig1h a0, s0, s1
  li      t1, 0x37edc6dd
  bne     a0, t1, fail

  # zip then unzip gives the value back; brev8 twice, rev8 twice likewise
  li      TESTNUM, 24
  zip     a0, s0
  unzip   a0, a0
  bne     a0, s0, fail
  brev8   a0, s0
  brev8   a0, a0
  bne     a0, s0, fail
  rev8    a0, s0
  rev8    a0, a0
  bne     a0, s0, fail

  # rotates by 0 and by 31 (the edges of the shift amount)
  li      TESTNUM, 25
  li      t0, 0
  ror     a0, s0, t0
  bne     a0, s0, fail
  rori    a0, s0, 31
  rol     a1, a0, zero
  bne     a1, a0, fail
  li      t0, 32 + 1          # only rs2[4:0] counts: rotate right by 1 undoes rori 31
  ror     a1, a0, t0
  bne     a1, s0, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
