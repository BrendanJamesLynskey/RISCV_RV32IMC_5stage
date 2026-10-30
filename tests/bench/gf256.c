/* gf256.c — GF(2^8) in plain RV32IMC C, the baselines for gf256_x.c.
   Reed-Solomon RS(255,223) over 0x11D: the 32 syndromes by Horner's rule
   and the Chien search for the error locator's roots, both multiplying
   with the usual exp/log tables (a b = exp[log a + log b], exp doubled to
   510 entries so the sum needs no reduction). And AES InvMixColumns four
   bytes at a time (SWAR), the fast constant-time C form: the state's
   columns are multiplied by 4 first, which turns InvMixColumns into
   MixColumns, and xtime works on all four bytes at once. */
#include <stdint.h>
#include "bench_data.h"

__attribute__((noipa))
void rs_syndromes(uint8_t *S, const uint8_t *r)
{
  for (int j = 0; j < RS_NSYM; j++) {
    uint32_t s = 0;
    for (int k = 0; k < RS_N; k++)
      s = (s ? rs_exp[rs_log[s] + j] : 0) ^ r[k];   /* s alpha^j + r_k */
    S[j] = s;
  }
}

/* Positions k of the errors: Lambda(alpha^(k+1)) = 0. Each term
   lambda_m alpha^(m i) is kept as its log, which steps by m each i. */
__attribute__((noipa))
int rs_chien(uint8_t *pos, const uint8_t *lam)
{
  int lg[RS_ERRS + 1], n = 0;
  for (int m = 1; m <= RS_ERRS; m++)
    lg[m] = lam[m] ? rs_log[lam[m]] : -1;
  for (int i = 1; i <= 255; i++) {
    uint32_t v = lam[0];
    for (int m = 1; m <= RS_ERRS; m++)
      if (lg[m] >= 0) {
        lg[m] += m;
        if (lg[m] >= 255) lg[m] -= 255;
        v ^= rs_exp[lg[m]];
      }
    if (v == 0) pos[n++] = i - 1;
  }
  return n;
}

static inline uint32_t xt4(uint32_t x)          /* xtime on each byte */
{
  return ((x & 0x7F7F7F7F) << 1) ^ (((x >> 7) & 0x01010101) * 0x1B);
}

static inline uint32_t ror32(uint32_t x, int n)
{
  return (x >> n) | (x << (32 - n));
}

__attribute__((noipa))
void aes_invmix(uint32_t *out, const uint32_t *in, int words)
{
  for (int i = 0; i < words; i++) {
    uint32_t c = in[i];
    c ^= xt4(xt4(c ^ ror32(c, 16)));             /* a_i ^= 4 (a_i ^ a_(i+2)) */
    uint32_t r1 = ror32(c, 8);                   /* then MixColumns */
    out[i] = xt4(c ^ r1) ^ r1 ^ ror32(c, 16) ^ ror32(c, 24);
  }
}
