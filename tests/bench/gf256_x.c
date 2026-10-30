/* gf256_x.c — the same with gfmul4, Xbrvdsp's packed GF(2^8) multiply
   (four byte lanes, modulo x^8 + poly; poly set by gf.cfg), and Zbkb's
   rotates. The syndromes go four at a time: each word holds four of them,
   and each received byte, copied to all four lanes, is added after a
   gfmul4 by (alpha^j .. alpha^(j+3)). The Chien search keeps Lambda's 16
   terms in four words, each step one gfmul4 per word. InvMixColumns is
   FIPS-197's matrix directly: four gfmul4, one per rotation of the column.
   (Inline .insn: the assembler does not know Xbrvdsp. Both macros are
   volatile, so no gfmul4 is moved above the gf.cfg it depends on.) */
#include <stdint.h>
#include "bench_data.h"

#define GFMUL4(a, b) ({ uint32_t r_; __asm__ volatile (".insn r 0x0b, 5, 0, %0, %1, %2" \
                                                       : "=r" (r_) : "r" (a), "r" (b)); r_; })
#define GF_CFG(a)    __asm__ volatile (".insn r 0x0b, 5, 1, x0, %0, x0" :: "r" (a))

static uint32_t bytes4(const uint8_t *p)
{
  return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

__attribute__((noipa))
void rs_syndromes_gf(uint8_t *S, const uint8_t *r)
{
  const uint32_t *a = (const uint32_t *)rs_alpha;
  uint32_t a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3], a4 = a[4], a5 = a[5], a6 = a[6], a7 = a[7];
  uint32_t s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0, s7 = 0;
  GF_CFG(0x1D);
  for (int k = 0; k < RS_N; k++) {
    uint32_t b = r[k] * 0x01010101u;
    s0 = GFMUL4(s0, a0) ^ b; s1 = GFMUL4(s1, a1) ^ b;
    s2 = GFMUL4(s2, a2) ^ b; s3 = GFMUL4(s3, a3) ^ b;
    s4 = GFMUL4(s4, a4) ^ b; s5 = GFMUL4(s5, a5) ^ b;
    s6 = GFMUL4(s6, a6) ^ b; s7 = GFMUL4(s7, a7) ^ b;
  }
  uint32_t *w = (uint32_t *)S;
  w[0] = s0; w[1] = s1; w[2] = s2; w[3] = s3; w[4] = s4; w[5] = s5; w[6] = s6; w[7] = s7;
}

__attribute__((noipa))
int rs_chien_gf(uint8_t *pos, const uint8_t *lam)
{
  uint32_t w0 = bytes4(lam + 1), w1 = bytes4(lam + 5), w2 = bytes4(lam + 9), w3 = bytes4(lam + 13);
  uint32_t m0 = bytes4(rs_exp + 1), m1 = bytes4(rs_exp + 5), m2 = bytes4(rs_exp + 9), m3 = bytes4(rs_exp + 13);
  uint32_t l0 = lam[0];
  int n = 0;
  GF_CFG(0x1D);
  for (int i = 1; i <= 255; i++) {
    w0 = GFMUL4(w0, m0); w1 = GFMUL4(w1, m1);
    w2 = GFMUL4(w2, m2); w3 = GFMUL4(w3, m3);
    uint32_t x = w0 ^ w1 ^ w2 ^ w3;
    x ^= x >> 16;
    x ^= x >> 8;
    if (((x ^ l0) & 0xFF) == 0) pos[n++] = i - 1;
  }
  return n;
}

static inline uint32_t ror32(uint32_t x, int n)
{
  return (x >> n) | (x << (32 - n));
}

__attribute__((noipa))
void aes_invmix_gf(uint32_t *out, const uint32_t *in, int words)
{
  GF_CFG(0x1B);
  for (int i = 0; i < words; i++) {
    uint32_t c = in[i];
    out[i] = GFMUL4(c, 0x0E0E0E0E) ^ GFMUL4(ror32(c, 8), 0x0B0B0B0B) ^
             GFMUL4(ror32(c, 16), 0x0D0D0D0D) ^ GFMUL4(ror32(c, 24), 0x09090909);
  }
}
