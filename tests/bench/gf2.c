/* gf2.c — polynomials over GF(2) in plain RV32IMC C, the baselines for
   gf2_zk.c. CRCs: CRC-32 a bit at a time (no table), and the usual
   byte-table forms of CRC-32C, CRC-16/XMODEM and CRC-8/SMBUS. A 32-bit
   Galois LFSR as a random-number generator (P = x^32 + x^22 + x^2 + x + 1,
   each output the state 32 steps on), a bit at a time and a byte at a time;
   xorshift32 for comparison; and the LFSR's jump ahead, which multiplies the
   state by x^N mod P (square and multiply, each product a shift-and-XOR
   loop). */
#include <stdint.h>
#include "bench_data.h"

__attribute__((noipa))
uint32_t crc32_bitwise(const uint8_t *p, int len)
{
  uint32_t crc = 0xFFFFFFFF;
  for (int i = 0; i < len; i++) {
    crc ^= p[i];
    for (int k = 0; k < 8; k++)
      crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
  }
  return crc ^ 0xFFFFFFFF;
}

__attribute__((noipa))
uint32_t crc32c_table(const uint8_t *p, int len)
{
  uint32_t crc = 0xFFFFFFFF;
  for (int i = 0; i < len; i++)
    crc = crc32c_tab[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
  return crc ^ 0xFFFFFFFF;
}

__attribute__((noipa))
uint32_t crc16_table(const uint8_t *p, int len)
{
  uint32_t crc = 0;
  for (int i = 0; i < len; i++)
    crc = ((crc << 8) ^ crc16_tab[((crc >> 8) ^ p[i]) & 0xFF]) & 0xFFFF;
  return crc;
}

__attribute__((noipa))
uint32_t crc8_table(const uint8_t *p, int len)
{
  uint32_t crc = 0;
  for (int i = 0; i < len; i++)
    crc = crc8_tab[crc ^ p[i]];
  return crc;
}

__attribute__((noipa))
void lfsr_bitwise(uint32_t *out, uint32_t s, int n)
{
  for (int i = 0; i < n; i++) {
    for (int k = 0; k < 32; k++)
      s = (s << 1) ^ (LFSR_P & -(s >> 31));
    out[i] = s;
  }
}

__attribute__((noipa))
void lfsr_table(uint32_t *out, uint32_t s, int n)
{
  for (int i = 0; i < n; i++) {
    for (int k = 0; k < 4; k++)
      s = (s << 8) ^ lfsr_tab[s >> 24];
    out[i] = s;
  }
}

__attribute__((noipa))
void xorshift32(uint32_t *out, uint32_t s, int n)
{
  for (int i = 0; i < n; i++) {
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    out[i] = s;
  }
}

/* a b mod P, b's bits from the top (Horner): shift, reduce, add */
static uint32_t gf2_mulmod(uint32_t a, uint32_t b)
{
  uint32_t r = 0;
  for (int k = 31; k >= 0; k--) {
    r = (r << 1) ^ (LFSR_P & -(r >> 31));
    r ^= a & -((b >> k) & 1);
  }
  return r;
}

__attribute__((noipa))
uint32_t lfsr_jump(uint32_t s, uint32_t e)
{
  uint32_t m = 2;                                /* x */
  for (; e; e >>= 1) {
    if (e & 1) s = gf2_mulmod(s, m);
    m = gf2_mulmod(m, m);
  }
  return s;
}
