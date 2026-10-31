/* mlkem_x_host.c — what mlkem_x.c's kernels compute, in plain C, for the
   host check of the extension build of ML-KEM (run_kem.sh HOST=1). The
   instructions are modelled as doc/lattice_crypto.md defines them (mont,
   addq, subq on values in [0, q)), and each kernel is written as the
   instruction sequence it replaces: the NTT with mont(zeta b) butterflies,
   the inverse with mont(zeta (b - a)) and the final mont(f r), the base
   multiplication as mont(a0 b0) + mont(gamma mont(a1 b1)) and
   mont(a0 b1) + mont(a1 b0). So the results, including their Montgomery
   factors, are the ones the core produces; the layer order and the
   scheduling, which only affect cycles, are not reproduced. */
#include <stdint.h>
#include "bench_data.h"

#define Q MLKEM_Q

static uint16_t mont(uint32_t p)        /* p R^-1 mod q, q' = -q^-1 mod 2^16 */
{
  uint32_t m = (p * 3327u) & 0xFFFFu;
  uint32_t t = (p + m * Q) >> 16;
  return (uint16_t)(t >= Q ? t - Q : t);
}

static uint16_t addq(uint16_t a, uint16_t b)
{
  unsigned t = a + b;
  return (uint16_t)(t >= Q ? t - Q : t);
}

static uint16_t subq(uint16_t a, uint16_t b)
{
  return (uint16_t)(a >= b ? a - b : a + Q - b);
}

void mlkem_ntt_ct2(uint16_t *r)
{
  unsigned k = 1;
  for (unsigned len = 128; len >= 2; len >>= 1)
    for (unsigned start = 0; start < 256; start += 2 * len) {
      uint16_t zeta = mlkem_zetas[k++];
      for (unsigned j = start; j < start + len; j++) {
        uint16_t t = mont((uint32_t)zeta * r[j + len]);
        r[j + len] = subq(r[j], t);
        r[j] = addq(r[j], t);
      }
    }
}

void mlkem_invntt_x2(uint16_t *r)
{
  unsigned k = 127;
  for (unsigned len = 2; len <= 128; len <<= 1)
    for (unsigned start = 0; start < 256; start += 2 * len) {
      uint16_t zeta = mlkem_zetas[k--];
      for (unsigned j = start; j < start + len; j++) {
        uint16_t t = r[j];
        r[j] = addq(t, r[j + len]);
        r[j + len] = mont((uint32_t)zeta * subq(r[j + len], t));
      }
    }
  for (unsigned j = 0; j < 256; j++)
    r[j] = mont(1441u * r[j]);          /* f = R^2 / 128 mod q */
}

void mlkem_basemul_x(uint16_t *r, const uint16_t *a, const uint16_t *b)
{
  for (unsigned i = 0; i < 128; i++) {
    uint16_t a0 = a[2 * i], a1 = a[2 * i + 1], b0 = b[2 * i], b1 = b[2 * i + 1];
    r[2 * i] = addq(mont((uint32_t)a0 * b0), mont((uint32_t)mlkem_gammas[i] * mont((uint32_t)a1 * b1)));
    r[2 * i + 1] = addq(mont((uint32_t)a0 * b1), mont((uint32_t)a1 * b0));
  }
}
