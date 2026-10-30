/*
 * dsp.c — DSP kernels, in plain RV32IMC C (the baseline) and using
 * Xbrvdsp, the core's DSP extension, through inline asm (_mac and _dmac; _agu
 * adds the address generators, which load and step a pointer in one
 * instruction).
 *
 * Each kernel runs twice (the first run with cold caches, the second warm),
 * between BENCH_MARK pairs, and its result is checked against the values
 * gen_data.py computed. main returns 0 if every result matches, else the
 * number of the first failing check.
 */
#include <stdint.h>
#include <limits.h>
#include "bench.h"
#include "bench_data.h"

/* noipa: compile each kernel as a real call, so the compiler cannot fold the
   constant inputs into it */
__attribute__((noipa))
void fir_q15(const int16_t *x, const int16_t *h, int16_t *y, int outs, int taps)
{
  for (int n = 0; n < outs; n++) {
    int32_t acc = 1 << 14;                       /* rounding */
    for (int k = 0; k < taps; k++)
      acc += (int32_t)h[k] * x[n + k];
    acc >>= 15;
    if (acc > 32767) acc = 32767;                /* saturate to Q15 */
    if (acc < -32768) acc = -32768;
    y[n] = (int16_t)acc;
  }
}

__attribute__((noipa))
int64_t energy_q15(const int16_t *x, int n)
{
  int64_t acc = 0;
  for (int i = 0; i < n; i++)
    acc += (int32_t)x[i] * x[i];
  return acc;
}

/* Xbrvdsp (doc/dsp_extension.md), custom-0. Volatile asm keeps the
   accumulator instructions in program order. */
static inline void acc_set(int32_t a)
{
  __asm__ volatile (".insn r CUSTOM_0, 0, 4, x0, %0, x0" :: "r" (a));
}
static inline void mac(int32_t a, int32_t b)
{
  __asm__ volatile (".insn r CUSTOM_0, 0, 0, x0, %0, %1" :: "r" (a), "r" (b));
}
static inline void dmac(int32_t a, int32_t b)
{
  __asm__ volatile (".insn r CUSTOM_0, 0, 1, x0, %0, %1" :: "r" (a), "r" (b));
}
static inline int32_t acc_rdh15(void)        /* sat16((acc + 2^14) >> 15) */
{
  int32_t r;
  __asm__ volatile (".insn r CUSTOM_0, 2, 0, %0, x0, x15" : "=r" (r));
  return r;
}
static inline int64_t acc_rd40(void)         /* all 40 bits, sign-extended */
{
  uint32_t lo;
  int32_t hi;
  __asm__ volatile (".insn r CUSTOM_0, 3, 0, %0, x0, x0" : "=r" (lo));
  __asm__ volatile (".insn r CUSTOM_0, 3, 1, %0, x0, x0" : "=r" (hi));
  return ((int64_t)hi << 32) | lo;
}

__attribute__((noipa))
void fir_q15_mac(const int16_t *x, const int16_t *h, int16_t *y, int outs, int taps)
{
  for (int n = 0; n < outs; n++) {
    acc_set(0);
    for (int k = 0; k < taps; k++)
      mac(h[k], x[n + k]);
    y[n] = (int16_t)acc_rdh15();                /* rounded and saturated in one step */
  }
}

__attribute__((noipa))
int64_t energy_q15_mac(const int16_t *x, int n)
{
  acc_set(0);
  for (int i = 0; i < n; i++)
    mac(x[i], x[i]);
  return acc_rd40();
}

/* Two samples per instruction: x is 4-byte aligned and n is even */
__attribute__((noipa))
int64_t energy_q15_dmac(const int16_t *x, int n)
{
  const int32_t *x2 = (const int32_t *)x;
  acc_set(0);
  for (int i = 0; i < n / 2; i++)
    dmac(x2[i], x2[i]);
  return acc_rd40();
}

/* Address generators (custom-1): arN holds a pointer and a stride in bytes.
   The "memory" clobber on ar_set keeps earlier stores ahead of the loads
   through the new pointer. */
#define AR_SET(n, p)  __asm__ volatile (".insn r CUSTOM_1, 0, 0, x" #n ", %0, x0" :: "r" (p) : "memory")
#define AR_CFG(n, s)  __asm__ volatile (".insn r CUSTOM_1, 0, 1, x" #n ", %0, x0" :: "r" (s))
#define LH_A(r, n)    __asm__ volatile (".insn i CUSTOM_1, 1, %0, x0, " #n : "=r" (r))
#define LW_A(r, n)    __asm__ volatile (".insn i CUSTOM_1, 2, %0, x0, " #n : "=r" (r))

/* The FIR with both pointers in address registers: the loop is two loads,
   the MAC, and the count */
__attribute__((noipa))
void fir_q15_agu(const int16_t *x, const int16_t *h, int16_t *y, int outs, int taps)
{
  AR_CFG(0, 2);
  AR_CFG(1, 2);
  for (int n = 0; n < outs; n++) {
    AR_SET(0, x + n);
    AR_SET(1, h);
    acc_set(0);
    for (int k = 0; k < taps; k++) {
      int32_t a, b;
      LH_A(a, 1);
      LH_A(b, 0);
      mac(a, b);
    }
    y[n] = (int16_t)acc_rdh15();
  }
}

/* The same, two taps per iteration, with all four loads ahead of the MACs:
   no load-use bubble (taps is even) */
__attribute__((noipa))
void fir_q15_agu2(const int16_t *x, const int16_t *h, int16_t *y, int outs, int taps)
{
  AR_CFG(0, 2);
  AR_CFG(1, 2);
  for (int n = 0; n < outs; n++) {
    AR_SET(0, x + n);
    AR_SET(1, h);
    acc_set(0);
    for (int k = 0; k < taps; k += 2) {
      int32_t a0, b0, a1, b1;
      LH_A(a0, 1);
      LH_A(b0, 0);
      LH_A(a1, 1);
      LH_A(b1, 0);
      mac(a0, b0);
      mac(a1, b1);
    }
    y[n] = (int16_t)acc_rdh15();
  }
}

/* Energy with dmac, two samples per load */
__attribute__((noipa))
int64_t energy_q15_agu(const int16_t *x, int n)
{
  AR_SET(0, x);
  AR_CFG(0, 4);
  acc_set(0);
  for (int i = 0; i < n / 2; i++) {
    int32_t w;
    LW_A(w, 0);
    dmac(w, w);
  }
  return acc_rd40();
}

/* The same, four samples per iteration, loads ahead of the MACs (n % 4 == 0) */
__attribute__((noipa))
int64_t energy_q15_agu2(const int16_t *x, int n)
{
  AR_SET(0, x);
  AR_CFG(0, 4);
  acc_set(0);
  for (int i = 0; i < n / 4; i++) {
    int32_t w0, w1;
    LW_A(w0, 0);
    LW_A(w1, 0);
    dmac(w0, w0);
    dmac(w1, w1);
  }
  return acc_rd40();
}

/* The FIR with dmac: two taps per instruction from aligned word loads.
   y[n] = sum_k h[k] x[n+k]. For even n, the pairs (x[n+k], x[n+k+1]) are
   aligned words, and so are (h[k], h[k+1]). For odd n they are not; instead
   start one sample early, at the aligned x[n-1], against a copy of the
   coefficients shifted by one, hs = (0, h[0], ..., h[taps-1], 0): the extra
   products are with the zeros. Both arrays are 4-byte aligned, and x has
   zeros after its last sample (gen_data.py). taps is a multiple of 4. */
__attribute__((noipa))
void fir_q15_dmac(const int16_t *x, const int16_t *h, int16_t *y, int outs, int taps)
{
  static int16_t hs[FIR_TAPS + 4] __attribute__((aligned(4)));
  hs[0] = 0;
  for (int k = 0; k < taps; k++)
    hs[k + 1] = h[k];
  hs[taps + 1] = hs[taps + 2] = hs[taps + 3] = 0;

  AR_CFG(0, 4);
  AR_CFG(1, 4);
  for (int n = 0; n < outs; n++) {
    int odd = n & 1;
    AR_SET(0, x + n - odd);
    AR_SET(1, odd ? hs : h);
    acc_set(0);
    /* pairs: taps/2, or taps/2 + 1 for odd n; run in twos (taps/4 or
       taps/4 + 1 iterations: an odd n's last pair pads with zeros) */
    for (int i = 0; i < taps / 4 + odd; i++) {
      int32_t x0, h0, x1, h1;
      LW_A(x0, 0);
      LW_A(h0, 1);
      LW_A(x1, 0);
      LW_A(h1, 1);
      dmac(x0, h0);
      dmac(x1, h1);
    }
    y[n] = (int16_t)acc_rdh15();
  }
}

/* Hardware loop (step 4). lp.setup runs the body that follows it count
   times; the body's last instruction (here dmac.lp) marks its end. The whole
   loop is one asm statement, so the compiler cannot put anything between
   lp.setup and the body. .balign 4 starts the body on a word: a 32-bit
   instruction at 2 mod 4 would cost a fetch bubble on every loop-back. */
static inline void dmac_pairs_lp(int count)   /* count x (x0, h0, x1, h1) */
{
  __asm__ volatile (
    ".balign 4\n\t"
    ".insn i CUSTOM_1, 6, x0, %0, 0\n\t"          /* lp.setup count */
    ".insn i CUSTOM_1, 2, t0, x0, 0\n\t"          /* lw.a t0, ar0 */
    ".insn i CUSTOM_1, 2, t1, x0, 1\n\t"          /* lw.a t1, ar1 */
    ".insn i CUSTOM_1, 2, t2, x0, 0\n\t"
    ".insn i CUSTOM_1, 2, t3, x0, 1\n\t"
    ".insn r CUSTOM_0, 0, 1, x0, t0, t1\n\t"      /* dmac */
    ".insn r CUSTOM_0, 0, 0x41, x0, t2, t3"        /* dmac.lp: end of the body */
    :: "r" (count) : "t0", "t1", "t2", "t3", "memory");
}

/* fir_q15_dmac with the inner loop in hardware */
__attribute__((noipa))
void fir_q15_lp(const int16_t *x, const int16_t *h, int16_t *y, int outs, int taps)
{
  static int16_t hs[FIR_TAPS + 4] __attribute__((aligned(4)));
  hs[0] = 0;
  for (int k = 0; k < taps; k++)
    hs[k + 1] = h[k];
  hs[taps + 1] = hs[taps + 2] = hs[taps + 3] = 0;

  AR_CFG(0, 4);
  AR_CFG(1, 4);
  for (int n = 0; n < outs; n++) {
    int odd = n & 1;
    AR_SET(0, x + n - odd);
    AR_SET(1, odd ? hs : h);
    acc_set(0);
    dmac_pairs_lp(taps / 4 + odd);
    y[n] = (int16_t)acc_rdh15();
  }
}

/* Energy: the whole loop in hardware, four samples per pass (n % 4 == 0) */
__attribute__((noipa))
int64_t energy_q15_lp(const int16_t *x, int n)
{
  AR_SET(0, x);
  AR_CFG(0, 4);
  acc_set(0);
  __asm__ volatile (
    ".balign 4\n\t"
    ".insn i CUSTOM_1, 6, x0, %0, 0\n\t"          /* lp.setup n/4 */
    ".insn i CUSTOM_1, 2, t0, x0, 0\n\t"          /* lw.a t0, ar0 */
    ".insn i CUSTOM_1, 2, t1, x0, 0\n\t"
    ".insn r CUSTOM_0, 0, 1, x0, t0, t0\n\t"      /* dmac */
    ".insn r CUSTOM_0, 0, 0x41, x0, t1, t1"        /* dmac.lp */
    :: "r" (n / 4) : "t0", "t1", "memory");
  return acc_rd40();
}

/* Biquad cascade, direct form I, Q14 coefficients c[5s..5s+4] =
   (b0, b1, b2, a1, a2). In place over y (which starts as a copy of x). */
__attribute__((noipa))
void biquad_q14(int16_t *y, const int16_t *c, int n, int sections)
{
  for (int s = 0; s < sections; s++, c += 5) {
    int32_t x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (int i = 0; i < n; i++) {
      int32_t x0 = y[i];
      int32_t acc = c[0] * x0 + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2;
      acc = (acc + (1 << 13)) >> 14;
      if (acc > 32767) acc = 32767;
      if (acc < -32768) acc = -32768;
      x2 = x1; x1 = x0; y2 = y1; y1 = acc;
      y[i] = (int16_t)acc;
    }
  }
}

static inline void msu(int32_t a, int32_t b)
{
  __asm__ volatile (".insn r CUSTOM_0, 0, 2, x0, %0, %1" :: "r" (a), "r" (b));
}
static inline int32_t acc_rdh14(void)        /* sat16((acc + 2^13) >> 14) */
{
  int32_t r;
  __asm__ volatile (".insn r CUSTOM_0, 2, 0, %0, x0, x14" : "=r" (r));
  return r;
}

/* The same with mac and msu into the accumulator; acc.rdh rounds, shifts
   and saturates */
__attribute__((noipa))
void biquad_q14_mac(int16_t *y, const int16_t *c, int n, int sections)
{
  for (int s = 0; s < sections; s++, c += 5) {
    int32_t b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4];
    int32_t x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (int i = 0; i < n; i++) {
      int32_t x0 = y[i];
      acc_set(0);
      mac(b0, x0);
      mac(b1, x1);
      mac(b2, x2);
      msu(a1, y1);
      msu(a2, y2);
      int32_t out = acc_rdh14();
      x2 = x1; x1 = x0; y2 = y1; y1 = out;
      y[i] = (int16_t)out;
    }
  }
}

/* Saturating Q31 mix */
__attribute__((noipa))
void mix_q31(int32_t *z, const int32_t *p, const int32_t *q, int n)
{
  for (int i = 0; i < n; i++) {
    int32_t s;
    if (__builtin_add_overflow(p[i], q[i], &s))
      s = p[i] < 0 ? INT32_MIN : INT32_MAX;
    z[i] = s;
  }
}

static inline int32_t sadd(int32_t a, int32_t b)
{
  int32_t r;
  __asm__ (".insn r CUSTOM_0, 4, 0, %0, %1, %2" : "=r" (r) : "r" (a), "r" (b));
  return r;
}

__attribute__((noipa))
void mix_q31_sadd(int32_t *z, const int32_t *p, const int32_t *q, int n)
{
  for (int i = 0; i < n; i++)
    z[i] = sadd(p[i], q[i]);
}

/* FFT (64-point complex, Q15; gen_data.py gives the exact algorithm). Each
   sample is a word: re in the low half, im in the high. */
static inline uint32_t cpack(int32_t re, int32_t im)
{
  return ((uint32_t)im << 16) | ((uint32_t)re & 0xFFFF);
}
static inline int32_t sat16(int32_t v)
{
  return v > 32767 ? 32767 : v < -32768 ? -32768 : v;
}

/* Bit-reversed copy, Gold-Rader: j counts in reverse */
__attribute__((noipa))
void fft_bitrev(uint32_t *y, const uint32_t *x, int n)
{
  int j = 0;
  for (int i = 0; i < n; i++) {
    y[i] = x[j];
    int k = n >> 1;
    while (j & k) {
      j ^= k;
      k >>= 1;
    }
    j |= k;
  }
}

/* The butterflies: log2(n) stages, each output halved */
__attribute__((noipa))
void fft_stages(uint32_t *y, int n)
{
  for (int len = 2, step = n / 2; len <= n; len <<= 1, step >>= 1) {
    int half = len >> 1;
    for (int s = 0; s < n; s += len)
      for (int j = 0; j < half; j++) {
        int32_t wr = fft_wr[j * step], wi = fft_wi[j * step];
        uint32_t a = y[s + j], b = y[s + j + half];
        int32_t ar = (int16_t)a, ai = (int16_t)(a >> 16);
        int32_t br = (int16_t)b, bi = (int16_t)(b >> 16);
        int32_t tr = sat16((br * wr - bi * wi + (1 << 14)) >> 15);
        int32_t ti = sat16((br * wi + bi * wr + (1 << 14)) >> 15);
        y[s + j]        = cpack((ar + tr) >> 1, (ai + ti) >> 1);
        y[s + j + half] = cpack((ar - tr) >> 1, (ai - ti) >> 1);
      }
  }
}

#define AR_MODE(n, m) __asm__ volatile (".insn r CUSTOM_1, 0, 3, x" #n ", %0, x0" :: "r" (m))

/* Bit-reversed copy with an address register in bit-reversed mode: x must be
   aligned to its size (n words) */
__attribute__((noipa))
void fft_bitrev_agu(uint32_t *y, const uint32_t *x, int n)
{
  AR_SET(0, x);
  AR_CFG(0, n / 2 * 4);                          /* half the buffer, in bytes */
  AR_MODE(0, 1);
  for (int i = 0; i < n; i++) {
    uint32_t w;
    LW_A(w, 0);
    y[i] = w;
  }
  AR_MODE(0, 0);
}

/* The butterflies with dmac: each part of t = b w is one dmac against a
   packed twiddle, (wr, -wi) for the real part and (wi, wr) for the
   imaginary, rounded and saturated by acc.rdh */
__attribute__((noipa))
void fft_stages_dmac(uint32_t *y, int n)
{
  for (int len = 2, step = n / 2; len <= n; len <<= 1, step >>= 1) {
    int half = len >> 1;
    for (int s = 0; s < n; s += len)
      for (int j = 0; j < half; j++) {
        uint32_t a = y[s + j], b = y[s + j + half];
        acc_set(0);
        dmac(b, fft_wa[j * step]);
        int32_t tr = acc_rdh15();
        acc_set(0);
        dmac(b, fft_wb[j * step]);
        int32_t ti = acc_rdh15();
        int32_t ar = (int16_t)a, ai = (int16_t)(a >> 16);
        y[s + j]        = cpack((ar + tr) >> 1, (ai + ti) >> 1);
        y[s + j + half] = cpack((ar - tr) >> 1, (ai - ti) >> 1);
      }
  }
}

/* Packed halves (step 5c) */
static inline uint32_t pk16(int32_t hi, int32_t lo)
{
  uint32_t r;
  __asm__ (".insn r CUSTOM_0, 4, 4, %0, %1, %2" : "=r" (r) : "r" (hi), "r" (lo));
  return r;
}
static inline uint32_t radd16(uint32_t a, uint32_t b)
{
  uint32_t r;
  __asm__ (".insn r CUSTOM_0, 4, 2, %0, %1, %2" : "=r" (r) : "r" (a), "r" (b));
  return r;
}
static inline uint32_t rsub16(uint32_t a, uint32_t b)
{
  uint32_t r;
  __asm__ (".insn r CUSTOM_0, 4, 3, %0, %1, %2" : "=r" (r) : "r" (a), "r" (b));
  return r;
}

/* The butterflies with dmac for t = b w, then t packed and the two outputs
   one halving add and one halving subtract, on both halves at once */
__attribute__((noipa))
void fft_stages_packed(uint32_t *y, int n)
{
  for (int len = 2, step = n / 2; len <= n; len <<= 1, step >>= 1) {
    int half = len >> 1;
    for (int s = 0; s < n; s += len)
      for (int j = 0; j < half; j++) {
        uint32_t a = y[s + j], b = y[s + j + half];
        acc_set(0);
        dmac(b, fft_wa[j * step]);
        int32_t tr = acc_rdh15();
        acc_set(0);
        dmac(b, fft_wb[j * step]);
        uint32_t t = pk16(acc_rdh15(), tr);
        y[s + j]        = radd16(a, t);
        y[s + j + half] = rsub16(a, t);
      }
  }
}

/* SHA-256 (sha256.c, plain; sha256_zk.c, Zbkb and Zknh) */
void sha256(const uint8_t *msg, int len, uint32_t h[8]);
void sha256_zk(const uint8_t *msg, int len, uint32_t h[8]);
/* AES-128 encryption (aes.c, plain; aes_zk.c, Zkne) */
void aes128_enc(uint8_t *out, const uint8_t *in, const uint8_t *rk, int blocks);
void aes128_enc_zk(uint32_t *out, const uint32_t *in, const uint32_t *rk, int blocks);
void aes128_enc_t(uint32_t *out, const uint32_t *in, const uint32_t *rk, int blocks);
/* CRC-32 (crc32.c, table-driven; crc32_zk.c, Zbkc and Zbkb) */
uint32_t crc32_table(const uint8_t *p, int len);
uint32_t crc32_clmul(const uint32_t *p, int len);
/* Polynomials over GF(2) (gf2.c, plain; gf2_zk.c, Zbkc and Zbkb) */
uint32_t crc32_bitwise(const uint8_t *p, int len);
uint32_t crc32c_table(const uint8_t *p, int len);
uint32_t crc16_table(const uint8_t *p, int len);
uint32_t crc8_table(const uint8_t *p, int len);
uint32_t crc32c_clmul(const uint32_t *p, int len);
uint32_t crc_clmul_msb(const uint32_t *p, int len, uint32_t P, uint32_t mu, int n);
void lfsr_bitwise(uint32_t *out, uint32_t s, int n);
void lfsr_table(uint32_t *out, uint32_t s, int n);
void lfsr_clmul(uint32_t *out, uint32_t s, int n);
void xorshift32(uint32_t *out, uint32_t s, int n);
uint32_t lfsr_jump(uint32_t s, uint32_t e);
uint32_t lfsr_jump_clmul(uint32_t s, uint32_t e);
/* GF(2^8) (gf256.c, plain; gf256_x.c, gfmul4) */
void rs_syndromes(uint8_t *S, const uint8_t *r);
void rs_syndromes_gf(uint8_t *S, const uint8_t *r);
int rs_chien(uint8_t *pos, const uint8_t *lam);
int rs_chien_gf(uint8_t *pos, const uint8_t *lam);
void aes_invmix(uint32_t *out, const uint32_t *in, int words);
void aes_invmix_gf(uint32_t *out, const uint32_t *in, int words);
/* ML-KEM's ring (mlkem.c, as pq-crystals' reference; mlkem_x.c, mq_unit) */
void mlkem_ntt(int16_t *r);
void mlkem_invntt(int16_t *r);
void mlkem_basemul(int16_t *r, const int16_t *a, const int16_t *b);
void mlkem_polymul(int16_t *c, int16_t *a, int16_t *b);
void mlkem_ntt_mq(uint16_t *r);
void mlkem_ntt_ct(uint16_t *r);
void mlkem_ntt_ct2(uint16_t *r);
void mlkem_invntt_x(uint16_t *r);
void mlkem_invntt_x2(uint16_t *r);
void mlkem_basemul_x(uint16_t *r, const uint16_t *a, const uint16_t *b);
void mlkem_polymul_x(uint16_t *c, uint16_t *a, uint16_t *b);

static int16_t fir_y[FIR_OUTS];

/* Each clears what it checks, so a kernel that writes nothing cannot pass
   on the previous run's output */
static int bytes_eq(uint8_t *a, const uint8_t *b, int n)
{
  int ok = 1;
  for (int i = 0; i < n; i++) {
    ok &= a[i] == b[i];
    a[i] = 0;
  }
  return ok;
}

/* timed(): kind 0, T-table AES; 1, Zkne AES; 2, log-table RS syndromes;
   3, gfmul4 syndromes. The input (and round keys) are first copied to the
   same buffers, and the kernel runs cold and then warm between markers 140
   and 141, so two calls with the same kind follow exactly the same path and
   touch the same addresses: only the data differs. */
static uint8_t t_in[256] __attribute__((aligned(4)));
static uint8_t t_rk[176] __attribute__((aligned(4)));
static uint8_t t_out[256] __attribute__((aligned(4)));

__attribute__((noipa))
static void timed(int kind, const uint8_t *in, int n, const uint8_t *rk)
{
  for (int i = 0; i < n; i++) t_in[i] = in[i];
  for (int i = 0; i < 176; i++) t_rk[i] = rk ? rk[i] : 0;
  for (int r = 0; r < 2; r++) {
    if (r) BENCH_MARK(140);
    switch (kind) {
    case 0:  aes128_enc_t((uint32_t *)t_out, (const uint32_t *)t_in, (const uint32_t *)t_rk, AES_BLOCKS); break;
    case 1:  aes128_enc_zk((uint32_t *)t_out, (const uint32_t *)t_in, (const uint32_t *)t_rk, AES_BLOCKS); break;
    case 2:  rs_syndromes(t_out, t_in); break;
    default: rs_syndromes_gf(t_out, t_in); break;
    }
    if (r) BENCH_MARK(141);
  }
}

/* A polynomial against the expected one, mod q: the reference leaves
   coefficients unreduced and signed; mlkem_x.c must give them exactly */
static int poly_eq(uint16_t *a, const uint16_t *b, int reduce)
{
  int ok = 1;
  for (int i = 0; i < 256; i++) {
    int v = reduce ? ((int16_t)a[i] % MLKEM_Q + MLKEM_Q) % MLKEM_Q : a[i];
    ok &= v == b[i];
    a[i] = 0;
  }
  return ok;
}

static void poly_copy(uint16_t *d, const uint16_t *s)
{
  for (int i = 0; i < 256; i++)
    d[i] = s[i];
}

static int words_eq(uint32_t *a, const uint32_t *b, int n)
{
  int ok = 1;
  for (int i = 0; i < n; i++) {
    ok &= a[i] == b[i];
    a[i] = 0;
  }
  return ok;
}

static int fir_ok(void)
{
  for (int n = 0; n < FIR_OUTS; n++)
    if (fir_y[n] != fir_expect[n])
      return 0;
  return 1;
}

int main(void)
{
  int64_t e;

  BENCH_MARK(0);
  fir_q15(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);
  BENCH_MARK(1);
  if (!fir_ok()) return 2;

  for (int n = 0; n < FIR_OUTS; n++) fir_y[n] = 0;
  BENCH_MARK(2);
  fir_q15(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);
  BENCH_MARK(3);
  if (!fir_ok()) return 3;

  BENCH_MARK(4);
  e = energy_q15(energy_x, ENERGY_N);
  BENCH_MARK(5);
  if (e != energy_expect) return 4;

  BENCH_MARK(6);
  e = energy_q15(energy_x, ENERGY_N);
  BENCH_MARK(7);
  if (e != energy_expect) return 5;

  /* The same kernels with Xbrvdsp: cold, then warm */
  for (int r = 0; r < 2; r++) {
    for (int n = 0; n < FIR_OUTS; n++) fir_y[n] = 0;
    if (r) BENCH_MARK(10); else BENCH_MARK(8);
    fir_q15_mac(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);
    if (r) BENCH_MARK(11); else BENCH_MARK(9);
    if (!fir_ok()) return 6;
  }
  for (int r = 0; r < 2; r++) {
    if (r) BENCH_MARK(14); else BENCH_MARK(12);
    e = energy_q15_mac(energy_x, ENERGY_N);
    if (r) BENCH_MARK(15); else BENCH_MARK(13);
    if (e != energy_expect) return 7;
  }
  for (int r = 0; r < 2; r++) {
    if (r) BENCH_MARK(18); else BENCH_MARK(16);
    e = energy_q15_dmac(energy_x, ENERGY_N);
    if (r) BENCH_MARK(19); else BENCH_MARK(17);
    if (e != energy_expect) return 8;
  }

  /* With the address generators */
  for (int r = 0; r < 2; r++) {
    for (int n = 0; n < FIR_OUTS; n++) fir_y[n] = 0;
    if (r) BENCH_MARK(22); else BENCH_MARK(20);
    fir_q15_agu(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);
    if (r) BENCH_MARK(23); else BENCH_MARK(21);
    if (!fir_ok()) return 9;
  }
  for (int r = 0; r < 2; r++) {
    for (int n = 0; n < FIR_OUTS; n++) fir_y[n] = 0;
    if (r) BENCH_MARK(26); else BENCH_MARK(24);
    fir_q15_agu2(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);
    if (r) BENCH_MARK(27); else BENCH_MARK(25);
    if (!fir_ok()) return 10;
  }
  for (int r = 0; r < 2; r++) {
    if (r) BENCH_MARK(30); else BENCH_MARK(28);
    e = energy_q15_agu(energy_x, ENERGY_N);
    if (r) BENCH_MARK(31); else BENCH_MARK(29);
    if (e != energy_expect) return 11;
  }
  for (int r = 0; r < 2; r++) {
    if (r) BENCH_MARK(34); else BENCH_MARK(32);
    e = energy_q15_agu2(energy_x, ENERGY_N);
    if (r) BENCH_MARK(35); else BENCH_MARK(33);
    if (e != energy_expect) return 12;
  }
  for (int r = 0; r < 2; r++) {
    for (int n = 0; n < FIR_OUTS; n++) fir_y[n] = 0;
    if (r) BENCH_MARK(38); else BENCH_MARK(36);
    fir_q15_dmac(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);
    if (r) BENCH_MARK(39); else BENCH_MARK(37);
    if (!fir_ok()) return 13;
  }
  for (int r = 0; r < 2; r++) {
    for (int n = 0; n < FIR_OUTS; n++) fir_y[n] = 0;
    if (r) BENCH_MARK(42); else BENCH_MARK(40);
    fir_q15_lp(fir_x, fir_h, fir_y, FIR_OUTS, FIR_TAPS);
    if (r) BENCH_MARK(43); else BENCH_MARK(41);
    if (!fir_ok()) return 14;
  }
  for (int r = 0; r < 2; r++) {
    if (r) BENCH_MARK(46); else BENCH_MARK(44);
    e = energy_q15_lp(energy_x, ENERGY_N);
    if (r) BENCH_MARK(47); else BENCH_MARK(45);
    if (e != energy_expect) return 15;
  }

  /* Step 5: biquad and saturating mix, plain C then Xbrvdsp, warm caches
     (each run once cold first, unmeasured) */
  static int16_t by[BIQUAD_N];
  static int32_t mz[MIX_N];
  for (int k = 0; k < 4; k++) {
    for (int i = 0; i < BIQUAD_N; i++) by[i] = biquad_x[i];
    if (k == 1) BENCH_MARK(48);
    if (k == 3) BENCH_MARK(50);
    if (k < 2) biquad_q14(by, biquad_c, BIQUAD_N, 2);
    else       biquad_q14_mac(by, biquad_c, BIQUAD_N, 2);
    if (k == 1) BENCH_MARK(49);
    if (k == 3) BENCH_MARK(51);
    for (int i = 0; i < BIQUAD_N; i++)
      if (by[i] != biquad_expect[i]) return 16 + k;
  }
  for (int k = 0; k < 4; k++) {
    for (int i = 0; i < MIX_N; i++) mz[i] = 0;
    if (k == 1) BENCH_MARK(52);
    if (k == 3) BENCH_MARK(54);
    if (k < 2) mix_q31(mz, mix_p, mix_q, MIX_N);
    else       mix_q31_sadd(mz, mix_p, mix_q, MIX_N);
    if (k == 1) BENCH_MARK(53);
    if (k == 3) BENCH_MARK(55);
    for (int i = 0; i < MIX_N; i++)
      if (mz[i] != mix_expect[i]) return 20 + k;
  }

  /* Step 5b: the FFT, plain C then Xbrvdsp; each run once cold, unmeasured */
  static uint32_t fy[FFT_N];
  for (int k = 0; k < 4; k++) {
    if (k == 1) BENCH_MARK(56);
    if (k == 3) BENCH_MARK(58);
    if (k < 2) fft_bitrev(fy, fft_x, FFT_N);
    else       fft_bitrev_agu(fy, fft_x, FFT_N);
    if (k == 1) BENCH_MARK(57);
    if (k == 3) BENCH_MARK(59);
    if (k == 1) BENCH_MARK(60);
    if (k == 3) BENCH_MARK(62);
    if (k < 2) fft_stages(fy, FFT_N);
    else       fft_stages_dmac(fy, FFT_N);
    if (k == 1) BENCH_MARK(61);
    if (k == 3) BENCH_MARK(63);
    for (int i = 0; i < FFT_N; i++)
      if (fy[i] != fft_expect[i]) return 24 + k;
  }
  for (int k = 0; k < 2; k++) {
    fft_bitrev_agu(fy, fft_x, FFT_N);
    if (k == 1) BENCH_MARK(64);
    fft_stages_packed(fy, FFT_N);
    if (k == 1) BENCH_MARK(65);
    for (int i = 0; i < FFT_N; i++)
      if (fy[i] != fft_expect[i]) return 28 + k;
  }

  /* Zk: SHA-256 of 256 bytes, plain then with Zbkb and Zknh; cold first */
  static uint32_t dg[8];
  for (int k = 0; k < 4; k++) {
    for (int i = 0; i < 8; i++) dg[i] = 0;
    if (k == 1) BENCH_MARK(66);
    if (k == 3) BENCH_MARK(68);
    if (k < 2) sha256(sha_msg, SHA_LEN, dg);
    else       sha256_zk(sha_msg, SHA_LEN, dg);
    if (k == 1) BENCH_MARK(67);
    if (k == 3) BENCH_MARK(69);
    for (int i = 0; i < 8; i++)
      if (dg[i] != sha_expect[i]) return 30 + k;
  }

  /* Zk: AES-128 encryption of 256 bytes: byte-oriented C, T-table C, then
     Zkne; each run cold first, unmeasured */
  static uint8_t act[16 * AES_BLOCKS] __attribute__((aligned(4)));
  for (int k = 0; k < 6; k++) {
    for (int i = 0; i < 16 * AES_BLOCKS; i++) act[i] = 0;
    if (k == 1) BENCH_MARK(70);
    if (k == 5) BENCH_MARK(72);
    if (k == 3) BENCH_MARK(74);
    if (k < 2)      aes128_enc(act, aes_pt, aes_rk, AES_BLOCKS);
    else if (k < 4) aes128_enc_t((uint32_t *)act, (const uint32_t *)aes_pt, (const uint32_t *)aes_rk, AES_BLOCKS);
    else            aes128_enc_zk((uint32_t *)act, (const uint32_t *)aes_pt, (const uint32_t *)aes_rk, AES_BLOCKS);
    if (k == 1) BENCH_MARK(71);
    if (k == 5) BENCH_MARK(73);
    if (k == 3) BENCH_MARK(75);
    for (int i = 0; i < 16 * AES_BLOCKS; i++)
      if (act[i] != aes_expect[i]) return 34 + k;
  }

  /* CRC-32 of 256 bytes: table-driven, then carry-less multiply; cold first */
  for (int k = 0; k < 4; k++) {
    uint32_t c;
    if (k == 1) BENCH_MARK(76);
    if (k == 3) BENCH_MARK(78);
    if (k < 2) c = crc32_table(crc_msg, CRC_LEN);
    else       c = crc32_clmul((const uint32_t *)crc_msg, CRC_LEN);
    if (k == 1) BENCH_MARK(77);
    if (k == 3) BENCH_MARK(79);
    if (c != crc_expect) return 40 + k;
  }

  /* GF(2): each kernel run cold, then warm between markers m and m + 1 */
#define WARM(m, run, ok, fail)                  \
  for (int k = 0; k < 2; k++) {                 \
    if (k) BENCH_MARK(m);                       \
    run;                                        \
    if (k) BENCH_MARK((m) + 1);                 \
    if (!(ok)) return fail;                     \
  }
  /* Seven CRCs of the same 256 bytes (markers 88-101) */
  const uint32_t *cw = (const uint32_t *)crc_msg;
  uint32_t c;
  WARM(88,  c = crc32_bitwise(crc_msg, CRC_LEN), c == crc_expect, 60);
  WARM(90,  c = crc32c_table(crc_msg, CRC_LEN), c == crc32c_expect, 61);
  WARM(92,  c = crc32c_clmul(cw, CRC_LEN), c == crc32c_expect, 62);
  WARM(94,  c = crc16_table(crc_msg, CRC_LEN), c == crc16_expect, 63);
  WARM(96,  c = crc_clmul_msb(cw, CRC_LEN, CRC16_P, CRC16_MU, 16), c == crc16_expect, 64);
  WARM(98,  c = crc8_table(crc_msg, CRC_LEN), c == crc8_expect, 65);
  WARM(100, c = crc_clmul_msb(cw, CRC_LEN, CRC8_P, CRC8_MU, 8), c == crc8_expect, 66);

  /* LFSR: 64 words a bit at a time, a byte at a time, by clmul; xorshift32
     (markers 102-109); the jump ahead, plain and by clmul (110-113) */
  static uint32_t rnd[LFSR_WORDS];
  WARM(102, lfsr_bitwise(rnd, LFSR_SEED, LFSR_WORDS), words_eq(rnd, lfsr_expect, LFSR_WORDS), 70);
  WARM(104, lfsr_table(rnd, LFSR_SEED, LFSR_WORDS), words_eq(rnd, lfsr_expect, LFSR_WORDS), 71);
  WARM(106, lfsr_clmul(rnd, LFSR_SEED, LFSR_WORDS), words_eq(rnd, lfsr_expect, LFSR_WORDS), 72);
  WARM(108, xorshift32(rnd, LFSR_SEED, LFSR_WORDS), words_eq(rnd, xs_expect, LFSR_WORDS), 73);
  WARM(110, c = lfsr_jump(LFSR_SEED, LFSR_JUMP), c == lfsr_jump_expect, 74);
  WARM(112, c = lfsr_jump_clmul(LFSR_SEED, LFSR_JUMP), c == lfsr_jump_expect, 75);

  /* GF(2^8): Reed-Solomon syndromes and Chien search, plain then gfmul4
     (markers 114-121); AES InvMixColumns of 256 bytes (122-125) */
  static uint8_t syn[RS_NSYM] __attribute__((aligned(4)));
  static uint8_t pos[RS_ERRS + 4];
  WARM(114, rs_syndromes(syn, rs_rx), bytes_eq(syn, rs_syn_expect, RS_NSYM), 76);
  WARM(116, rs_syndromes_gf(syn, rs_rx), bytes_eq(syn, rs_syn_expect, RS_NSYM), 77);
  WARM(118, c = rs_chien(pos, rs_lambda), c == RS_ERRS && bytes_eq(pos, rs_pos_expect, RS_ERRS), 78);
  WARM(120, c = rs_chien_gf(pos, rs_lambda), c == RS_ERRS && bytes_eq(pos, rs_pos_expect, RS_ERRS), 79);
  WARM(122, aes_invmix(rnd, (const uint32_t *)aes_pt, 64), bytes_eq((uint8_t *)rnd, aes_invmix_expect, 256), 80);
  WARM(124, aes_invmix_gf(rnd, (const uint32_t *)aes_pt, 64), bytes_eq((uint8_t *)rnd, aes_invmix_expect, 256), 81);

  /* ML-KEM's ring, the reference then the extension: the NTT (markers
     126-131: reference, mqmul2 alone, butterfly instructions; 146-147, the
     butterfly instructions two layers per pass), the inverse NTT (132-135;
     148-149, two layers per pass),
     basemul (136-139) and a whole product a * b (142-145).
     Inputs are copied in before each run (outside the markers): the
     transforms work in place. */
#define WARM_POLY(m, setup, run, ok, fail)      \
  for (int k = 0; k < 2; k++) {                 \
    setup;                                      \
    if (k) BENCH_MARK(m);                       \
    run;                                        \
    if (k) BENCH_MARK((m) + 1);                 \
    if (!(ok)) return fail;                     \
  }
  static uint16_t pa[256] __attribute__((aligned(4))), pb[256] __attribute__((aligned(4)));
  static uint16_t pc[256] __attribute__((aligned(4)));
  int16_t *sa = (int16_t *)pa, *sb = (int16_t *)pb, *sc = (int16_t *)pc;
  WARM_POLY(126, poly_copy(pa, mlkem_a), mlkem_ntt(sa), poly_eq(pa, mlkem_ntt_a, 1), 100);
  WARM_POLY(128, poly_copy(pa, mlkem_a), mlkem_ntt_mq(pa), poly_eq(pa, mlkem_ntt_a, 0), 101);
  WARM_POLY(130, poly_copy(pa, mlkem_a), mlkem_ntt_ct(pa), poly_eq(pa, mlkem_ntt_a, 0), 102);
  WARM_POLY(146, poly_copy(pa, mlkem_a), mlkem_ntt_ct2(pa), poly_eq(pa, mlkem_ntt_a, 0), 109);
  WARM_POLY(132, poly_copy(pa, mlkem_ntt_a), mlkem_invntt(sa), poly_eq(pa, mlkem_invntt_expect, 1), 103);
  WARM_POLY(134, poly_copy(pa, mlkem_ntt_a), mlkem_invntt_x(pa), poly_eq(pa, mlkem_invntt_expect, 0), 104);
  WARM_POLY(148, poly_copy(pa, mlkem_ntt_a), mlkem_invntt_x2(pa), poly_eq(pa, mlkem_invntt_expect, 0), 110);
  WARM_POLY(136, (poly_copy(pa, mlkem_ntt_a), poly_copy(pb, mlkem_ntt_b)), mlkem_basemul(sc, sa, sb),
            poly_eq(pc, mlkem_basemul_expect, 1), 105);
  WARM_POLY(138, (poly_copy(pa, mlkem_ntt_a), poly_copy(pb, mlkem_ntt_b)), mlkem_basemul_x(pc, pa, pb),
            poly_eq(pc, mlkem_basemul_expect, 0), 106);
  WARM_POLY(142, (poly_copy(pa, mlkem_a), poly_copy(pb, mlkem_b)), mlkem_polymul(sc, sa, sb),
            poly_eq(pc, mlkem_mul_expect, 1), 107);
  WARM_POLY(144, (poly_copy(pa, mlkem_a), poly_copy(pb, mlkem_b)), mlkem_polymul_x(pc, pa, pb),
            poly_eq(pc, mlkem_mul_expect, 0), 108);

  /* Timing against the data: each kernel on two inputs, through timed()
     (markers 140/141, in this order), after a first call on the second
     input that is not compared: it brings timed()'s own code into the
     I-cache (GCC unrolls its cold-then-warm loop, so the warm run's code is
     first fetched by the first warm run). Zkne AES and the gfmul4 syndromes
     must then take the same cycles on both inputs; the T-table AES and the
     log-table syndromes need not. */
  for (int z = 0; z < 4; z++)
    for (int k = 0; k < 3; k++) {
      int two = k != 1;
      if (z < 2) timed(z, two ? aes_pt2 : aes_pt, 16 * AES_BLOCKS, two ? aes_rk2 : aes_rk);
      else       timed(z, two ? rs_rx2 : rs_rx, RS_N, 0);
      if (z < 2 ? !bytes_eq(t_out, two ? aes_expect2 : aes_expect, 16 * AES_BLOCKS)
                : !bytes_eq(t_out, two ? rs_syn2_expect : rs_syn_expect, RS_NSYM))
        return 82 + 3 * z + k;
    }

  return 0;
}
