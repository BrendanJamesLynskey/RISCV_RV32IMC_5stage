#!/usr/bin/env bash
# run_cpi_micro.sh — build and run the CPI directed micro-tests (cpi_micro.S) on
# BRV32P (Icarus) and check them with cpi_breakdown.py --micro.
#
# Usage: tests/bench/run_cpi_micro.sh
# Needs: riscv64-unknown-elf-gcc, iverilog. Writes tests/bench/build/cpi/.
# Exits non-zero if the pipeline trace does not check, a cause does not sum
# to cycles - retired, or a region's lost cycles differ from the prediction.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CROSS="${CROSS:-riscv64-unknown-elf-}"
B="$HERE/build/cpi"
mkdir -p "$B"

"${CROSS}gcc" -O2 -march=rv32imc_zicsr -mabi=ilp32 -mcmodel=medany -ffreestanding -static -nostdlib -nostartfiles \
  -T "$HERE/link.ld" "$HERE/crt.S" "$HERE/cpi_micro.S" -o "$B/micro.elf"
"${CROSS}objcopy" -O binary "$B/micro.elf" "$B/micro.bin"
python3 "$ROOT/tests/isa/elf2hex.py" "$B/micro.bin" "$B/micro.hex"
tohost=$("${CROSS}nm" "$B/micro.elf" | awk '$3 == "tohost" { print $1 }')

. "$HERE/sim.sh"
sim_build "$B/sim" 16384
result=$(cd "$B" && $(sim_cmd "$B/sim") +hex="$B/micro.hex" +tohost="$tohost" +trace="$B/micro.trace" \
           +pipe="$B/micro.pipe" +timeout=200000 | grep '^RESULT' || echo "RESULT ERROR (simulator)")
echo "$result"
case "$result" in "RESULT PASS"*) ;; *) exit 1 ;; esac

python3 "$ROOT/scripts/pipeview.py" check "$B/micro.pipe" "$B/micro.trace"
python3 "$HERE/cpi_breakdown.py" "$B/micro.pipe" --micro --crosscheck
