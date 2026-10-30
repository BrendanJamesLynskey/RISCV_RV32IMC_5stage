/* aes_zk.c — the same AES-128 encryption with Zkne: each round is 16
   aes32esmi (aes32esi in the last), one per state byte, each doing that
   byte's S-box, its column of MixColumns, and the XOR into the next column.
   ShiftRows is in the choice of source word. The state is four
   little-endian column words. (Inline asm: GCC 13's aes32 builtins reject
   the byte-select operand.) */
#include <stdint.h>
#include "bench_data.h"

#define ESMI(t, s, bs) __asm__ ("aes32esmi %0, %0, %1, " #bs : "+r" (t) : "r" (s))
#define ESI(t, s, bs)  __asm__ ("aes32esi %0, %0, %1, " #bs : "+r" (t) : "r" (s))

#define ROUND(OP, k)                                                  \
  t0 = k[0]; OP(t0, s0, 0); OP(t0, s1, 1); OP(t0, s2, 2); OP(t0, s3, 3); \
  t1 = k[1]; OP(t1, s1, 0); OP(t1, s2, 1); OP(t1, s3, 2); OP(t1, s0, 3); \
  t2 = k[2]; OP(t2, s2, 0); OP(t2, s3, 1); OP(t2, s0, 2); OP(t2, s1, 3); \
  t3 = k[3]; OP(t3, s3, 0); OP(t3, s0, 1); OP(t3, s1, 2); OP(t3, s2, 3)

__attribute__((noipa))
void aes128_enc_zk(uint32_t *out, const uint32_t *in, const uint32_t *rk, int blocks)
{
  for (int n = 0; n < blocks; n++, in += 4, out += 4) {
    uint32_t s0 = in[0] ^ rk[0], s1 = in[1] ^ rk[1], s2 = in[2] ^ rk[2], s3 = in[3] ^ rk[3];
    uint32_t t0, t1, t2, t3;
    for (int r = 1; r < 10; r++) {
      ROUND(ESMI, (rk + 4 * r));
      s0 = t0; s1 = t1; s2 = t2; s3 = t3;
    }
    ROUND(ESI, (rk + 40));
    out[0] = t0; out[1] = t1; out[2] = t2; out[3] = t3;
  }
}
