#!/usr/bin/env bash
# run_saif_netlist.sh — switching activity from the routed netlist, for
# Vivado's power estimate (doc/lattice_crypto.md, Step 5c). As run_saif.sh, but
# the simulated design is the placed-and-routed SoC itself, so the SAIF names
# the nets Vivado's power report uses, not the RTL's. For each program
# (saif_polymul.c, built with -DNETLIST so that it reports on the GPIO pins):
#   1. Vivado implements the SoC with the program as its SRAM's initial image
#      (scripts/vivado_netlist.tcl: 16384 words, reset vector 0x8000_0000) and
#      writes it as a funcsim netlist (write_verilog -mode funcsim, no SDF);
#   2. xsim runs the netlist under tb_netlist.v and writes the SAIF;
#   3. Vivado reports power for the routed design from that SAIF
#      (scripts/vivado_netlist_power.tcl), and from run_saif.sh's RTL SAIF
#      (build/power/<be>.saif, if it exists) for comparison.
# Results are in build/netlist/<be>/ (power_netlist_saif.rpt, power_rtl_saif.rpt,
# power_vectorless.rpt, utilization.rpt, summary.txt).
#
# Usage (from anywhere): [REPS=n] tests/power/run_saif_netlist.sh [ref|ext ...]
# TIMEOUT (cycles, default 20,000,000) ends the simulation early (a speed test).
# REPS is the number of products (default 4, as run_saif.sh): the netlist
# simulates far more slowly than the RTL, so a short run first is wise.
# Needs: riscv64-unknown-elf-gcc and Vivado (vivado, xvlog, xelab, xsim) on the PATH.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BENCH="$ROOT/tests/bench"
CROSS="${CROSS:-riscv64-unknown-elf-}"
MARCH="${MARCH:-rv32imc_zicsr}"
REPS="${REPS:-4}"
B="$ROOT/build/netlist"
mkdir -p "$B/data"

python3 "$BENCH/gen_data.py" > "$B/data/bench_data.h"
CFLAGS=(-O2 -falign-loops=4 -mabi=ilp32 -mcmodel=medany -ffreestanding -I "$B/data" -I "$BENCH" -DNETLIST -DREPS="$REPS")
"${CROSS}gcc" "${CFLAGS[@]}" -march="${MARCH}_zbkb" -c "$BENCH/mlkem_x.c" -o "$B/data/mlkem_x.o"
GLBL="$(dirname "$(dirname "$(command -v vivado)")")/data/verilog/src/glbl.v"

for be in "${@:-ref ext}"; do
  for b in $be; do
    D="$B/$b"; mkdir -p "$D"
    def=(); [ "$b" = ext ] && def=(-DMLKEM_EXT)
    "${CROSS}gcc" "${CFLAGS[@]}" "${def[@]}" -march="$MARCH" -static -nostdlib -nostartfiles \
      -T "$BENCH/link.ld" "$BENCH/crt.S" "$HERE/saif_polymul.c" "$BENCH/mlkem.c" "$B/data/mlkem_x.o" -o "$D/$b.elf"
    "${CROSS}objcopy" -O binary "$D/$b.elf" "$D/$b.bin"
    python3 "$ROOT/tests/isa/elf2hex.py" "$D/$b.bin" "$D/firmware.hex"

    cd "$D"
    [ -f netlist.v ] && [ "${REUSE:-0}" = 1 ] || vivado -mode batch -nojournal -log vivado_impl.log \
      -source "$ROOT/scripts/vivado_netlist.tcl" -tclargs "$ROOT" > /dev/null
    xvlog netlist.v "$GLBL" "$HERE/tb_netlist.v" > xvlog.log
    xelab --relax -debug typical -L unisims_ver -L secureip tb_netlist glbl -s tb_netlist > xelab.log
    cat > saif.tcl <<TCL
open_saif $b.saif
log_saif [get_objects -r /tb_netlist/dut/*]
run all
close_saif
quit
TCL
    xsim tb_netlist -tclbatch saif.tcl -testplusarg timeout=${TIMEOUT:-20000000} > xsim.log
    grep '^RESULT' xsim.log | sed "s/^/$b: /"
    grep -q '^RESULT PASS' xsim.log
    rtl=(); [ -f "$ROOT/build/power/$b.saif" ] && rtl=("$ROOT/build/power/$b.saif")
    vivado -mode batch -nojournal -log vivado_power.log \
      -source "$ROOT/scripts/vivado_netlist_power.tcl" -tclargs "$D/$b.saif" "${rtl[@]}" > /dev/null
    cd "$ROOT"
  done
done
