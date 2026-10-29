/* Link script for the benchmarks: as the ISA tests (code from 0x8000_0000,
   everything within the 32 KB SRAM), plus the sections C needs and a stack
   at the top of memory. */
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
  _stack_top = 0x80008000;
  ASSERT(_end <= 0x80007000, "benchmark leaves under 4 KB of stack")
}
