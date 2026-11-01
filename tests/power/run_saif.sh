#!/usr/bin/env bash
# run_saif.sh — switching activity for Vivado's power estimate: build the
# polynomial-product workload twice (saif_polymul.c: reference C, and the
# mq_unit kernels), run each on the SoC in xsim, and write the SoC's activity
# as SAIF (build/power/<be>.saif). Then
#   SAIF_FILES="build/power/ref.saif build/power/ext.saif" \
#     vivado -mode batch -source scripts/vivado_ooc.tcl
# reports power for each, besides the vectorless estimate.
#
# Usage (from anywhere): tests/power/run_saif.sh [ref|ext ...]
# Needs: riscv64-unknown-elf-gcc and Vivado's xvlog/xelab/xsim on the PATH.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BENCH="$ROOT/tests/bench"
CROSS="${CROSS:-riscv64-unknown-elf-}"
MARCH="${MARCH:-rv32imc_zicsr}"
B="$ROOT/build/power"
mkdir -p "$B"

python3 "$BENCH/gen_data.py" > "$B/bench_data.h"
CFLAGS=(-O2 -falign-loops=4 -mabi=ilp32 -mcmodel=medany -ffreestanding -I "$B" -I "$BENCH")
"${CROSS}gcc" "${CFLAGS[@]}" -march="${MARCH}_zbkb" -c "$BENCH/mlkem_x.c" -o "$B/mlkem_x.o"

# One xsim snapshot serves both programs: the program comes in by +hex
cd "$B"
xvlog --relax -d TB_MEM_DEPTH=16384 -i "$ROOT/rtl/pkg" -i "$ROOT/rtl/core" \
  "$ROOT"/rtl/core/*.v "$ROOT"/rtl/cache/*.v \
  "$ROOT/rtl/bus/axi_interconnect.v" "$ROOT/rtl/bus/axi_sram.v" "$ROOT/rtl/bus/axi_periph_bridge.v" \
  "$ROOT"/rtl/periph/*.v "$ROOT/rtl/brv32p_soc.v" "$ROOT/tests/isa/tb_isa.v" > xvlog.log
xelab --relax -debug typical tb_isa -s tb_isa > xelab.log

for be in "${@:-ref ext}"; do
  for b in $be; do
    def=(); [ "$b" = ext ] && def=(-DMLKEM_EXT)
    "${CROSS}gcc" "${CFLAGS[@]}" "${def[@]}" -march="$MARCH" -static -nostdlib -nostartfiles \
      -T "$BENCH/link.ld" "$BENCH/crt.S" "$HERE/saif_polymul.c" "$BENCH/mlkem.c" "$B/mlkem_x.o" -o "$b.elf"
    "${CROSS}objcopy" -O binary "$b.elf" "$b.bin"
    python3 "$ROOT/tests/isa/elf2hex.py" "$b.bin" "$b.hex"
    tohost=$("${CROSS}nm" "$b.elf" | awk '$3 == "tohost" { print $1 }')
    cat > "$b.tcl" <<TCL
open_saif $b.saif
log_saif [get_objects -r /tb_isa/dut/*]
run all
close_saif
quit
TCL
    xsim tb_isa -tclbatch "$b.tcl" -testplusarg hex="$B/$b.hex" -testplusarg tohost="$tohost" \
      -testplusarg marks="$B/$b.marks" -testplusarg timeout=2000000 > "$b.xsim.log"
    grep '^RESULT' "$b.xsim.log" | sed "s/^/$b: /"
    grep -q '^RESULT PASS' "$b.xsim.log"
  done
done
