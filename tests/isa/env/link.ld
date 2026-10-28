/* Link script for the ISA tests: code from address 0 (the reset vector),
   tohost and data 4 KB-aligned after it; everything in the 32 KB SRAM. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x00000000;
  .text.init : { *(.text.init) }
  .text      : { *(.text) }
  . = ALIGN(0x1000);
  .tohost    : { *(.tohost) }
  .data      : { *(.data) }
  .bss       : { *(.bss) }
  _end = .;
  ASSERT(_end <= 0x8000, "test does not fit in the 32 KB SRAM")
}
