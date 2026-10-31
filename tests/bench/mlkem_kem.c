/* mlkem_kem.c — ML-KEM-512 (FIPS 203: KeyGen, Encaps, Decaps) on top of
   either polynomial back end, structured as the standard and pq-crystals'
   reference are: SampleNTT (rejection from SHAKE128), the centred binomial
   distribution, compression and byte encoding, K-PKE, then the KEM with
   implicit rejection in Decaps. The back end is chosen at compile time:
   without MLKEM_EXT the reference arithmetic (mlkem.c: int16_t
   coefficients, Barrett-reduced NTT output, not in [0, q)); with it the
   Xbrvdsp kernels (mlkem_x.c: uint16_t in [0, q), two to a word). The two
   leave the same Montgomery factors (basemul times R^-1, the inverse NTT
   times R), so the top level is the same and follows pq-crystals:
   t = A s + e needs one multiply by R (poly_tomont) after the
   accumulated basemul, and u and v none, their inverse NTT cancelling
   their basemul's. poly_normalise brings the reference's coefficients
   into [0, q) wherever the encoding needs it; for the extension it is
   nothing. The small packed ops the top level needs with the extension
   (add, subtract, multiply by a constant) are inline asm here; on the host
   (no __riscv) they are plain C with the same results, and
   mlkem_x_host.c stands in for the kernels, so both back ends can be
   checked against the model with gcc before a simulation. */
#include <stdint.h>
#include <stddef.h>
#include "keccak.h"
#include "bench_data.h"
#include "kem_data.h"

#define N 256
#define K KEM_K
#define Q MLKEM_Q
#define POLY_BYTES 384                  /* 256 coefficients at 12 bits */
#define SYM_BYTES 32

/* ---- the polynomial back end ------------------------------------------- */

#ifdef MLKEM_EXT
typedef uint16_t coef_t;
void mlkem_ntt_ct2(uint16_t *r);
void mlkem_invntt_x2(uint16_t *r);
void mlkem_basemul_x(uint16_t *r, const uint16_t *a, const uint16_t *b);
#define poly_ntt      mlkem_ntt_ct2
#define poly_invntt   mlkem_invntt_x2
#define poly_basemul  mlkem_basemul_x
#else
typedef int16_t coef_t;
void mlkem_ntt(int16_t r[256]);
void mlkem_invntt(int16_t r[256]);
void mlkem_basemul(int16_t *r, const int16_t *a, const int16_t *b);
#define poly_ntt      mlkem_ntt
#define poly_invntt   mlkem_invntt
#define poly_basemul  mlkem_basemul
#endif

typedef coef_t poly[N] __attribute__((aligned(4)));   /* the extension reads words */

#ifdef MLKEM_EXT

#if defined(__riscv)
#define MQ_CFG(a)   __asm__ volatile (".insn r 0x0b, 6, 5, x0, %0, x0" :: "r" (a))
#define MQ_ZETA(a)  __asm__ volatile (".insn r 0x0b, 6, 6, x0, %0, x0" :: "r" (a))
#define MQ_OP(f, x, a, b) __asm__ volatile (".insn r 0x0b, 6, " #f ", %0, %1, %2" : "=r" (x) : "r" (a), "r" (b))
/* r = a + b and r = a - b mod q, two coefficients per instruction */
static void poly_add(poly r, const poly a, const poly b)
{
  uint32_t *rw = (uint32_t *)r;
  const uint32_t *aw = (const uint32_t *)a, *bw = (const uint32_t *)b;
  MQ_CFG(MLKEM_QCFG);
  for (unsigned i = 0; i < N / 2; i++) {
    uint32_t x;
    MQ_OP(1, x, aw[i], bw[i]);
    rw[i] = x;
  }
}
static void poly_sub(poly r, const poly a, const poly b)
{
  uint32_t *rw = (uint32_t *)r;
  const uint32_t *aw = (const uint32_t *)a, *bw = (const uint32_t *)b;
  MQ_CFG(MLKEM_QCFG);
  for (unsigned i = 0; i < N / 2; i++) {
    uint32_t x;
    MQ_OP(2, x, aw[i], bw[i]);
    rw[i] = x;
  }
}
/* r = r * R: ctadd2 from x0 with zeta = R^2 mod q gives mont(R^2 r) = R r */
static void poly_tomont(poly r)
{
  uint32_t *rw = (uint32_t *)r;
  MQ_CFG(MLKEM_QCFG);
  MQ_ZETA(1353);
  for (unsigned i = 0; i < N / 2; i++) {
    uint32_t x;
    __asm__ volatile (".insn r 0x0b, 6, 3, %0, x0, %1" : "=r" (x) : "r" (rw[i]));
    rw[i] = x;
  }
}
#else                                   /* the host: the same, in C */
static uint16_t mont_host(uint32_t p)
{
  uint32_t m = (p * 3327u) & 0xFFFFu;   /* q' = -q^-1 mod 2^16 */
  uint32_t t = (p + m * Q) >> 16;
  return t >= Q ? t - Q : t;
}
static void poly_add(poly r, const poly a, const poly b)
{
  for (unsigned i = 0; i < N; i++) {
    unsigned t = a[i] + b[i];
    r[i] = t >= Q ? t - Q : t;
  }
}
static void poly_sub(poly r, const poly a, const poly b)
{
  for (unsigned i = 0; i < N; i++)
    r[i] = a[i] >= b[i] ? a[i] - b[i] : a[i] + Q - b[i];
}
static void poly_tomont(poly r)
{
  for (unsigned i = 0; i < N; i++)
    r[i] = mont_host(1353u * r[i]);
}
#endif
static void poly_normalise(poly r)      /* already in [0, q) */
{
  (void)r;
}

#else                                   /* the reference: pq-crystals' reduce.c */

#define QINV -3327                      /* q^-1 mod 2^16 */
static int16_t montgomery_reduce(int32_t a)
{
  int16_t t = (int16_t)a * QINV;
  return (a - (int32_t)t * Q) >> 16;
}
static int16_t barrett_reduce(int16_t a)
{
  const int16_t v = ((1 << 26) + Q / 2) / Q;
  int16_t t = ((int32_t)v * a + (1 << 25)) >> 26;
  return a - t * Q;
}
static void poly_add(poly r, const poly a, const poly b)
{
  for (unsigned i = 0; i < N; i++)
    r[i] = a[i] + b[i];
}
static void poly_sub(poly r, const poly a, const poly b)
{
  for (unsigned i = 0; i < N; i++)
    r[i] = a[i] - b[i];
}
static void poly_tomont(poly r)         /* times R: fqmul by R^2 mod q */
{
  for (unsigned i = 0; i < N; i++)
    r[i] = montgomery_reduce((int32_t)r[i] * 1353);
}
/* Barrett-reduce to (-q/2, q/2], then add q to the negative ones: [0, q) */
static void poly_normalise(poly r)
{
  for (unsigned i = 0; i < N; i++) {
    int16_t t = barrett_reduce(r[i]);
    r[i] = t + ((t >> 15) & Q);
  }
}

#endif

/* r = sum of a[i] o b[i] over the K pairs (times R^-1), reduced as the
   back end leaves a sum: the reference Barrett-reduces, as pq-crystals'
   polyvec_basemul_acc_montgomery does; the extension's add is mod q */
static void poly_basemul_acc(poly r, const coef_t *const a[K], const coef_t *const b[K])
{
  poly t;
  poly_basemul(r, a[0], b[0]);
  for (unsigned i = 1; i < K; i++) {
    poly_basemul(t, a[i], b[i]);
    poly_add(r, r, t);
  }
#ifndef MLKEM_EXT
  for (unsigned i = 0; i < N; i++)
    r[i] = barrett_reduce(r[i]);
#endif
}

/* ---- encoding, compression, sampling (FIPS 203 section 4) --------------- */

/* ByteEncode_d: d bits per coefficient, least significant first; the
   coefficients must be in [0, 2^d) */
static void byte_encode(uint8_t *out, const poly f, unsigned d)
{
  uint32_t acc = 0;
  unsigned bits = 0;
  for (unsigned i = 0; i < N; i++) {
    acc |= (uint32_t)(uint16_t)f[i] << bits;
    bits += d;
    while (bits >= 8) {
      *out++ = (uint8_t)acc;
      acc >>= 8;
      bits -= 8;
    }
  }
}

static void byte_decode(poly f, const uint8_t *in, unsigned d)
{
  uint32_t acc = 0, mask = (1u << d) - 1;
  unsigned bits = 0;
  for (unsigned i = 0; i < N; i++) {
    while (bits < d) {
      acc |= (uint32_t)*in++ << bits;
      bits += 8;
    }
    f[i] = (coef_t)(acc & mask);
    acc >>= d;
    bits -= d;
  }
}

/* Compress_d: round(2^d x / q) mod 2^d, on coefficients in [0, q) */
static void compress(poly f, unsigned d)
{
  for (unsigned i = 0; i < N; i++)
    f[i] = (coef_t)(((((uint32_t)(uint16_t)f[i] << d) + Q / 2) / Q) & ((1u << d) - 1));
}

static void decompress(poly f, unsigned d)
{
  for (unsigned i = 0; i < N; i++)
    f[i] = (coef_t)(((uint32_t)(uint16_t)f[i] * Q + (1u << (d - 1))) >> d);
}

/* SampleNTT (Algorithm 7): three bytes of SHAKE128(seed) give two 12-bit
   candidates, kept if below q, until 256 are kept */
static void sample_ntt(poly a, const uint8_t seed[SYM_BYTES + 2])
{
  keccak_t st;
  uint8_t buf[SHAKE128_RATE];
  unsigned n = 0;
  keccak_init(&st, SHAKE128_RATE);
  keccak_absorb(&st, seed, SYM_BYTES + 2);
  keccak_finish(&st, 0x1F);
  while (n < N) {
    keccak_squeeze(&st, buf, SHAKE128_RATE);
    for (unsigned i = 0; i < SHAKE128_RATE && n < N; i += 3) {
      unsigned d1 = buf[i] | ((buf[i + 1] & 15) << 8), d2 = (buf[i + 1] >> 4) | (buf[i + 2] << 4);
      if (d1 < Q)
        a[n++] = (coef_t)d1;
      if (d2 < Q && n < N)
        a[n++] = (coef_t)d2;
    }
  }
}

/* SamplePolyCBD_eta (Algorithm 8) from 64 eta bytes: each coefficient is
   the difference of two eta-bit population counts, stored mod q */
static void sample_cbd(poly f, const uint8_t *b, unsigned eta)
{
  for (unsigned i = 0; i < N; i++) {
    unsigned x = 0, y = 0, bit = 2 * i * eta;
    for (unsigned j = 0; j < eta; j++, bit++)
      x += (b[bit >> 3] >> (bit & 7)) & 1;
    for (unsigned j = 0; j < eta; j++, bit++)
      y += (b[bit >> 3] >> (bit & 7)) & 1;
    f[i] = (coef_t)(x >= y ? x - y : x + Q - y);
  }
}

/* PRF_eta(s, b) = SHAKE256(s || b), 64 eta bytes */
static void prf(uint8_t *out, unsigned eta, const uint8_t s[SYM_BYTES], uint8_t nonce)
{
  uint8_t in[SYM_BYTES + 1];
  for (unsigned i = 0; i < SYM_BYTES; i++)
    in[i] = s[i];
  in[SYM_BYTES] = nonce;
  shake256(out, 64 * eta, in, SYM_BYTES + 1);
}

/* A_hat[i][j] = SampleNTT(rho || j || i) */
static void gen_matrix(poly A[K][K], const uint8_t rho[SYM_BYTES])
{
  uint8_t seed[SYM_BYTES + 2];
  for (unsigned i = 0; i < SYM_BYTES; i++)
    seed[i] = rho[i];
  for (unsigned i = 0; i < K; i++)
    for (unsigned j = 0; j < K; j++) {
      seed[SYM_BYTES] = (uint8_t)j;
      seed[SYM_BYTES + 1] = (uint8_t)i;
      sample_ntt(A[i][j], seed);
    }
}

static void copy(uint8_t *dst, const uint8_t *src, size_t n)
{
  while (n--)
    *dst++ = *src++;
}

/* ---- K-PKE (section 5) -------------------------------------------------- */

static void pke_keygen(uint8_t ek[KEM_EK_BYTES], uint8_t dk[K * POLY_BYTES], const uint8_t d[SYM_BYTES])
{
  uint8_t buf[SYM_BYTES + 1], g[64];
  poly A[K][K], s[K], e[K], t;
  const coef_t *as[K], *ss[K];
  copy(buf, d, SYM_BYTES);
  buf[SYM_BYTES] = K;                   /* FIPS 203 as published hashes d || k */
  sha3_512(g, buf, SYM_BYTES + 1);      /* rho = g[0..31], sigma = g[32..63] */
  gen_matrix(A, g);
  for (unsigned i = 0; i < K; i++) {
    uint8_t r[64 * KEM_ETA1];
    prf(r, KEM_ETA1, g + SYM_BYTES, (uint8_t)i);
    sample_cbd(s[i], r, KEM_ETA1);
    prf(r, KEM_ETA1, g + SYM_BYTES, (uint8_t)(K + i));
    sample_cbd(e[i], r, KEM_ETA1);
    poly_ntt(s[i]);
    poly_ntt(e[i]);
    ss[i] = s[i];
  }
  for (unsigned i = 0; i < K; i++) {    /* t = A s + e */
    for (unsigned j = 0; j < K; j++)
      as[j] = A[i][j];
    poly_basemul_acc(t, as, ss);
    poly_tomont(t);
    poly_add(t, t, e[i]);
    poly_normalise(t);
    byte_encode(ek + POLY_BYTES * i, t, 12);
    poly_normalise(s[i]);
    byte_encode(dk + POLY_BYTES * i, s[i], 12);
  }
  copy(ek + K * POLY_BYTES, g, SYM_BYTES);
}

static void pke_encrypt(uint8_t c[KEM_CT_BYTES], const uint8_t ek[KEM_EK_BYTES],
                        const uint8_t m[SYM_BYTES], const uint8_t r[SYM_BYTES])
{
  poly A[K][K], t[K], y[K], u, v;
  const coef_t *as[K], *ts[K], *ys[K];
  uint8_t buf[64 * KEM_ETA1];
  unsigned nonce = 0;
  for (unsigned i = 0; i < K; i++) {
    byte_decode(t[i], ek + POLY_BYTES * i, 12);
    ts[i] = t[i];
  }
  gen_matrix(A, ek + K * POLY_BYTES);
  for (unsigned i = 0; i < K; i++) {
    prf(buf, KEM_ETA1, r, (uint8_t)nonce++);
    sample_cbd(y[i], buf, KEM_ETA1);
    poly_ntt(y[i]);
    ys[i] = y[i];
  }
  for (unsigned i = 0; i < K; i++) {    /* u = NTT^-1(A^T y) + e1 */
    for (unsigned j = 0; j < K; j++)
      as[j] = A[j][i];
    poly_basemul_acc(u, as, ys);
    poly_invntt(u);
    prf(buf, KEM_ETA2, r, (uint8_t)nonce++);
    sample_cbd(v, buf, KEM_ETA2);       /* e1[i], briefly in v */
    poly_add(u, u, v);
    poly_normalise(u);
    compress(u, KEM_DU);
    byte_encode(c + 32 * KEM_DU * i, u, KEM_DU);
  }
  poly_basemul_acc(v, ts, ys);          /* v = NTT^-1(t y) + e2 + mu */
  poly_invntt(v);
  prf(buf, KEM_ETA2, r, (uint8_t)nonce);
  sample_cbd(u, buf, KEM_ETA2);
  poly_add(v, v, u);
  byte_decode(u, m, 1);
  decompress(u, 1);
  poly_add(v, v, u);
  poly_normalise(v);
  compress(v, KEM_DV);
  byte_encode(c + 32 * KEM_DU * K, v, KEM_DV);
}

static void pke_decrypt(uint8_t m[SYM_BYTES], const uint8_t dk[K * POLY_BYTES], const uint8_t c[KEM_CT_BYTES])
{
  poly s[K], u[K], v, w;
  const coef_t *ss[K], *us[K];
  for (unsigned i = 0; i < K; i++) {
    byte_decode(u[i], c + 32 * KEM_DU * i, KEM_DU);
    decompress(u[i], KEM_DU);
    poly_ntt(u[i]);
    byte_decode(s[i], dk + POLY_BYTES * i, 12);
    ss[i] = s[i];
    us[i] = u[i];
  }
  byte_decode(v, c + 32 * KEM_DU * K, KEM_DV);
  decompress(v, KEM_DV);
  poly_basemul_acc(w, ss, us);          /* w = v - NTT^-1(s NTT(u)) */
  poly_invntt(w);
  poly_sub(w, v, w);
  poly_normalise(w);
  compress(w, 1);
  byte_encode(m, w, 1);
}

/* ---- ML-KEM (section 7) ------------------------------------------------- */

void kem_keygen(uint8_t ek[KEM_EK_BYTES], uint8_t dk[KEM_DK_BYTES],
                const uint8_t d[SYM_BYTES], const uint8_t z[SYM_BYTES])
{
  pke_keygen(ek, dk, d);
  copy(dk + K * POLY_BYTES, ek, KEM_EK_BYTES);
  sha3_256(dk + K * POLY_BYTES + KEM_EK_BYTES, ek, KEM_EK_BYTES);
  copy(dk + K * POLY_BYTES + KEM_EK_BYTES + SYM_BYTES, z, SYM_BYTES);
}

void kem_encaps(uint8_t key[SYM_BYTES], uint8_t c[KEM_CT_BYTES],
                const uint8_t ek[KEM_EK_BYTES], const uint8_t m[SYM_BYTES])
{
  uint8_t buf[2 * SYM_BYTES], g[64];
  copy(buf, m, SYM_BYTES);
  sha3_256(buf + SYM_BYTES, ek, KEM_EK_BYTES);
  sha3_512(g, buf, 2 * SYM_BYTES);      /* K = g[0..31], r = g[32..63] */
  copy(key, g, SYM_BYTES);
  pke_encrypt(c, ek, m, g + SYM_BYTES);
}

/* Decaps with implicit rejection: if the re-encryption of the recovered
   message is not c, the key is J(z || c) instead, selected without a
   branch on the comparison */
void kem_decaps(uint8_t key[SYM_BYTES], const uint8_t dk[KEM_DK_BYTES], const uint8_t c[KEM_CT_BYTES])
{
  const uint8_t *ek = dk + K * POLY_BYTES, *h = ek + KEM_EK_BYTES, *z = h + SYM_BYTES;
  uint8_t mp[2 * SYM_BYTES], buf[SYM_BYTES + KEM_CT_BYTES], g[64], kbar[SYM_BYTES], c2[KEM_CT_BYTES];
  uint32_t diff = 0;
  uint8_t mask;
  pke_decrypt(mp, dk, c);               /* m' || h */
  copy(mp + SYM_BYTES, h, SYM_BYTES);
  sha3_512(g, mp, 2 * SYM_BYTES);       /* K' = g[0..31], r' = g[32..63] */
  copy(buf, z, SYM_BYTES);              /* K_bar = J(z || c) */
  copy(buf + SYM_BYTES, c, KEM_CT_BYTES);
  shake256(kbar, SYM_BYTES, buf, SYM_BYTES + KEM_CT_BYTES);
  pke_encrypt(c2, ek, mp, g + SYM_BYTES);
  for (unsigned i = 0; i < KEM_CT_BYTES; i++)
    diff |= c[i] ^ c2[i];
  mask = (uint8_t)(0 - ((diff | (0u - diff)) >> 31));   /* 0xFF if any byte differed */
  for (unsigned i = 0; i < SYM_BYTES; i++)
    key[i] = g[i] ^ (mask & (g[i] ^ kbar[i]));
}
