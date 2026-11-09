# Branch prediction: five predictors on the BRV32P core

The core resolves branches in EX and predicts in IF from a branch history table (BHT)
and a 64-entry branch target buffer (BTB). `BP_KIND` (rtl/pkg/brv32p_bp.vh,
`rtl/core/branch_predictor.v`) now selects the direction predictor; the BTB, the
interface and the pipeline are unchanged. Ideas follow H&P 6th ed. §3.3 (dynamic
prediction, correlating and tournament predictors); the code is written for this core.

| `BP_KIND` | Predictor |
|---|---|
| 0 | static not-taken: never predicts taken |
| 1 | one bit per entry: repeat the branch's last outcome |
| 2 | two-bit saturating counters, indexed by pc[8:1]: **the default, the original circuit, unchanged** |
| 3 | gshare: two-bit counters indexed by pc[8:1] xor the last `GH_BITS` outcomes |
| 4 | tournament: a chooser (two-bit counters per pc) picks between kind 2 and kind 3 for each branch; it moves toward whichever was right when they disagreed |

Parameters: `BP_BHT_ENTRIES` (64, 256, 1024; default 256), `BP_GH_BITS` (default 8, at most
log2 of the table size). Builds choose them with macros (`-DBP_KIND_DEFAULT=3`,
`-DBP_BHT_DEFAULT=1024`, `-DBP_GH_DEFAULT=10`; Vivado `-verilog_define`).

**What the history is.** The global history holds the outcomes of branches *after they
resolve in EX*, not speculatively at fetch, so it lags fetch by a few cycles; and a
branch is trained in the counter it was predicted from, using the history it saw at fetch,
which the predictor remembers by fetch address in a small table (`hs_*`). A full design
carries that history down the pipeline with the branch; this keeps the interface unchanged. (A
first-cut would train the counter today's history selects, and would be wrong whenever an
older branch is still in flight.) Jumps (JAL, JALR) never train the predictor in this core and cost two
bubbles whatever the kind.

**The default is unchanged.** With `BP_KIND` 2 the ISA suite (112 tests) gives the same
cycle count in every test as the unmodified core, the DSP program the same 2,555,964
cycles (Icarus 12 and Verilator 5.020), and all four other kinds pass the whole ISA suite.

## Method

`tests/bench/bp_sweep.sh` builds the SoC for each configuration and runs the DSP program
and the ML-KEM-512 program (reference and Xbrvdsp arithmetic); the testbench
(`+stats=`, `tb_isa.v`) counts branches resolved in EX and mispredicts at every
`BENCH_MARK`. `bp_report.py` makes the tables from the same benchmark set as
[cpi_breakdown.md](cpi_breakdown.md) (22 kernels and the ML-KEM-512 KeyGen, Encaps and
Decaps on both back ends). Verilator 5.020; a configuration takes about two minutes.
"Mispredicts" are conditional branches and hardware-loop ends. The counters sit at EX, two stages ahead of the marker's
retirement, so a window can gain or lose a branch at its edges; whole-program
totals are exact.

The cost model from [cpi_breakdown.md](cpi_breakdown.md), two bubbles per mispredict, holds
exactly: on the whole DSP program, static not-taken against the default has
171,662 more mispredicts and 343,324 more mispredict-bubble cycles (2.000 x).

## Results

All kinds, over the whole set (the sum over the 22 kernel windows and 6 ML-KEM windows):

| predictor | cond. branches | mispredicts | per branch | per 1,000 instr | CPI | cycles vs 2-bit | 2 x mispredict change |
|---|--:|--:|--:|--:|--:|--:|--:|
| static not-taken | 246940 | 175158 | 70.931% | 32.34 | 1.7641 | +509035 | +278716 |
| 1-bit, 256 entries | 246940 | 62656 | 25.373% | 11.57 | 1.6889 | +101721 | +53712 |
| 2-bit (default), 256 entries | 246940 | 35800 | 14.497% | 6.61 | 1.6701 | +0 | +0 |
| gshare, 256 entries, history 8 | 246940 | 11186 | 4.530% | 2.07 | 1.6687 | -7708 | -49228 |
| tournament, 256 entries, history 8 | 246940 | 9409 | 3.810% | 1.74 | 1.6670 | -16871 | -52782 |

"2 x mispredict change" is what the cost model predicts for the change in cycles; the CPI
column is cycles over instructions for the whole set. Per benchmark, the cell is mispredicts per 1,000
instructions / CPI:

| benchmark | branches / 1,000 instr | static not-taken | 1-bit | 2-bit (default) | gshare | tournament |
|---|--:|--:|--:|--:|--:|--:|
| fir | 157 | 141.3 / 1.414 | 16.0 / 1.171 | 8.0 / 1.155 | 8.7 / 1.157 | 8.0 / 1.155 |
| fir_mac | 170 | 150.5 / 1.458 | 19.1 / 1.195 | 9.6 / 1.176 | 9.7 / 1.177 | 9.6 / 1.176 |
| fir_agu2 | 133 | 106.1 / 1.221 | 27.0 / 1.076 | 13.5 / 1.049 | 0.2 / 1.010 | 0.2 / 1.010 |
| fir_dmac | 140 | 94.1 / 1.201 | 55.2 / 1.142 | 27.6 / 1.087 | 1.4 / 1.016 | 0.8 / 1.015 |
| energy | 100 | 99.2 / 1.305 | 0.8 / 1.109 | 0.4 / 1.108 | 1.9 / 1.111 | 0.4 / 1.108 |
| energy_mac | 249 | 245.7 / 1.755 | 1.9 / 1.269 | 1.0 / 1.267 | 6.7 / 1.278 | 1.0 / 1.267 |
| energy_agu2 | 166 | 155.9 / 1.359 | 5.0 / 1.059 | 2.5 / 1.054 | 2.5 / 1.054 | 2.5 / 1.054 |
| biquad | 111 | 74.1 / 1.263 | 0.4 / 1.116 | 0.3 / 1.116 | 0.6 / 1.116 | 0.3 / 1.116 |
| biquad_mac | 67 | 66.1 / 1.139 | 0.8 / 1.008 | 0.5 / 1.008 | 0.8 / 1.008 | 0.4 / 1.008 |
| fft_bitrev | 206 | 134.9 / 1.333 | 104.9 / 1.273 | 112.4 / 1.288 | 21.4 / 1.106 | 22.5 / 1.108 |
| fft_bitrev_agu | 192 | 186.4 / 1.618 | 5.9 / 1.257 | 3.0 / 1.251 | 5.9 / 1.257 | 5.9 / 1.257 |
| fft_stages | 110 | 102.3 / 1.316 | 7.9 / 1.128 | 4.5 / 1.121 | 3.5 / 1.119 | 3.5 / 1.119 |
| fft_stages_dmac | 37 | 26.3 / 1.185 | 10.2 / 1.152 | 5.8 / 1.144 | 4.1 / 1.140 | 3.7 / 1.140 |
| sha256 | 28 | 27.2 / 1.072 | 1.5 / 1.023 | 0.9 / 1.022 | 0.9 / 1.022 | 0.8 / 1.022 |
| sha256_zk | 52 | 50.4 / 1.124 | 2.6 / 1.033 | 1.3 / 1.031 | 1.4 / 1.031 | 1.3 / 1.031 |
| aes128 | 102 | 75.9 / 1.201 | 37.0 / 1.126 | 24.6 / 1.102 | 18.5 / 1.090 | 17.1 / 1.087 |
| aes128_zk | 33 | 29.3 / 1.084 | 7.0 / 1.039 | 3.5 / 1.032 | 7.0 / 1.039 | 3.5 / 1.032 |
| crc32_table | 100 | 99.2 / 1.300 | 0.8 / 1.103 | 0.4 / 1.102 | 0.8 / 1.103 | 0.4 / 1.102 |
| crc32_clmul | 98 | 95.5 / 1.218 | 3.0 / 1.035 | 1.5 / 1.032 | 3.0 / 1.035 | 1.5 / 1.032 |
| crc32_bitwise | 148 | 131.0 / 1.264 | 32.9 / 1.068 | 16.4 / 1.035 | 0.1 / 1.002 | 0.1 / 1.002 |
| mlkem_polymul | 53 | 41.5 / 1.303 | 10.7 / 1.242 | 5.4 / 1.231 | 1.5 / 1.224 | 1.5 / 1.223 |
| mlkem_polymul_x | 44 | 35.4 / 1.597 | 5.0 / 1.541 | 2.7 / 1.537 | 2.3 / 1.535 | 1.6 / 1.533 |
| ML-KEM-512 ref KeyGen | 40 | 28.9 / 1.755 | 10.0 / 1.681 | 5.9 / 1.664 | 1.6 / 1.663 | 1.3 / 1.662 |
| ML-KEM-512 ref Encaps | 43 | 30.0 / 1.771 | 11.0 / 1.700 | 6.1 / 1.682 | 1.7 / 1.681 | 1.4 / 1.679 |
| ML-KEM-512 ref Decaps | 49 | 35.0 / 1.732 | 11.4 / 1.656 | 6.2 / 1.638 | 1.8 / 1.636 | 1.5 / 1.635 |
| ML-KEM-512 ext KeyGen | 38 | 25.5 / 1.836 | 10.2 / 1.764 | 6.2 / 1.745 | 1.6 / 1.745 | 1.3 / 1.743 |
| ML-KEM-512 ext Encaps | 41 | 27.2 / 1.860 | 11.8 / 1.788 | 6.4 / 1.767 | 1.8 / 1.767 | 1.5 / 1.765 |
| ML-KEM-512 ext Decaps | 47 | 32.6 / 1.852 | 12.4 / 1.774 | 7.2 / 1.753 | 2.0 / 1.752 | 1.7 / 1.750 |

Table size, for the default and gshare, with the history as long as the index allows:

| predictor | cond. branches | mispredicts | per branch | per 1,000 instr | CPI | cycles vs 2-bit | 2 x mispredict change |
|---|--:|--:|--:|--:|--:|--:|--:|
| 2-bit (default), 64 entries | 246940 | 37456 | 15.168% | 6.92 | 1.6709 | +4471 | +3312 |
| 2-bit (default), 256 entries | 246940 | 35800 | 14.497% | 6.61 | 1.6701 | +0 | +0 |
| 2-bit (default), 1024 entries | 246940 | 35356 | 14.318% | 6.53 | 1.6699 | -915 | -888 |
| gshare, 64 entries, history 6 | 246940 | 13440 | 5.443% | 2.48 | 1.6696 | -2511 | -44720 |
| gshare, 256 entries, history 8 | 246940 | 11186 | 4.530% | 2.07 | 1.6687 | -7708 | -49228 |
| gshare, 1024 entries, history 10 | 246940 | 10487 | 4.247% | 1.94 | 1.6677 | -12904 | -50626 |

gshare, table size and history length:

| predictor | cond. branches | mispredicts | per branch | per 1,000 instr | CPI | cycles vs 2-bit | 2 x mispredict change |
|---|--:|--:|--:|--:|--:|--:|--:|
| gshare, 64 entries, history 2 | 246940 | 24039 | 9.735% | 4.44 | 1.6662 | -21332 | -23522 |
| gshare, 64 entries, history 4 | 246940 | 19857 | 8.041% | 3.67 | 1.6704 | +1441 | -31886 |
| gshare, 64 entries, history 6 | 246940 | 13440 | 5.443% | 2.48 | 1.6696 | -2511 | -44720 |
| gshare, 256 entries, history 0 | 246940 | 35800 | 14.497% | 6.61 | 1.6701 | +0 | +0 |
| gshare, 256 entries, history 2 | 246940 | 24607 | 9.965% | 4.54 | 1.6659 | -22837 | -22386 |
| gshare, 256 entries, history 4 | 246940 | 19020 | 7.702% | 3.51 | 1.6697 | -2425 | -33560 |
| gshare, 256 entries, history 6 | 246940 | 12200 | 4.940% | 2.25 | 1.6683 | -9880 | -47200 |
| gshare, 256 entries, history 8 | 246940 | 11186 | 4.530% | 2.07 | 1.6687 | -7708 | -49228 |
| gshare, 1024 entries, history 2 | 246940 | 24459 | 9.905% | 4.52 | 1.6658 | -23344 | -22682 |
| gshare, 1024 entries, history 4 | 246940 | 19263 | 7.801% | 3.56 | 1.6697 | -2415 | -33074 |
| gshare, 1024 entries, history 6 | 246940 | 12159 | 4.924% | 2.24 | 1.6683 | -9931 | -47282 |
| gshare, 1024 entries, history 8 | 246940 | 10932 | 4.427% | 2.02 | 1.6682 | -10532 | -49736 |
| gshare, 1024 entries, history 10 | 246940 | 10487 | 4.247% | 1.94 | 1.6677 | -12904 | -50626 |

## What it shows

* **The ordering is the textbook one.** Static not-taken is wrong for 71% of conditional
  branches here (loops: most are taken), one bit for 25%, two bits for 14.5%, gshare for 4.5% and
  the tournament for 3.8%. The one-bit predictor mispredicts twice per loop execution (the exit,
  then the first iteration of the next), the two-bit predictor once: the gap in every loop kernel.
* **gshare wins where a branch's outcome follows a pattern of its recent ones**, and
  loses on a few short runs. Big wins: `fft_bitrev` (112 to 21 per 1,000 instructions, the
  bit-reversal's data-dependent branch repeats a pattern), `crc32_bitwise` (16.4 to 0.1) and `fir_agu2` / `fir_dmac`
  (short inner loops whose exit the history predicts), `aes128` (24.6 to 18.5). Losses: `energy_mac`
  (1.0 to 6.7), `fir` (8.0 to 8.7), `aes128_zk`, `fft_bitrev_agu`: runs of a few hundred branches
  that are almost always the same way. A gshare branch is spread over many counters, one per history, each
  of which must be trained separately, so a short run pays the training cost many times (aliasing is not the cause: with a 1,024-entry table `energy_mac` still has 5.8 to 8.7 mispredicts per 1,000 instructions, against 1.0 for the 2-bit predictor). The
  tournament avoids nearly all of these losses: its chooser stays with the local counter until gshare
  has proved better for that branch.
* **Table size hardly matters** (64 to 1,024 entries: 6.92, 6.61, 6.53 mispredicts per 1,000
  instructions): the kernels have only a few dozen static branches, so 64 entries rarely alias. History
  length matters up to 6 to 8 bits (4.4 at 2 bits of history, 2.5 at 6, 2.1 at 8, 1.9 at 10, for 64 to 1,024
  entries).
* **The cycle gain is small on the whole set, large on kernels.** Over the whole set the
  CPI moves from 1.6701 to 1.6687 (gshare) and 1.6670 (tournament), 0.2%, because
  ML-KEM-512 dominates the cycles and runs at CPI 1.64 to 1.77 with the memory system, not branches, as its
  main loss ([cpi_breakdown.md](cpi_breakdown.md)). On the compute kernels the gain is real:
  `crc32_bitwise` 1.035 to 1.002, `fir_agu2` 1.049 to 1.010, `fir_dmac` 1.087 to 1.016,
  `fft_bitrev` 1.288 to 1.106.
* **What did not match the cost model.** The mispredict bubbles follow the model exactly, on every
  program. But on ML-KEM the *total* cycles do not follow them. Whole-program,
  reference arithmetic, against the 2-bit default: static not-taken has 217,816 more mispredict-bubble cycles
  and 390,331 more cycles in all; the other 172,515 are 57,512 more I-cache wait, 116,117 more D-cache wait and 1,114 fewer straddle cycles. gshare
  saves 34,514 mispredict-bubble cycles but only 2,602 cycles in all (the I-cache wait falls 24,906, the D-cache wait
  rises 57,595). A mispredict changes more than the fetch it wastes: the wrong path fetches lines, and
  whatever the instruction and data sides then compete for on the bus moves with it. I did not
  isolate which; the whole-set CPI column therefore is not a clean measure of the predictor, and
  the mispredict counts and the compute kernels are.

## Cost: LUTs, flip-flops, timing

Vivado 2025.2, `scripts/vivado_ooc.tcl`: out-of-context synthesis, place and route of the whole SoC (32 KB SRAM,
Zk/DSP/mod-q units, both caches) for the Artix-7 xc7a100tcsg324-1, 10 ns clock, one run per build; `VERILOG_DEFINES="BP_KIND_DEFAULT=n"`.
The default (2-bit) build is the repository's existing one, run again.

| Predictor | LUTs (whole SoC) | Flip-flops | LUTs / FFs in the predictor | WNS at 10 ns | Fmax | Worst path |
|---|--:|--:|--:|--:|--:|---|
| 2-bit (default) | 11,832 | 7,975 | 2,414 / 4,224 | -5.966 ns | 62.6 MHz | `pc_if` to `instr_id` (fetch) |
| gshare, history 8 | 11,770 | 7,934 | 2,374 / 4,232 | -5.678 ns | 63.8 MHz | mod-q multiplier to write-back |
| tournament | 13,190 | 8,929 | 3,767 / 5,256 | -5.505 ns | 64.5 MHz | `pc_if` to `pc_if` (next-PC loop) |

* **Area.** gshare costs nothing over the 2-bit table: it replaces the table of counters by a table of counters of the same
  size, and adds an 8-bit history, a 64-entry table of what was predicted at each fetch address, and an XOR (8 more flip-flops, 12 LUTs of
  memory). The tournament is both predictors and a chooser: +1,358 LUTs and +954 flip-flops over the default for the whole SoC (+11.5% LUTs, +12% flip-flops).
  The predictor is 20% of the SoC's LUTs in the default build and 29% in the tournament build; most of it is the table of
  256 two-bit counters held in flip-flops with a per-entry update, not the logic of the kinds.
* **Timing is not separated by the predictor.** All three builds miss 10 ns by 5.5 to 6.0 ns, and the order of the WNS (the
  tournament best) is not meaningful: the worst path moves between runs (the README's table has -5.7 ns for an earlier revision of this design, this run -5.966 ns), and in the gshare build it is the mod-q multiplier, not fetch. Only the tournament's worst path goes through the
  predictor (the next-PC loop, `pc_if` through the BHT and BTB reads to `pc_if`) and even there at 15.4 ns it is no worse than the other two.
  One run each does not resolve a difference of a few tenths of a nanosecond: this says gshare and tournament do not make the
  clock visibly worse, not that they are free.
* So, for these workloads: gshare for the price of a few flip-flops, a clear win on loop-heavy compute kernels, and neutral or a small loss
  where branches are biased and runs are short; the tournament for about 11% more LUTs removes the losses and gets most of
  the rest, and is worth it only if branchy kernels dominate (the whole-set CPI gain is 0.2%).


## Reproducing

```
SIM=verilator VERILATOR=<verilator> tests/bench/bp_sweep.sh     # about 40 minutes for the whole sweep
python3 tests/bench/bp_report.py > tables.md
```
Icarus works too (`SIM` unset) and takes about half an hour for each DSP run.
