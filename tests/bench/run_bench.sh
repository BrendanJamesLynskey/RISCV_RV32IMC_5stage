#!/usr/bin/env bash
# run_bench.sh — build and run the DSP benchmarks on BRV32P (Icarus), check
# them in lockstep with Spike, and report cycles per kernel.
#
# Usage: tests/bench/run_bench.sh
# Needs: riscv64-unknown-elf-gcc, iverilog; Spike ($SPIKE or on the PATH) and
#        its model of the DSP extension ($XBRVDSP_LIB, built by
#        tools/spike_xbrvdsp/build.sh) for the lockstep check (LOCKSTEP=0
#        skips it).
# Writes tests/bench/build/ and prints the report (bench_report.py), which is
# also saved as build/report.txt. Exits non-zero if a result is wrong or the
# lockstep fails.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CROSS="${CROSS:-riscv64-unknown-elf-}"
MARCH="${MARCH:-rv32imc_zicsr}"
MARCH_ZK="${MARCH}_zbkb_zknh_zkne_zknd" # the *_zk.c files only: the plain kernels stay plain
B="$HERE/build"
mkdir -p "$B"

SPIKE="${SPIKE:-$(command -v spike || true)}"
LOCKSTEP="${LOCKSTEP:-1}"
[ -x "$SPIKE" ] || LOCKSTEP=0

python3 "$HERE/gen_data.py" > "$B/bench_data.h"
CFLAGS=(-O2 -falign-loops=4 -mabi=ilp32 -mcmodel=medany -ffreestanding -I "$B" -I "$HERE")
for f in sha256_zk aes_zk; do
  "${CROSS}gcc" "${CFLAGS[@]}" -march="$MARCH_ZK" -c "$HERE/$f.c" -o "$B/$f.o"
done
"${CROSS}gcc" "${CFLAGS[@]}" -march="$MARCH" -static -nostdlib -nostartfiles -T "$HERE/link.ld" \
  "$HERE/crt.S" "$HERE/dsp.c" "$HERE/sha256.c" "$HERE/aes.c" "$B/sha256_zk.o" "$B/aes_zk.o" -o "$B/dsp.elf"
"${CROSS}objcopy" -O binary "$B/dsp.elf" "$B/dsp.bin"
python3 "$ROOT/tests/isa/elf2hex.py" "$B/dsp.bin" "$B/dsp.hex"
"${CROSS}objdump" -d "$B/dsp.elf" > "$B/dsp.dis"
tohost=$("${CROSS}nm" "$B/dsp.elf" | awk '$3 == "tohost" { print $1 }')

iverilog -g2005 -o "$B/tb_isa.vvp" -I "$ROOT/rtl/pkg" -I "$ROOT/rtl/core" \
  "$ROOT"/rtl/core/*.v "$ROOT"/rtl/cache/*.v \
  "$ROOT/rtl/bus/axi_interconnect.v" "$ROOT/rtl/bus/axi_sram.v" "$ROOT/rtl/bus/axi_periph_bridge.v" \
  "$ROOT"/rtl/periph/*.v "$ROOT/rtl/brv32p_soc.v" "$ROOT/tests/isa/tb_isa.v"
result=$(cd "$B" && vvp -n tb_isa.vvp +hex="$B/dsp.hex" +tohost="$tohost" +trace="$B/dsp.trace" \
           +pipe="$B/dsp.pipe" +timeout=2000000 | grep '^RESULT' || echo "RESULT ERROR (simulator)")
echo "$result"
case "$result" in "RESULT PASS"*) ;; *) exit 1 ;; esac

python3 "$ROOT/scripts/pipeview.py" check "$B/dsp.pipe" "$B/dsp.trace"
if [ "$LOCKSTEP" = 1 ]; then
  XBRVDSP_LIB="${XBRVDSP_LIB:-$ROOT/tools/spike_xbrvdsp/build/libxbrvdsp.so}"
  "$SPIKE" --isa="$MARCH_ZK" --extlib="$XBRVDSP_LIB" --extension=xbrvdsp -m0x80000000:0x8000 \
    --log-commits "$B/dsp.elf" 2> "$B/dsp.spike" || true
  python3 "$ROOT/tests/isa/lockstep.py" "$B/dsp.trace" "$B/dsp.spike" | tail -n 1
fi

python3 "$HERE/bench_report.py" "$B/dsp.pipe" "$B/dsp.dis" | tee "$B/report.txt"
