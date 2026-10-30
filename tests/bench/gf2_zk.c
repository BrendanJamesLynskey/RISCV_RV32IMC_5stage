/* gf2_zk.c — the same with carry-less multiply (Zbkc) and Barrett
   reduction. Every kernel is one formula: for a word x (degree below 64
   once multiplied by x^32),
     q = clmulh(x, mu) ^ x;  x x^32 mod P = clmul(q, P)
   with P less its x^32 term and mu = floor(x^64 / P), also less it.
   A CRC of degree n below 32 uses P x^(32-n), so the CRC sits left-aligned
   in a word and the loop is the same for every CRC: only the two constants
   change (gen_data.py). Reflected CRCs bit-reverse each word (rev8, brev8:
   Zbkb); the others take it big-endian (rev8). The LFSR's 32 steps are the
   same reduction with no data, and its jump ahead's products are
   clmul/clmulh then the reduction of the high word. */
#include <stdint.h>
#include "bench_data.h"

#define OP2(name, a, b) ({ uint32_t r_; __asm__ (name " %0, %1, %2" : "=r" (r_) : "r" (a), "r" (b)); r_; })
#define OP1(name, a)    ({ uint32_t r_; __asm__ (name " %0, %1" : "=r" (r_) : "r" (a)); r_; })

__attribute__((noipa))
uint32_t crc32c_clmul(const uint32_t *p, int len)
{
  uint32_t crc = 0xFFFFFFFF;
  for (int i = 0; i < len / 4; i++) {
    uint32_t x = crc ^ OP1("brev8", OP1("rev8", p[i]));
    uint32_t q = OP2("clmulh", x, CRC32C_MU) ^ x;
    crc = OP2("clmul", q, CRC32C_P);
  }
  return OP1("brev8", OP1("rev8", crc)) ^ 0xFFFFFFFF;
}

/* Any CRC of degree n up to 32, MSB first, initial value 0, no final XOR
   (CRC-16/XMODEM, CRC-8/SMBUS): one routine, the constants passed in */
__attribute__((noipa))
uint32_t crc_clmul_msb(const uint32_t *p, int len, uint32_t P, uint32_t mu, int n)
{
  uint32_t c = 0;
  for (int i = 0; i < len / 4; i++) {
    uint32_t x = c ^ OP1("rev8", p[i]);
    uint32_t q = OP2("clmulh", x, mu) ^ x;
    c = OP2("clmul", q, P);
  }
  return c >> (32 - n);
}

__attribute__((noipa))
void lfsr_clmul(uint32_t *out, uint32_t s, int n)
{
  for (int i = 0; i < n; i++) {
    uint32_t q = OP2("clmulh", s, LFSR_MU) ^ s;
    s = OP2("clmul", q, LFSR_P);
    out[i] = s;
  }
}

static uint32_t gf2_mulmod_clmul(uint32_t a, uint32_t b)
{
  uint32_t lo = OP2("clmul", a, b), hi = OP2("clmulh", a, b);
  uint32_t q = OP2("clmulh", hi, LFSR_MU) ^ hi;
  return OP2("clmul", q, LFSR_P) ^ lo;
}

__attribute__((noipa))
uint32_t lfsr_jump_clmul(uint32_t s, uint32_t e)
{
  uint32_t m = 2;
  for (; e; e >>= 1) {
    if (e & 1) s = gf2_mulmod_clmul(s, m);
    m = gf2_mulmod_clmul(m, m);
  }
  return s;
}
