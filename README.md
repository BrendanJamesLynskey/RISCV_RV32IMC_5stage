# BRV32P — 5-Stage Pipelined RV32IMC RISC-V SoC

A synthesisable RV32IMC RISC-V SoC implemented in Verilog-2001. Features a classic 5-stage in-order pipeline with full forwarding, 2-way set-associative caches, an AXI4-Lite bus fabric, and an M-extension multiply/divide unit.

---

## Features

| Category | Detail |
|---|---|
| **ISA** | RV32IMC — Base Integer, Multiply/Divide, Compressed — with the ratified scalar-crypto extensions **Zbkb**, **Zbkc**, **Zbkx**, **Zknh**, **Zkne** and **Zknd** ([doc/crypto_extensions.md](doc/crypto_extensions.md)), plus **Xbrvdsp**, its own DSP extension (multiply-accumulate into a 40-bit accumulator, address generators that load and step a pointer in one instruction (linear or bit-reversed), a hardware loop, and saturating and packed-halves arithmetic; [doc/dsp_extension.md](doc/dsp_extension.md)) |
| **Pipeline** | 5-stage (IF / ID / EX / MEM / WB), in-order |
| **Hazards** | Full data forwarding; load-use, mul-use and csr-use stalls; flush on misprediction |
| **Branch prediction** | 2-bit saturating BHT + Branch Target Buffer (BTB) |
| **I-cache** | 2-way set-associative, 2 KB, 16-byte lines, read-only (filled on a miss) |
| **D-cache** | 2-way set-associative, 2 KB, write-through |
| **Bus** | AXI4-Lite, 2-master / 2-slave interconnect with priority arbiter |
| **Memory** | 32 KB unified backing SRAM |
| **Peripherals** | GPIO (with interrupts), UART (8N1 TX/RX), Timer/counter |
| **CSRs** | Machine-mode subset: `mstatus`, `mie`, `mip`, `mepc`, `mcause`, `mtvec`, `mcycle`, `minstret` |
| **Toolchain** | Icarus Verilog 10.1+ (`-g2005`); CocoTB for Python-based tests |

---

## Pipeline Overview

```
        ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐
 PC ──► │  IF  │──►│  ID  │──►│  EX  │──►│ MEM  │──►│  WB  │
        └──────┘   └──────┘   └──────┘   └──────┘   └──────┘
            ▲          │          │          │
            │   BTB/BHT│   fwd ◄──┘──────── ┘  (EX→EX, MEM→EX)
            └──────────┘
                 branch resolve / flush
```

- **Forwarding paths:** EX/MEM → EX (ALU result), MEM/WB → EX (load result after one stall cycle)
- **Compressed decode:** 16-bit RV32C instructions are expanded to 32-bit equivalents in the ID stage before entering the main decode path
- **M-extension:** Multiplies compute in MEM, on one 33×33 signed multiplier for all four forms (a dependent instruction waits one cycle, as after a load); divides use a 32-step restoring divider in EX, which stalls the pipeline until the result is ready

---

## Memory Map

| Address Range | Size | Description |
|---|---|---|
| `0x0000_0000` – `0x0000_7FFF` | 32 KB | Unified SRAM (instruction + data) |
| `0x2000_0000` – `0x2000_00FF` | 256 B | GPIO registers |
| `0x2000_0100` – `0x2000_01FF` | 256 B | UART registers |
| `0x2000_0200` – `0x2000_02FF` | 256 B | Timer registers |

Decoding is partial. Any address with bits [31:28] = `0x2` goes to the peripheral bridge, which decodes bits
[11:8]. Every other address aliases the 32 KB SRAM. For example, `0x1000_0000` is SRAM address 0, the start of
the program.

---

## Directory Structure

```
RISCV_RV32IMC_5stage/
├── rtl/
│   ├── pkg/
│   │   └── brv32p_defs.vh            # Shared definitions (`include file)
│   ├── core/
│   │   ├── brv32p_core.v             # 5-stage pipeline top
│   │   ├── decoder.v                 # RV32IMC (+ Xbrvdsp) instruction decoder
│   │   ├── compressed_decoder.v      # RV32C → RV32 expander
│   │   ├── alu.v                     # Arithmetic logic unit
│   │   ├── regfile.v                 # 32 × 32-bit register file
│   │   ├── muldiv.v                  # M-extension divider (multiplies run in MEM)
│   │   ├── dsp_unit.v                # Xbrvdsp multiply-accumulate (40-bit accumulator)
│   │   ├── agu.v                     # Xbrvdsp address generators (ar0-ar3)
│   │   ├── loop_unit.v               # Xbrvdsp hardware loop (lc, lp_start)
│   │   ├── zk_unit.v                 # Zbkb, Zbkc, Zbkx, Zknh, Zkne, Zknd (scalar cryptography)
│   │   ├── branch_predictor.v        # 2-bit BHT + BTB
│   │   ├── hazard_unit.v             # Forwarding and stall logic
│   │   └── csr.v                     # Machine-mode CSRs
│   ├── cache/
│   │   ├── icache.v                  # 2-way set-associative I-cache
│   │   └── dcache.v                  # 2-way set-associative D-cache (write-through)
│   ├── bus/
│   │   ├── axi_interconnect.v        # 2M → 2S AXI4-Lite arbiter
│   │   ├── axi_sram.v                # AXI4-Lite SRAM slave
│   │   └── axi_periph_bridge.v       # AXI4-Lite → peripheral bridge
│   ├── periph/
│   │   ├── gpio.v                    # GPIO with interrupt support
│   │   ├── uart.v                    # UART TX / RX (8N1)
│   │   └── timer.v                   # Timer / counter
│   └── brv32p_soc.v                  # SoC top-level
├── tb/
│   └── tb_brv32p_soc.v               # Self-checking Verilog testbench
├── cocotb/
│   ├── test_brv32p_soc.py            # CocoTB test suite
│   └── Makefile
├── firmware/
│   ├── firmware.hex                  # Pre-built firmware image
│   └── gen_firmware.py               # Firmware generation script
├── tests/
│   ├── isa/
│   │   ├── run_isa.sh                # Build and run the ISA tests (+ Spike lockstep)
│   │   ├── tb_isa.v                  # ISA testbench: tohost detection, commit log, pipeline trace
│   │   ├── lockstep.py               # Compare the commit log with Spike's
│   │   ├── elf2hex.py                # ELF image → $readmemh hex
│   │   └── env/                      # Bare-metal test environment (riscv_test.h, link.ld)
│   ├── directed/                     # Own tests: FENCE.I, misaligned traps, interrupts
│   └── bench/                        # DSP and SHA-256 benchmarks (C), data generator, cycle report
├── tools/spike_xbrvdsp/              # Spike model of the DSP extension, for lockstep
├── scripts/
│   ├── lint.sh                       # Verilator -Wall lint
│   ├── pipeview.py                   # Pipeline trace: check, diagrams, JSON for animation
│   └── lint_waivers.vlt              # The waived rules, each with its reason
├── .github/workflows/ci.yml          # CI: ISA + lockstep + pipeline trace, testbenches, lint
├── doc/
│   ├── BRV32P_Design_Report.md       # Detailed micro-architecture write-up
│   ├── pipeline_trace.md             # The pipeline trace, its checking, and real diagrams
│   ├── dsp_extension.md              # Xbrvdsp: encodings, semantics, micro-architecture
│   └── crypto_extensions.md          # Zbkb/c/x, Zknh, Zkne, Zknd: implementation, tests, SHA-256, AES, CRC-32
└── README.md
```

---

## Prerequisites

### Simulation (Icarus Verilog)

```
sudo apt install iverilog          # Ubuntu / Debian
# or
brew install icarus-verilog        # macOS
```

Minimum version: **Icarus Verilog 10.1** (for `-g2005` Verilog-2001 mode).

### CocoTB

```
pip install cocotb
```

CocoTB requires a compatible simulator on `PATH` (Icarus Verilog or Verilator).

### Firmware (pre-built hex is provided)

The test program is hand-encoded by a Python script; no compiler is needed:

```
python3 firmware/gen_firmware.py      # writes firmware/firmware.hex
```

---

## Running Tests

### Icarus Verilog

```bash
iverilog -g2005 -o sim_brv32p \
  -I rtl/pkg -I rtl/core \
  rtl/core/*.v \
  rtl/cache/*.v \
  rtl/bus/axi_interconnect.v \
  rtl/bus/axi_sram.v \
  rtl/bus/axi_periph_bridge.v \
  rtl/periph/*.v \
  rtl/brv32p_soc.v \
  tb/tb_brv32p_soc.v

cp firmware/firmware.hex .
vvp sim_brv32p
```

The run ends with `Results: N PASSED, M FAILED` and `ALL TESTS PASSED` only when every check passed.

### CocoTB (cocotb 2.x)

```bash
cd cocotb
cp ../firmware/firmware.hex .
make
```

---

### ISA tests, in lockstep with Spike

```bash
sudo apt install gcc-riscv64-unknown-elf iverilog
tests/isa/run_isa.sh                     # every suite (riscv-tests is cloned on first use)
tests/isa/run_isa.sh rv32ui/add rv32uc/rvc
SPIKE=/path/to/spike tests/isa/run_isa.sh   # also compare each test with Spike
tools/spike_xbrvdsp/build.sh <spike-src> <spike-build>   # Spike's model of the DSP extension, for its tests
```

Each test is assembled with `riscv64-unknown-elf-gcc` and run on the SoC in Icarus. It reports pass or fail by a
store to `tohost`, which the testbench sees on the core's retire trace. With Spike available, the same ELF also
runs on Spike, and `lockstep.py` compares the two commit logs instruction by instruction: pc, encoding, register
write and store. Any difference fails the test and is shown with context.

### Pipeline trace and diagrams

Each ISA test also records a per-cycle pipeline trace: what every stage holds and every stall, flush, forward,
miss, mispredict and trap. `scripts/pipeview.py` rebuilds each instruction's path through the pipeline from it,
checks the rebuild against the RTL on every cycle and against the retire trace (a mismatch fails the test), and
draws pipeline diagrams or exports JSON for animation:

```bash
scripts/pipeview.py diagram tests/isa/build/rv32ui-lw.pipe --dis tests/isa/build/rv32ui-lw.dis --event load-use
```

```
8000019c lw a4,4(a3)                ddddddXMW
800001a0 mv t1,a4                   ffffffDdXMWwwwwwwwwwww     <- one load-use bubble, then forwarded from WB
```

See [doc/pipeline_trace.md](doc/pipeline_trace.md) for the format, the checking method, and real diagrams of
load-use, mispredicts, MUL/DIV, an interrupt and cache misses.

### Lint

```bash
scripts/lint.sh                          # Verilator -Wall; waivers and reasons in scripts/lint_waivers.vlt
```

### DSP benchmarks

```bash
tests/bench/run_bench.sh                 # build, run, check against Spike, report
```

DSP kernels in plain C (`tests/bench/dsp.c`, `-O2`, RV32IMC), with inputs and expected results generated by
`gen_data.py`: the baseline for the DSP instruction-set extension. Each kernel runs twice, with cold and then warm
caches, between marker instructions; `bench_report.py` measures the cycles between the markers from the pipeline
trace, and gives the cause of every cycle in which nothing retired (`pipeview.lost_cycles` follows each bubble
back to the event that made it).

| Kernel (warm caches) | What it computes | Cycles | Per unit | IPC | Main remaining loss |
|---|---|---|---|---|---|
| `fir` | 16-tap Q15 FIR, 64 outputs, 32-bit accumulator, rounded and saturated | 9,396 | 9.18 per tap | 0.87 | mul-use bubbles, one per tap: 1,024 cycles |
| `energy` | Sum of squares of 256 Q15 samples, 64-bit accumulator | 2,848 | 11.12 per sample | 0.90 | mul-use bubbles: 256 cycles |
| `fir_mac` | The FIR with Xbrvdsp: `mac` per tap, `acc.rdh` to round and saturate | 7,985 | 7.80 per tap | 0.85 | load-use bubbles, one per tap: 1,024 cycles |
| `energy_mac` | The energy with `mac`, read back exactly from the 40-bit accumulator | 1,329 | 5.19 per sample | 0.78 | load-use bubbles: 256 cycles |
| `energy_dmac` | The energy with `dmac`: two samples per instruction from one 32-bit load | 806 | 3.15 per sample | 0.81 | load-use bubbles: 128 cycles |
| `fir_agu` | `fir_mac` with both pointers in address registers: `lh.a`, `lh.a`, `mac` per tap | 7,104 | 6.94 per tap | 0.82 | load-use bubbles, one per tap: 1,024 cycles |
| `fir_agu2` | The same, two taps per iteration, all four loads ahead of the MACs | 5,043 | 4.92 per tap | 0.96 | inner-loop exit mispredicts: 134 cycles |
| `energy_agu` | `energy_dmac` with `lw.a` | 681 | 2.66 per sample | 0.78 | load-use bubbles: 128 cycles |
| `energy_agu2` | The same, four samples per iteration | 439 | 1.71 per sample | 0.92 | I-cache misses: 13 cycles |
| `fir_dmac` | The FIR two taps per `dmac`, all loads aligned words (odd outputs use a shifted copy of the taps) | 3,843 | 3.75 per tap | 0.92 | inner-loop exit mispredicts: 200 cycles |
| `fir_lp` | `fir_dmac` with the inner loop in hardware: four `lw.a`, `dmac`, `dmac.lp` | 3,267 | 3.19 per tap | 0.91 | mispredicts (loop exit, even/odd test): 264 cycles |
| `energy_lp` | `energy_agu2` as a hardware loop: two `lw.a`, `dmac`, `dmac.lp` | 295 | 1.15 per sample | 0.93 | I-cache misses: 13 cycles |
| `biquad` | Two-section Q14 biquad IIR (direct form I), 256 samples, plain C | 15,485 | 30.24 per sample per section | 0.90 | mispredicts: 1,032 cycles |
| `biquad_mac` | The same with `mac`, `msu` and `acc.rdh` | 7,801 | 15.24 per sample per section | 0.99 | — |
| `mix` | Saturating Q31 add, 256 samples, plain C (`__builtin_add_overflow`) | 5,533 | 21.61 per sample | 0.55 | D-cache waits: 1,963 cycles |
| `mix_sadd` | The same with `sadd` | 4,042 | 15.79 per sample | 0.51 | D-cache waits: 1,963 cycles |
| `fft_bitrev` | 64-point FFT input permutation, plain C (Gold–Rader reverse counter) | 1,164 | 18.19 per point | 0.80 | mispredicts: 216 cycles |
| `fft_bitrev_agu` | The same, loading through an address register in bit-reversed mode | 410 | 6.41 per point | 0.82 | load-use bubbles: 64 cycles |
| `fft_stages` | 64-point complex Q15 FFT, 6 stages of radix-2 butterflies, plain C | 10,497 | 54.67 per butterfly | 0.89 | D-cache waits: 453 cycles |
| `fft_stages_dmac` | The same, each half of the twiddle product one `dmac` against a packed twiddle | 8,152 | 42.46 per butterfly | 0.89 | load-use bubbles: 384 cycles |
| `fft_stages_packed` | The same, then `pk16` packs t and `radd16`/`rsub16` give both outputs, on both halves at once | 5,258 | 27.39 per butterfly | 0.87 | load-use bubbles: 385 cycles |
| `sha256` | SHA-256 of 256 bytes, plain RV32IMC | 26,363 | 103.0 per byte | 0.98 | D-cache waits: 476 cycles |
| `sha256_zk` | The same source built with Zbkb and Zknh (σ/Σ one instruction each) | 14,346 | 56.0 per byte | 0.97 | D-cache waits: 328 cycles |
| `aes128` | AES-128 encryption of 256 bytes, byte-oriented C | 102,864 | 401.8 per byte | 0.91 | mispredicts: 4,590 cycles |
| `aes128_ttable` | The same with one 1 KB T-table (the usual fast software form) | 23,775 | 92.9 per byte | 0.82 | D-cache waits: 3,965 cycles |
| `aes128_zk` | The same with Zkne: 16 `aes32esmi` per round | 5,031 | 19.6 per byte | 0.97 | — |
| `crc32_table` | zlib's CRC-32 of 256 bytes, table-driven C (1 KB table) | 2,834 | 11.1 per byte | 0.91 | load-use bubbles: 256 cycles |
| `crc32_clmul` | The same a word at a time: Barrett reduction by `clmul`/`clmulh` (Zbkc) | 681 | 2.7 per byte | 0.97 | I-cache misses: 13 cycles |

The extension removes the 64-bit carry chain from the energy kernel (3.5× with `dmac`) and the multiply, add
and saturation code from the FIR. With `mac` alone the FIR gains 15%, because GCC puts each load directly
before the `mac` that uses it, costing a load-use bubble per tap. The address generators (step 2) remove the
pointer increments; written two taps per iteration, with the loads ahead of the MACs, the FIR runs at 4.92
cycles per tap and the energy at 1.71 per sample (6.5× the plain C). With two taps per `dmac` the FIR reaches
3.75 per tap (2.4×); odd outputs, whose sample pairs are not aligned, start a sample early against a copy of
the coefficients shifted by one ([doc/dsp_extension.md](doc/dsp_extension.md), step 3). The hardware loop
(step 4) folds the loop-back into the body's last `dmac`, predicted like a branch: the FIR reaches 3.19 cycles
per tap (2.9×) and the energy 1.15 per sample (9.7×). The biquad halves with `mac`/`msu`/`acc.rdh` (step 5a);
the saturating mix gains less because it is memory-bound (its three arrays conflict in the D-cache). The FFT
(step 5b) gains about 2×: bit-reversed addressing cuts its permutation by about 2.8×, `dmac` against packed twiddles
computes each half of the twiddle product in one instruction, and packed halving adds and subtracts (step 5c)
make each butterfly output one instruction. SHA-256 with the ratified Zbkb and Zknh runs 1.8× faster, and
AES-128 with Zkne 4.7× faster than T-table C, and CRC-32 by carry-less multiply (Zbkc) 4.2× faster than
table-driven C ([doc/crypto_extensions.md](doc/crypto_extensions.md)). Memory-bound kernels move by a few percent when the data layout
changes (an added array shifts the D-cache conflicts); the table is from the latest build. The benchmarks are compiled with
`-falign-loops=4`, so that no loop starts with a 32-bit instruction at 2 mod 4, which costs a fetch bubble
on every jump back.

**Multiply in MEM.** The plain-C kernels pay one mul-use bubble per multiply, because their loops use each
product in the very next instruction and have nothing to put between. Before the multiply moved to MEM they took
8,308 and 2,591 cycles, and 9,331 and 2,847 after (both built before `-falign-loops`). In time, at each design's Fmax (58.8 then 65.7 MHz), the C FIR is unchanged (141.3 to
142.0 µs), the C energy 1.7% faster, and everything without a dependent multiply, including the Xbrvdsp kernels
(whose MAC unit stays in EX), 11.7% faster.

The plain-C numbers before that are after the early-straddle fetch change (below). Before it, the same kernels took 9,462 and 3,376 cycles
(9.24 per tap, 13.19 per sample), and the main loss in both was fetch: a 32-bit instruction that starts in the
upper half of a word cost a bubble while fetch read the next word (1,220 and 772 cycles).

**Early straddle.** When the next instruction in sequence starts in the upper half of the word fetch has just
read (after a compressed instruction in the lower half, or after a straddling instruction that ended in that
word) and is 32 bits long, fetch now keeps that half at once and reads the following word next, so no bubble is
needed. It changes only the aligner's `straddle` and `half_buf` registers, not the next-PC path. Effect: FIR
−12%, energy −23%; the ISA suites assembled with C −5 to −6%, the uncompressed ones unchanged. One test,
`rv32ui-c/ld_st`, is 2% slower (4,450 to 4,537 cycles): fetch now reaches new lines sooner, and its I-cache fills
collide more often with that test's stores on the shared AXI-Lite bus.

The FIR's inner loop is 7 instructions per tap (two loads, two pointer increments, `mul`, `add`, `bne`), and the
energy loop 9 per sample: a 64-bit sum on RV32 needs a carry chain. A multiply-accumulate into a wide
accumulator, post-increment loads and a zero-overhead loop would remove most of them.

## Verification status

| Suite | What it covers | Result |
|---|---|---|
| riscv-tests `rv32ui`, `rv32um`, `rv32uc` | Every RV32I, M and C instruction, with bypass and hazard cases | all pass |
| The same `rv32ui`/`rv32um` sources assembled **with C** | Mixed 16/32-bit code: 32-bit instructions straddling words, branches sharing a word | all pass |
| Directed (`tests/directed`) | The DSP extension (every instruction, rounding, saturation, 40-bit wrap and readback; a MAC interrupted in EX leaves the accumulator untouched; the address generators' strides, extension, readback and precise misaligned traps, and interrupted `lw.a` loops; `sadd`/`ssub` at and across both limits; `radd16`/`rsub16`/`pk16` at the extremes; bit-reversed addressing (8, 4 and 1024 points, and the wrap); hardware loops of 0 to many passes, one-instruction bodies, branches and compressed code in the body, save and restore around an inner loop, and interrupts at the loop end); Zbkb, Zbkc, Zbkx, Zknh, Zkne and Zknd, every instruction (AES with every byte select, carry-less products at the edges, permutes with out-of-range indexes) against Python and Spike, with forwarding; a multiply's or a CSR instruction's result used by the next instruction in every role (rs1, rs2, branch, store data, load address, JALR target, MAC operand, the next multiply or CSR instruction); FENCE.I on cached code, and in the cycle an I-cache fill completes; misaligned-access traps; timer interrupts (cause, and nothing lost or run twice) | all pass |
| Lockstep with Spike | Every ISA and directed test except `timer_irq` and `dsp_irq` (Spike has no timer; both check themselves), compared instruction by instruction; tests of the DSP extension use its Spike model (`tools/spike_xbrvdsp`) | all match |
| Pipeline trace | Every ISA and directed test: the rebuilt pipeline matches the RTL's stage registers every cycle, and its retirements match the retire trace | all check |
| SoC testbench + cocotb | Directed SoC program: GPIO, UART byte, caches, predictor training, ECALL | 30/30, 14/14 |
| Verilator lint | `-Wall`, with four documented waivers | clean |

That is 109 applicable ISA tests. Three upstream tests are listed as not applicable, with reasons in
`run_isa.sh`: `ma_data` twice (needs hardware misaligned access; this core traps, as the spec allows) and
`fence_i` assembled with C (it overwrites compressed code). Spike behaves identically on all three. The directed
tests were checked against mutants of the RTL with the behaviour removed, and each mutant fails.

**Not yet covered:**
- external (GPIO/UART) interrupts;
- nested interrupts;
- D-cache eviction under load;
- formal verification;
- random instruction streams (riscv-dv).

## Bugs found and fixed

The core was reviewed in two passes in October 2026. Each fix is its own commit, with the failing test first
where possible.

**Pass 1: making the directed testbench honest.** The original testbench printed `ALL TESTS PASSED` while
hiding failures.

| Bug | Symptom | Root cause |
|---|---|---|
| Redirect during a memory stall | JAL lost its link write and its jump | A mispredict flushed ID/EX while EX/MEM and the PC were held; traps, MRET, predictor updates and CSR writes also repeated on every stalled cycle |
| AUIPC | Returned a register value | `pc + imm` computed but never selected |
| Imprecise traps | The instruction after ECALL executed | `flush_mem` never driven |
| Firmware | GPIO stayed 0; data overwrote code | JALR patched at the wrong index; data aliased onto the program |

**Pass 2: ISA tests, then lockstep with Spike.** The first run passed 5 of 51 tests.

| Bug | Symptom | Root cause |
|---|---|---|
| No WB→ID bypass | 38 of 51 tests failed | A register read in ID while its producer wrote back in WB got the old value |
| Divider | Every DIV/REM wrong | The restoring step subtracted from the wrong bit window and ran 33 steps; `busy` rose a cycle late, so the divide left EX with 0; a stall could lose the result |
| Load-use bubble during a stall | A load vanished | The bubble's flush was not gated by the memory stall |
| RVC fetch | Compressed code ran garbage | No alignment: the high half of a word was never selected, and straddling 32-bit instructions never assembled |
| Predictor aliasing | Infinite loop in C-assembled code | BHT/BTB ignored pc[1], so a branch's entry hit the instruction beside it, and a predicted-taken non-branch was never corrected |
| CSR write data | `csrw mtvec, t0` wrote 2·t0 | The ALU added a register named by the CSR address bits |
| CSR immediates | `csrsi mstatus, 8` did nothing | zimm taken from the rd field |
| CSR forwarding | The instruction after `csrr` saw 0 | MEM forwarded the EX result, not the CSR value |
| `mepc` alignment | MRET returned 2 bytes early | `mepc` forced to 4-byte alignment despite C |
| Misaligned access | Silently wrong data | No check; it now traps (cause 4 or 6, with mtval) |
| FENCE.I | Stale code ran after a patch | Decoded as a no-op; it now invalidates the I-cache |
| Illegal compressed instructions | 0x0000 executed | `illegal_c` computed but never used |
| Interrupt cause | Timer interrupts reported as external | mcause hard-wired to 11 |
| Interrupt precision, `minstret` | An interrupted instruction could run twice; `minstret` counted wrongly | No per-stage valid bits; fixed with valid bits and a retire port |
| Branch prediction never helped a taken branch | A 2-instruction loop took 4 cycles per iteration | The mispredict check compared a taken branch's target with pc + 4, not with the predicted target, so every correctly predicted taken branch was flushed. Fixed: loops run at 1 IPC; the timer test needs 27% fewer cycles |

**Found later**, reviewing the I-cache after the pipeline trace showed how fetch misses behave; confirmed by a
new directed test, with the failing run's pipeline diagram in [doc/pipeline_trace.md](doc/pipeline_trace.md):

| Bug | Symptom | Root cause |
|---|---|---|
| FENCE.I lost during an I-cache fill | Stale code ran after a patch, when the instruction after the fence started an uncached line | FENCE.I in EX waits out the fetch miss and acts in the cycle the filled word is delivered; the I-cache ignored `invalidate` in that state. Test `directed/fence_i_fill` |

The test harness had bugs of its own, also fixed:
- image paths over 128 characters were truncated, and the run continued on an all-NOP memory;
- the final `tohost` store was missing from the trace.

## How this was built

This core was first written quickly with AI assistance (Feb–Mar 2026). In October 2026 I reviewed it line by line
and rebuilt its verification. That review found the bugs listed above, each fixed in its own commit.

## Design Notes

### Hazard handling

Load-use, mul-use and csr-use hazards insert a single bubble between the load, multiply or CSR instruction and
its consumer: all three produce their result in MEM, too late to forward from MEM into EX, so the consumer takes
it from WB. Other RAW hazards are resolved by
forwarding from EX/MEM and MEM/WB into EX, and by a write-through bypass in the register file (a read in ID sees a
same-cycle write in WB). A CSR instruction's result is read in MEM and reaches a dependent instruction from WB. Flushes and
redirects act only on a cycle when the pipeline advances.

### Instruction fetch and RV32C

Memory returns aligned words. The IF stage picks the halfword at `pc[1]`. A 32-bit instruction that starts in the
high half of a word is kept for a cycle, joined with the low half of the next word, and sent on (a bubble goes to
ID meanwhile).

### Branch prediction

The BHT uses a 2-bit saturating counter per entry; the BHT and BTB are indexed and tagged by halfword address
(`pc[31:1]`). The BTB caches the resolved target. A misprediction, including a taken prediction for an instruction
that turns out not to be a branch, flushes the two younger instructions (2-cycle penalty).

### Cache coherence

The D-cache uses a **write-through, write-allocate** policy (a store miss fills the line, then writes it), so memory is always up to date. FENCE.I invalidates
the I-cache and refetches the next instruction, which makes code written by stores visible.

### AXI4-Lite interconnect

The 2M → 2S crossbar grants exclusive access to each slave on a fixed-priority basis (core > I-cache on bus 0; core > D-cache on bus 1). Outstanding transactions are single-beat only (no bursts).

---

## Known Limitations

- No virtual memory or privilege levels below Machine mode
- UART baud rate is fixed at elaboration time (set in `brv32p_defs.vh`)
- No DMA engine; peripheral access is polled or interrupt-driven
- Misaligned loads and stores trap (cause 4/6) rather than being split in hardware
- Interrupts: timer and one combined external line (GPIO | UART); no nesting support beyond what software does

---

## Documentation

See [`doc/BRV32P_Design_Report.md`](doc/BRV32P_Design_Report.md) for a detailed micro-architecture description covering pipeline staging, cache organisation, the AXI interconnect, and peripheral register maps.

---

## Licence

MIT

---

## FPGA results

Out-of-context synthesis, place and route with `scripts/vivado_ooc.tcl`. Vivado 2025.2; part xc7a100tcsg324-1, the
Artix-7 on a Digilent Nexys A7-100T; 100 MHz target. Whole SoC, with the 32 KB SRAM.

| Resource | Used | Available | |
|---|---|---|---|
| LUTs | 10,669 | 63,400 | 16.8% (the cache arrays are LUT RAM; the Zk unit about 1,790; the DSP unit, AGU and loop unit about 700 together) |
| Registers | 7,760 | 126,800 | 6.1% |
| Block RAM (36 Kb) | 8 | 135 | the 32 KB SRAM |
| DSP48 | 7 | 240 | 4 for the 33×33 multiplier, 3 for the DSP unit's two 16×16 multipliers |
| **Fmax** | **64.1 MHz** | | WNS −5.6 ns at 10 ns |

**Critical path** (19 logic levels, 15.5 ns, 75% routing): fetch, from `pc_if` through the I-cache tag and data
LUT-RAM reads and the RV32C alignment into the IF/ID register. In other runs it was the next-PC loop through the
same reads (15.3 ns), or forwarding into a branch target and the mispredict logic (14.5 ns).
The worst path moves between runs. Two limits take turns: fetching, aligning and predicting in one cycle, and
resolving a branch in EX on forwarded operands. Raising Fmax much further means splitting fetch over two stages
and taking the branch target off the forwarding path.

The path before this (16.0 ns, at 62.2 MHz) was a CSR read in MEM forwarded combinationally into EX. Its value
was `mip`, straight from a peripheral's interrupt line, and it passed through a branch target and the mispredict
logic. The fix is the one used for the multiply: a CSR result is not forwarded from MEM. A dependent instruction
waits a cycle (the csr-use interlock) and takes the value from WB. The DSP benchmarks did not change by a single
cycle; code rarely uses a CSR value in the very next instruction. Fetching, aligning and
predicting in one cycle is what limits the clock now; splitting fetch into two stages is the next step for Fmax.

**How it got here.**

| Change | Fmax | Critical path after it |
|---|---|---|
| Before the early straddle | 61.6 MHz | forwarding → 32×32 multiplier in EX |
| Early straddle | 58.4 MHz | the same |
| Xbrvdsp step 1 (DSP unit) | 58.8 MHz | the same; the DSP unit cost 390 LUTs and 3 DSP48s |
| Multiply moved to MEM | 64.3 MHz | branch resolution → `kill` → the divider's operand-register enables |
| Divider operand registers no longer gated by `kill` | 65.7 MHz | the next-PC loop |
| Xbrvdsp step 2 (address generators) | 66.3 MHz | fetch: I-cache read, alignment, into the IF/ID register; the AGU cost 197 LUTs and 192 registers |
| Xbrvdsp step 4 (hardware loop) | 65.9 MHz | the next-PC loop; the loop unit cost 120 LUTs and 64 registers |
| Xbrvdsp step 5a (`sadd`, `ssub`) | 65.0 MHz | a CSR read in MEM (`mip`, from a peripheral's interrupt line) forwarded into a branch in EX, to the mispredict flush's enables: an existing path, not through `sadd`; `sadd`/`ssub` cost 32 LUTs |
| Xbrvdsp step 5b (bit-reversed addressing) | 65.5 MHz | the next-PC loop again; the mode cost the AGU 40 LUTs and 4 registers |
| Xbrvdsp step 5c (packed halves) | 62.2 MHz | the CSR-read forwarding path again, now 16.0 ns: a peripheral's interrupt line into `mip`, read in MEM, forwarded into EX, through a branch target and the mispredict, into the ID/EX register; the packed halves cost 26 LUTs, off that path |
| CSR results forwarded from WB (csr-use interlock) | 65.6 MHz | fetch: the I-cache read and alignment into IF/ID, and the next-PC loop (the five worst paths); 54 LUTs fewer |
| Zbkb and Zknh (`zk_unit`) | 67.4 MHz (placement noise: the unit is not on the worst path) | forwarding into a branch target and the mispredict, into the ID/EX register; Zk cost about 730 LUTs, with one rotator shared by `ror`, `rori` and `rol` (two separate rotators cost about 1,140) |
| Zkne and Zknd (AES) | 65.3 MHz | the next-PC loop; AES cost 489 LUTs (two S-boxes and the GF(2⁸) constant multiplies) |
| Zbkc and Zbkx | **64.1 MHz** | fetch into IF/ID (15.5 ns), not the new unit; 567 LUTs, mostly the 32×32 carry-less multiplier array |

Moving the multiply also cut the DSP48s from 15 to 7: the old RTL wrote three 64-bit products (signed × signed,
signed × unsigned, unsigned × unsigned), and Vivado built each. One 33×33 signed multiply with the operands
sign- or zero-extended covers all four instructions. The divider fix keeps the flush only on the control
registers (`div_active`, `div_count`); a killed division leaves `div_active` low, so the operand registers need
not be gated.

**What changed to get here.** An earlier run built every memory from flip-flops (about 43k LUTs and 78k
registers; it did not fit an Artix-7 35T). Two coding changes fixed it:
- The memories are no longer accessed inside async-reset processes: the SRAM became block RAM, and the cache
  arrays became LUT RAM.
- The cache arrays are now 1-D: Vivado does not map a 3-D array to RAM.

The branch predictor's tables are still registers (4,224), because each entry is reset.
