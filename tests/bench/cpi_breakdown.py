#!/usr/bin/env python3
"""CPI breakdown by cause from a +pipe= trace (the form of H&P 6th ed. App. C:
CPI = 1 + sum of stall cycles per instruction, one term per cause).

Usage: cpi_breakdown.py <x.pipe | -> [--kernels name,name,...] [--marks [name:]a,...]
                        [--md] [--micro] [--crosscheck]

Reads the trace once, as a stream (a file, or "-" for a pipe from vvp, so
a long run needs no disk). Between a BENCH_MARK pair (2k, 2k+1) it
counts cycles, retired instructions, and every cycle in which nothing retired,
each under exactly one cause. The window is the cycles strictly between the two
marker retirements, so the markers themselves are not counted.

How a lost cycle gets its cause. Each pipeline register carries a tag: an
instruction, or a bubble with the reason it was made. The tags advance with the
same rules the trace checker uses (pipeview.py): a register is cleared, loaded
or held from the previous cycle's stall/flush signals. A cycle in which WB holds
a bubble is lost to the bubble's tag; a cycle in which MEM is held is lost to
the hold. So when several things happen in one cycle, the order is the RTL's:

  1. a held MEM stage (mem_stall) freezes everything: the cycle goes to
     D-cache if the data side is waiting, else to I-cache, else to the
     second cycle of the mod-q multiplier. Nothing else is charged in it;
  2. a flush wins over a stall (hazard_unit.v: mispredict overrides the
     load-use stall), and among flushes a trap beats MRET beats a
     mispredict beats FENCE.I (a trap in MEM is older than a branch in EX);
  3. a multiply/divide stall freezes EX before any load-use check (the
     hazard unit tests muldiv_busy first), so a load-use hazard that
     coincides with it is charged to the divide;
  4. an I-cache miss makes a bubble in ID only if nothing older was
     squashed in the same cycle (rule 2);
  5. what is left in the first four cycles is pipeline fill, and a
     32-bit instruction straddling two fetch words is "straddle".

The causes sum to cycles - retired; the script exits 1 if they do not.
With --crosscheck it also compares every lost cycle with
pipeview.lost_cycles(), the independent back-tracing version, and exits 1 on
any difference.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts"))
import bench_report  # noqa: E402  (the kernel list: marker numbers)

# bubble tag -> reported cause
CAUSES = ["load-use", "mul-use", "csr-use", "mul/div busy", "mispredict", "trap/mret/fence.i",
          "I-cache miss", "D-cache miss", "straddle", "other"]
CAUSE_OF = {"load-use": "load-use", "mul-use": "mul-use", "csr-use": "csr-use",
            "divide": "mul/div busy", "mqmul2": "mul/div busy",
            "mispredict": "mispredict",
            "trap": "trap/mret/fence.i", "interrupt": "trap/mret/fence.i", "mret": "trap/mret/fence.i",
            "fence.i": "trap/mret/fence.i",
            "icache": "I-cache miss", "dcache": "D-cache miss",
            "straddle": "straddle", "fill": "other", "flush": "other"}

# the benchmark set: (name in bench_report.KERNELS, group); plain first, then its extension kernels
SET = [("fir", "FIR"), ("fir_mac", "FIR"), ("fir_agu2", "FIR"), ("fir_dmac", "FIR"),
       ("energy", "energy"), ("energy_mac", "energy"), ("energy_agu2", "energy"),
       ("biquad", "biquad"), ("biquad_mac", "biquad"),
       ("fft_bitrev", "FFT"), ("fft_bitrev_agu", "FFT"), ("fft_stages", "FFT"), ("fft_stages_dmac", "FFT"),
       ("sha256", "SHA-256"), ("sha256_zk", "SHA-256"),
       ("aes128", "AES"), ("aes128_zk", "AES"),
       ("crc32_table", "CRC"), ("crc32_clmul", "CRC"), ("crc32_bitwise", "CRC"),
       ("mlkem_polymul", "polymul"), ("mlkem_polymul_x", "polymul")]


class Stream:
    """Counts, per cause, over a whole run, and snapshots them at markers."""

    def __init__(self, crosscheck=False):
        self.cycles = 0
        self.retired = 0
        self.lost = dict.fromkeys(CAUSES, 0)
        # tags of the registers; "fill" until real contents arrive
        self.t_id = self.t_ex = self.t_mem = self.t_wb = "fill"
        self.prev = None
        self.before, self.after = {}, {}     # marker -> counters, one per retirement (before / after its own cycle)
        self.check = [] if crosscheck else None

    def snap(self):
        return (self.cycles, self.retired, dict(self.lost))

    def feed(self, f):
        """f: the split line of one trace cycle."""
        p = self.prev
        if p is not None:
            # tags for this cycle, from the previous cycle's signals
            if p["flush_mem"]:
                t_mem = redirect(p)
            elif not p["mem_stall"]:
                t_mem = "divide" if p["stall_ex"] else self.t_ex
            else:
                t_mem = self.t_mem
            if p["mem_stall"]:
                t_wb = "dcache" if p["dmem_stall"] else "icache" if p["imem_stall"] else "mqmul2"
            elif p["exc_mem"] and p["valid_mem"]:
                t_wb = "trap"
            else:
                t_wb = self.t_mem
            if p["flush_ex"] and not p["mem_stall"]:
                t_ex = redirect(p) if p["flush_id"] else \
                    "load-use" if p["load_use"] else "mul-use" if p["mul_use"] else "csr-use" if p["csr_use"] \
                    else "load-use"
            elif not p["stall_ex"] and not p["mem_stall"]:
                t_ex = self.t_id
            else:
                t_ex = self.t_ex
            if p["flush_id"]:
                t_id = redirect(p)
            elif not p["stall_id"] and not p["mem_stall"]:
                t_id = "icache" if p["imem_stall"] else "straddle"
            else:
                t_id = self.t_id
            self.t_id, self.t_ex, self.t_mem, self.t_wb = t_id, t_ex, t_mem, t_wb
        c = {
            "valid_mem": int(f[19]), "dmem_stall": int(f[25]), "imem_stall": int(f[4]),
            "stall_ex": int(f[36]), "stall_id": int(f[35]), "flush_id": int(f[37]), "flush_ex": int(f[38]),
            "flush_mem": int(f[39]), "mem_stall": int(f[40]), "load_use": int(f[41]), "mispredict": int(f[43]),
            "trap_enter": int(f[44]), "exc_mem": int(f[45]), "irq_take": int(f[46]), "mret": int(f[47]),
            "fencei": int(f[48]), "mul_use": int(f[50]), "csr_use": int(f[51]),
        }
        n = int(f[0])
        valid_wb = f[27] == "1"
        mark = None
        if valid_wb:
            raw = int(f[29], 16)
            if raw & 0xFFFFF == 0x02013:
                mark = raw >> 20
                self.before.setdefault(mark, []).append(self.snap())
        self.cycles += 1
        if valid_wb:
            self.retired += 1
        else:
            cause = CAUSE_OF[self.t_wb]
            self.lost[cause] += 1
            if self.check is not None:
                self.check.append((n, self.t_wb))
        if mark is not None:
            self.after.setdefault(mark, []).append(self.snap())
        self.prev = c

    def window(self, begin, occ=0):
        """(cycles, retired, lost-by-cause) strictly between the occ-th retirement of marker begin and
        that of begin+1, or None."""
        if len(self.after.get(begin, ())) <= occ or len(self.before.get(begin + 1, ())) <= occ:
            return None
        c0, r0, l0 = self.after[begin][occ]
        c1, r1, l1 = self.before[begin + 1][occ]
        return c1 - c0, r1 - r0, {k: l1[k] - l0[k] for k in CAUSES}


def redirect(c):
    return ("interrupt" if c["irq_take"] and not c["exc_mem"] else "trap") if c["trap_enter"] else \
           "mret" if c["mret"] else "mispredict" if c["mispredict"] else "fence.i" if c["fencei"] else "flush"


def run(path, crosscheck=False):
    s = Stream(crosscheck)
    fh = sys.stdin if path == "-" else open(path)
    with fh:
        for line in fh:
            if line.startswith("#"):
                continue
            s.feed(line.split())
    return s


def row(name, win):
    cyc, ret, lost = win
    total = sum(lost.values())
    if total != cyc - ret:
        print(f"FAIL {name}: causes sum to {total}, cycles - retired = {cyc - ret}")
        sys.exit(1)
    return cyc, ret, lost


def table(rows, md):
    """rows: [(name, cycles, retired, lost)]; the App. C form: CPI = 1 + sum(stalls / instruction)."""
    heads = ["benchmark", "instrs", "cycles", "CPI"] + CAUSES + ["largest"]
    out = []
    for name, cyc, ret, lost in rows:
        big = max(CAUSES, key=lambda k: lost[k])
        out.append([name, f"{ret}", f"{cyc}", f"{cyc / ret:.3f}"] +
                   [f"{lost[k] / ret:.3f}" if lost[k] else "-" for k in CAUSES] +
                   [big if lost[big] else "none"])
    if md:
        print("| " + " | ".join(heads) + " |")
        print("|" + "|".join("---" if i in (0, len(heads) - 1) else "--:" for i in range(len(heads))) + "|")
        for r in out:
            print("| " + " | ".join(r) + " |")
    else:
        w = [max(len(h), *(len(r[i]) for r in out)) for i, h in enumerate(heads)]
        print("  ".join(h.ljust(w[i]) if i in (0, len(heads) - 1) else h.rjust(w[i]) for i, h in enumerate(heads)))
        for r in out:
            print("  ".join(c.ljust(w[i]) if i in (0, len(heads) - 1) else c.rjust(w[i]) for i, c in enumerate(r)))


# Directed micro-tests (cpi_micro.S): marker pair -> (what, expected cycles lost per cause, in a
# window of 16 repeats). The cycle count is checked against a prediction from hazard_unit.v.
MICRO = [
    (0, 1, "load then dependent add", {"load-use": 16}),
    (2, 1, "load then independent add", {}),
    (4, 1, "mul then dependent add", {"mul-use": 16}),
    (6, 1, "mul then independent add", {}),
    (8, 1, "csrr then dependent add", {"csr-use": 16}),
    (10, 1, "csrr then independent add", {}),
    (12, 1, "16 taken branches, counter 00: predicted not taken", {"mispredict": 32}),
    (12, 2, "16 taken branches, counter 01: predicted not taken", {"mispredict": 32}),
    (12, 3, "16 taken branches, counter 10: predicted taken", {}),
    (12, 4, "16 taken branches, counter 11: predicted taken", {}),
    (12, 5, "16 not-taken branches, counter 11: predicted taken", {"mispredict": 32}),
    (12, 6, "16 not-taken branches, counter 10: predicted taken", {"mispredict": 32}),
]


def micro(s):
    bad = False
    print(f"{'region (16 repeats)':<56}{'cycles':>7}{'instrs':>7}  lost cycles by cause")
    for begin, occ, what, exp in MICRO:
        w = s.window(begin, occ)
        if w is None:
            print(f"{what:<56} markers {begin}/{begin + 1} pass {occ} not found")
            bad = True
            continue
        cyc, ret, lost = row(what, w)
        got = {k: v for k, v in lost.items() if v}
        ok = got == exp
        bad |= not ok
        print(f"{what:<56}{cyc:>7}{ret:>7}  {got if got else 'none'}{'' if ok else '   EXPECTED ' + str(exp)}")
    # the per-event costs the RTL implies, from the windows
    lu = s.window(0, 1)[2]["load-use"] / 16
    base = s.window(2, 1)[0]
    dep = s.window(0, 1)[0]
    mp = s.window(12, 1)[2]["mispredict"] / 16
    print(f"\ncost per load-use: {lu:g} bubble; the dependent region takes {dep - base} cycles more than the "
          f"independent one for 16 pairs (hazard_unit.v predicts 1 per pair: 16)")
    print(f"cost per mispredicted branch: {mp:g} bubbles (prediction: 2. The branch resolves in EX, so the "
          f"instruction in ID and the one being fetched are squashed: flush_id and flush_ex)")
    return not bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pipe")
    ap.add_argument("--kernels", help="comma-separated names from bench_report.KERNELS (default: the E1 set)")
    ap.add_argument("--marks", help="comma-separated begin markers, one window each (even numbers), "
                                    "optionally named: Encaps:2,Decaps:4")
    ap.add_argument("--md", action="store_true", help="markdown table")
    ap.add_argument("--micro", action="store_true", help="check the directed micro-tests (cpi_micro.S)")
    ap.add_argument("--crosscheck", action="store_true", help="compare with pipeview.lost_cycles")
    a = ap.parse_args()

    s = run(a.pipe, a.crosscheck)
    if s.retired + sum(s.lost.values()) != s.cycles:
        print("FAIL: cycles != retired + lost over the whole run")
        sys.exit(1)

    if a.crosscheck:
        import pipeview
        cycles = pipeview.read_pipe(a.pipe)
        ref = pipeview.lost_cycles(cycles)
        mine = dict(s.check)
        names = {"icache": "I-cache miss", "dcache": "D-cache wait", "mqmul2": "mqmul2 2nd cycle",
                 "straddle": "straddle fetch", "fill": "pipeline fill", "divide": "divide"}
        diff = [(n, mine.get(n), ref.get(n)) for n in set(mine) | set(ref)
                if names.get(mine.get(n), mine.get(n)) != ref.get(n)]
        if diff:
            print(f"FAIL crosscheck: {len(diff)} cycles differ, e.g. {sorted(diff)[:5]}")
            sys.exit(1)
        print(f"crosscheck: all {len(mine)} lost cycles agree with pipeview.lost_cycles")

    if a.micro:
        sys.exit(0 if micro(s) else 1)

    begins = []
    if a.marks:
        begins = [(m.split(":")[0], int(m.split(":")[-1])) for m in a.marks.split(",")]
    else:
        table_k = {name: b for b, name, _, _ in bench_report.KERNELS}
        names = a.kernels.split(",") if a.kernels else [n for n, _ in SET]
        begins = [(n, table_k[n]) for n in names]
    rows = []
    for name, b in begins:
        w = s.window(b)
        if w is None:
            print(f"{name}: markers {b}/{b + 1} not found")
            sys.exit(1)
        cyc, ret, lost = row(name, w)
        rows.append((name, cyc, ret, lost))
    table(rows, a.md)
    print(f"\nwhole run: {s.cycles} cycles, {s.retired} retired, "
          f"{sum(s.lost.values())} lost; causes sum check passed for every row", file=sys.stderr)


if __name__ == "__main__":
    main()
