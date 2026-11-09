#!/usr/bin/env python3
"""Cache model for the 3 Cs (H&P 6th ed. App. B.3, §2.2): replays the access
stream the testbench logged (+cachelog=) through caches of any size,
associativity and line size, and classifies every miss.

Usage: cache_model.py <cachelog> [--json out.json] [--check]
(--check: exit 1 unless the model reproduces the RTL's miss counts for the default cache)

Stream (tb_isa.v): "I cyc addr h|m" and "D cyc addr h|m r|w" are the accesses
the RTL cache saw (consecutive hits to the same 16-byte line are dropped: they
cannot change any cache's state), "i cyc"/"d cyc" mark the end of a fill, and
"M n cyc" a BENCH_MARK. The replay is true LRU, write-allocate (the RTL's D-cache
fetches the line on a write miss too), no prefetch.

A miss is
  compulsory  the first touch of that line, ever, in the run;
  capacity    not compulsory, and a fully associative LRU cache of the same
              size (in lines) would miss too;
  conflict    the rest: only the set mapping made it miss.
"""
import json
import sys
from collections import OrderedDict

SIZES = [512, 1024, 2048, 4096, 8192]
WAYS = [1, 2, 4]
LINES = [16, 32]


def read(path):
    """-> {'I': [addr...], 'D': [addr...]}, markers {n: (index into I, index into D)}, fills {'I':[cycles], 'D':[...]}"""
    acc = {"I": [], "D": []}
    marks = {}
    miss_cyc = {"I": [], "D": []}
    fills = {"I": [], "D": []}
    pend = {"I": None, "D": None}
    rtl_miss = {"I": 0, "D": 0}
    with open(path) as fh:
        for line in fh:
            f = line.split()
            t = f[0]
            if t == "I" or t == "D":
                acc[t].append(int(f[2], 16))
                if f[3] == "m":
                    rtl_miss[t] += 1
                    pend[t] = int(f[1])
            elif t == "i" or t == "d":
                k = t.upper()
                if pend[k] is not None:
                    fills[k].append(int(f[1]) - pend[k] + 1)
                    pend[k] = None
            elif t == "M":
                marks.setdefault(int(f[1]), (len(acc["I"]), len(acc["D"]), int(f[2]), int(f[3]), int(f[4])))
    return acc, marks, fills, rtl_miss


def lru_sim(stream, sets, ways, line):
    """-> list of booleans: miss?"""
    shift = line.bit_length() - 1
    mask = sets - 1
    state = [[] for _ in range(sets)]      # most recent last
    out = []
    for a in stream:
        ln = a >> shift
        s = state[ln & mask]
        if ln in s:
            s.remove(ln)
            s.append(ln)
            out.append(False)
        else:
            if len(s) >= ways:
                del s[0]
            s.append(ln)
            out.append(True)
    return out


def fa_sim(stream, lines_cap, line):
    shift = line.bit_length() - 1
    cache = OrderedDict()
    out = []
    for a in stream:
        ln = a >> shift
        if ln in cache:
            cache.move_to_end(ln)
            out.append(False)
        else:
            if len(cache) >= lines_cap:
                cache.popitem(last=False)
            cache[ln] = 1
            out.append(True)
    return out


def classify(stream, size, ways, line):
    """-> (comp, cap, conf) as lists of stream indexes"""
    sets = size // (ways * line)
    real = lru_sim(stream, sets, ways, line)
    fa = fa_sim(stream, size // line, line)
    seen = set()
    shift = line.bit_length() - 1
    comp, cap, conf = [], [], []
    for i, a in enumerate(stream):
        ln = a >> shift
        first = ln not in seen
        seen.add(ln)
        if real[i]:
            if first:
                comp.append(i)
            elif fa[i]:
                cap.append(i)
            else:
                conf.append(i)
    return comp, cap, conf


def main():
    from bisect import bisect_left
    path = sys.argv[1]
    out = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    acc, marks, fills, rtl_miss = read(path)
    wins = sorted(b for b in marks if b % 2 == 0 and b + 1 in marks)
    res = {"accesses": {k: len(v) for k, v in acc.items()}, "marks": {str(k): v for k, v in marks.items()},
           "fill_cycles": {k: (sum(v) / len(v) if v else 0) for k, v in fills.items()},
           "rtl_miss": rtl_miss, "windows": wins, "configs": {}}
    for cache in ("I", "D"):
        ci = 0 if cache == "I" else 1
        for line in LINES:
            for ways in WAYS:
                for size in SIZES:
                    comp, cap, conf = classify(acc[cache], size, ways, line)
                    c = {"comp": len(comp), "cap": len(cap), "conf": len(conf), "win": {}}
                    for b in wins:
                        lo, hi = marks[b][ci], marks[b + 1][ci]
                        c["win"][str(b)] = [bisect_left(x, hi) - bisect_left(x, lo) for x in (comp, cap, conf)] + [marks[b + 1][3 + ci] - marks[b][3 + ci]]
                    res["configs"][f"{cache}:{size}:{ways}:{line}"] = c
    if "--check" in sys.argv:
        bad = False
        for cache in ("I", "D"):
            c = res["configs"][f"{cache}:2048:2:16"]
            m = c["comp"] + c["cap"] + c["conf"]
            ok = m == rtl_miss[cache]
            bad |= not ok
            print(f"{cache}-cache, default 2 KB: model {m} misses, RTL {rtl_miss[cache]}: {'ok' if ok else 'MISMATCH'}")
        if bad:
            sys.exit(1)
    if out:
        json.dump(res, open(out, "w"))
    else:
        print(json.dumps(res)[:2000])


if __name__ == "__main__":
    main()
