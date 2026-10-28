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
| **I-cache** | 2-way set-associative, 2 KB, write-allocate |
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

## Verification status

The verification is honest, but it is still small. Here is what is and is not covered today.

**Covered** by one directed program (`firmware/gen_firmware.py`, 48 RV32I instructions), checked by the Verilog
testbench (30 checks) and the cocotb suite (14 tests):
- ALU and immediate instructions;
- EX→EX forwarding;
- one load-use stall;
- word and byte load and store through the D-cache;
- BEQ, BNE, JAL (target and link) and JALR;
- AUIPC;
- a 100-iteration countdown loop;
- CSRRS of `mcycle`;
- ECALL (`mcause` = 11, and the trap is precise);
- GPIO output and input;
- one UART byte, decoded by the testbench;
- I-cache fill and branch-predictor training.

**Not yet covered:**
- **The M and C extensions**: no multiply, divide or compressed instruction is executed by any test;
- most of RV32I (halfwords, SLTU, SRA, other branch conditions);
- interrupts;
- illegal-instruction traps;
- MRET;
- D-cache eviction.

**Known issues:**
- `minstret` counts only instructions that write a register, store or ECALL, and it counts again on stalled
  cycles.
- On an interrupt, `mepc` points at the instruction in MEM, which still completes, so it would run twice after
  MRET.
- The 2-instruction countdown loop takes 4 cycles per iteration, so the predictor does not reach the ideal
  2 cycles.

**Planned:**
- compiler-built ISA tests for I, M and C;
- a per-cycle retire trace compared instruction by instruction against Spike;
- CI.

## Bugs found and fixed

When this core's verification was reviewed (October 2026), the original testbench printed `ALL TESTS PASSED`
while hiding failures. Once every check counted, these bugs showed up. Each fix is its own commit:

| Bug | Symptom | Root cause | Caught by |
|---|---|---|---|
| Redirect during a memory stall | JAL never wrote its link register; its jump was lost | A mispredict flushed ID/EX during a memory stall, while the PC and EX/MEM were held, so the JAL was flushed out of EX. Traps, MRET, predictor updates and CSR writes also acted once per stalled cycle | JAL link check |
| AUIPC | AUIPC returned a register value, not pc + imm | `auipc_result` was computed but never selected; AUIPC used the ALU as rs1 + imm | Program-end check (x20 at 0xA4) |
| Imprecise traps | The instruction after ECALL executed | `flush_mem` was never driven, so the younger instruction reached MEM | Precise-trap check |
| Firmware JALR | GPIO output stayed 0; the program looped | The "patch" wrote index 18 (0x48), not the JALR at 0x74 | GPIO and program-end checks |
| Firmware data address | Stores overwrote the program | Data at `0x1000_0000` aliases SRAM address 0 | Memory-map review |
| Hollow tests | Failures reported as INFO or passed on reset values | See the testbench and cocotb commits | Review |

## Design Notes

### Hazard handling

Load-use hazards insert a single bubble between the load instruction and its consumer. All other RAW hazards are resolved by forwarding from the EX/MEM or MEM/WB pipeline registers. There are no WAW or WAR hazards in an in-order pipeline.

### Branch prediction

The BHT uses a 2-bit saturating counter per entry and is indexed by the lower PC bits. The BTB caches the resolved target address. On a misprediction the two instructions fetched speculatively are flushed (2-cycle penalty).

### Cache coherence

The D-cache uses a **write-through, no-write-allocate** policy. There is no hardware coherence protocol between I-cache and D-cache; software must flush the I-cache after writing self-modifying code.

### AXI4-Lite interconnect

The 2M → 2S crossbar grants exclusive access to each slave on a fixed-priority basis (core > I-cache on bus 0; core > D-cache on bus 1). Outstanding transactions are single-beat only (no bursts).

---

## Known Limitations

- No virtual memory or privilege levels below Machine mode
- UART baud rate is fixed at elaboration time (set in `brv32p_defs.vh`)
- No DMA engine; peripheral access is polled or interrupt-driven
- I-cache and D-cache are not coherent; self-modifying code requires a software cache flush sequence
- Verification is a single directed program so far: see "Verification status" above

---

## Documentation

See [`doc/BRV32P_Design_Report.md`](doc/BRV32P_Design_Report.md) for a detailed micro-architecture description covering pipeline staging, cache organisation, the AXI interconnect, and peripheral register maps.

---

## Licence

MIT
