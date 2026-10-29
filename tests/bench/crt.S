/*
 * crt.S — start-up for the benchmarks: set the stack, call main, and report
 * through tohost as the ISA tests do (main returns 0: pass, n: fail case n).
 * Any trap reports case 1337.
 */
  .section .text.init
  .globl _start
_start:
  la      sp, _stack_top
  la      t0, trap
  csrw    mtvec, t0
  call    main
  beqz    a0, 1f
  slli    a0, a0, 1
  ori     a0, a0, 1
  j       2f
1:
  li      a0, 1
2:
  la      t0, tohost
  sw      a0, 0(t0)
3:
  j       3b

  .align  2
trap:
  li      a0, (1337 << 1) | 1
  la      t0, tohost
  sw      a0, 0(t0)
4:
  j       4b

  .section .tohost, "aw", @progbits
  .align  6
  .globl  tohost
tohost:   .dword 0
  .align  6
  .globl  fromhost
fromhost: .dword 0
