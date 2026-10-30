/* mlkem_x.c — the same with Xbrvdsp's packed arithmetic mod q (mq_unit.v):
   coefficients are uint16_t in [0, q), two to a word, and every
   instruction works on both. Each layer of the NTT pairs word j with word
   j + len/2: two butterflies with the same zeta, one per lane. mlkem_ntt_mq
   uses the general modular multiply (mqmul2 by {zeta, zeta}, which takes
   two cycles in MEM, then mqadd2 and mqsub2: three instructions per two
   butterflies); mlkem_ntt_ct the butterfly instructions (ctadd2 and
   ctsub2, with zeta set once per block by mq.zeta: two, one cycle each).
   Results are fully reduced, so there is no Barrett pass. The inverse NTT's
   Gentleman-Sande butterfly is gsmul2 and mqadd2. basemul forms a0 b0 and a1 b1 in one mqmul2, a0 b1 and a1 b0 in
   another (rs2 rotated by 16, Zbkb's rori), and ctadd2 with zeta = gamma
   adds a0 b0 + gamma a1 b1. Multiplications keep pq-crystals' Montgomery
   factors, so each function's result is the reference's, reduced.
   (Inline .insn: the assembler does not know Xbrvdsp. All are volatile, so
   none moves across the mq.zeta or mq.cfg it depends on. A result is ready
   a cycle later than an ALU's, as a multiply's is, and GCC, not knowing
   that, puts each store straight after the instruction that feeds it; so
   the butterflies of an NTT inner loop are one asm statement, with their
   stores after it, and each asm's instructions are ordered so that the
   last word loaded is not needed straight away.) */
#include <stdint.h>
#include "bench_data.h"

#define MQ_CFG(a)    __asm__ volatile (".insn r 0x0b, 6, 5, x0, %0, x0" :: "r" (a))
#define MQ_ZETA(a)   __asm__ volatile (".insn r 0x0b, 6, 6, x0, %0, x0" :: "r" (a))

/* Two butterflies with zeta (as {zeta, zeta}) in z: a + zeta b, a - zeta b */
#define BFLY2_MQ(x0, x1, y0, y1, a0, a1, b0, b1, z)                                         \
  __asm__ volatile (".insn r 0x0b, 6, 0, %2, %6, %8\n\t"                                    \
                    ".insn r 0x0b, 6, 0, %3, %7, %8\n\t"                                    \
                    ".insn r 0x0b, 6, 1, %0, %4, %2\n\t"                                    \
                    ".insn r 0x0b, 6, 1, %1, %5, %3\n\t"                                    \
                    ".insn r 0x0b, 6, 2, %2, %4, %2\n\t"                                    \
                    ".insn r 0x0b, 6, 2, %3, %5, %3"                                        \
                    : "=&r" (x0), "=&r" (x1), "=&r" (y0), "=&r" (y1)                        \
                    : "r" (a0), "r" (a1), "r" (b0), "r" (b1), "r" (z))
/* The same with zeta in state (mq.zeta): ctadd2, ctsub2 */
#define BFLY2_CT(x0, x1, y0, y1, a0, a1, b0, b1)                                            \
  __asm__ volatile (".insn r 0x0b, 6, 3, %0, %4, %6\n\t"                                    \
                    ".insn r 0x0b, 6, 4, %2, %4, %6\n\t"                                    \
                    ".insn r 0x0b, 6, 3, %1, %5, %7\n\t"                                    \
                    ".insn r 0x0b, 6, 4, %3, %5, %7"                                        \
                    : "=&r" (x0), "=&r" (x1), "=&r" (y0), "=&r" (y1)                        \
                    : "r" (a0), "r" (a1), "r" (b0), "r" (b1))
/* Inverse NTT (Gentleman-Sande): a + b, zeta (b - a), zeta in state */
#define BFLY2_GS(x0, x1, y0, y1, a0, a1, b0, b1)                                  \
  __asm__ volatile (".insn r 0x0b, 6, 9, %2, %4, %6\n\t"                         \
                    ".insn r 0x0b, 6, 1, %0, %4, %6\n\t"                         \
                    ".insn r 0x0b, 6, 9, %3, %5, %7\n\t"                         \
                    ".insn r 0x0b, 6, 1, %1, %5, %7"                             \
                    : "=&r" (x0), "=&r" (x1), "=&r" (y0), "=&r" (y1)              \
                    : "r" (a0), "r" (a1), "r" (b0), "r" (b1))

__attribute__((noipa))
void mlkem_ntt_mq(uint16_t *r)
{
  uint32_t *w = (uint32_t *)r;
  unsigned k = 1;
  MQ_CFG(MLKEM_QCFG);
  for (unsigned h = 64; h >= 2; h >>= 1)                  /* h = len / 2 words */
    for (unsigned s = 0; s < 128; s += 2 * h) {
      uint32_t z = mlkem_zetas[k++] * 0x10001u;
      for (unsigned j = s; j < s + h; j += 2) {
        uint32_t b0 = w[j + h], b1 = w[j + h + 1], a0 = w[j], a1 = w[j + 1], x0, x1, y0, y1;
        BFLY2_MQ(x0, x1, y0, y1, a0, a1, b0, b1, z);
        w[j] = x0; w[j + 1] = x1; w[j + h] = y0; w[j + h + 1] = y1;
      }
    }
  for (unsigned s = 0; s < 128; s += 4) {                 /* len 2: one word each side */
    uint32_t z0 = mlkem_zetas[k] * 0x10001u, z1 = mlkem_zetas[k + 1] * 0x10001u, x0, x1, y0, y1;
    uint32_t a0 = w[s], b0 = w[s + 1], a1 = w[s + 2], b1 = w[s + 3];
    k += 2;
    __asm__ volatile (".insn r 0x0b, 6, 0, %2, %6, %8\n\t"
                      ".insn r 0x0b, 6, 0, %3, %7, %9\n\t"
                      ".insn r 0x0b, 6, 1, %0, %4, %2\n\t"
                      ".insn r 0x0b, 6, 1, %1, %5, %3\n\t"
                      ".insn r 0x0b, 6, 2, %2, %4, %2\n\t"
                      ".insn r 0x0b, 6, 2, %3, %5, %3"
                      : "=&r" (x0), "=&r" (x1), "=&r" (y0), "=&r" (y1)
                      : "r" (a0), "r" (a1), "r" (b0), "r" (b1), "r" (z0), "r" (z1));
    w[s] = x0; w[s + 1] = y0; w[s + 2] = x1; w[s + 3] = y1;
  }
}

__attribute__((noipa))
void mlkem_ntt_ct(uint16_t *r)
{
  uint32_t *w = (uint32_t *)r;
  unsigned k = 1;
  MQ_CFG(MLKEM_QCFG);
  for (unsigned h = 64; h >= 2; h >>= 1)
    for (unsigned s = 0; s < 128; s += 2 * h) {
      MQ_ZETA(mlkem_zetas[k++]);
      for (unsigned j = s; j < s + h; j += 2) {
        uint32_t a0 = w[j], a1 = w[j + 1], b0 = w[j + h], b1 = w[j + h + 1], x0, x1, y0, y1;
        BFLY2_CT(x0, x1, y0, y1, a0, a1, b0, b1);
        w[j] = x0; w[j + 1] = x1; w[j + h] = y0; w[j + h + 1] = y1;
      }
    }
  for (unsigned s = 0; s < 128; s += 2) {                 /* len 2: a zeta per word pair */
    uint32_t a = w[s], b = w[s + 1], z = mlkem_zetas[k++], x, y;
    __asm__ volatile (".insn r 0x0b, 6, 6, x0, %4, x0\n\t"
                      ".insn r 0x0b, 6, 3, %0, %2, %3\n\t"
                      ".insn r 0x0b, 6, 4, %1, %2, %3"
                      : "=&r" (x), "=&r" (y) : "r" (a), "r" (b), "r" (z));
    w[s] = x; w[s + 1] = y;
  }
}

/* Two layers per pass (h and h/2 words: layers len = 2h and len = h), so
   each coefficient is loaded and stored once per two layers. Stores, not
   arithmetic, are what limit the single-layer loops above: the D-cache is
   write-through with a one-word write buffer, and a store waits while the
   one before it is still being written (about four cycles each). Each asm
   step takes two groups of four words, j, j + h/2, j + h, j + 3h/2 (and
   j + 1 ...): the first layer pairs (j, j + h) and (j + h/2, j + 3h/2) with
   zeta1; the second (j, j + h/2) with zeta2a and (j + h, j + 3h/2) with
   zeta2b. Results are written in place of operands no longer needed, and
   the stores are spread out between the last butterflies. */
#define NTT2_STEP(p, h, z1, z2a, z2b)                                                       \
  do {                                                                                      \
    uint32_t t0_, w0_, w2_, v0_, v2_, w1_, w3_, v1_, v3_;                                   \
    __asm__ volatile ("lw    %1, 0(%9)\n\t"                                                 \
                      "lw    %2, %c13(%9)\n\t"                                              \
                      "lw    %3, 4(%9)\n\t"                                                 \
                      "lw    %4, %c13+4(%9)\n\t"                                            \
                      "lw    %5, %c12(%9)\n\t"                                              \
                      "lw    %6, %c14(%9)\n\t"                                              \
                      "lw    %7, %c12+4(%9)\n\t"                                            \
                      "lw    %8, %c14+4(%9)\n\t"                                            \
                      ".insn r 0x0b, 6, 6, x0, %10, x0\n\t"   /* zeta1 */                   \
                      ".insn r 0x0b, 6, 3, %0, %1, %2\n\t"                                  \
                      ".insn r 0x0b, 6, 4, %2, %1, %2\n\t"                                  \
                      ".insn r 0x0b, 6, 3, %1, %3, %4\n\t"                                  \
                      ".insn r 0x0b, 6, 4, %4, %3, %4\n\t"                                  \
                      ".insn r 0x0b, 6, 3, %3, %5, %6\n\t"                                  \
                      ".insn r 0x0b, 6, 4, %6, %5, %6\n\t"                                  \
                      ".insn r 0x0b, 6, 3, %5, %7, %8\n\t"                                  \
                      ".insn r 0x0b, 6, 4, %8, %7, %8\n\t"                                  \
                      ".insn r 0x0b, 6, 6, x0, %11, x0\n\t"   /* zeta2a */                  \
                      ".insn r 0x0b, 6, 3, %7, %0, %3\n\t"                                  \
                      ".insn r 0x0b, 6, 4, %3, %0, %3\n\t"                                  \
                      ".insn r 0x0b, 6, 3, %0, %1, %5\n\t"                                  \
                      ".insn r 0x0b, 6, 4, %5, %1, %5\n\t"                                  \
                      ".insn r 0x0b, 6, 6, x0, %15, x0\n\t"   /* zeta2b */                  \
                      "sw    %7, 0(%9)\n\t"                                                 \
                      ".insn r 0x0b, 6, 3, %1, %2, %6\n\t"                                  \
                      ".insn r 0x0b, 6, 4, %6, %2, %6\n\t"                                  \
                      "sw    %3, %c12(%9)\n\t"                                              \
                      ".insn r 0x0b, 6, 3, %2, %4, %8\n\t"                                  \
                      ".insn r 0x0b, 6, 4, %8, %4, %8\n\t"                                  \
                      "sw    %0, 4(%9)\n\t"                                                 \
                      "sw    %5, %c12+4(%9)\n\t"                                            \
                      "sw    %1, %c13(%9)\n\t"                                              \
                      "sw    %6, %c14(%9)\n\t"                                              \
                      "sw    %2, %c13+4(%9)\n\t"                                            \
                      "sw    %8, %c14+4(%9)"                                                \
                      : "=&r" (t0_), "=&r" (w0_), "=&r" (w2_), "=&r" (v0_), "=&r" (v2_),    \
                        "=&r" (w1_), "=&r" (w3_), "=&r" (v1_), "=&r" (v3_)                  \
                      : "r" (p), "r" (z1), "r" (z2a), "i" (2 * (h)), "i" (4 * (h)),         \
                        "i" (6 * (h)), "r" (z2b)                                            \
                      : "memory");                                                          \
  } while (0)

#define NTT2_PASS(w, h)                                                                     \
  for (unsigned b_ = 0; b_ < 64 / (h); b_++) {                                              \
    uint32_t z1_ = mlkem_zetas[64 / (h) + b_], z2a_ = mlkem_zetas[128 / (h) + 2 * b_];      \
    uint32_t z2b_ = mlkem_zetas[128 / (h) + 2 * b_ + 1];                                    \
    for (uint32_t *p_ = (w) + 2 * (h) * b_; p_ < (w) + 2 * (h) * b_ + (h) / 2; p_ += 2)     \
      NTT2_STEP(p_, h, z1_, z2a_, z2b_);                                                    \
  }

__attribute__((noipa))
void mlkem_ntt_ct2(uint16_t *r)
{
  uint32_t *w = (uint32_t *)r;
  MQ_CFG(MLKEM_QCFG);
  NTT2_PASS(w, 64);
  NTT2_PASS(w, 16);
  NTT2_PASS(w, 4);
  for (unsigned s = 0, k = 64; s < 128; s += 2) {        /* len 2 */
    uint32_t a = w[s], b = w[s + 1], z = mlkem_zetas[k++], x, y;
    __asm__ volatile (".insn r 0x0b, 6, 6, x0, %4, x0\n\t"
                      ".insn r 0x0b, 6, 3, %0, %2, %3\n\t"
                      ".insn r 0x0b, 6, 4, %1, %2, %3"
                      : "=&r" (x), "=&r" (y) : "r" (a), "r" (b), "r" (z));
    w[s] = x; w[s + 1] = y;
  }
}

/* Inverse NTT; the output is multiplied by R, as the reference's. Each
   Gentleman-Sande butterfly pair is gsmul2 (zeta (b - a)) and mqadd2
   (a + b); the final multiply by f = R^2/128 is ctadd2 from x0 with
   zeta = f. */
__attribute__((noipa))
void mlkem_invntt_x(uint16_t *r)
{
  uint32_t *w = (uint32_t *)r;
  unsigned k = 127;
  MQ_CFG(MLKEM_QCFG);
  for (unsigned s = 0; s < 128; s += 4) {                 /* len 2 */
    uint32_t z0 = mlkem_zetas[k], z1 = mlkem_zetas[k - 1], x0, x1, y0, y1;
    uint32_t a0 = w[s], b0 = w[s + 1], a1 = w[s + 2], b1 = w[s + 3];
    k -= 2;
    __asm__ volatile (".insn r 0x0b, 6, 6, x0, %8, x0\n\t"
                      ".insn r 0x0b, 6, 9, %2, %4, %6\n\t"
                      ".insn r 0x0b, 6, 1, %0, %4, %6\n\t"
                      ".insn r 0x0b, 6, 6, x0, %9, x0\n\t"
                      ".insn r 0x0b, 6, 9, %3, %5, %7\n\t"
                      ".insn r 0x0b, 6, 1, %1, %5, %7"
                      : "=&r" (x0), "=&r" (x1), "=&r" (y0), "=&r" (y1)
                      : "r" (a0), "r" (a1), "r" (b0), "r" (b1), "r" (z0), "r" (z1));
    w[s] = x0; w[s + 1] = y0; w[s + 2] = x1; w[s + 3] = y1;
  }
  for (unsigned h = 2; h <= 64; h <<= 1)
    for (unsigned s = 0; s < 128; s += 2 * h) {
      MQ_ZETA(mlkem_zetas[k--]);
      for (unsigned j = s; j < s + h; j += 2) {
        uint32_t a0 = w[j], a1 = w[j + 1], b0 = w[j + h], b1 = w[j + h + 1], x0, x1, y0, y1;
        BFLY2_GS(x0, x1, y0, y1, a0, a1, b0, b1);
        w[j] = x0; w[j + 1] = x1; w[j + h] = y0; w[j + h + 1] = y1;
      }
    }
  MQ_ZETA(1441);                                          /* f = R^2 / 128 mod q */
  for (unsigned j = 0; j < 128; j += 2) {
    uint32_t a0 = w[j], a1 = w[j + 1], x0, x1;
    __asm__ volatile (".insn r 0x0b, 6, 3, %0, x0, %2\n\t"
                      ".insn r 0x0b, 6, 3, %1, x0, %3"
                      : "=&r" (x0), "=&r" (x1) : "r" (a0), "r" (a1));
    w[j] = x0; w[j + 1] = x1;
  }
}

/* The inverse NTT two layers per pass, as mlkem_ntt_ct2: len 2 alone,
   then (4, 8), (16, 32), (64, 128). Each step takes two groups of four
   words, j, j + h/2, j + h, j + 3h/2 (and j + 1 ...); the first layer pairs
   (j, j + h/2) with zeta_a and (j + h, j + 3h/2) with zeta_b, the second
   (j, j + h) and (j + h/2, j + 3h/2) with zeta1. Results go to whichever
   register is free (the operand a butterfly has finished with). The last
   pass also applies the final multiply by f = R^2/128: a + b is
   multiplied by f (ctadd2 from x0), and b - a by zeta1 f R^-1 instead of
   zeta1, which saves a pass over the coefficients. */
/* operands: %0 spare; %1 %3 words j, j + 1; %5 %7 j + h/2; %2 %4 j + h;
   %6 %8 j + 3h/2; %9 the pointer; %10 %11 %12 zeta_a, zeta_b, zeta1;
   %13 %14 %15 the byte offsets 2h, 4h, 6h; %16 f */
#define INTT2_FIRST                                                                \
  "lw    %1, 0(%9)\n\t"                                                            \
  "lw    %5, %c13(%9)\n\t"                                                         \
  "lw    %3, 4(%9)\n\t"                                                            \
  "lw    %7, %c13+4(%9)\n\t"                                                       \
  "lw    %2, %c14(%9)\n\t"                                                         \
  "lw    %6, %c15(%9)\n\t"                                                         \
  "lw    %4, %c14+4(%9)\n\t"                                                       \
  "lw    %8, %c15+4(%9)\n\t"                                                       \
  ".insn r 0x0b, 6, 6, x0, %10, x0\n\t"                   /* zeta_a */           \
  ".insn r 0x0b, 6, 9, %0, %1, %5\n\t"                                             \
  ".insn r 0x0b, 6, 1, %1, %1, %5\n\t"                                             \
  ".insn r 0x0b, 6, 9, %5, %3, %7\n\t"                                             \
  ".insn r 0x0b, 6, 1, %3, %3, %7\n\t"                                             \
  ".insn r 0x0b, 6, 6, x0, %11, x0\n\t"                   /* zeta_b */           \
  ".insn r 0x0b, 6, 9, %7, %2, %6\n\t"                                             \
  ".insn r 0x0b, 6, 1, %2, %2, %6\n\t"                                             \
  ".insn r 0x0b, 6, 9, %6, %4, %8\n\t"                                             \
  ".insn r 0x0b, 6, 1, %4, %4, %8\n\t"                                             \
  ".insn r 0x0b, 6, 6, x0, %12, x0\n\t"                   /* zeta1 */            \
  ".insn r 0x0b, 6, 9, %8, %1, %2\n\t"                                             \
  ".insn r 0x0b, 6, 1, %1, %1, %2\n\t"                                             \
  ".insn r 0x0b, 6, 9, %2, %3, %4\n\t"                                             \
  ".insn r 0x0b, 6, 1, %3, %3, %4\n\t"
#define INTT2_OPS(p, h, za, zb, z1, f)                                             \
  : "=&r" (t0_), "=&r" (w0_), "=&r" (w2_), "=&r" (v0_), "=&r" (v2_),               \
    "=&r" (w1_), "=&r" (w3_), "=&r" (v1_), "=&r" (v3_)                             \
  : "r" (p), "r" (za), "r" (zb), "r" (z1), "i" (2 * (h)), "i" (4 * (h)),           \
    "i" (6 * (h)), "r" (f)                                                         \
  : "memory"
#define INTT2_STEP(p, h, za, zb, z1)                                               \
  do {                                                                             \
    uint32_t t0_, w0_, w2_, v0_, v2_, w1_, w3_, v1_, v3_;                          \
    __asm__ volatile (INTT2_FIRST                                                  \
                      "sw    %1, 0(%9)\n\t"                                        \
                      ".insn r 0x0b, 6, 9, %4, %0, %7\n\t"                         \
                      ".insn r 0x0b, 6, 1, %0, %0, %7\n\t"                         \
                      "sw    %8, %c14(%9)\n\t"                                     \
                      ".insn r 0x0b, 6, 9, %7, %5, %6\n\t"                         \
                      ".insn r 0x0b, 6, 1, %5, %5, %6\n\t"                         \
                      "sw    %3, 4(%9)\n\t"                                        \
                      "sw    %2, %c14+4(%9)\n\t"                                   \
                      "sw    %0, %c13(%9)\n\t"                                     \
                      "sw    %4, %c15(%9)\n\t"                                     \
                      "sw    %5, %c13+4(%9)\n\t"                                   \
                      "sw    %7, %c15+4(%9)"                                       \
                      INTT2_OPS(p, h, za, zb, z1, z1));                            \
  } while (0)
#define INTT2_STEP_F(p, h, za, zb, z1f, f)                                         \
  do {                                                                             \
    uint32_t t0_, w0_, w2_, v0_, v2_, w1_, w3_, v1_, v3_;                          \
    __asm__ volatile (INTT2_FIRST                                                  \
                      ".insn r 0x0b, 6, 9, %4, %0, %7\n\t"                         \
                      ".insn r 0x0b, 6, 1, %0, %0, %7\n\t"                         \
                      ".insn r 0x0b, 6, 9, %7, %5, %6\n\t"                         \
                      ".insn r 0x0b, 6, 1, %5, %5, %6\n\t"                         \
                      ".insn r 0x0b, 6, 6, x0, %16, x0\n\t"   /* f */              \
                      ".insn r 0x0b, 6, 3, %1, x0, %1\n\t"                         \
                      "sw    %8, %c14(%9)\n\t"                                     \
                      ".insn r 0x0b, 6, 3, %3, x0, %3\n\t"                         \
                      "sw    %2, %c14+4(%9)\n\t"                                   \
                      ".insn r 0x0b, 6, 3, %0, x0, %0\n\t"                         \
                      "sw    %4, %c15(%9)\n\t"                                     \
                      ".insn r 0x0b, 6, 3, %5, x0, %5\n\t"                         \
                      "sw    %7, %c15+4(%9)\n\t"                                   \
                      "sw    %1, 0(%9)\n\t"                                        \
                      "sw    %3, 4(%9)\n\t"                                        \
                      "sw    %0, %c13(%9)\n\t"                                     \
                      "sw    %5, %c13+4(%9)"                                       \
                      INTT2_OPS(p, h, za, zb, z1f, f));                            \
  } while (0)

#define INTT2_PASS(w, h, STEP, ...)                                                \
  for (unsigned b_ = 0; b_ < 64 / (h); b_++) {                                     \
    uint32_t za = mlkem_zetas[256 / (h) - 1 - 2 * b_];                             \
    uint32_t zb = mlkem_zetas[256 / (h) - 2 - 2 * b_];                             \
    uint32_t z1 = mlkem_zetas[128 / (h) - 1 - b_];                                 \
    for (uint32_t *p = (w) + 2 * (h) * b_; p < (w) + 2 * (h) * b_ + (h) / 2; p += 2) \
      STEP(p, h, za, zb, __VA_ARGS__);                                             \
  }

__attribute__((noipa))
void mlkem_invntt_x2(uint16_t *r)
{
  uint32_t *w = (uint32_t *)r;
  const uint32_t f = 1441;                                /* R^2 / 128 mod q */
  MQ_CFG(MLKEM_QCFG);
  for (unsigned s = 0, k = 127; s < 128; s += 4) {        /* len 2 */
    uint32_t z0 = mlkem_zetas[k], z1 = mlkem_zetas[k - 1], x0, x1, y0, y1;
    uint32_t a0 = w[s], b0 = w[s + 1], a1 = w[s + 2], b1 = w[s + 3];
    k -= 2;
    __asm__ volatile (".insn r 0x0b, 6, 6, x0, %8, x0\n\t"
                      ".insn r 0x0b, 6, 9, %2, %4, %6\n\t"
                      ".insn r 0x0b, 6, 1, %0, %4, %6\n\t"
                      ".insn r 0x0b, 6, 6, x0, %9, x0\n\t"
                      ".insn r 0x0b, 6, 9, %3, %5, %7\n\t"
                      ".insn r 0x0b, 6, 1, %1, %5, %7"
                      : "=&r" (x0), "=&r" (x1), "=&r" (y0), "=&r" (y1)
                      : "r" (a0), "r" (a1), "r" (b0), "r" (b1), "r" (z0), "r" (z1));
    w[s] = x0; w[s + 1] = y0; w[s + 2] = x1; w[s + 3] = y1;
  }
  INTT2_PASS(w, 4, INTT2_STEP, z1);
  INTT2_PASS(w, 16, INTT2_STEP, z1);
  uint32_t z1f;                                           /* zeta1 f R^-1 = mont(f * zeta1) */
  MQ_ZETA(f);
  __asm__ volatile (".insn r 0x0b, 6, 3, %0, x0, %1" : "=r" (z1f) : "r" ((uint32_t)mlkem_zetas[1]));
  INTT2_PASS(w, 64, INTT2_STEP_F, z1f, f);
}

/* The 128 degree-one products (times R^-1, as the reference's), two per
   asm statement: their gammas differ, so mq.zeta goes between the two
   ctadd2s */
__attribute__((noipa))
void mlkem_basemul_x(uint16_t *r, const uint16_t *a, const uint16_t *b)
{
  uint32_t *rw = (uint32_t *)r;
  const uint32_t *aw = (const uint32_t *)a, *bw = (const uint32_t *)b;
  MQ_CFG(MLKEM_QCFG);
  for (unsigned i = 0; i < 128; i += 2) {
    uint32_t x0 = aw[i], x1 = aw[i + 1], y0 = bw[i], y1 = bw[i + 1];
    uint32_t g0 = mlkem_gammas[i], g1 = mlkem_gammas[i + 1];
    uint32_t r0, r1, t0, t1, p0, c0, p1, c1, u0, u1;
    __asm__ volatile ("rori  %2, %12, 16\n\t"             /* y rotated: {b0, b1} */
                      "rori  %3, %13, 16\n\t"
                      ".insn r 0x0b, 6, 0, %4, %10, %12\n\t"   /* p = {a1 b1, a0 b0} */
                      ".insn r 0x0b, 6, 0, %5, %10, %2\n\t"    /* c = {a1 b0, a0 b1} */
                      ".insn r 0x0b, 6, 0, %6, %11, %13\n\t"
                      ".insn r 0x0b, 6, 0, %7, %11, %3\n\t"
                      ".insn r 0x0b, 6, 6, x0, %14, x0\n\t"    /* mq.zeta gamma0 */
                      "rori  %2, %4, 16\n\t"
                      "rori  %8, %5, 16\n\t"
                      "rori  %3, %6, 16\n\t"
                      "rori  %9, %7, 16\n\t"
                      ".insn r 0x0b, 6, 3, %2, %4, %2\n\t"     /* a0 b0 + gamma a1 b1 */
                      ".insn r 0x0b, 6, 6, x0, %15, x0\n\t"    /* mq.zeta gamma1 */
                      ".insn r 0x0b, 6, 3, %3, %6, %3\n\t"
                      ".insn r 0x0b, 6, 1, %8, %5, %8\n\t"     /* a0 b1 + a1 b0 */
                      ".insn r 0x0b, 6, 1, %9, %7, %9\n\t"
                      "pack  %0, %2, %8\n\t"
                      "pack  %1, %3, %9"
                      : "=&r" (r0), "=&r" (r1), "=&r" (t0), "=&r" (t1), "=&r" (p0), "=&r" (c0),
                        "=&r" (p1), "=&r" (c1), "=&r" (u0), "=&r" (u1)
                      : "r" (x0), "r" (x1), "r" (y0), "r" (y1), "r" (g0), "r" (g1));
    rw[i] = r0;
    rw[i + 1] = r1;
  }
}

/* c = a * b in Z_q[X]/(X^256 + 1); a and b are overwritten by their NTTs */
__attribute__((noipa))
void mlkem_polymul_x(uint16_t *c, uint16_t *a, uint16_t *b)
{
  mlkem_ntt_ct2(a);
  mlkem_ntt_ct2(b);
  mlkem_basemul_x(c, a, b);
  mlkem_invntt_x2(c);
}
