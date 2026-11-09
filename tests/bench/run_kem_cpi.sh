#!/usr/bin/env bash
# run_kem_cpi.sh — CPI breakdown of ML-KEM-512 on BRV32P: runs run_kem.sh with
# its pipeline trace going through a named pipe into cpi_breakdown.py, so the
# multi-gigabyte trace never touches the disk.
#
# Usage: tests/bench/run_kem_cpi.sh [ref|ext ...]      (default: both)
# Prints one table per back end (KeyGen, Encaps, Decaps); exits non-zero if the
# run fails or a cause does not sum. Needs what run_kem.sh needs (LOCKSTEP=0).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
backends=("$@")
[ ${#backends[@]} -eq 0 ] && backends=(ref ext)
mkdir -p "$HERE/build"
F="$HERE/build/kem_cpi.fifo"
for be in "${backends[@]}"; do
  rm -f "$F"; mkfifo "$F"
  python3 "$HERE/cpi_breakdown.py" - --marks KeyGen:0,Encaps:2,Decaps:4 < "$F" > "$HERE/build/kem_${be}_cpi.txt" &
  reader=$!
  LOCKSTEP=0 PIPE="$F" "$HERE/run_kem.sh" "$be" > "$HERE/build/kem_${be}_cpi.log"
  wait "$reader"
  echo "ML-KEM-512, $be arithmetic"
  cat "$HERE/build/kem_${be}_cpi.txt"
  rm -f "$F"
done
