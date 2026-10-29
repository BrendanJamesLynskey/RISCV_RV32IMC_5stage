/* Link script for the ISA tests: code from 0x8000_0000 (where Spike puts RAM;
   the testbench sets the core's reset PC there, and the SoC's SRAM aliases
   it), tohost and data 4 KB-aligned after it; everything within 32 KB. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text      : { *(.text) }
  . = ALIGN(0x1000);
  .tohost    : { *(.tohost) }
  .data      : { *(.data) }
  .bss       : { *(.bss) }
  _end = .;
  ASSERT(_end <= 0x80008000, "test does not fit in the 32 KB SRAM")
}
