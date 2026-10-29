/*
 * bench.h — measurement markers for the benchmarks.
 *
 * BENCH_MARK(n) is "slti zero, zero, n": a no-op hint that retires like any
 * instruction but writes nothing, so it changes no result and Spike's commit
 * log matches the core's. bench_report.py finds the markers in the pipeline
 * trace and measures the cycles between BENCH_MARK(2k) and BENCH_MARK(2k+1).
 */
#ifndef BENCH_H
#define BENCH_H

#define BENCH_MARK(n) __asm__ volatile ("slti zero, zero, %0" :: "i" (n) : "memory")

#endif
