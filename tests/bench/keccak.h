/* keccak.h — Keccak-f[1600] and the FIPS 202 functions ML-KEM uses:
   SHA3-256, SHA3-512, SHAKE128 and SHAKE256 (keccak.c). */
#ifndef KECCAK_H
#define KECCAK_H

#include <stdint.h>
#include <stddef.h>

/* A sponge: the state as 25 lanes (or 200 bytes: the two views share
   storage, which assumes a little-endian machine, as RV32 and x86 are; the
   bit-interleaved builds, -DKECCAK_BI and -DKECCAK_BI_ZBKB, keep it as 50
   words instead and convert at absorb and squeeze, see keccak.c),
   the rate in bytes, and the position of the next byte to absorb or
   squeeze. */
typedef struct {
  union {
    uint64_t lane[25];
    uint32_t w[50];     /* the bit-interleaved builds: lane i is w[2i] (even bits), w[2i + 1] (odd) */
    uint8_t byte[200];
  } s;
  unsigned rate, pos;
} keccak_t;

#define SHAKE128_RATE 168
#define SHAKE256_RATE 136
#define SHA3_256_RATE 136
#define SHA3_512_RATE 72

#if defined(KECCAK_BI) || defined(KECCAK_BI_ZBKB)
void keccak_f1600_bi(uint32_t w[50]);
#else
void keccak_f1600(uint64_t s[25]);
#endif

/* Incremental use (SampleNTT draws from SHAKE128 until it has enough):
   init, absorb any number of times, finish once (pad is 0x1F for SHAKE,
   0x06 for SHA3), then squeeze any number of times. */
void keccak_init(keccak_t *st, unsigned rate);
void keccak_absorb(keccak_t *st, const uint8_t *in, size_t len);
void keccak_finish(keccak_t *st, uint8_t pad);
void keccak_squeeze(keccak_t *st, uint8_t *out, size_t len);

void sha3_256(uint8_t out[32], const uint8_t *in, size_t len);
void sha3_512(uint8_t out[64], const uint8_t *in, size_t len);
void shake128(uint8_t *out, size_t outlen, const uint8_t *in, size_t inlen);
void shake256(uint8_t *out, size_t outlen, const uint8_t *in, size_t inlen);

#endif
