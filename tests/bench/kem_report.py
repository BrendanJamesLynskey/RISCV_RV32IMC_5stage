#!/usr/bin/env python3
"""Report cycles per ML-KEM operation from the testbench's marker file.

Usage: kem_report.py <ref|ext> <kem_<be>.marks>

The marker file (tb_isa.v, +marks=) has one line, "n cycle", for each
BENCH_MARK(n) that retired. kem_main.c brackets each operation with a pair
(2k, 2k + 1), and keccak.c brackets every Keccak-f[1600] permutation with
10 and 11; so for each operation the report gives its cycles, how many
permutations it ran, the cycles they took, and their share.
"""
import sys

OPS = [(0, "KeyGen"), (2, "Encaps"), (4, "Decaps"), (6, "Decaps, tampered ct (rejected)")]


def main():
    backend, path = sys.argv[1], sys.argv[2]
    marks = [(int(n), int(c)) for n, c in (line.split() for line in open(path) if line.strip())]
    at = {}
    for n, c in marks:
        at.setdefault(n, c)
    perms = []                                       # (entry cycle, exit cycle) of each permutation
    entry = None
    for n, c in marks:
        if n == 10:
            entry = c
        elif n == 11 and entry is not None:
            perms.append((entry, c))
            entry = None
    print(f"ML-KEM-512, {backend} arithmetic")
    print(f"{'operation':<34}{'cycles':>11}{'Keccak-f':>10}{'in Keccak':>12}{'share':>8}")
    total = total_keccak = n_perms = 0
    for begin, name in OPS:
        if begin not in at or begin + 1 not in at:
            print(f"{name:<34} markers {begin}/{begin + 1} not found")
            sys.exit(1)
        lo, hi = at[begin], at[begin + 1]
        inside = [b - a for a, b in perms if lo <= a < hi]
        keccak = sum(inside)
        print(f"{name:<34}{hi - lo:>11,}{len(inside):>10}{keccak:>12,}{keccak / (hi - lo):>8.1%}")
        total += hi - lo
        total_keccak += keccak
        n_perms += len(inside)
    print(f"{'all four':<34}{total:>11,}{n_perms:>10}{total_keccak:>12,}{total_keccak / total:>8.1%}")
    if n_perms:
        print(f"one Keccak-f[1600] permutation: {total_keccak // n_perms:,} cycles (mean)")


if __name__ == "__main__":
    main()
