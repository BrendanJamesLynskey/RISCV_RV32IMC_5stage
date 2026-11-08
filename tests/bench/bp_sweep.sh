#!/usr/bin/env bash
# bp_sweep.sh — run the benchmark set on every branch-predictor configuration
# and collect the testbench's +stats= counters (branches, mispredicts) at each
# BENCH_MARK. bp_report.py turns them into the tables of doc/branch_prediction.md.
#
# Usage: SIM=verilator VERILATOR=... tests/bench/bp_sweep.sh [config ...]
#        a config is "KIND:BHT:GH", e.g. 3:256:8 (default: the whole sweep)
# Needs: as run_bench.sh and run_kem.sh. Builds the three programs once if their
# hex files are missing (tests/bench/build/{dsp,kem_ref,kem_ext}.hex), then, for
# each config, builds the SoC with that predictor and runs all three.
# Writes tests/bench/build/bp/k<KIND>_b<BHT>_g<GH>/{dsp,kem_ref,kem_ext}.stats.
# Icarus takes about half an hour per DSP run; with SIM=verilator a config is
# about 2 minutes, nearly all of it the build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
B="$HERE/build"
. "$HERE/sim.sh"

[ -f "$B/dsp.hex" ] && [ -f "$B/kem_ref.hex" ] && [ -f "$B/kem_ext.hex" ] || {
  LOCKSTEP=0 "$HERE/run_bench.sh" > /dev/null; LOCKSTEP=0 "$HERE/run_kem.sh" > /dev/null; }
tohost() { "${CROSS:-riscv64-unknown-elf-}nm" "$1" | awk '$3 == "tohost" { print $1 }'; }

configs=("$@")
if [ ${#configs[@]} -eq 0 ]; then
  configs=(0:256:0 1:256:0 2:64:0 2:256:0 2:1024:0
           3:64:2 3:64:4 3:64:6  3:256:2 3:256:4 3:256:6 3:256:8  3:1024:2 3:1024:4 3:1024:6 3:1024:8 3:1024:10
           4:256:8 4:1024:10)
fi
for c in "${configs[@]}"; do
  IFS=: read -r kind bht gh <<< "$c"
  d="$B/bp/k${kind}_b${bht}_g${gh}"
  [ -f "$d/kem_ext.stats" ] && continue
  sim_build "$d/sim" 32768 -DBP_KIND_DEFAULT="$kind" -DBP_BHT_DEFAULT="$bht" -DBP_GH_DEFAULT="$gh"
  # the DSP program is 64 KB, ML-KEM 128 KB: the memory depth is a testbench define,
  # so the ML-KEM-sized build runs the smaller program too (same cycles: the SRAM's
  # size does not change its timing)
  run="$(sim_cmd "$d/sim")"
  for prog in dsp kem_ref kem_ext; do
    elf="$B/$prog.elf"
    res=$(cd "$d" && $run +hex="$B/$prog.hex" +tohost="$(tohost "$elf")" +stats="$d/$prog.stats" +timeout=60000000 | grep '^RESULT' || echo "RESULT ERROR")
    echo "$c $prog: $res"
    case "$res" in "RESULT PASS"*) ;; *) exit 1 ;; esac
  done
done
