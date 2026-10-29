/*
 * dsp.c — DSP kernels, in plain RV32IMC C (the baseline) and using
 * Xbrvdsp, the core's DSP extension, through inline asm (_mac and _dmac).
 *
 * Each kernel runs twice (the first run with cold caches, the second warm),
 * between BENCH_MARK pairs, and its result is checked against the values
 * gen_data.py computed. main returns 0 if every result matches, else the
 * number of the first failing check.
 */
#include <stdint.h>
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

static int16_t fir_y[FIR_OUTS];

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

  return 0;
}
