/* crc32_zk.c — the same CRC-32 a word at a time by carry-less multiply
   (Zbkc) and Barrett reduction. The CRC is reflected; working in the
   normal (MSB-first) domain instead, each little-endian word is
   bit-reversed (rev8 then brev8, Zbkb), and then
     x = crc ^ w;  q = clmulh(x, mu) ^ x;  crc = clmul(q, P)
   with P = 0x04C11DB7 and mu = floor(x^64 / P(x)) without its x^32 term.
   gen_data.py checks this formula against zlib. len is a multiple of 4. */
#include <stdint.h>

#define OP2(name, a, b) ({ uint32_t r_; __asm__ (name " %0, %1, %2" : "=r" (r_) : "r" (a), "r" (b)); r_; })
#define OP1(name, a)    ({ uint32_t r_; __asm__ (name " %0, %1" : "=r" (r_) : "r" (a)); r_; })

__attribute__((noipa))
uint32_t crc32_clmul(const uint32_t *p, int len)
{
  const uint32_t P = 0x04C11DB7, MU = 0x04D101DF;
  uint32_t crc = 0xFFFFFFFF;                     /* all ones: the same reversed */
  for (int i = 0; i < len / 4; i++) {
    uint32_t x = crc ^ OP1("brev8", OP1("rev8", p[i]));
    uint32_t q = OP2("clmulh", x, MU) ^ x;
    crc = OP2("clmul", q, P);
  }
  return OP1("brev8", OP1("rev8", crc)) ^ 0xFFFFFFFF;
}
