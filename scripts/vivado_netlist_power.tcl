# vivado_netlist_power.tcl — power of the routed design (routed.dcp) from the
# SAIF of its netlist simulation (tests/power/run_saif_netlist.sh), and, for
# comparison, from the RTL simulation's SAIF on the same design.
#   vivado -mode batch -source vivado_netlist_power.tcl -tclargs <netlist.saif> [<rtl.saif>]
open_checkpoint routed.dcp
reset_switching_activity -all
read_saif -strip_path tb_netlist/dut [lindex $argv 0]
report_power -hierarchical_depth 4 -file power_netlist_saif.rpt
if {[llength $argv] > 1} {
  reset_switching_activity -all
  read_saif -strip_path tb_isa/dut [lindex $argv 1]
  report_power -hierarchical_depth 4 -file power_rtl_saif.rpt
}
