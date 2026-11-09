// brv32p_cache.vh — defaults for the caches' sizes.
//
// The SoC takes the number of sets of each cache from these macros, so a build
// can change them without editing the RTL: iverilog -DIC_SETS_DEFAULT=128.
// Each set holds 2 ways of 16-byte lines (the RTL supports exactly that: the
// replacement bit and the fill counter are sized for it), so the size in bytes
// is 32 x sets: 64 sets = 2 KB, the default.
`ifndef BRV32P_CACHE_VH
`define BRV32P_CACHE_VH
`ifndef IC_SETS_DEFAULT
`define IC_SETS_DEFAULT 64
`endif
`ifndef DC_SETS_DEFAULT
`define DC_SETS_DEFAULT 64
`endif
`endif
