/*
 * sha256_impl.h — SHA-256 (FIPS 180-4), included by sha256.c (plain
 * RV32IMC) and sha256_zk.c (built with Zbkb and Zknh), each defining
 * SHA256_NAME and the four functions SIG0, SIG1, SUM0, SUM1 first. The
 * code is otherwise identical, so the difference is the extensions alone.
 */
#include <stdint.h>

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define CH(e, f, g)  (((e) & (f)) ^ (~(e) & (g)))
#define MAJ(a, b, c) (((a) & (b)) ^ ((a) & (c)) ^ ((b) & (c)))

static const uint32_t sha256_k[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static void sha256_block(uint32_t h[8], const uint8_t *p)
{
  uint32_t w[64];
  for (int t = 0; t < 16; t++)
    w[t] = ((uint32_t)p[4 * t] << 24) | ((uint32_t)p[4 * t + 1] << 16) |
           ((uint32_t)p[4 * t + 2] << 8) | p[4 * t + 3];
  for (int t = 16; t < 64; t++)
    w[t] = SIG1(w[t - 2]) + w[t - 7] + SIG0(w[t - 15]) + w[t - 16];
  uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
  for (int t = 0; t < 64; t++) {
    uint32_t t1 = hh + SUM1(e) + CH(e, f, g) + sha256_k[t] + w[t];
    uint32_t t2 = SUM0(a) + MAJ(a, b, c);
    hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

/* The digest of msg[0..len), as eight big-endian words */
__attribute__((noipa))
void SHA256_NAME(const uint8_t *msg, int len, uint32_t h[8])
{
  static const uint32_t h0[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
  for (int i = 0; i < 8; i++) h[i] = h0[i];
  int n = 0;
  for (; n + 64 <= len; n += 64)
    sha256_block(h, msg + n);
  uint8_t last[128];                              /* the padded tail: one or two blocks */
  int r = len - n, tail = r + 9 <= 64 ? 64 : 128;
  for (int i = 0; i < tail; i++) last[i] = 0;
  for (int i = 0; i < r; i++) last[i] = msg[n + i];
  last[r] = 0x80;
  uint32_t bits = (uint32_t)len * 8;
  for (int i = 0; i < 4; i++) last[tail - 1 - i] = (uint8_t)(bits >> (8 * i));
  for (int i = 0; i < tail; i += 64)
    sha256_block(h, last + i);
}
