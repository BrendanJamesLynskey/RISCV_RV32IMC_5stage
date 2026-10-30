# vivado_ooc.tcl — out-of-context synthesis and implementation of the SoC on the
# Nexys A7-100T's FPGA (Artix-7 xc7a100tcsg324-1), for utilisation and Fmax.
#
# Usage (from the repo root):
#   vivado -mode batch -source scripts/vivado_ooc.tcl -tclargs [part] [period_ns]
# Reports go to build/vivado/. Out of context means no I/O buffers or pin
# constraints: the numbers are for the logic itself.

set part   [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xc7a100tcsg324-1"}]
set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 10.0}]
set out    build/vivado

# Single-threaded keeps the peak memory down (each worker process holds its
# own copy of the design); runs one at a time on a 16 GB machine
set_param general.maxThreads 1
file mkdir $out

read_verilog [glob rtl/core/*.v rtl/cache/*.v rtl/bus/*.v rtl/periph/*.v] rtl/brv32p_soc.v
set_property include_dirs [list rtl/pkg rtl/core] [current_fileset]

# The SRAM's initial image is the SoC test program; Vivado reads it relative
# to the run directory
file copy -force firmware/firmware.hex firmware.hex

synth_design -top brv32p_soc -part $part -mode out_of_context
create_clock -name clk -period $period [get_ports clk]
report_utilization -file $out/utilization_synth.rpt

opt_design
place_design
route_design

report_utilization    -file $out/utilization.rpt
report_utilization    -hierarchical -file $out/utilization_hier.rpt
report_timing_summary -max_paths 5 -file $out/timing_summary.rpt
report_timing         -max_paths 1 -nworst 1 -path_type full -file $out/critical_path.rpt
# Power: Vivado's vectorless estimate (default toggle rates, no simulation
# activity) at the constrained clock; the hierarchy shows each unit's share.
# A comparison between designs, not a prediction for a given program.
report_power          -hierarchical_depth 4 -file $out/power.rpt

set wns  [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set fmax [expr {1000.0 / ($period - $wns)}]
set fh [open $out/summary.txt w]
puts $fh "part $part"
puts $fh "clock_period_ns $period"
puts $fh "wns_ns $wns"
puts $fh [format "fmax_mhz %.1f" $fmax]
close $fh
puts [format "SUMMARY part=%s period=%.2fns WNS=%.3fns Fmax=%.1fMHz" $part $period $wns $fmax]
