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
           (64, "fft_stages_packed", 6 * 32, "bfly"),
           (66, "sha256", 256, "byte"), (68, "sha256_zk", 256, "byte"),
           (70, "aes128", 256, "byte"), (74, "aes128_ttable", 256, "byte"), (72, "aes128_zk", 256, "byte"),
           (76, "crc32_table", 256, "byte"), (78, "crc32_clmul", 256, "byte"),
           (88, "crc32_bitwise", 256, "byte"),
           (90, "crc32c_table", 256, "byte"), (92, "crc32c_clmul", 256, "byte"),
           (94, "crc16_table", 256, "byte"), (96, "crc16_clmul", 256, "byte"),
           (98, "crc8_table", 256, "byte"), (100, "crc8_clmul", 256, "byte"),
           (102, "lfsr_bitwise", 64, "word"), (104, "lfsr_table", 64, "word"),
           (106, "lfsr_clmul", 64, "word"), (108, "xorshift32", 64, "word"),
           (110, "lfsr_jump 10^6", 1, "jump"), (112, "lfsr_jump_clmul 10^6", 1, "jump"),
           (114, "rs_syndromes", 255, "byte"), (116, "rs_syndromes_gf", 255, "byte"),
           (118, "rs_chien", 255, "point"), (120, "rs_chien_gf", 255, "point"),
           (122, "aes_invmix", 256, "byte"), (124, "aes_invmix_gf", 256, "byte"),
           (126, "mlkem_ntt", 896, "bfly"), (128, "mlkem_ntt_mq", 896, "bfly"), (130, "mlkem_ntt_ct", 896, "bfly"),
           (146, "mlkem_ntt_ct2", 896, "bfly"),
           (132, "mlkem_invntt", 896, "bfly"), (134, "mlkem_invntt_x", 896, "bfly"),
           (148, "mlkem_invntt_x2", 896, "bfly"),
           (136, "mlkem_basemul", 128, "pair"), (138, "mlkem_basemul_x", 128, "pair"),
           (142, "mlkem_polymul", 1, "poly"), (144, "mlkem_polymul_x", 1, "poly")]


def marker(raw):
    """n for "slti zero, zero, n" (opcode OP-IMM, funct3 010, rd 0, rs1 0)."""
    if raw & 0xFFFFF == 0x02013 and (raw >> 15) & 0x1F == 0:
        return raw >> 20
    return None


def main():
    cycles = pipeview.read_pipe(sys.argv[1])       # checked by pipeview.py check (run_bench.sh)
    lost = pipeview.lost_cycles(cycles)
    at, occ = {}, {}
    for c in cycles:
        if c.valid_wb:
            m = marker(c.raw_wb)
            if m is not None:
                at.setdefault(m, c.n)
                occ.setdefault(m, []).append(c.n)
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

    # Timing against the data (Zkt): timed() in dsp.c runs each kernel three
    # times between markers 140 and 141: a warm-up, then the two inputs. The
    # constant-time kernels must take the same cycles on both; the
    # table-driven ones, for contrast, need not.
    t3 = [b - a for a, b in zip(occ.get(140, []), occ.get(141, []))]
    t = [c for i, c in enumerate(t3) if i % 3]
    if len(t3) == 12:
        print()
        bad = False
        for (name, ct), (c1, c2) in zip([("T-table AES", False), ("Zkne AES", True),
                                         ("log-table RS syndromes", False), ("gfmul4 RS syndromes", True)],
                                        zip(t[0::2], t[1::2])):
            verdict = ("equal" if c1 == c2 else "DIFFERENT") if ct else "may differ"
            print(f"timing against the data, two inputs: {name:<24}{c1:>7} and {c2:>7} cycles  {verdict}")
            bad |= ct and c1 != c2
        if bad:
            sys.exit(1)
    else:
        print(f"timing check: expected 12 timed runs, found {len(t3)}")
        sys.exit(1)

if __name__ == "__main__":
    main()
