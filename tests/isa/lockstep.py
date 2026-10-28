#!/usr/bin/env python3
"""Compare BRV32P's retire trace with Spike's commit log, instruction by
instruction.

Usage: lockstep.py <rtl.trace> <spike.log> [start_pc]

Both logs are reduced to one record per retired instruction:
    (pc, encoding, register write, store)
Spike's own boot ROM (pc below start_pc, default 0x80000000) is skipped, and
so are the parts the RTL trace does not record (load addresses, CSR writes).
Spike's log is cut at the RTL trace's final store (the test's tohost write).
Exits 0 if the two match for the whole run, else prints the first mismatch
with context and exits 1.
"""
import re
import sys

LINE = re.compile(r"core\s+0:\s+\d+\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)")
XREG = re.compile(r"\bx(\d+)\s+0x([0-9a-f]+)")
STORE = re.compile(r"\bmem\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)")


def records(path, start_pc):
    out = []
    for line in open(path, errors="replace"):
        m = LINE.match(line.strip())
        if not m:
            continue
        pc, insn, rest = int(m.group(1), 16), int(m.group(2), 16), m.group(3)
        if pc < start_pc:
            continue
        x = XREG.search(rest)
        reg = (int(x.group(1)), int(x.group(2), 16)) if x and x.group(1) != "0" else None
        s = STORE.search(rest)
        store = (int(s.group(1), 16), int(s.group(2), 16)) if s else None
        out.append((pc, insn, reg, store, line.rstrip()))
    return out


def main():
    rtl_path, spike_path = sys.argv[1], sys.argv[2]
    start_pc = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x80000000
    rtl, spike = records(rtl_path, start_pc), records(spike_path, start_pc)
    # The RTL trace ends at the test's store to tohost; Spike keeps running
    # until its host interface polls tohost, so cut it at that same store
    if rtl and rtl[-1][3] is not None:
        for k, rec in enumerate(spike):
            if rec[3] == rtl[-1][3]:
                spike = spike[:k + 1]
                break
    for i, (r, s) in enumerate(zip(rtl, spike)):
        if r[:4] != s[:4]:
            print(f"MISMATCH at instruction {i}:")
            for j in range(max(0, i - 3), i):
                print(f"   ok   {rtl[j][4]}")
            print(f"  RTL   {r[4]}")
            print(f"  Spike {s[4]}")
            return 1
    if len(rtl) != len(spike):
        print(f"LENGTH MISMATCH: RTL retired {len(rtl)}, Spike {len(spike)}; "
              f"the first {min(len(rtl), len(spike))} match")
        return 1
    print(f"MATCH {len(rtl)} instructions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
