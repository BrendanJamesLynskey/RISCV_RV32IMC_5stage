#!/usr/bin/env bash
# run_kem.sh — build and run the whole of ML-KEM-512 (kem_main.c) on BRV32P
# (Icarus), with the reference arithmetic and with the Xbrvdsp kernels,
# check each in lockstep with Spike, and report cycles per operation.
#
# Usage: tests/bench/run_kem.sh [ref|ext ...]      (default: both, in turn)
#        HOST=1 tests/bench/run_kem.sh             build with the host's gcc
#                                                 and check against the model
#                                                 (no simulation)
# Needs: as run_bench.sh. LOCKSTEP=0 skips the Spike check.
# Writes tests/bench/build/kem_<be>.* and prints the report (kem_report.py),
# also saved as build/kem_<be>.txt. Exits non-zero if a result is wrong or
# the lockstep fails.
#
# Each build is a separate program, not part of dsp.elf: it needs 128 KB
# (link_kem.ld; TB_MEM_DEPTH=32768 and Spike's -m must agree) and runs for
# millions of cycles, so the pipeline trace is not written (bench_report.py
# would need gigabytes to read it). The cycles come from the testbench's
# +marks= file instead: the cycle at which each BENCH_MARK retires.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CROSS="${CROSS:-riscv64-unknown-elf-}"
MARCH="${MARCH:-rv32imc_zicsr}"
MARCH_ZK="${MARCH}_zbkb_zbkc_zbkx_zknh_zkne_zknd"   # mlkem_x.c uses Zbkb's rori and pack
B="$HERE/build"
mkdir -p "$B"
MEM_WORDS=32768

SPIKE="${SPIKE:-$(command -v spike || true)}"
LOCKSTEP="${LOCKSTEP:-1}"
[ -x "$SPIKE" ] || LOCKSTEP=0

python3 "$HERE/gen_data.py" > "$B/bench_data.h"
python3 "$HERE/gen_kem.py" > "$B/kem_data.h"

if [ "${HOST:-0}" = 1 ]; then
  gcc -O2 -Wall -Wextra -I "$B" -I "$HERE" "$HERE/keccak.c" "$HERE/mlkem_kem.c" "$HERE/mlkem.c" "$HERE/kem_main.c" \
    -o "$B/kem_host_ref"
  gcc -O2 -Wall -Wextra -DMLKEM_EXT -I "$B" -I "$HERE" "$HERE/keccak.c" "$HERE/mlkem_kem.c" "$HERE/mlkem_x_host.c" \
    "$HERE/kem_main.c" -o "$B/kem_host_ext"
  for be in ref ext; do
    if "$B/kem_host_$be"; then echo "host $be: PASS"; else echo "host $be: FAIL case $?"; exit 1; fi
  done
  exit 0
fi

CFLAGS=(-O2 -falign-loops=4 -mabi=ilp32 -mcmodel=medany -ffreestanding -I "$B" -I "$HERE")
"${CROSS}gcc" "${CFLAGS[@]}" -march="$MARCH_ZK" -c "$HERE/mlkem_x.c" -o "$B/mlkem_x.o"

iverilog -g2005 -DTB_MEM_DEPTH=$MEM_WORDS -o "$B/tb_kem.vvp" -I "$ROOT/rtl/pkg" -I "$ROOT/rtl/core" \
  "$ROOT"/rtl/core/*.v "$ROOT"/rtl/cache/*.v \
  "$ROOT/rtl/bus/axi_interconnect.v" "$ROOT/rtl/bus/axi_sram.v" "$ROOT/rtl/bus/axi_periph_bridge.v" \
  "$ROOT"/rtl/periph/*.v "$ROOT/rtl/brv32p_soc.v" "$ROOT/tests/isa/tb_isa.v"

backends=("$@")
[ ${#backends[@]} -eq 0 ] && backends=(ref ext)
for be in "${backends[@]}"; do
  case "$be" in
    ref) srcs=("$HERE/mlkem.c"); defs=() ;;
    ext) srcs=("$B/mlkem_x.o"); defs=(-DMLKEM_EXT) ;;
    *) echo "unknown back end: $be (ref or ext)"; exit 2 ;;
  esac
  elf="$B/kem_$be.elf"
  "${CROSS}gcc" "${CFLAGS[@]}" "${defs[@]}" -march="$MARCH" -static -nostdlib -nostartfiles -T "$HERE/link_kem.ld" \
    "$HERE/crt.S" "$HERE/kem_main.c" "$HERE/keccak.c" "$HERE/mlkem_kem.c" "${srcs[@]}" -o "$elf"
  "${CROSS}objcopy" -O binary "$elf" "$B/kem_$be.bin"
  python3 "$ROOT/tests/isa/elf2hex.py" "$B/kem_$be.bin" "$B/kem_$be.hex"
  "${CROSS}objdump" -d "$elf" > "$B/kem_$be.dis"
  tohost=$("${CROSS}nm" "$elf" | awk '$3 == "tohost" { print $1 }')

  result=$(cd "$B" && vvp -n tb_kem.vvp +hex="$B/kem_$be.hex" +tohost="$tohost" +trace="$B/kem_$be.trace" \
             +marks="$B/kem_$be.marks" +timeout=60000000 | grep '^RESULT' || echo "RESULT ERROR (simulator)")
  echo "kem_$be: $result"
  case "$result" in "RESULT PASS"*) ;; *) exit 1 ;; esac

  if [ "$LOCKSTEP" = 1 ]; then
    XBRVDSP_LIB="${XBRVDSP_LIB:-$ROOT/tools/spike_xbrvdsp/build/libxbrvdsp.so}"
    "$SPIKE" --isa="$MARCH_ZK" --extlib="$XBRVDSP_LIB" --extension=xbrvdsp -m0x80000000:$((MEM_WORDS * 4)) \
      --log-commits "$elf" 2> "$B/kem_$be.spike" || true
    ls_out=$(python3 "$ROOT/tests/isa/lockstep.py" "$B/kem_$be.trace" "$B/kem_$be.spike" | tail -n 1)
    echo "kem_$be lockstep: $ls_out"
    case "$ls_out" in MATCH*) ;; *) exit 1 ;; esac
    rm -f "$B/kem_$be.spike"            # hundreds of megabytes each; the trace stays for the artifact
  fi

  python3 "$HERE/kem_report.py" "$be" "$B/kem_$be.marks" | tee "$B/kem_$be.txt"
done
