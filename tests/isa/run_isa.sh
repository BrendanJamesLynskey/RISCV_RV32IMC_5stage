#!/usr/bin/env bash
# run_isa.sh — build and run the riscv-tests ISA suites on BRV32P (Icarus).
#
# Usage: tests/isa/run_isa.sh [test ...]     e.g.  run_isa.sh rv32ui/add rv32um/mul
#        (no arguments: every test in SUITES)
# Needs: riscv64-unknown-elf-gcc, iverilog, and a riscv-tests checkout in
#        $RISCV_TESTS (default: tests/isa/riscv-tests, cloned on first use).
# Writes build output to tests/isa/build/ and a summary to build/results.txt.
# Exits non-zero if any test fails.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RISCV_TESTS="${RISCV_TESTS:-$HERE/riscv-tests}"
RISCV_TESTS_REV="${RISCV_TESTS_REV:-3df703c}"   # the revision these results are for
CROSS="${CROSS:-riscv64-unknown-elf-}"
B="$HERE/build"
mkdir -p "$B"

if [ ! -d "$RISCV_TESTS/isa" ]; then
  git clone -q https://github.com/riscv-software-src/riscv-tests.git "$RISCV_TESTS"
  git -C "$RISCV_TESTS" checkout -q "$RISCV_TESTS_REV"
fi

# Suites, their source directory and the -march each is assembled for.
# rv32ui and rv32um are built without C, as upstream does (32-bit encodings).
# rv32ui-c and rv32um-c are the same sources assembled with C enabled: the
# assembler compresses most instructions, so 16- and 32-bit instructions mix
# and 32-bit ones straddle word boundaries, which stresses instruction fetch.
declare -A MARCH=( [rv32ui]=rv32i_zicsr_zifencei [rv32um]=rv32im_zicsr_zifencei [rv32uc]=rv32ic_zicsr_zifencei
                   [rv32ui-c]=rv32ic_zicsr_zifencei [rv32um-c]=rv32imc_zicsr_zifencei )
declare -A SRC=( [rv32ui]=rv32ui [rv32um]=rv32um [rv32uc]=rv32uc [rv32ui-c]=rv32ui [rv32um-c]=rv32um )
SUITES=(rv32ui rv32um rv32uc rv32ui-c rv32um-c)

tests=("$@")
if [ ${#tests[@]} -eq 0 ]; then
  for s in "${SUITES[@]}"; do
    for f in "$RISCV_TESTS/isa/${SRC[$s]}"/*.S; do tests+=("$s/$(basename "$f" .S)"); done
  done
fi

# Compile the SoC and ISA testbench once
iverilog -g2005 -o "$B/tb_isa.vvp" -I "$ROOT/rtl/pkg" -I "$ROOT/rtl/core" \
  "$ROOT"/rtl/core/*.v "$ROOT"/rtl/cache/*.v \
  "$ROOT/rtl/bus/axi_interconnect.v" "$ROOT/rtl/bus/axi_sram.v" "$ROOT/rtl/bus/axi_periph_bridge.v" \
  "$ROOT"/rtl/periph/*.v "$ROOT/rtl/brv32p_soc.v" "$HERE/tb_isa.v"

: > "$B/results.txt"
fails=0
for t in "${tests[@]}"; do
  suite="${t%%/*}"; name="${t##*/}"; out="$B/$suite-$name"
  "${CROSS}gcc" -march="${MARCH[$suite]}" -mabi=ilp32 -static -mcmodel=medany -nostdlib -nostartfiles \
    -I "$HERE/env" -I "$RISCV_TESTS/isa/macros/scalar" -T "$HERE/env/link.ld" \
    "$RISCV_TESTS/isa/${SRC[$suite]}/$name.S" -o "$out.elf"
  "${CROSS}objcopy" -O binary "$out.elf" "$out.bin"
  python3 "$HERE/elf2hex.py" "$out.bin" "$out.hex"
  "${CROSS}objdump" -d "$out.elf" > "$out.dis"
  tohost=$("${CROSS}nm" "$out.elf" | awk '$3 == "tohost" { print $1 }')
  result=$(cd "$B" && vvp -n tb_isa.vvp +hex="$out.hex" +tohost="$tohost" +trace="$out.trace" | grep '^RESULT' || echo "RESULT ERROR (simulator)")
  printf '%-16s %s\n' "$t" "${result#RESULT }" | tee -a "$B/results.txt"
  case "$result" in "RESULT PASS"*) ;; *) fails=$((fails + 1)) ;; esac
done

echo "$(( ${#tests[@]} - fails )) / ${#tests[@]} passed" | tee -a "$B/results.txt"
[ "$fails" -eq 0 ]
