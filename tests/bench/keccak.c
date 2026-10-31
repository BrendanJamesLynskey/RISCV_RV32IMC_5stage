/* keccak.c — Keccak-f[1600] and the FIPS 202 functions ML-KEM uses
   (SHA3-256, SHA3-512, SHAKE128, SHAKE256), in plain portable C: the lanes
   are uint64_t, which rv32imc's GCC splits into register pairs, and the
   permutation is written as the standard's five steps (theta, rho, pi,
   chi, iota), one round at a time, the rounds not unrolled. It is the
   Keccak every ML-KEM operation spends most of its time in, so it is kept
   straightforward: a faster one is a separate question from the
   arithmetic mod q. Each permutation is bracketed by BENCH_MARK(10) and
   (11) on the core, so run_kem.sh can count the permutations in each
   operation and the cycles they take; on the host the markers are empty. */
#include "keccak.h"
#ifdef __riscv
#include "bench.h"
#else
#define BENCH_MARK(n) do {} while (0)
#endif

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

void keccak_init(keccak_t *st, unsigned rate)
{
  for (unsigned i = 0; i < 25; i++)
    st->s.lane[i] = 0;
  st->rate = rate;
  st->pos = 0;
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
