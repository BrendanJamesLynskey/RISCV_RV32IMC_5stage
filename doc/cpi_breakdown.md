# CPI breakdown: where the cycles go

Every cycle in which no instruction retires is charged to exactly one cause, and
CPI is written in the form of H&P 6th ed. App. C: CPI = 1 + the sum, over causes,
of stall cycles per instruction. The tool is `tests/bench/cpi_breakdown.py`; it reads
the `+pipe=` trace ([pipeline_trace.md](pipeline_trace.md)) as a stream, so the
multi-million-cycle ML-KEM runs go through a named pipe without touching the disk
(`tests/bench/run_kem_cpi.sh`). The core retires at most one instruction per cycle, so
cycles - retired is the number of lost cycles, and the tool exits 1 if the causes do
not add up to it, for any window.

Tools: Verilator 5.020 for the runs below (Icarus 12 gives byte-identical pipeline
traces on the micro-test, and the same cycle count for the DSP run; see
`tests/bench/sim.sh`), riscv64-unknown-elf-gcc `-O2`, main d738d39 plus this branch.

## How a cycle gets its cause

Each pipeline register carries a tag: an instruction, or a bubble with the reason it
was made. The tags advance by the rules in the table in
[pipeline_trace.md](pipeline_trace.md) (cleared, loaded or held, from the previous
cycle's stall and flush signals). A cycle in which WB holds a bubble is charged to
that bubble's tag; a cycle in which MEM is held is charged to the hold. When several
things happen in one cycle, the RTL decides, and the tool follows it:

1. A held MEM stage (`mem_stall`) freezes everything, and the cycle goes to the D side
   if `dmem_stall`, else the I side, else to the second cycle of the mod-q multiplier.
   Nothing else is charged in it.
2. A flush beats a stall (`hazard_unit.v:112-118`: a mispredict overrides the load-use
   stall). Among flushes: trap, then MRET, then mispredict, then FENCE.I.
3. A multiply/divide stall freezes EX before any use hazard is looked at
   (`hazard_unit.v:99`), so a load-use that coincides with it is charged to the divide.
4. An I-cache miss makes a bubble in ID only if nothing older was squashed in the
   same cycle (rule 2).
5. What is left: the first cycles (pipeline fill, in "other") and a 32-bit instruction
   straddling two fetch words ("straddle").

The cause columns:

| Column | What it counts |
|---|---|
| load-use, mul-use, csr-use | the one bubble each hazard inserts in EX |
| mul/div busy | EX frozen by the divider, and the second cycle of the mod-q multiplier |
| mispredict | the two bubbles of a branch resolved wrongly in EX |
| trap/mret/fence.i | flushes by a trap or interrupt, MRET, FENCE.I |
| I-cache miss | MEM is held, or ID is empty, because instruction fetch waits on a fill |
| D-cache miss | MEM held on the data side: a line fill, a store waiting for the write buffer, or an uncached access. The trace cannot tell these apart, and the benchmarks touch no peripheral, so it is nearly all fills and write-buffer waits |
| straddle | fetch delivered the first half of a 32-bit instruction only |
| other | pipeline fill |

The attribution was checked against an independent one: `scripts/pipeview.py`'s
`lost_cycles()` traces each bubble back to its origin, where this tool moves tags
forward. The two agree on every lost cycle of the micro-test (1,379) (`--crosscheck`).

## Two predictions from `hazard_unit.v`, measured

`tests/bench/cpi_micro.S` runs 16 repeats of a pattern, twice, and measures the second
pass between markers (`tests/bench/run_cpi_micro.sh`, in CI).

* A load followed by an instruction that uses it costs exactly one bubble: 16 pairs
  take 16 cycles more than 16 pairs with an independent second instruction, and the
  breakdown puts all 16 under load-use. A multiply (result ready after MEM) and a CSR
  read (read in MEM) behave the same way: one bubble each.
* A branch resolves in EX, so when it is wrong the instruction in ID and the one being
  fetched are squashed (`flush_id`, `flush_ex`): two bubbles. 16 mispredicted branches
  cost 32 cycles, whether the error is a taken branch predicted not taken or the other way.

```
region (16 repeats)                                      cycles instrs  lost cycles by cause
load then dependent add                                      48     32  {'load-use': 16}
load then independent add                                    32     32  none
mul then dependent add                                       48     32  {'mul-use': 16}
mul then independent add                                     32     32  none
csrr then dependent add                                      48     32  {'csr-use': 16}
csrr then independent add                                    32     32  none
16 taken branches, counter 00: predicted not taken           48     16  {'mispredict': 32}
16 taken branches, counter 01: predicted not taken           48     16  {'mispredict': 32}
16 taken branches, counter 10: predicted taken               16     16  none
16 taken branches, counter 11: predicted taken               16     16  none
16 not-taken branches, counter 11: predicted taken           80     48  {'mispredict': 32}
16 not-taken branches, counter 10: predicted taken           80     48  {'mispredict': 32}

cost per load-use: 1 bubble; the dependent region takes 16 cycles more than the independent one for 16 pairs (hazard_unit.v predicts 1 per pair: 16)
cost per mispredicted branch: 2 bubbles (prediction: 2. The branch resolves in EX, so the instruction in ID and the one being fetched are squashed: flush_id and flush_ex)
```

The pattern also shows the 2-bit counter's hysteresis: after a not-taken warm-up the
counters sit at 00, so the first two taken passes are both mispredicted (00 to 01, then
01 to 10) and the third is right.

One thing that did not match the first guess: with the loop-back branch of the test at
an address that shares a BTB entry with one of the 16 branches (the BTB has 64
entries, indexed by pc[6:1], so two branches 128 bytes apart collide), one branch of
the 16 was mispredicted on every "predicted taken" pass. The final program places the
loop branch away from all of them. Also: JAL and JALR never train the predictor
(`brv32p_core.v:524`), so a call and its return cost two bubbles each time.

## Benchmarks

CPI per kernel, warm caches, between the markers of `bench_report.py` (the window is
the cycles strictly between the two markers, which is one cycle fewer than
`bench_report.py` counts). Each cause column is stall cycles per instruction, so
CPI = 1 + the row's columns. "-" is zero. Plain kernels come first, then their
extension variants (`_mac`, `_agu2`, `_dmac`, `_zk`, `_clmul`, `_x`).

| benchmark | instrs | cycles | CPI | load-use | mul-use | csr-use | mul/div busy | mispredict | trap/mret/fence.i | I-cache miss | D-cache miss | straddle | other | largest |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| fir | 8146 | 9408 | 1.155 | - | 0.126 | - | - | 0.016 | - | 0.005 | - | 0.008 | - | mul-use |
| fir_mac | 6799 | 7997 | 1.176 | 0.151 | - | - | - | 0.020 | - | 0.006 | - | 0.000 | - | load-use |
| fir_agu2 | 4818 | 5055 | 1.049 | - | - | - | - | 0.028 | - | 0.008 | - | 0.013 | - | mispredict |
| fir_dmac | 3549 | 3855 | 1.086 | - | - | - | - | 0.056 | - | 0.011 | 0.001 | 0.018 | - | mispredict |
| energy | 2571 | 2847 | 1.107 | - | 0.100 | - | - | 0.002 | - | 0.005 | - | 0.000 | - | mul-use |
| energy_mac | 1038 | 1314 | 1.266 | 0.247 | - | - | - | 0.006 | - | 0.013 | - | 0.001 | - | load-use |
| energy_agu2 | 404 | 425 | 1.052 | - | - | - | - | 0.015 | - | 0.032 | - | 0.005 | - | I-cache miss |
| biquad | 13867 | 15471 | 1.116 | 0.000 | - | - | - | 0.074 | - | 0.001 | 0.003 | 0.037 | - | mispredict |
| biquad_mac | 7728 | 7787 | 1.008 | 0.000 | - | - | - | 0.002 | - | - | 0.005 | 0.000 | - | D-cache miss |
| fft_bitrev | 934 | 1202 | 1.287 | - | - | - | - | 0.229 | - | - | 0.056 | 0.002 | - | mispredict |
| fft_bitrev_agu | 338 | 422 | 1.249 | 0.189 | - | - | - | 0.018 | - | 0.038 | - | 0.003 | - | load-use |
| fft_stages | 9378 | 10509 | 1.121 | 0.000 | 0.020 | - | - | 0.009 | - | - | 0.050 | 0.041 | - | D-cache miss |
| fft_stages_dmac | 7253 | 8294 | 1.144 | 0.053 | - | - | - | 0.012 | - | - | 0.078 | 0.000 | - | D-cache miss |
| sha256 | 25783 | 26341 | 1.022 | 0.000 | - | - | - | 0.003 | - | 0.001 | 0.017 | 0.000 | - | D-cache miss |
| sha256_zk | 13918 | 14345 | 1.031 | - | - | - | - | 0.005 | - | 0.001 | 0.024 | 0.001 | - | D-cache miss |
| aes128 | 93345 | 102826 | 1.102 | 0.027 | - | - | - | 0.049 | - | 0.000 | 0.010 | 0.014 | - | mispredict |
| aes128_zk | 4873 | 5030 | 1.032 | 0.000 | - | - | - | 0.008 | - | 0.003 | 0.021 | 0.000 | - | D-cache miss |
| crc32_table | 2571 | 2833 | 1.102 | 0.100 | - | - | - | 0.002 | - | - | - | - | - | load-use |
| crc32_clmul | 660 | 680 | 1.030 | - | - | - | - | 0.009 | - | 0.020 | - | 0.002 | - | I-cache miss |
| crc32_bitwise | 15627 | 16172 | 1.035 | - | - | - | - | 0.033 | - | 0.002 | - | 0.000 | - | mispredict |
| mlkem_polymul | 76143 | 93756 | 1.231 | 0.040 | 0.153 | - | - | 0.028 | - | 0.000 | 0.010 | 0.000 | - | mul-use |
| mlkem_polymul_x | 10040 | 15426 | 1.536 | 0.018 | - | - | 0.025 | 0.007 | - | 0.024 | 0.459 | 0.003 | - | D-cache miss |

ML-KEM-512, one operation each, from the whole-program run (`run_kem_cpi.sh`; "ref" is
the reference arithmetic, "ext" the Xbrvdsp kernels):

| benchmark | instrs | cycles | CPI | load-use | mul-use | csr-use | mul/div busy | mispredict | trap/mret/fence.i | I-cache miss | D-cache miss | straddle | other | largest |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| ML-KEM-512 ref KeyGen | 861694 | 1433911 | 1.664 | 0.056 | 0.024 | - | - | 0.016 | - | 0.223 | 0.344 | 0.001 | - | D-cache miss |
| ML-KEM-512 ref Encaps | 913917 | 1536781 | 1.682 | 0.054 | 0.038 | - | 0.028 | 0.018 | - | 0.207 | 0.336 | 0.001 | - | D-cache miss |
| ML-KEM-512 ref Decaps | 1048629 | 1717945 | 1.638 | 0.052 | 0.047 | - | 0.032 | 0.019 | - | 0.182 | 0.304 | 0.001 | - | D-cache miss |
| ML-KEM-512 ext KeyGen | 740355 | 1291646 | 1.745 | 0.060 | 0.001 | - | 0.001 | 0.013 | - | 0.260 | 0.408 | 0.001 | - | D-cache miss |
| ML-KEM-512 ext Encaps | 743503 | 1313601 | 1.767 | 0.059 | 0.002 | - | 0.036 | 0.014 | - | 0.255 | 0.400 | 0.001 | - | D-cache miss |
| ML-KEM-512 ext Decaps | 798338 | 1399709 | 1.753 | 0.057 | 0.003 | - | 0.045 | 0.016 | - | 0.241 | 0.390 | 0.001 | - | D-cache miss |


## The largest cause, and what it suggests

* **The compute kernels lose little, and to hazards the compiler or an extension
  removes.** Plain FIR loses 0.126 per instruction to mul-use (one bubble per tap);
  with the MAC it becomes load-use 0.151; the address-generating load (`fir_agu2`) takes
  that away too, and CPI falls to 1.049. After that the loop-exit mispredict is what
  is left (0.028), which only a loop predictor or the hardware loop removes.
* **Branchy code pays for mispredicts.** `fft_bitrev` has 0.229 per instruction
  (data-dependent branches, 2 cycles each); `aes128` 0.049; bitwise CRC 0.033. The
  predictor experiment ([branch_prediction.md](branch_prediction.md), if present) measures what better prediction buys.
* **Memory dominates once the arithmetic is fast.** The `_x` ML-KEM polymul spends
  0.459 cycles per instruction waiting on the D side, and its CPI of 1.536 is almost
  all that. The whole of ML-KEM-512 runs at CPI 1.64 to 1.77, with the D-cache at
  0.30 to 0.41 and the I-cache at 0.18 to 0.26 per instruction. The Xbrvdsp kernels
  cut the instruction count but raise the CPI, because the cache share does not shrink
  with them. With 2 KB caches of 16-byte lines this is the first thing to change:
  a bigger or better-organised cache would pay more than any further arithmetic work.
* **Nothing in these kernels traps, takes an interrupt, or executes FENCE.I**, so
  trap/mret/fence.i and csr-use are zero throughout.
