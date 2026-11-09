#!/usr/bin/env bash
# cache_sweep.sh — cache size sweeps on the benchmark programs, in the RTL and
# in the model of cache_model.py.
#
# Usage: SIM=verilator VERILATOR=... tests/bench/cache_sweep.sh [smoke]
#   smoke: the default build on the short CPI micro-test program only, and the
#          model's miss counts for the default cache checked against the RTL's
#          (what CI runs, under Icarus; the full sweep needs SIM=verilator).
# Needs: as run_bench.sh / run_kem.sh (dsp.hex, kem_ref.hex, kem_ext.hex are
# built if missing). Writes tests/bench/build/cache/:
#   <prog>.json       the model's 3-C counts for every size/ways/line, from the
#                     default build's access log (cache_model.py)
#   ic<S>_dc<S>/<prog>.sum   marker and end lines of a run with that many sets
#                     in the I-cache and D-cache (the RTL supports 2 ways x
#                     16-byte lines; sets set the size: 32 bytes per set)
# The model's miss counts for the sizes the RTL can run are then checked
# against the RTL's own (cache_report.py).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
B="$HERE/build"
O="$B/cache"
. "$HERE/sim.sh"
mkdir -p "$O"

if [ "${1:-}" = smoke ]; then
  [ -f "$B/cpi/micro.hex" ] || "$HERE/run_cpi_micro.sh" > /dev/null
  d="$O/smoke"
  sim_build "$d/sim" 16384
  tohost=$("${CROSS:-riscv64-unknown-elf-}nm" "$B/cpi/micro.elf" | awk '$3 == "tohost" { print $1 }')
  (cd "$d" && $(sim_cmd "$d/sim") +hex="$B/cpi/micro.hex" +tohost="$tohost" +cachelog="$d/micro.log" +timeout=200000 | grep '^RESULT PASS')
  python3 "$HERE/cache_model.py" "$d/micro.log" --json "$d/micro.json" --check
  exit 0
fi

[ -f "$B/dsp.hex" ] && [ -f "$B/kem_ref.hex" ] && [ -f "$B/kem_ext.hex" ] || {
  LOCKSTEP=0 "$HERE/run_bench.sh" > /dev/null; LOCKSTEP=0 "$HERE/run_kem.sh" > /dev/null; }
tohost() { "${CROSS:-riscv64-unknown-elf-}nm" "$1" | awk '$3 == "tohost" { print $1 }'; }

progs=(dsp kem_ref kem_ext)
# I-cache sets x D-cache sets: the default, then each cache alone from 512 B to 8 KB
configs=("64 64" "16 64" "32 64" "128 64" "256 64" "64 16" "64 32" "64 128" "64 256")

for c in "${configs[@]}"; do
  read -r ics dcs <<< "$c"
  d="$O/ic${ics}_dc${dcs}"
  [ -f "$d/${progs[-1]}.sum" ] && continue
  sim_build "$d/sim" 32768 -DIC_SETS_DEFAULT="$ics" -DDC_SETS_DEFAULT="$dcs"
  run="$(sim_cmd "$d/sim")"
  for p in "${progs[@]}"; do
    log="$d/$p.log"
    res=$(cd "$d" && $run +hex="$B/$p.hex" +tohost="$(tohost "$B/$p.elf")" +cachelog="$log" +timeout=60000000 | grep '^RESULT' || echo "RESULT ERROR")
    echo "I-sets $ics D-sets $dcs $p: $res"
    case "$res" in "RESULT PASS"*) ;; *) exit 1 ;; esac
    grep -E '^[ME] ' "$log" > "$d/$p.sum"
    if [ "$c" = "64 64" ]; then python3 "$HERE/cache_model.py" "$log" --json "$O/$p.json"; fi
    rm -f "$log"
  done
done
