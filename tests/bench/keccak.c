/* keccak.c — Keccak-f[1600] and the FIPS 202 functions ML-KEM uses
   (SHA3-256, SHA3-512, SHAKE128, SHAKE256), in plain portable C, in three
   builds chosen by a macro (the same keccak.h API in each):

   (none)           the lanes are uint64_t, which rv32imc's GCC splits into
                    register pairs, and the permutation is written as the
                    standard's five steps (theta, rho, pi, chi, iota), one
                    round at a time, the rounds not unrolled. It is the
                    baseline, kept straightforward.
   -DKECCAK_BI      bit-interleaved 32-bit lanes (as in XKCP's inplace32BI
                    and pqm4): each 64-bit lane is held as two words, its
                    even bits and its odd bits, so a 64-bit rotation is two
                    32-bit rotations, and no 64-bit value is ever formed.
   -DKECCAK_BI_ZBKB the same, with Zbkb's zip and unzip for converting
                    lanes to and from the interleaved form at absorb and
                    squeeze. (rori and andn need no source change: GCC
                    uses them when -march has _zbkb.) Where the target has
                    no Zbkb, as on the host, zip and unzip are plain C.

   Each permutation is bracketed by BENCH_MARK(10) and (11) on the core,
   so run_kem.sh can count the permutations in each operation and the
   cycles they take; on the host the markers are empty. */
#include "keccak.h"
#ifdef __riscv
#include "bench.h"
#else
#define BENCH_MARK(n) do {} while (0)
#endif

void keccak_init(keccak_t *st, unsigned rate)
{
  for (unsigned i = 0; i < 25; i++)
    st->s.lane[i] = 0;
  st->rate = rate;
  st->pos = 0;
}

#if defined(KECCAK_BI) || defined(KECCAK_BI_ZBKB)

/* The state is 50 words: lane i is w[2i] (its even bits: bit k of the word
   is bit 2k of the lane) and w[2i + 1] (its odd bits). Rotating a lane left
   by 2m rotates both words left by m; by 2m + 1 swaps them and rotates
   one of them one place further. */
static const uint32_t RCI[48] = {
  0x00000001, 0x00000000, 0x00000000, 0x00000089,
  0x00000000, 0x8000008b, 0x00000000, 0x80008080,
  0x00000001, 0x0000008b, 0x00000001, 0x00008000,
  0x00000001, 0x80008088, 0x00000001, 0x80000082,
  0x00000000, 0x0000000b, 0x00000000, 0x0000000a,
  0x00000001, 0x00008082, 0x00000000, 0x00008003,
  0x00000001, 0x0000808b, 0x00000001, 0x8000000b,
  0x00000001, 0x8000008a, 0x00000001, 0x80000081,
  0x00000000, 0x80000081, 0x00000000, 0x80000008,
  0x00000000, 0x00000083, 0x00000000, 0x80008003,
  0x00000001, 0x80008088, 0x00000000, 0x80000088,
  0x00000001, 0x00008000, 0x00000000, 0x80008082
};

/* rotate left by a constant. With Zbkb it is rori (there is no immediate
   rotate left in the extension, and GCC would load the amount into a
   register and use rol), otherwise shifts and an or */
static inline __attribute__((always_inline)) uint32_t rol32(uint32_t x, unsigned n)
{
  unsigned r = (32 - n) & 31;
#if defined(KECCAK_BI_ZBKB) && defined(__riscv_zbkb)
  uint32_t y;
  if (r == 0)
    return x;
  __asm__("rori %0, %1, %2" : "=r" (y) : "r" (x), "i" (r));
  return y;
#else
  return r ? (x >> r) | (x << (32 - r)) : x;
#endif
}

static inline __attribute__((always_inline))
void rot64(uint32_t *re, uint32_t *ro, uint32_t e, uint32_t o, unsigned n)
{
  if (n & 1) {
    *re = rol32(o, (n >> 1) + 1);
    *ro = rol32(e, n >> 1);
  } else {
    *re = rol32(e, n >> 1);
    *ro = rol32(o, n >> 1);
  }
}

/* One output plane y: lane k of it is the input lane i, with column x's
   theta value xored in, rotated by n (rho and pi); then chi along the
   plane. The input and output are different arrays, as an output plane
   overwrites lanes a later plane still needs. */
#define LANE(k, i, x, n) \
  rot64(&ae[k], &ao[k], in[2 * (i)] ^ de[x], in[2 * (i) + 1] ^ dd[x], n)
#define CHI(y)                                                          \
  do {                                                                  \
    _Pragma("GCC unroll 5")                                              \
    for (unsigned k = 0; k < 5; k++) {                                  \
      out[2 * (5 * (y) + k)]     = ae[k] ^ (~ae[(k + 1) % 5] & ae[(k + 2) % 5]); \
      out[2 * (5 * (y) + k) + 1] = ao[k] ^ (~ao[(k + 1) % 5] & ao[(k + 2) % 5]); \
    }                                                                   \
  } while (0)

#define ROUND(src, dst, rc)                                             \
  do {                                                                  \
    const uint32_t *in = (src);                                         \
    uint32_t *out = (dst);                                              \
    uint32_t ce[5], cd[5], de[5], dd[5], ae[5], ao[5];                  \
    _Pragma("GCC unroll 5")                                              \
    for (unsigned x = 0; x < 5; x++) {                                  \
      ce[x] = in[2 * x] ^ in[2 * x + 10] ^ in[2 * x + 20] ^ in[2 * x + 30] ^ in[2 * x + 40]; \
      cd[x] = in[2 * x + 1] ^ in[2 * x + 11] ^ in[2 * x + 21] ^ in[2 * x + 31] ^ in[2 * x + 41]; \
    }                                                                   \
    _Pragma("GCC unroll 5")                                              \
    for (unsigned x = 0; x < 5; x++) {   /* D = C[x-1] ^ rotl64(C[x+1], 1) */ \
      de[x] = ce[(x + 4) % 5] ^ rol32(cd[(x + 1) % 5], 1);              \
      dd[x] = cd[(x + 4) % 5] ^ ce[(x + 1) % 5];                        \
    }                                                                   \
    LANE(0, 0, 0, 0);  LANE(1, 6, 1, 44);  LANE(2, 12, 2, 43); LANE(3, 18, 3, 21); LANE(4, 24, 4, 14); \
    CHI(0);                                                             \
    out[0] ^= (rc)[0]; out[1] ^= (rc)[1];                               \
    LANE(0, 3, 3, 28); LANE(1, 9, 4, 20);  LANE(2, 10, 0, 3);  LANE(3, 16, 1, 45); LANE(4, 22, 2, 61); \
    CHI(1);                                                             \
    LANE(0, 1, 1, 1);  LANE(1, 7, 2, 6);   LANE(2, 13, 3, 25); LANE(3, 19, 4, 8);  LANE(4, 20, 0, 18); \
    CHI(2);                                                             \
    LANE(0, 4, 4, 27); LANE(1, 5, 0, 36);  LANE(2, 11, 1, 10); LANE(3, 17, 2, 15); LANE(4, 23, 3, 56); \
    CHI(3);                                                             \
    LANE(0, 2, 2, 62); LANE(1, 8, 3, 55);  LANE(2, 14, 4, 39); LANE(3, 15, 0, 41); LANE(4, 21, 1, 2); \
    CHI(4);                                                             \
  } while (0)

/* One round per pass, reading one array and writing the other, so after 24
   rounds the result is back in w. (Two rounds per pass was the first
   version: 3.4 KB of straight-line code, which does not fit the 2 KB
   I-cache, and a permutation took 51,101 cycles; one round is 1.7 KB.) */
void keccak_f1600_bi(uint32_t w[50])
{
  uint32_t t[50];
  uint32_t *p = w, *q = t, *x;
  BENCH_MARK(10);
  for (unsigned r = 0; r < 48; r += 2) {
    ROUND(p, q, RCI + r);
    x = p; p = q; q = x;
  }
  BENCH_MARK(11);
}

/* zip and unzip (Zbkb): unzip32 gathers a word's even bits into its low
   half and its odd bits into its high half; zip32 is the inverse */
#if defined(KECCAK_BI_ZBKB) && defined(__riscv_zbkb)
static inline uint32_t unzip32(uint32_t x)
{
  uint32_t r;
  __asm__("unzip %0, %1" : "=r" (r) : "r" (x));
  return r;
}
static inline uint32_t zip32(uint32_t x)
{
  uint32_t r;
  __asm__("zip %0, %1" : "=r" (r) : "r" (x));
  return r;
}
#else
static uint32_t unzip32(uint32_t x)
{
  uint32_t t;
  t = (x ^ (x >> 1)) & 0x22222222u; x ^= t ^ (t << 1);
  t = (x ^ (x >> 2)) & 0x0C0C0C0Cu; x ^= t ^ (t << 2);
  t = (x ^ (x >> 4)) & 0x00F000F0u; x ^= t ^ (t << 4);
  t = (x ^ (x >> 8)) & 0x0000FF00u; x ^= t ^ (t << 8);
  return x;
}
static uint32_t zip32(uint32_t x)
{
  uint32_t t;
  t = (x ^ (x >> 8)) & 0x0000FF00u; x ^= t ^ (t << 8);
  t = (x ^ (x >> 4)) & 0x00F000F0u; x ^= t ^ (t << 4);
  t = (x ^ (x >> 2)) & 0x0C0C0C0Cu; x ^= t ^ (t << 2);
  t = (x ^ (x >> 1)) & 0x22222222u; x ^= t ^ (t << 1);
  return x;
}
#endif

/* A 64-bit lane, as low and high words, to and from (even, odd) */
static inline void interleave(uint32_t lo, uint32_t hi, uint32_t *e, uint32_t *o)
{
  uint32_t a = unzip32(lo), b = unzip32(hi);
  *e = (a & 0xFFFFu) | (b << 16);
  *o = (a >> 16) | (b & 0xFFFF0000u);
}

static inline void deinterleave(uint32_t e, uint32_t o, uint32_t *lo, uint32_t *hi)
{
  *lo = zip32((e & 0xFFFFu) | (o << 16));
  *hi = zip32((e >> 16) | (o & 0xFFFF0000u));
}

static uint32_t load32(const uint8_t *p)
{
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void store32(uint8_t *p, uint32_t v)
{
  p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

/* XOR byte b into the state at byte position pos (a byte is its own lane
   with a single non-zero byte) */
static void xor_byte(keccak_t *st, unsigned pos, uint8_t b)
{
  unsigned sh = (pos & 7) * 8;
  uint32_t lo = sh < 32 ? (uint32_t)b << sh : 0, hi = sh < 32 ? 0 : (uint32_t)b << (sh - 32);
  uint32_t e, o;
  interleave(lo, hi, &e, &o);
  st->s.w[2 * (pos >> 3)] ^= e;
  st->s.w[2 * (pos >> 3) + 1] ^= o;
}

static uint8_t get_byte(const keccak_t *st, unsigned pos)
{
  uint32_t lo, hi;
  deinterleave(st->s.w[2 * (pos >> 3)], st->s.w[2 * (pos >> 3) + 1], &lo, &hi);
  unsigned sh = (pos & 7) * 8;
  return (uint8_t)((sh < 32 ? lo >> sh : hi >> (sh - 32)) & 0xFF);
}

static void permute(keccak_t *st)
{
  keccak_f1600_bi(st->s.w);
}

void keccak_absorb(keccak_t *st, const uint8_t *in, size_t len)
{
  while (len) {
    if ((st->pos & 7) == 0 && len >= 8 && st->pos + 8 <= st->rate) {
      uint32_t e, o;                        /* a whole lane at once */
      interleave(load32(in), load32(in + 4), &e, &o);
      st->s.w[2 * (st->pos >> 3)] ^= e;
      st->s.w[2 * (st->pos >> 3) + 1] ^= o;
      st->pos += 8; in += 8; len -= 8;
    } else {
      xor_byte(st, st->pos++, *in++);
      len--;
    }
    if (st->pos == st->rate) {
      permute(st);
      st->pos = 0;
    }
  }
}

/* Pad (the domain byte, then 1 in the rate's last bit), and start the
   first output block */
void keccak_finish(keccak_t *st, uint8_t pad)
{
  xor_byte(st, st->pos, pad);
  xor_byte(st, st->rate - 1, 0x80);
  permute(st);
  st->pos = 0;
}

void keccak_squeeze(keccak_t *st, uint8_t *out, size_t len)
{
  while (len) {
    if (st->pos == st->rate) {
      permute(st);
      st->pos = 0;
    }
    if ((st->pos & 7) == 0 && len >= 8 && st->pos + 8 <= st->rate) {
      uint32_t lo, hi;
      deinterleave(st->s.w[2 * (st->pos >> 3)], st->s.w[2 * (st->pos >> 3) + 1], &lo, &hi);
      store32(out, lo); store32(out + 4, hi);
      st->pos += 8; out += 8; len -= 8;
    } else {
      *out++ = get_byte(st, st->pos++);
      len--;
    }
  }
}

#else

static const uint64_t RC[24] = {
  0x0000000000000001ull, 0x0000000000008082ull, 0x800000000000808aull, 0x8000000080008000ull,
  0x000000000000808bull, 0x0000000080000001ull, 0x8000000080008081ull, 0x8000000000008009ull,
  0x000000000000008aull, 0x0000000000000088ull, 0x0000000080008009ull, 0x000000008000000aull,
  0x000000008000808bull, 0x800000000000008bull, 0x8000000000008089ull, 0x8000000000008003ull,
  0x8000000000008002ull, 0x8000000000000080ull, 0x000000000000800aull, 0x800000008000000aull,
  0x8000000080008081ull, 0x8000000000008080ull, 0x0000000080000001ull, 0x8000000080008008ull
};
/* Lane x + 5y holds the state's (x, y). The five steps are written out
   with constant lane indices and rotation amounts: with loops over x and
   "(x + 1) % 5", GCC on rv32 computes the index with a hardware divide
   and the rotation as a variable 64-bit shift, and a permutation took
   116,000 cycles on the core instead of about a tenth of that. */
#define ROL(x, n) (((x) << (n)) | ((x) >> (64 - (n))))
/* rho and pi, as the standard's loop: lane 1 moves to lane 10 rotated by
   1, which moves to lane 7 rotated by 3, ... until lane 6 moves to lane 1
   rotated by 44 */
#define RHO_PI(dst, n)  do { u = s[dst]; s[dst] = ROL(t, n); t = u; } while (0)

void keccak_f1600(uint64_t s[25])
{
  uint64_t c0, c1, c2, c3, c4, d, t, u;
  BENCH_MARK(10);
  for (unsigned round = 0; round < 24; round++) {
    c0 = s[0] ^ s[5] ^ s[10] ^ s[15] ^ s[20];           /* theta */
    c1 = s[1] ^ s[6] ^ s[11] ^ s[16] ^ s[21];
    c2 = s[2] ^ s[7] ^ s[12] ^ s[17] ^ s[22];
    c3 = s[3] ^ s[8] ^ s[13] ^ s[18] ^ s[23];
    c4 = s[4] ^ s[9] ^ s[14] ^ s[19] ^ s[24];
    d = c4 ^ ROL(c1, 1); s[0] ^= d; s[5] ^= d; s[10] ^= d; s[15] ^= d; s[20] ^= d;
    d = c0 ^ ROL(c2, 1); s[1] ^= d; s[6] ^= d; s[11] ^= d; s[16] ^= d; s[21] ^= d;
    d = c1 ^ ROL(c3, 1); s[2] ^= d; s[7] ^= d; s[12] ^= d; s[17] ^= d; s[22] ^= d;
    d = c2 ^ ROL(c4, 1); s[3] ^= d; s[8] ^= d; s[13] ^= d; s[18] ^= d; s[23] ^= d;
    d = c3 ^ ROL(c0, 1); s[4] ^= d; s[9] ^= d; s[14] ^= d; s[19] ^= d; s[24] ^= d;
    t = s[1];                                            /* rho and pi */
    RHO_PI(10, 1);  RHO_PI(7, 3);   RHO_PI(11, 6);  RHO_PI(17, 10); RHO_PI(18, 15); RHO_PI(3, 21);
    RHO_PI(5, 28);  RHO_PI(16, 36); RHO_PI(8, 45);  RHO_PI(21, 55); RHO_PI(24, 2);  RHO_PI(4, 14);
    RHO_PI(15, 27); RHO_PI(23, 41); RHO_PI(19, 56); RHO_PI(13, 8);  RHO_PI(12, 25); RHO_PI(2, 43);
    RHO_PI(20, 62); RHO_PI(14, 18); RHO_PI(22, 39); RHO_PI(9, 61);  RHO_PI(6, 20);  RHO_PI(1, 44);
    for (unsigned y = 0; y < 25; y += 5) {               /* chi, one plane at a time */
      c0 = s[y]; c1 = s[y + 1]; c2 = s[y + 2]; c3 = s[y + 3]; c4 = s[y + 4];
      s[y]     = c0 ^ (~c1 & c2);
      s[y + 1] = c1 ^ (~c2 & c3);
      s[y + 2] = c2 ^ (~c3 & c4);
      s[y + 3] = c3 ^ (~c4 & c0);
      s[y + 4] = c4 ^ (~c0 & c1);
    }
    s[0] ^= RC[round];                                   /* iota */
  }
  BENCH_MARK(11);
}

void keccak_absorb(keccak_t *st, const uint8_t *in, size_t len)
{
  while (len--) {
    st->s.byte[st->pos++] ^= *in++;
    if (st->pos == st->rate) {
      keccak_f1600(st->s.lane);
      st->pos = 0;
    }
  }
}

/* Pad (the domain byte, then 1 in the rate's last bit), and start the
   first output block */
void keccak_finish(keccak_t *st, uint8_t pad)
{
  st->s.byte[st->pos] ^= pad;
  st->s.byte[st->rate - 1] ^= 0x80;
  keccak_f1600(st->s.lane);
  st->pos = 0;
}

void keccak_squeeze(keccak_t *st, uint8_t *out, size_t len)
{
  while (len--) {
    if (st->pos == st->rate) {
      keccak_f1600(st->s.lane);
      st->pos = 0;
    }
    *out++ = st->s.byte[st->pos++];
  }
}

#endif

static void hash(uint8_t *out, size_t outlen, const uint8_t *in, size_t inlen, unsigned rate, uint8_t pad)
{
  keccak_t st;
  keccak_init(&st, rate);
  keccak_absorb(&st, in, inlen);
  keccak_finish(&st, pad);
  keccak_squeeze(&st, out, outlen);
}

void sha3_256(uint8_t out[32], const uint8_t *in, size_t len)
{
  hash(out, 32, in, len, SHA3_256_RATE, 0x06);
}

void sha3_512(uint8_t out[64], const uint8_t *in, size_t len)
{
  hash(out, 64, in, len, SHA3_512_RATE, 0x06);
}

void shake128(uint8_t *out, size_t outlen, const uint8_t *in, size_t inlen)
{
  hash(out, outlen, in, inlen, SHAKE128_RATE, 0x1F);
}

void shake256(uint8_t *out, size_t outlen, const uint8_t *in, size_t inlen)
{
  hash(out, outlen, in, inlen, SHAKE256_RATE, 0x1F);
}
