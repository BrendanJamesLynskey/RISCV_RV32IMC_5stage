#!/usr/bin/env python3
"""Tables and plots for doc/cache_sweeps.md from cache_sweep.sh's output.

Usage: cache_report.py [tests/bench/build/cache] [--plots doc/img]

Per program (the DSP benchmark program as a whole, and ML-KEM-512 with the
reference and the Xbrvdsp arithmetic) and per cache: misses, miss rate (misses
per access the pipeline made), misses per 1,000 instructions, the 3-C split
(cache_model.py), AMAT = 1 + miss rate x miss penalty (hit time one cycle, the
penalty the mean stall of a fill measured in the RTL run), and CPI. CPI is
measured where the RTL ran the configuration (sizes); elsewhere it is
estimated as the default's CPI plus (misses - default's misses) x penalty per
instruction, for the cache under study with the other left at its default, and
the estimate is checked against the measured CPI at every size the RTL ran.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PLOTS = sys.argv[sys.argv.index("--plots") + 1] if "--plots" in sys.argv else None
_pos = [a for a in sys.argv[1:] if not a.startswith("--") and a != PLOTS]
D = _pos[0] if _pos else os.path.join(HERE, "build", "cache")
PROGS = [("dsp", "DSP benchmark program"), ("kem_ref", "ML-KEM-512, reference arithmetic"), ("kem_ext", "ML-KEM-512, Xbrvdsp arithmetic")]
SIZES = [512, 1024, 2048, 4096, 8192]
SETS = {512: 16, 1024: 32, 2048: 64, 4096: 128, 8192: 256}


def kb(n):
    return f"{n // 1024} KB" if n >= 1024 else f"{n} B"


def read_sum(path):
    """-> (E fields, {marker: M fields}) of a run"""
    e, m = None, {}
    for line in open(path):
        f = line.split()
        if f[0] == "E":
            e = [int(x) for x in f[1:]]
        else:
            m.setdefault(int(f[1]), [int(x) for x in f[2:]])
    return e, m


def load():
    model, runs = {}, {}
    for p, _ in PROGS:
        mp = os.path.join(D, p + ".json")
        if os.path.exists(mp):
            model[p] = json.load(open(mp))
    for name in os.listdir(D):
        if name.startswith("ic") and "_dc" in name:
            ics, dcs = (int(x) for x in name[2:].split("_dc"))
            for p, _ in PROGS:
                f = os.path.join(D, name, p + ".sum")
                if os.path.exists(f):
                    runs[(ics, dcs, p)] = read_sum(f)
    return model, runs


def main():
    model, runs = load()
    out = []
    pr = out.append
    series = {}
    for p, title in PROGS:
        if p not in model or (64, 64, p) not in runs:
            continue
        m = model[p]
        e0 = runs[(64, 64, p)][0]
        cyc0, ins = e0[0], e0[1]
        pen = {"I": m["fill_cycles"]["I"], "D": m["fill_cycles"]["D"]}
        acc = {"I": e0[2], "D": e0[3]}
        for cache, name in (("I", "instruction"), ("D", "data")):
            pr(f"\n#### {title}: {name} cache, 2 ways, 16-byte lines\n")
            pr(f"{ins:,} instructions, {acc[cache]:,} accesses, mean miss penalty {pen[cache]:.1f} cycles (measured).\n")
            pr("| size | misses | miss rate | per 1,000 instr | compulsory | capacity | conflict | AMAT (cycles) | CPI (RTL) | CPI (model) |")
            pr("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
            base_miss = sum(model[p]["configs"][f"{cache}:2048:2:16"][k] for k in ("comp", "cap", "conf"))
            for size in SIZES:
                c = model[p]["configs"][f"{cache}:{size}:2:16"]
                miss = c["comp"] + c["cap"] + c["conf"]
                key = (SETS[size], 64, p) if cache == "I" else (64, SETS[size], p)
                if key in runs:
                    e = runs[key][0]
                    rtl_m = e[4] if cache == "I" else e[5]
                    cpi = f"{e[0] / e[1]:.4f}"
                    rtl_note = "" if rtl_m == miss else f" (RTL {rtl_m})"
                else:
                    cpi, rtl_note = "-", ""
                est = cyc0 / ins + (miss - base_miss) * pen[cache] / ins
                pr(f"| {kb(size)} | {miss:,}{rtl_note} | {miss / acc[cache]:.3%} | {1000 * miss / ins:.2f} | "
                   f"{c['comp']:,} | {c['cap']:,} | {c['conf']:,} | {1 + miss / acc[cache] * pen[cache]:.4f} | {cpi} | {est:.4f} |")
                series.setdefault((p, cache), []).append((size, 1000 * c["comp"] / ins, 1000 * c["cap"] / ins, 1000 * c["conf"] / ins))
            pr(f"\nAssociativity and line size ({cache}-cache; model only; CPI estimated from misses x penalty, the line-32 penalty is not measured so CPI is left out):\n")
            pr("| size | 1-way | 2-way | 4-way | 2-way, 32-byte lines |")
            pr("|---|--:|--:|--:|--:|")
            for size in SIZES:
                cells = []
                for w, ln in ((1, 16), (2, 16), (4, 16), (2, 32)):
                    c = model[p]["configs"][f"{cache}:{size}:{w}:{ln}"]
                    miss = c["comp"] + c["cap"] + c["conf"]
                    cells.append(f"{1000 * miss / ins:.2f} ({c['conf'] / miss:.0%} conf.)" if miss else "0")
                pr(f"| {kb(size)} | " + " | ".join(cells) + " |")
            pr("\nMisses per 1,000 instructions, with the conflict share of them.\n")
    print("\n".join(out))

    if PLOTS:
        import matplotlib
        matplotlib.use("svg")
        import matplotlib.pyplot as plt
        os.makedirs(PLOTS, exist_ok=True)
        for cache, fname, name in (("D", "dcache_misses.svg", "Data cache"), ("I", "icache_misses.svg", "Instruction cache")):
            fig, axes = plt.subplots(1, 3, figsize=(11, 3.2), sharex=True)
            for ax, (p, title) in zip(axes, PROGS):
                if (p, cache) not in series:
                    continue
                rows = series[(p, cache)]
                xs = range(len(rows))
                comp = [r[1] for r in rows]
                cap = [r[2] for r in rows]
                conf = [r[3] for r in rows]
                ax.bar(xs, comp, label="compulsory", color="#4d4d4d")
                ax.bar(xs, cap, bottom=comp, label="capacity", color="#9a9a9a")
                ax.bar(xs, conf, bottom=[a + b for a, b in zip(comp, cap)], label="conflict", color="#d9d9d9", edgecolor="#4d4d4d")
                ax.set_xticks(list(xs))
                ax.set_xticklabels([kb(r[0]) for r in rows], fontsize=8)
                ax.set_title(title, fontsize=9)
            axes[0].set_ylabel("misses per 1,000 instructions")
            axes[-1].legend(fontsize=8)
            fig.suptitle(f"{name}, 2-way, 16-byte lines: the 3 Cs by size", fontsize=10)
            fig.tight_layout()
            fig.savefig(os.path.join(PLOTS, fname))
            if os.environ.get("PNG"): fig.savefig(os.path.join(PLOTS, fname.replace(".svg", ".png")), dpi=80)
            plt.close(fig)


if __name__ == "__main__":
    main()
