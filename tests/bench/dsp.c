/*
 * dsp.c — DSP kernels in plain RV32IMC C: the baseline the DSP extension is
 * measured against.
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

  return 0;
}
