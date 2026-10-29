#!/usr/bin/env bash
# build.sh — build libxbrvdsp.so, the Spike model of the DSP extension.
# Usage: tools/spike_xbrvdsp/build.sh <spike source dir> <spike build dir> [out dir]
# The library compiles against Spike's source headers (decode_macros.h and
# insn_macros.h are not installed); use the same revision as the Spike binary.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$1"; BLD="$2"; OUT="${3:-$HERE/build}"
mkdir -p "$OUT"
# Include paths as Spike's own build sets them (-iquote for the subprojects,
# so fesvr/syscall.h cannot hide the system <syscall.h>)
g++ -std=c++2a -O2 -fPIC -shared -Wall \
  -iquote "$BLD" -I "$SRC" -iquote "$SRC/riscv" -iquote "$SRC/fesvr" -iquote "$SRC/softfloat" \
  "$HERE/xbrvdsp.cc" -o "$OUT/libxbrvdsp.so"
echo "$OUT/libxbrvdsp.so"
