# vivado_netlist.tcl — the SoC with one program in its SRAM, implemented as in
# vivado_ooc.tcl, then written out as a funcsim netlist for xsim
# (tests/power/run_saif_netlist.sh). Run from the program's directory
# (build/netlist/<ref|ext>), which holds firmware.hex; the SRAM is 16384 words
# and the reset vector 0x8000_0000, as the benchmarks are built.
#
#   vivado -mode batch -source scripts/vivado_netlist.tcl -tclargs <repo root>
# Writes netlist.v, routed.dcp, power_vectorless.rpt, utilization.rpt, summary.txt
set root   [lindex $argv 0]
set part   xc7a100tcsg324-1
set period 10.0

set_param general.maxThreads 1
read_verilog [glob $root/rtl/core/*.v $root/rtl/cache/*.v $root/rtl/bus/*.v $root/rtl/periph/*.v] $root/rtl/brv32p_soc.v
set_property include_dirs [list $root/rtl/pkg $root/rtl/core] [current_fileset]

synth_design -top brv32p_soc -part $part -mode out_of_context \
  -generic MEM_DEPTH=16384 -generic RESET_PC=32'h80000000
create_clock -name clk -period $period [get_ports clk]
opt_design
place_design
route_design

write_checkpoint -force routed.dcp
report_utilization -file utilization.rpt
report_utilization -hierarchical -file utilization_hier.rpt
report_power -hierarchical_depth 4 -file power_vectorless.rpt
write_verilog -mode funcsim -force netlist.v

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set fh [open summary.txt w]
puts $fh "wns_ns $wns"
close $fh
