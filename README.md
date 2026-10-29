# BRV32P — 5-Stage Pipelined RV32IMC RISC-V SoC

A synthesisable RV32IMC RISC-V SoC implemented in Verilog-2001. Features a classic 5-stage in-order pipeline with full forwarding, 2-way set-associative caches, an AXI4-Lite bus fabric, and an M-extension multiply/divide unit.

---

## Features

| Category | Detail |
|---|---|
| **ISA** | RV32IMC — Base Integer, Multiply/Divide, Compressed |
| **Pipeline** | 5-stage (IF / ID / EX / MEM / WB), in-order |
| **Hazards** | Full data forwarding; load-use stall; flush on misprediction |
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
- **M-extension:** Multi-cycle multiply/divide unit in EX; pipeline stalls until result is ready

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
│   │   ├── decoder.v                 # RV32IMC instruction decoder
│   │   ├── compressed_decoder.v      # RV32C → RV32 expander
│   │   ├── alu.v                     # Arithmetic logic unit
│   │   ├── regfile.v                 # 32 × 32-bit register file
│   │   ├── muldiv.v                  # M-extension multiply / divide
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
│   │   ├── tb_isa.v                  # ISA testbench: tohost detection, commit log
│   │   ├── lockstep.py               # Compare the commit log with Spike's
│   │   ├── elf2hex.py                # ELF image → $readmemh hex
│   │   └── env/                      # Bare-metal test environment (riscv_test.h, link.ld)
│   └── directed/                     # Own tests: FENCE.I, misaligned traps, interrupts
├── scripts/
│   ├── lint.sh                       # Verilator -Wall lint
│   └── lint_waivers.vlt              # The waived rules, each with its reason
├── .github/workflows/ci.yml          # CI: ISA + lockstep, testbenches, lint
├── doc/
│   └── BRV32P_Design_Report.md       # Detailed micro-architecture write-up
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
```

Each test is assembled with `riscv64-unknown-elf-gcc` and run on the SoC in Icarus. It reports pass or fail by a
store to `tohost`, which the testbench sees on the core's retire trace. With Spike available, the same ELF also
runs on Spike, and `lockstep.py` compares the two commit logs instruction by instruction: pc, encoding, register
write and store. Any difference fails the test and is shown with context.

### Lint

```bash
scripts/lint.sh                          # Verilator -Wall; waivers and reasons in scripts/lint_waivers.vlt
```

## Verification status

| Suite | What it covers | Result |
|---|---|---|
| riscv-tests `rv32ui`, `rv32um`, `rv32uc` | Every RV32I, M and C instruction, with bypass and hazard cases | all pass |
| The same `rv32ui`/`rv32um` sources assembled **with C** | Mixed 16/32-bit code: 32-bit instructions straddling words, branches sharing a word | all pass |
| Directed (`tests/directed`) | FENCE.I on cached code; misaligned-access traps; timer interrupts (cause, and nothing lost or run twice) | all pass |
| Lockstep with Spike | Every ISA and directed test except `timer_irq` (Spike has no timer), compared instruction by instruction | all match |
| SoC testbench + cocotb | Directed SoC program: GPIO, UART byte, caches, predictor training, ECALL | 30/30, 14/14 |
| Verilator lint | `-Wall`, with four documented waivers | clean |

That is 101 applicable ISA tests. Three upstream tests are listed as not applicable, with reasons in
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

The test harness had bugs of its own, also fixed:
- image paths over 128 characters were truncated, and the run continued on an all-NOP memory;
- the final `tohost` store was missing from the trace.

## How this was built

This core was first written quickly with AI assistance (Feb–Mar 2026). In October 2026 I reviewed it line by line
and rebuilt its verification. That review found the bugs listed above, each fixed in its own commit.

## Design Notes

### Hazard handling

Load-use hazards insert a single bubble between the load and its consumer. Other RAW hazards are resolved by
forwarding from EX/MEM and MEM/WB into EX, and by a write-through bypass in the register file (a read in ID sees a
same-cycle write in WB). A CSR instruction's result is forwarded from MEM, where the CSR is read. Flushes and
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
| LUTs | 8,030 | 63,400 | 12.7% (1,456 of them as LUT RAM: the cache arrays) |
| Registers | 7,324 | 126,800 | 5.8% |
| Block RAM (36 Kb) | 8 | 135 | the 32 KB SRAM |
| DSP48 | 12 | 240 | the 32×32 multiplier |
| **Fmax** | **62.3 MHz** | | WNS −6.05 ns at 10 ns |

**Critical path** (17 logic levels, 15.9 ns, 70% routing): the next-PC loop, from `pc_if` through the I-cache
LUT-RAM read, the RV32C alignment and the next-PC selection, back into `pc_if`. Fetching, aligning and predicting
in one cycle is what limits the clock. Splitting fetch into two stages is the obvious next step.

**What changed to get here.** An earlier run built every memory from flip-flops (about 43k LUTs and 78k
registers; it did not fit an Artix-7 35T). Two coding changes fixed it:
- The memories are no longer accessed inside async-reset processes: the SRAM became block RAM, and the cache
  arrays became LUT RAM.
- The cache arrays are now 1-D: Vivado does not map a 3-D array to RAM.

The branch predictor's tables are still registers (4,224), because each entry is reset.
