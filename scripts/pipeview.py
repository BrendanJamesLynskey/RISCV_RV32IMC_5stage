#!/usr/bin/env python3
"""Rebuild instruction lifetimes from BRV32P's per-cycle pipeline trace.

Usage:
  pipeview.py check   <x.pipe> <x.trace>                  consistency check
  pipeview.py diagram <x.pipe> [--dis x.dis] [--from N | --event E [--skip K]] [--cycles N]
  pipeview.py json    <x.pipe> --dis x.dis [--from N | --event E] [--cycles N] -o out.json

The pipe file (tests/isa/tb_isa.v, +pipe=) records, every cycle, what each
stage register holds and what the hazard unit decided. It has no instruction
IDs, so this script follows each instruction through the pipeline by applying
the same register rules as the RTL to the recorded control signals:

  IF/ID  : cleared by flush_id; loads when !stall_id && !mem_stall
           (a bubble while the first half of a straddling instruction waits)
  ID/EX  : cleared by flush_ex && !mem_stall; loads when !stall_ex && !mem_stall
  EX/MEM : cleared by flush_mem; loads when !mem_stall (a bubble while EX is
           stalled by MUL/DIV)
  MEM/WB : loads when !mem_stall (an instruction that traps in MEM does not
           go on to WB)

check verifies the reconstruction against the RTL every cycle: each stage's
recorded pc and encoding must be the instruction the rules put there, and the
instructions leaving WB must be exactly the retire trace (the commit log the
Spike lockstep compares). A mismatch exits 1.
"""
import argparse
import json
import re
import sys

STAGES = ("IF", "ID", "EX", "MEM", "WB")
LETTER = {"IF": "F", "ID": "D", "EX": "X", "MEM": "M", "WB": "W"}
FWD = {0: None, 1: "MEM", 2: "WB"}


def data(field):
    """A data value; x or z (undefined, e.g. the result of a suppressed load
    that does not retire) reads as None. Addresses and control must be known."""
    return None if any(ch in field for ch in "xXzZ") else int(field, 16)


class Cycle:
    """One line of the pipe file."""

    def __init__(self, line):
        g = [part.split() for part in line.split("|")]
        f, i, e, m, w, c = g
        self.n = int(f[0])
        self.pc_if, self.fetch_valid, self.straddle, self.imem_stall, self.pred = (
            int(f[1], 16), int(f[2]), int(f[3]), int(f[4]), int(f[5]))
        self.valid_id, self.pc_id, self.raw_id = int(i[0]), int(i[1], 16), int(i[2], 16)
        (self.valid_ex, self.pc_ex, self.raw_ex, self.rs1_ex, self.rs2_ex,
         self.fwd_rs1, self.fwd_rs2) = (int(e[0]), int(e[1], 16), int(e[2], 16),
                                        int(e[3]), int(e[4]), int(e[5]), int(e[6]))
        (self.valid_mem, self.pc_mem, self.raw_mem, self.rd_mem, self.dmem_rd,
         self.dmem_wr, self.dmem_stall) = (int(m[0]), int(m[1], 16), int(m[2], 16),
                                           int(m[3]), int(m[4]), int(m[5]), int(m[6]))
        (self.valid_wb, self.pc_wb, self.raw_wb, self.rd_we, self.rd_wb,
         self.rd_data) = (int(w[0]), int(w[1], 16), int(w[2], 16), int(w[3]),
                          int(w[4]), data(w[5]))
        (self.stall_if, self.stall_id, self.stall_ex, self.flush_id, self.flush_ex,
         self.flush_mem, self.mem_stall, self.load_use, self.muldiv_busy,
         self.mispredict, self.trap_enter, self.exc_mem, self.irq_take, self.mret,
         self.fencei) = (int(x) for x in c[:15])
        self.trap_cause = int(c[15], 16)

    def events(self):
        """What happened this cycle, as short tags."""
        ev = []
        if self.imem_stall:
            ev.append("icache-miss")
        if self.dmem_stall:
            ev.append("dcache-miss")
        if self.load_use and not self.mem_stall:
            ev.append("load-use")
        if self.muldiv_busy:
            ev.append("muldiv")
        if self.mispredict:
            ev.append("mispredict")
        if self.trap_enter:
            ev.append("irq" if self.irq_take and not self.exc_mem else "trap")
        if self.mret:
            ev.append("mret")
        if self.fencei:
            ev.append("fence.i")
        if self.fwd_rs1 or self.fwd_rs2:
            ev.append("forward")
        return ev


class Insn:
    def __init__(self, uid, pc, cycle):
        self.uid = uid
        self.pc = pc
        self.raw = None
        self.stages = []          # (stage, cycle), one per cycle in the pipeline
        self.fate = None          # retired / squashed / trapped / in-flight
        self.end = None           # cycle of retirement or removal
        self.cause = None         # why it was squashed
        self.enter("IF", cycle)

    def enter(self, stage, cycle):
        self.stages.append((stage, cycle))


def read_pipe(path):
    cycles = []
    for line in open(path):
        if line.startswith("#") or not line.strip():
            continue
        cycles.append(Cycle(line))
    return cycles


class PipeError(Exception):
    pass


def rebuild(cycles):
    """Follow every instruction through the pipeline. Returns (insns, occupancy)
    where occupancy[k] maps stage -> Insn (or None) for cycles[k]."""
    insns = []

    def new(pc, cycle):
        ins = Insn(len(insns), pc, cycle)
        insns.append(ins)
        return ins

    occ = {s: None for s in STAGES}
    occ["IF"] = new(cycles[0].pc_if, cycles[0].n)
    occupancy = []

    for k, c in enumerate(cycles):
        # Check what the rules put in each stage against the RTL's registers
        def expect(stage, valid, pc, raw):
            ins = occ[stage]
            if valid and ins is None:
                raise PipeError(f"cycle {c.n}: {stage} holds pc {pc:08x}, rebuilt as a bubble")
            if not valid and ins is not None and stage != "WB":
                raise PipeError(f"cycle {c.n}: {stage} is a bubble, rebuilt as pc {ins.pc:08x}")
            if valid:
                if ins.pc != pc:
                    raise PipeError(f"cycle {c.n}: {stage} pc {pc:08x}, rebuilt as {ins.pc:08x}")
                if ins.raw is None:
                    ins.raw = raw
                elif ins.raw != raw:
                    raise PipeError(f"cycle {c.n}: {stage} encoding {raw:08x}, rebuilt as {ins.raw:08x}")

        if occ["IF"] is None or occ["IF"].pc != c.pc_if:
            raise PipeError(f"cycle {c.n}: IF pc {c.pc_if:08x}, rebuilt as "
                            f"{'nothing' if occ['IF'] is None else format(occ['IF'].pc, '08x')}")
        expect("ID", c.valid_id, c.pc_id, c.raw_id)
        expect("EX", c.valid_ex, c.pc_ex, c.raw_ex)
        expect("MEM", c.valid_mem, c.pc_mem, c.raw_mem)
        expect("WB", c.valid_wb, c.pc_wb, c.raw_wb)
        occupancy.append(dict(occ))

        if c.valid_wb:
            occ["WB"].fate, occ["WB"].end = "retired", c.n
            if c.rd_we and c.rd_data is None:
                raise PipeError(f"cycle {c.n}: x{c.rd_wb} written with an undefined value")
        if k + 1 == len(cycles):
            break
        nxt = cycles[k + 1].n

        ld_id = not c.flush_id and not c.stall_id and not c.mem_stall
        fl_ex = c.flush_ex and not c.mem_stall
        ld_ex = not fl_ex and not c.stall_ex and not c.mem_stall
        ld_mem = not c.flush_mem and not c.mem_stall
        ld_wb = not c.mem_stall
        cause = ("trap" if c.trap_enter else "mret" if c.mret else
                 "mispredict" if c.mispredict else "fence.i" if c.fencei else None)

        def squash(ins):
            if ins is not None:
                ins.fate, ins.end, ins.cause = "squashed", c.n, cause

        new_occ = dict(occ)
        # MEM/WB
        if ld_wb:
            m = occ["MEM"]
            if m is not None and c.exc_mem:
                m.fate, m.end, m.cause = "trapped", c.n, "trap"
                m = None
            new_occ["WB"] = m
        # EX/MEM
        if c.flush_mem:
            squash(occ["EX"])
            new_occ["MEM"] = None
            moved_ex = True
        elif ld_mem:
            moved_ex = not c.stall_ex
            new_occ["MEM"] = occ["EX"] if moved_ex else None
        else:
            moved_ex = False
        # ID/EX
        if fl_ex:
            new_occ["EX"] = None
            moved_id = c.flush_id          # a mispredict squashes ID; a load-use bubble holds it
            if not c.flush_id and ld_id:
                raise PipeError(f"cycle {c.n}: ID/EX bubble while IF/ID loads")
        elif ld_ex:
            new_occ["EX"] = occ["ID"]
            moved_id = True
        else:
            moved_id = False
        if not moved_ex and new_occ["EX"] is not occ["EX"] and occ["EX"] is not None and not fl_ex:
            raise PipeError(f"cycle {c.n}: EX overwritten while its instruction stays")
        # IF/ID
        if c.flush_id:
            squash(occ["ID"])
            squash(occ["IF"])
            new_occ["ID"] = None
            new_occ["IF"] = new(cycles[k + 1].pc_if, nxt)
        elif ld_id:
            if c.fetch_valid:
                new_occ["ID"] = occ["IF"]
                new_occ["IF"] = new(cycles[k + 1].pc_if, nxt)
            else:
                new_occ["ID"] = None   # first half of a straddling instruction
        elif moved_id and occ["ID"] is not None:
            raise PipeError(f"cycle {c.n}: ID moved on but IF/ID did not load")

        for s in STAGES:
            if new_occ[s] is not None and s != "IF":
                new_occ[s].enter(s, nxt)
        if new_occ["IF"] is occ["IF"]:
            occ["IF"].enter("IF", nxt)
        occ = new_occ

    for ins in insns:
        if ins.fate is None:
            ins.fate = "in-flight"
    return insns, occupancy


def read_retire_trace(path):
    line_re = re.compile(r"core\s+0:\s+\d+\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)")
    out = []
    for line in open(path):
        m = line_re.match(line.strip())
        if m:
            out.append((int(m.group(1), 16), int(m.group(2), 16)))
    return out


def read_dis(path):
    """pc -> assembly text from objdump -d."""
    asm = {}
    if not path:
        return asm
    line_re = re.compile(r"^\s*([0-9a-f]+):\s+[0-9a-f]+\s+(\S.*)$")
    for line in open(path):
        m = line_re.match(line.rstrip())
        if m:
            text = m.group(2).split("#")[0].strip()
            asm[int(m.group(1), 16)] = re.sub(r"\s+", " ", text)
    return asm


def cmd_check(args):
    cycles = read_pipe(args.pipe)
    try:
        insns, _ = rebuild(cycles)
    except PipeError as e:
        print(f"PIPE FAIL {e}")
        return 1
    retired = sorted((i for i in insns if i.fate == "retired"), key=lambda i: i.end)
    trace = read_retire_trace(args.trace)
    got = [(i.pc, i.raw) for i in retired]
    for n, (a, b) in enumerate(zip(got, trace)):
        if a != b:
            print(f"PIPE FAIL retirement {n}: rebuilt {a[0]:08x} ({a[1]:08x}), "
                  f"retire trace {b[0]:08x} ({b[1]:08x})")
            return 1
    if len(got) != len(trace):
        print(f"PIPE FAIL {len(got)} retired in the pipe trace, {len(trace)} in the retire trace")
        return 1
    fates = {f: sum(1 for i in insns if i.fate == f) for f in ("retired", "squashed", "trapped", "in-flight")}
    print(f"PIPE OK {len(cycles)} cycles, " + ", ".join(f"{v} {k}" for k, v in fates.items()))
    return 0


def window(cycles, insns, start, count, event=None, skip=0):
    """The cycles [lo, hi] to show and the instructions alive in them. With an
    event, start a few cycles before its first occurrence (after skipping
    `skip` occurrences)."""
    if event:
        hits = [c.n for c in cycles if event in c.events()]
        if len(hits) <= skip:
            raise SystemExit(f"no {event} event in {len(cycles)} cycles")
        start = max(cycles[0].n, hits[skip] - 6)
    lo = start if start else cycles[0].n
    hi = lo + count - 1 if count else cycles[-1].n
    shown = [i for i in insns if any(lo <= cyc <= hi for _, cyc in i.stages)]
    return lo, hi, shown


def cmd_diagram(args):
    cycles = read_pipe(args.pipe)
    insns, _ = rebuild(cycles)
    asm = read_dis(args.dis)
    lo, hi, shown = window(cycles, insns, args.start, args.cycles or 60, args.event, args.skip)
    width = hi - lo + 1
    by_n = {c.n: c for c in cycles}
    head = [" "] * width                     # full cycle number at every tenth column
    for n in range(lo, hi + 1):
        if n % 10 == 0:
            for j, ch in enumerate(str(n)):
                if n - lo + j < width:
                    head[n - lo + j] = ch
    print(f"{'cycle':>8} {'':<26} {''.join(head)}")
    print(f"{'':>8} {'':<26} " + "".join(str(n % 10) for n in range(lo, hi + 1)))
    for ins in shown:
        row = [" "] * width
        prev = None
        for stage, cyc in ins.stages:
            if lo <= cyc <= hi:
                ch = LETTER[stage]
                row[cyc - lo] = ch if stage != prev else ch.lower()   # lower case: held there
            prev = stage
        if ins.end and lo <= ins.end + 1 <= hi and ins.fate in ("squashed", "trapped"):
            row[ins.end + 1 - lo] = "*" if ins.fate == "squashed" else "!"   # gone from the next cycle
        text = asm.get(ins.pc, "")
        tag = {"squashed": f" (squashed: {ins.cause})", "trapped": " (trapped)"}.get(ins.fate, "")
        print(f"{ins.pc:08x} {text[:26]:<26} {''.join(row)}{tag}")
    # One mark per cycle: the event that explains the most
    PRIORITY = ("irq", "trap", "mret", "fence.i", "mispredict", "load-use", "muldiv",
                "dcache-miss", "icache-miss")
    marks = {"icache-miss": "I", "dcache-miss": "D", "load-use": "L", "muldiv": "B",
             "mispredict": "P", "trap": "T", "irq": "Q", "mret": "R", "fence.i": "F"}
    row = []
    for n in range(lo, hi + 1):
        ev = by_n[n].events() if n in by_n else []
        row.append(next((marks[e] for e in PRIORITY if e in ev), "."))
    print(f"{'events':>8} {'':<26} {''.join(row)}")
    print("\nF D X M W = IF ID EX MEM WB; lower case = held in that stage; * = squashed, ! = trapped")
    print("events: I icache miss, D dcache miss, L load-use bubble, B mul/div busy, P mispredict,")
    print("        T trap, Q interrupt, R mret, F fence.i")
    return 0


def cmd_json(args):
    cycles = read_pipe(args.pipe)
    insns, occupancy = rebuild(cycles)
    asm = read_dis(args.dis)
    lo, hi, shown = window(cycles, insns, args.start, args.cycles, args.event, args.skip)
    ids = {i.uid for i in shown}
    out = {
        "format": "brv32p-pipeview-1",
        "source": args.pipe.split("/")[-1],
        "cycles": [],
        "insns": [],
    }
    for ins in shown:
        out["insns"].append({
            "id": ins.uid, "pc": f"{ins.pc:08x}",
            "raw": None if ins.raw is None else (f"{ins.raw:04x}" if ins.raw >> 16 == 0 and ins.raw & 3 != 3 else f"{ins.raw:08x}"),
            "asm": asm.get(ins.pc, ""), "fate": ins.fate, "end": ins.end, "cause": ins.cause,
            "stages": [[s, cyc] for s, cyc in ins.stages if lo <= cyc <= hi],
        })
    for c, occ in zip(cycles, occupancy):
        if not lo <= c.n <= hi:
            continue
        rec = {"n": c.n, "stages": {s: (occ[s].uid if occ[s] is not None and occ[s].uid in ids else None)
                                    for s in STAGES},
               "events": c.events(), "retire": bool(c.valid_wb),
               "fetch": {"pc": f"{c.pc_if:08x}", "valid": bool(c.fetch_valid),
                         "straddle": bool(c.straddle), "predict_taken": bool(c.pred)}}
        if c.fwd_rs1 or c.fwd_rs2:
            rec["fwd"] = {"rs1": [c.rs1_ex, FWD[c.fwd_rs1]], "rs2": [c.rs2_ex, FWD[c.fwd_rs2]]}
        if c.valid_wb and c.rd_we and c.rd_wb:
            if c.rd_data is None:
                raise PipeError(f"cycle {c.n}: x{c.rd_wb} written with an undefined value")
            rec["write"] = [c.rd_wb, f"{c.rd_data:08x}"]
        if c.trap_enter:
            rec["trap_cause"] = c.trap_cause
        out["cycles"].append(rec)
    with open(args.o, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"wrote {args.o}: {len(out['cycles'])} cycles, {len(out['insns'])} instructions")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("check")
    p.add_argument("pipe")
    p.add_argument("trace")
    for name in ("diagram", "json"):
        p = sub.add_parser(name)
        p.add_argument("pipe")
        p.add_argument("--dis")
        p.add_argument("--from", dest="start", type=int, default=0)
        p.add_argument("--cycles", type=int, default=0)
        p.add_argument("--event", help="start just before the first cycle with this event "
                       "(icache-miss, dcache-miss, load-use, muldiv, mispredict, trap, irq, mret, "
                       "fence.i, forward)")
        p.add_argument("--skip", type=int, default=0, help="with --event: skip this many occurrences")
        if name == "json":
            p.add_argument("-o", required=True)
    args = ap.parse_args()
    return {"check": cmd_check, "diagram": cmd_diagram, "json": cmd_json}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
