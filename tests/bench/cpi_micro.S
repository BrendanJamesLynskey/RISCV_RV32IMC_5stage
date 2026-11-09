/*
 * cpi_micro.S — directed micro-tests for the CPI breakdown (cpi_breakdown.py).
 *
 * Every region is straight-line code, repeated 16 times, inside a loop that
 * runs it twice. The marker pair around it retires on each pass; the second
 * pass (caches warm) is the one measured. Built without compressed
 * instructions, so every instruction is one word and none straddles a fetch.
 *
 *   markers 0/1    lw, then an add that uses it           16 load-use bubbles
 *   markers 2/3    lw, then an add that does not          none
 *   markers 4/5    mul, then an add that uses it          16 mul-use bubbles
 *   markers 6/7    mul, then an independent add           none
 *   markers 8/9    csrr, then an add that uses it         16 csr-use bubbles
 *   markers 10/11  csrr, then an independent add          none
 *   markers 12/13  16 forward branches `bnez a1, 1f` over two nops, run seven
 *                  times with a1 = 0 (warm-up), 1, 1, 1, 1, 0, 0. After the
 *                  warm-up the 2-bit counters are at 00. Pass 1: taken,
 *                  predicted not taken (00 -> 01). Pass 2: the same
 *                  (01 -> 10). Passes 3 and 4: predicted taken and right
 *                  (10 -> 11). Pass 5: not taken, predicted taken (11 -> 10).
 *                  Pass 6: the same (10 -> 01).
 */
  .option norvc
  .section .text
  .globl main

  .macro MARK n
  slti    zero, zero, \n
  .endm

  .macro LU
  .rept 16
  lw      t0, 0(a0)
  add     t1, t0, t0
  .endr
  .endm
  .macro NOLU
  .rept 16
  lw      t0, 0(a0)
  add     t1, a0, a0
  .endr
  .endm
  .macro MU
  .rept 16
  mul     t0, a2, a2
  add     t1, t0, t0
  .endr
  .endm
  .macro NOMU
  .rept 16
  mul     t0, a2, a2
  add     t1, a2, a2
  .endr
  .endm
  .macro CU
  .rept 16
  csrr    t0, mscratch
  add     t1, t0, t0
  .endr
  .endm
  .macro NOCU
  .rept 16
  csrr    t0, mscratch
  add     t1, a2, a2
  .endr
  .endm
  .macro BR
  .rept 16
  bnez    a1, 1f
  nop
  nop
1:
  .endr
  .endm

  .macro REGION a, b, body
  li      s1, 2
2:
  MARK    \a
  \body
  MARK    \b
  addi    s1, s1, -1
  bnez    s1, 2b
  .endm

main:
  la      a0, buf
  li      a2, 3
  REGION  0, 1, LU
  REGION  2, 3, NOLU
  REGION  4, 5, MU
  REGION  6, 7, NOMU
  REGION  8, 9, CU
  REGION  10, 11, NOCU

  la      s2, seq
  li      s1, 7
  .balign 256                   /* the BTB has 64 entries, one per 2 bytes of pc: keep the loop branch */
3:                              /* (offset 220) from sharing an entry with any of the 16 branches */
  lbu     a1, 0(s2)
  addi    s2, s2, 1
  MARK    12
  BR
  MARK    13
  addi    s1, s1, -1
  nop
  nop
  bnez    s1, 3b

  li      a0, 0
  ret

  .section .data
  .align  4
buf:
  .word   0x12345678, 0, 0, 0
seq:
  .byte   0, 1, 1, 1, 1, 0, 0
