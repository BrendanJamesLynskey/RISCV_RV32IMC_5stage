/* Link script for the benchmarks: as the ISA tests (code from 0x8000_0000),
   plus the sections C needs and a stack at the top of memory. The benchmarks
   outgrew the SoC's 32 KB SRAM, so run_bench.sh simulates 64 KB (the SRAM's
   depth is a parameter) and gives Spike the same. */
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
  _stack_top = 0x80010000;
  ASSERT(_end <= 0x8000F000, "benchmark leaves under 4 KB of stack")
}
