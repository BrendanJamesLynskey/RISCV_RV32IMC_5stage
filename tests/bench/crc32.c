/* crc32.c — CRC-32 (zlib's: reflected, polynomial 0x04C11DB7, initial and
   final value all ones) in plain RV32IMC C, the usual table-driven form: one
   1 KB table, one lookup per byte. */
#include <stdint.h>
#include "bench_data.h"

__attribute__((noipa))
uint32_t crc32_table(const uint8_t *p, int len)
{
  uint32_t crc = 0xFFFFFFFF;
  for (int i = 0; i < len; i++)
    crc = crc32_tab[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
  return crc ^ 0xFFFFFFFF;
}
