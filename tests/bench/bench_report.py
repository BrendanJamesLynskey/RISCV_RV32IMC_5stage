#!/usr/bin/env python3
"""Report cycles per benchmark kernel from a pipeline trace.

Usage: bench_report.py <dsp.pipe> <dsp.dis>

Finds the BENCH_MARK(n) markers ("slti zero, zero, n") as they retire, and
for each pair (2k, 2k+1) reports the cycles and instructions between them,
and what caused each cycle in which nothing retired (pipeview.lost_cycles:
a stall, or the event that created the bubble then reaching WB).
"""
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
import pipeview  # noqa: E402

# Kernels: (begin marker, name, work units, unit)
KERNELS = [(0, "fir, cold caches", 64 * 16, "tap"), (2, "fir", 64 * 16, "tap"),
           (4, "energy, cold caches", 256, "sample"), (6, "energy", 256, "sample"),
           (8, "fir_mac, cold caches", 64 * 16, "tap"), (10, "fir_mac", 64 * 16, "tap"),
           (12, "energy_mac, cold", 256, "sample"), (14, "energy_mac", 256, "sample"),
           (16, "energy_dmac, cold", 256, "sample"), (18, "energy_dmac", 256, "sample"),
           (20, "fir_agu, cold", 64 * 16, "tap"), (22, "fir_agu", 64 * 16, "tap"),
           (24, "fir_agu2, cold", 64 * 16, "tap"), (26, "fir_agu2", 64 * 16, "tap"),
           (28, "energy_agu, cold", 256, "sample"), (30, "energy_agu", 256, "sample"),
           (32, "energy_agu2, cold", 256, "sample"), (34, "energy_agu2", 256, "sample"),
           (36, "fir_dmac, cold", 64 * 16, "tap"), (38, "fir_dmac", 64 * 16, "tap"),
           (40, "fir_lp, cold", 64 * 16, "tap"), (42, "fir_lp", 64 * 16, "tap"),
           (44, "energy_lp, cold", 256, "sample"), (46, "energy_lp", 256, "sample"),
           (48, "biquad", 2 * 256, "sample"), (50, "biquad_mac", 2 * 256, "sample"),
           (52, "mix", 256, "sample"), (54, "mix_sadd", 256, "sample"),
           (56, "fft_bitrev", 64, "point"), (58, "fft_bitrev_agu", 64, "point"),
           (60, "fft_stages", 6 * 32, "bfly"), (62, "fft_stages_dmac", 6 * 32, "bfly"),
           (64, "fft_stages_packed", 6 * 32, "bfly")]


def marker(raw):
    """n for "slti zero, zero, n" (opcode OP-IMM, funct3 010, rd 0, rs1 0)."""
    if raw & 0xFFFFF == 0x02013 and (raw >> 15) & 0x1F == 0:
        return raw >> 20
    return None


def main():
    cycles = pipeview.read_pipe(sys.argv[1])
    _, occupancy = pipeview.rebuild(cycles)
    lost = pipeview.lost_cycles(cycles, occupancy)
    at = {}
    for c in cycles:
        if c.valid_wb:
            m = marker(c.raw_wb)
            if m is not None:
                at.setdefault(m, c.n)
    print(f"{'kernel':<22}{'cycles':>8}{'instrs':>8}{'IPC':>7}{'cycles/unit':>16}   cycles that retired nothing, by cause")
    for begin, name, units, unit in KERNELS:
        if begin not in at or begin + 1 not in at:
            print(f"{name:<22} markers {begin}/{begin + 1} not found")
            continue
        lo, hi = at[begin], at[begin + 1]
        n_cyc = hi - lo
        retired = n_cyc - sum(1 for n in range(lo + 1, hi + 1) if n in lost) - 1   # less the end marker
        causes = Counter(lost[n] for n in range(lo + 1, hi + 1) if n in lost)
        lost_s = ", ".join(f"{k} {v}" for k, v in causes.most_common())
        print(f"{name:<22}{n_cyc:>8}{retired:>8}{retired / n_cyc:>7.2f}{n_cyc / units:>11.2f}/{unit:<6}  {lost_s}")


if __name__ == "__main__":
    main()
