/* Link script for the whole-ML-KEM benchmark (kem_main.c): as link.ld, but
   128 KB. K-PKE keeps the matrix A and a few vectors of polynomials on the
   stack (about 10 KB in Encrypt), so run_kem.sh simulates 128 KB
   (TB_MEM_DEPTH=32768) and gives Spike the same, and the stack has 16 KB. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text      : { *(.text .text.*) }
  .rodata    : { *(.rodata .rodata.* .srodata .srodata.*) }
  . = ALIGN(0x1000);
  .tohost    : { *(.tohost) }
  .data      : { *(.data .data.* .sdata .sdata.*) }
  .bss       : { *(.bss .bss.* .sbss .sbss.* COMMON) }
  _end = .;
  _stack_top = 0x80020000;
  ASSERT(_end <= 0x8001C000, "benchmark leaves under 16 KB of stack")
}
