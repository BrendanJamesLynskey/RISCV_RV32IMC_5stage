/* mlkem.c — ML-KEM's polynomial arithmetic in plain C, as pq-crystals'
   reference implementation does it (ref/ntt.c, ref/reduce.c, ref/poly.c):
   int16_t coefficients, Montgomery reduction (R = 2^16) for products,
   Barrett reduction in the inverse NTT, and zetas in Montgomery form. The
   results are correct mod q but not reduced to [0, q): dsp.c compares
   them mod q. */
#include <stdint.h>
#include "bench_data.h"

#define QINV -3327                     /* q^-1 mod 2^16 */

static int16_t montgomery_reduce(int32_t a)
{
  int16_t t = (int16_t)a * QINV;
  return (a - (int32_t)t * MLKEM_Q) >> 16;
}

static int16_t barrett_reduce(int16_t a)
{
  const int16_t v = ((1 << 26) + MLKEM_Q / 2) / MLKEM_Q;
  int16_t t = ((int32_t)v * a + (1 << 25)) >> 26;
  return a - t * MLKEM_Q;
}

static int16_t fqmul(int16_t a, int16_t b)
{
  return montgomery_reduce((int32_t)a * b);
}

/* Forward NTT, then Barrett-reduce every coefficient (poly_ntt) */
__attribute__((noipa))
void mlkem_ntt(int16_t r[256])
{
  unsigned k = 1;
  for (unsigned len = 128; len >= 2; len >>= 1)
    for (unsigned start = 0; start < 256; start += 2 * len) {
      int16_t zeta = mlkem_zetas_ref[k++];
      for (unsigned j = start; j < start + len; j++) {
        int16_t t = fqmul(zeta, r[j + len]);
        r[j + len] = r[j] - t;
        r[j] = r[j] + t;
      }
    }
  for (unsigned j = 0; j < 256; j++)
    r[j] = barrett_reduce(r[j]);
}

/* Inverse NTT; the output is multiplied by R (invntt_tomont) */
__attribute__((noipa))
void mlkem_invntt(int16_t r[256])
{
  const int16_t f = 1441;              /* R^2 / 128 mod q */
  unsigned k = 127;
  for (unsigned len = 2; len <= 128; len <<= 1)
    for (unsigned start = 0; start < 256; start += 2 * len) {
      int16_t zeta = mlkem_zetas_ref[k--];
      for (unsigned j = start; j < start + len; j++) {
        int16_t t = r[j];
        r[j] = barrett_reduce(t + r[j + len]);
        r[j + len] = r[j + len] - t;
        r[j + len] = fqmul(zeta, r[j + len]);
      }
    }
  for (unsigned j = 0; j < 256; j++)
    r[j] = fqmul(r[j], f);
}

static void basemul(int16_t r[2], const int16_t a[2], const int16_t b[2], int16_t zeta)
{
  r[0]  = fqmul(a[1], b[1]);
  r[0]  = fqmul(r[0], zeta);
  r[0] += fqmul(a[0], b[0]);
  r[1]  = fqmul(a[0], b[1]);
  r[1] += fqmul(a[1], b[0]);
}

/* The 128 degree-one products of two NTT-domain polynomials (times R^-1) */
__attribute__((noipa))
void mlkem_basemul(int16_t *r, const int16_t *a, const int16_t *b)
{
  for (unsigned i = 0; i < 64; i++) {
    basemul(&r[4 * i], &a[4 * i], &b[4 * i], mlkem_zetas_ref[64 + i]);
    basemul(&r[4 * i + 2], &a[4 * i + 2], &b[4 * i + 2], -mlkem_zetas_ref[64 + i]);
  }
}

/* c = a * b in Z_q[X]/(X^256 + 1); a and b are overwritten by their NTTs */
__attribute__((noipa))
void mlkem_polymul(int16_t *c, int16_t *a, int16_t *b)
{
  mlkem_ntt(a);
  mlkem_ntt(b);
  mlkem_basemul(c, a, b);
  mlkem_invntt(c);
}
