#!/usr/bin/env bash
# run_isa.sh — build and run the riscv-tests ISA suites on BRV32P (Icarus).
#
# Usage: tests/isa/run_isa.sh [test ...]     e.g.  run_isa.sh rv32ui/add rv32um/mul
#        (no arguments: every test in SUITES)
# Needs: riscv64-unknown-elf-gcc, iverilog, and a riscv-tests checkout in
#        $RISCV_TESTS (default: tests/isa/riscv-tests, cloned on first use).
# Lockstep: if Spike is found ($SPIKE, or spike on the PATH), each test also
#        runs on Spike and the two commit logs are compared instruction by
#        instruction (lockstep.py); a mismatch fails the test. LOCKSTEP=0 skips.
# Pipeline trace: each test also writes a per-cycle pipeline trace (.pipe),
#        and scripts/pipeview.py checks it against the retire trace; a
#        mismatch fails the test. PIPE=0 skips.
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
# "directed" holds this repo's own tests (tests/directed): behaviour the
# upstream user-level suites cannot see (FENCE.I on cached code, misaligned
# access traps, interrupts).
MARCH[directed]=rv32imc_zicsr_zifencei_zbkb_zbkc_zbkx_zknh_zkne_zknd
declare -A SRC=( [rv32ui]="$RISCV_TESTS/isa/rv32ui" [rv32um]="$RISCV_TESTS/isa/rv32um" [rv32uc]="$RISCV_TESTS/isa/rv32uc"
                 [rv32ui-c]="$RISCV_TESTS/isa/rv32ui" [rv32um-c]="$RISCV_TESTS/isa/rv32um" [directed]="$ROOT/tests/directed" )
SUITES=(rv32ui rv32um rv32uc rv32ui-c rv32um-c directed)

# Tests that use the SoC's own peripherals, which Spike does not model
NO_LOCKSTEP=" directed/timer_irq directed/dsp_irq "

# Upstream tests that do not apply to this core, skipped in a full run (name a
# test explicitly to run it anyway). In each case Spike, configured like the
# core, behaves the same way (the lockstep logs match).
declare -A NOT_APPLICABLE=(
  [rv32ui/ma_data]="needs misaligned access in hardware; the core traps instead (allowed by the spec; see directed/misaligned)"
  [rv32ui-c/ma_data]="as rv32ui/ma_data"
  [rv32ui-c/fence_i]="patches code assuming 32-bit encodings; assembled with C it overwrites compressed code and takes an illegal-instruction trap"
)

SPIKE="${SPIKE:-$(command -v spike || true)}"
LOCKSTEP="${LOCKSTEP:-1}"
PIPE="${PIPE:-1}"
[ -x "$SPIKE" ] || LOCKSTEP=0

# Tests that use Xbrvdsp, the custom DSP extension (directed/dsp_*, directed/gf, directed/mq
# and directed/mul_use), need Spike's model of it: tools/spike_xbrvdsp/build.sh
# builds libxbrvdsp.so. Without it, they still run on the core, but their
# lockstep check fails.
XBRVDSP_LIB="${XBRVDSP_LIB:-$ROOT/tools/spike_xbrvdsp/build/libxbrvdsp.so}"

tests=("$@")
skipped=()
if [ ${#tests[@]} -eq 0 ]; then
  for s in "${SUITES[@]}"; do
    for f in "${SRC[$s]}"/*.S; do
      t="$s/$(basename "$f" .S)"
      if [ -n "${NOT_APPLICABLE[$t]:-}" ]; then skipped+=("$t"); else tests+=("$t"); fi
    done
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
    "${SRC[$suite]}/$name.S" -o "$out.elf"
  "${CROSS}objcopy" -O binary "$out.elf" "$out.bin"
  python3 "$HERE/elf2hex.py" "$out.bin" "$out.hex"
  "${CROSS}objdump" -d "$out.elf" > "$out.dis"
  tohost=$("${CROSS}nm" "$out.elf" | awk '$3 == "tohost" { print $1 }')
  pipe_arg=(); [ "$PIPE" = 1 ] && pipe_arg=(+pipe="$out.pipe")
  result=$(cd "$B" && vvp -n tb_isa.vvp +hex="$out.hex" +tohost="$tohost" +trace="$out.trace" "${pipe_arg[@]}" | grep '^RESULT' || echo "RESULT ERROR (simulator)")
  pipe_note=""
  if [ "$PIPE" = 1 ]; then
    pipe_out=$(python3 "$ROOT/scripts/pipeview.py" check "$out.pipe" "$out.trace" | tail -n 1) || true
    pipe_note="  [pipe: ${pipe_out#PIPE }]"
    case "$pipe_out" in "PIPE OK"*) ;; *) result="RESULT FAIL pipe trace" ;; esac
  fi
  ls_note=""
  if [ "$LOCKSTEP" = 1 ] && [[ "$NO_LOCKSTEP" != *" $t "* ]]; then
    spike_ext=()
    case "$t" in directed/dsp_*|directed/mul_use|directed/gf|directed/mq) spike_ext=(--extlib="$XBRVDSP_LIB" --extension=xbrvdsp) ;; esac
    timeout 120 "$SPIKE" --isa="${MARCH[$suite]}" "${spike_ext[@]}" -m0x80000000:0x8000 --log-commits "$out.elf" 2> "$out.spike" || true
    ls_out=$(python3 "$HERE/lockstep.py" "$out.trace" "$out.spike" | tail -n 1) || ls_out="FAIL $ls_out"
    ls_note="  [lockstep: $ls_out]"
    case "$ls_out" in MATCH*) ;; *) result="RESULT FAIL lockstep" ;; esac
  fi
  printf '%-22s %s%s%s\n' "$t" "${result#RESULT }" "$ls_note" "$pipe_note" | tee -a "$B/results.txt"
  case "$result" in "RESULT PASS"*) ;; *) fails=$((fails + 1)) ;; esac
done

for t in "${skipped[@]}"; do
  printf '%-22s N/A: %s\n' "$t" "${NOT_APPLICABLE[$t]}" | tee -a "$B/results.txt"
done
echo "$(( ${#tests[@]} - fails )) / ${#tests[@]} passed${skipped:+, ${#skipped[@]} not applicable}" | tee -a "$B/results.txt"
[ "$fails" -eq 0 ]
