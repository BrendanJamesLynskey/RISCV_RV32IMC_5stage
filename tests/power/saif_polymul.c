/* saif_polymul.c — the workload for a power estimate from simulated activity
   (run_saif.sh): REPS polynomial products in ML-KEM's ring, by pq-crystals'
   reference C (mlkem.c) or, built with -DMLKEM_EXT, by the mq_unit kernels
   (mlkem_x.c). The last product is checked against gen_data.py's value. */
#include <stdint.h>
#include "bench.h"
#include "bench_data.h"

#ifndef REPS
#define REPS 4
#endif

void mlkem_polymul(int16_t *c, int16_t *a, int16_t *b);
void mlkem_polymul_x(uint16_t *c, uint16_t *a, uint16_t *b);

#ifdef NETLIST
/* A routed netlist has only the SoC's ports (tb_netlist.v), not the testbench's
   view of the core: report on the GPIO pins, 1 pass and 2 fail */
static void netlist_report(uint32_t v)
{
  *(volatile uint32_t *)0x20000008 = 0xFFFFFFFFu;   /* direction: all outputs */
  *(volatile uint32_t *)0x20000000 = v;
}
#endif

static uint16_t pa[256] __attribute__((aligned(4)));
static uint16_t pb[256] __attribute__((aligned(4)));
static uint16_t pc[256] __attribute__((aligned(4)));

int main(void)
{
  for (int r = 0; r < REPS; r++) {
    for (int i = 0; i < 256; i++) {
      pa[i] = mlkem_a[i];
      pb[i] = mlkem_b[i];
    }
    BENCH_MARK(2);
#ifdef MLKEM_EXT
    mlkem_polymul_x(pc, pa, pb);
#else
    mlkem_polymul((int16_t *)pc, (int16_t *)pa, (int16_t *)pb);
#endif
    BENCH_MARK(3);
  }
  /* the reference result is correct mod q, not reduced */
  for (int i = 0; i < 256; i++) {
    int32_t d = ((int32_t)(int16_t)pc[i] - (int32_t)mlkem_mul_expect[i]) % MLKEM_Q;
    if (d) {
#ifdef NETLIST
      netlist_report(2);
#endif
      return 2;
    }
  }
#ifdef NETLIST
  netlist_report(1);
#endif
  return 0;
}
