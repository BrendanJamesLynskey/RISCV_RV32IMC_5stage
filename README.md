# BRV32P — 5-Stage Pipelined RV32IMC RISC-V SoC

A fully-verified, synthesisable RV32IMC RISC-V SoC implemented in Verilog-2001. Features a classic 5-stage in-order pipeline with full forwarding, 2-way set-associative caches, an AXI4-Lite bus fabric, and an M-extension multiply/divide unit.

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
| `0x1000_0000` – `0x1000_00FF` | 256 B | GPIO registers |
| `0x1000_0100` – `0x1000_01FF` | 256 B | UART registers |
| `0x1000_0200` – `0x1000_02FF` | 256 B | Timer registers |

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
│   └── tb_brv32p_soc.v               # Verilog testbench
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

### Firmware toolchain (optional — pre-built hex is provided)

```
sudo apt install gcc-riscv64-unknown-elf   # Ubuntu 20.04+
# Then build with:
cd firmware && python gen_firmware.py
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

### CocoTB

```bash
cd cocotb
cp ../firmware/firmware.hex .
make
```

---

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
- Formal verification not yet included; compliance is tested via directed testbenches

---

## Documentation

See [`doc/BRV32P_Design_Report.md`](doc/BRV32P_Design_Report.md) for a detailed micro-architecture description covering pipeline staging, cache organisation, the AXI interconnect, and peripheral register maps.

---

## Licence

MIT

---

## Synthesis Results

Target: Xilinx Artix-7 (xc7a35tcpg236-1) | Tool: Vivado 2025.2

| Module | LUTs | FFs | BRAM | DSP | Fmax (MHz) |
|--------|------|-----|------|-----|------------|
| brv32p_soc | 43,059 | 78,529 | 0 | 12 | 64.5 |

*Auto-generated by Vivado batch synthesis. Clock target: 100 MHz. Note: design exceeds xc7a35t capacity (20,800 LUTs / 41,600 FFs). SRAM and cache memories were dissolved into flip-flops due to async-reset coding style preventing BRAM inference — LUT/FF counts are inflated by memory implementation. MEM_DEPTH reduced to 1024 for synthesis feasibility.*
