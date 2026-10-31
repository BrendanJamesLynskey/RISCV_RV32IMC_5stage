/*
 * kem_main.c — the whole of ML-KEM-512 on the core: KeyGen, Encaps, Decaps
 * and Decaps of a tampered ciphertext, each between a BENCH_MARK pair, and
 * each result compared byte for byte with the model's (gen_kem.py,
 * kem_data.h). Built twice by run_kem.sh: with the reference arithmetic
 * (kem_ref.elf) and with the Xbrvdsp kernels (kem_ext.elf, -DMLKEM_EXT).
 * Before the timed operations it checks keccak.c against hashlib's digests
 * (not timed). main returns 0 if everything matches, else the number of
 * the first failing check, which crt.S reports through tohost. The same
 * file builds on the host (gcc, no __riscv), where the markers are empty
 * and main's value is the exit status.
 *
 * Markers: 0/1 KeyGen, 2/3 Encaps, 4/5 Decaps, 6/7 Decaps (tampered);
 * 10/11 bracket every Keccak-f[1600] permutation (keccak.c). The testbench
 * writes the cycle at which each marker retires (+marks=), and
 * kem_report.py turns that into cycles per operation and the share spent
 * in Keccak. A separate program, not part of dsp.elf: it needs more than
 * dsp.elf's 64 KB and 4 KB of stack (link_kem.ld).
 */
#include <stdint.h>
#include "keccak.h"
#include "kem_data.h"
#ifdef __riscv
#include "bench.h"
#else
#define BENCH_MARK(n) do {} while (0)
#endif

void kem_keygen(uint8_t *ek, uint8_t *dk, const uint8_t *d, const uint8_t *z);
void kem_encaps(uint8_t *key, uint8_t *c, const uint8_t *ek, const uint8_t *m);
void kem_decaps(uint8_t *key, const uint8_t *dk, const uint8_t *c);

static int same(const uint8_t *a, const uint8_t *b, unsigned n)
{
  for (unsigned i = 0; i < n; i++)
    if (a[i] != b[i])
      return 0;
  return 1;
}

static uint8_t ek[KEM_EK_BYTES], dk[KEM_DK_BYTES], ct[KEM_CT_BYTES], key[32], out[300];

int main(void)
{
  sha3_256(out, kat_msg, 0);
  if (!same(out, kat_sha3_256_empty, 32)) return 1;
  sha3_256(out, kat_msg, sizeof kat_msg);
  if (!same(out, kat_sha3_256, 32)) return 2;
  sha3_512(out, kat_msg, sizeof kat_msg);
  if (!same(out, kat_sha3_512, 64)) return 3;
  shake128(out, 300, kat_msg, sizeof kat_msg);
  if (!same(out, kat_shake128, 300)) return 4;
  shake256(out, 300, kat_msg, sizeof kat_msg);
  if (!same(out, kat_shake256, 300)) return 5;

  BENCH_MARK(0);
  kem_keygen(ek, dk, kem_d, kem_z);
  BENCH_MARK(1);
  if (!same(ek, kem_ek_expect, KEM_EK_BYTES)) return 6;
  if (!same(dk, kem_dk_expect, KEM_DK_BYTES)) return 7;

  BENCH_MARK(2);
  kem_encaps(key, ct, ek, kem_m);
  BENCH_MARK(3);
  if (!same(ct, kem_ct_expect, KEM_CT_BYTES)) return 8;
  if (!same(key, kem_key_expect, 32)) return 9;

  BENCH_MARK(4);
  kem_decaps(key, dk, ct);
  BENCH_MARK(5);
  if (!same(key, kem_key_expect, 32)) return 10;

  BENCH_MARK(6);
  kem_decaps(key, dk, kem_ct_bad);
  BENCH_MARK(7);
  if (!same(key, kem_key_bad_expect, 32)) return 11;
  return 0;
}
