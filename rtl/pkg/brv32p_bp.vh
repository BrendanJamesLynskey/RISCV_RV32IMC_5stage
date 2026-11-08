// brv32p_bp.vh — defaults for the branch predictor's parameters.
//
// The core and the predictor take their defaults from these macros, so a
// build can choose a predictor without editing the RTL: iverilog
// -DBP_KIND_DEFAULT=3, Vivado synth_design -verilog_define BP_KIND_DEFAULT=3.
// BP_KIND: 0 static not-taken, 1 one-bit table, 2 two-bit table (the
// design's predictor), 3 gshare, 4 tournament of 2 and 3.
`ifndef BRV32P_BP_VH
`define BRV32P_BP_VH
`ifndef BP_KIND_DEFAULT
`define BP_KIND_DEFAULT 2
`endif
`ifndef BP_BHT_DEFAULT
`define BP_BHT_DEFAULT 256
`endif
`ifndef BP_GH_DEFAULT
`define BP_GH_DEFAULT 8
`endif
`endif
