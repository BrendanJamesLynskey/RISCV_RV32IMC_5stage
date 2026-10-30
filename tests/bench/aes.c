/* aes.c — AES-128 encryption in plain RV32IMC C (the baseline): the
   byte-oriented form of FIPS-197, an S-box table and xtime for MixColumns.
   Round keys come expanded (gen_data.py). ECB over n 16-byte blocks. */
#include <stdint.h>
#include "bench_data.h"

static inline uint8_t xt(uint8_t v) { return (uint8_t)((v << 1) ^ ((v & 0x80) ? 0x1b : 0)); }

__attribute__((noipa))
void aes128_enc(uint8_t *out, const uint8_t *in, const uint8_t *rk, int blocks)
{
  for (int n = 0; n < blocks; n++, in += 16, out += 16) {
    uint8_t s[16], t[16];
    for (int i = 0; i < 16; i++) s[i] = in[i] ^ rk[i];
    for (int r = 1; r <= 10; r++) {
      for (int c = 0; c < 4; c++)                    /* SubBytes and ShiftRows */
        for (int i = 0; i < 4; i++)
          t[4 * c + i] = aes_sbox[s[4 * ((c + i) & 3) + i]];
      if (r < 10)
        for (int c = 0; c < 4; c++) {                /* MixColumns */
          uint8_t a0 = t[4 * c], a1 = t[4 * c + 1], a2 = t[4 * c + 2], a3 = t[4 * c + 3];
          uint8_t all = a0 ^ a1 ^ a2 ^ a3;
          t[4 * c]     = a0 ^ all ^ xt(a0 ^ a1);
          t[4 * c + 1] = a1 ^ all ^ xt(a1 ^ a2);
          t[4 * c + 2] = a2 ^ all ^ xt(a2 ^ a3);
          t[4 * c + 3] = a3 ^ all ^ xt(a3 ^ a0);
        }
      for (int i = 0; i < 16; i++) s[i] = t[i] ^ rk[16 * r + i];
    }
    for (int i = 0; i < 16; i++) out[i] = s[i];
  }
}

/* The usual fast software form: one 1 KB table T[x] = the MixColumns column
   of S-box(x), (2s, s, s, 3s) as a little-endian word, rotated for the other
   rows (four 4 KB tables would not fit the 2 KB D-cache). Each round is 16
   table lookups. Its loads depend on the data, which is the timing leak
   Zkt-style instructions avoid. */
#define ROTL(x, n) (((x) << (n)) | ((x) >> (32 - (n))))
#define TCOL(a, b, c, d) (aes_t0[(a) & 0xff] ^ ROTL(aes_t0[((b) >> 8) & 0xff], 8) ^ \
                          ROTL(aes_t0[((c) >> 16) & 0xff], 16) ^ ROTL(aes_t0[(d) >> 24], 24))
#define SCOL(a, b, c, d) ((uint32_t)aes_sbox[(a) & 0xff] | (uint32_t)aes_sbox[((b) >> 8) & 0xff] << 8 | \
                          (uint32_t)aes_sbox[((c) >> 16) & 0xff] << 16 | (uint32_t)aes_sbox[(d) >> 24] << 24)

__attribute__((noipa))
void aes128_enc_t(uint32_t *out, const uint32_t *in, const uint32_t *rk, int blocks)
{
  for (int n = 0; n < blocks; n++, in += 4, out += 4) {
    uint32_t s0 = in[0] ^ rk[0], s1 = in[1] ^ rk[1], s2 = in[2] ^ rk[2], s3 = in[3] ^ rk[3];
    for (int r = 1; r < 10; r++) {
      const uint32_t *k = rk + 4 * r;
      uint32_t t0 = TCOL(s0, s1, s2, s3) ^ k[0];
      uint32_t t1 = TCOL(s1, s2, s3, s0) ^ k[1];
      uint32_t t2 = TCOL(s2, s3, s0, s1) ^ k[2];
      uint32_t t3 = TCOL(s3, s0, s1, s2) ^ k[3];
      s0 = t0; s1 = t1; s2 = t2; s3 = t3;
    }
    out[0] = SCOL(s0, s1, s2, s3) ^ rk[40];
    out[1] = SCOL(s1, s2, s3, s0) ^ rk[41];
    out[2] = SCOL(s2, s3, s0, s1) ^ rk[42];
    out[3] = SCOL(s3, s0, s1, s2) ^ rk[43];
  }
}
