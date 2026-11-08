# sim.sh — source this: build and run the ISA testbench (tests/isa/tb_isa.v) on
# the SoC with Icarus (the default) or with Verilator.
#
#   . tests/bench/sim.sh
#   sim_build <dir> <memory words> [-DNAME=value ...]    # builds into <dir>
#   $(sim_cmd <dir>) +hex=... +tohost=... +marks=...     # runs it
#
# SIM=verilator (VERILATOR= the verilator binary, VERILATOR_ROOT set as that
# install needs) is about 100 times faster: 13 s for the 2.5-million-cycle DSP
# benchmark run against about half an hour in Icarus 12. Both give the same
# cycle counts (checked on the benchmark markers and cycle by cycle on the
# micro-test pipeline trace, doc/cpi_breakdown.md). Icarus is what CI uses.
#
# Verilator 5.020 is a 2-state simulator and has no X: the registers that are
# not reset (cache data and tags) start at zero, not unknown. Nothing reads them
# before they are written (the valid bits are reset).
_SIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

sim_build() {
  local dir="$1" mem="$2"; shift 2
  local root="${SIM_RTL_ROOT:-$_SIM_ROOT}"
  local files=("$root"/rtl/core/*.v "$root"/rtl/cache/*.v
    "$root/rtl/bus/axi_interconnect.v" "$root/rtl/bus/axi_sram.v" "$root/rtl/bus/axi_periph_bridge.v"
    "$root"/rtl/periph/*.v "$root/rtl/brv32p_soc.v" "$root/tests/isa/tb_isa.v")
  mkdir -p "$dir"
  if [ "${SIM:-iverilog}" = verilator ]; then
    "${VERILATOR:-verilator}" --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_isa \
      -DTB_MEM_DEPTH="$mem" "$@" -I"$root/rtl/pkg" -I"$root/rtl/core" -O3 --x-assign fast --x-initial fast \
      -j 2 --Mdir "$dir/obj" -o vtb "${files[@]}" > "$dir/verilator.log" 2>&1
  else
    iverilog -g2005 -DTB_MEM_DEPTH="$mem" "$@" -o "$dir/tb.vvp" -I "$root/rtl/pkg" -I "$root/rtl/core" "${files[@]}"
  fi
}

sim_cmd() {
  if [ "${SIM:-iverilog}" = verilator ]; then echo "$1/obj/vtb"; else echo "vvp -n $1/tb.vvp"; fi
}
