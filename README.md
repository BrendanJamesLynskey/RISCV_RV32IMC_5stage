# BRV32P — 5-Stage Pipelined RV32IMC RISC-V Microcontroller

A high-performance pipelined RISC-V SoC with caches and AXI4-Lite bus.

## Features
- 5-stage pipeline (IF/ID/EX/MEM/WB) with full data forwarding
- RV32IMC: Base Integer + Multiply/Divide + Compressed instructions
- 2-bit branch predictor with Branch Target Buffer
- 2-way set-associative I-cache and D-cache (2 KB each)
- AXI4-Lite bus interconnect with priority arbiter
- 32 KB unified backing SRAM
- GPIO, UART (8N1), Timer peripherals

## Directory Structure
```
brv32p/
├── rtl/
│   ├── pkg/brv32p_defs.vh            # Shared definitions (include file)
│   ├── core/
│   │   ├── brv32p_core.v             # 5-stage pipeline top
│   │   ├── decoder.v                 # RV32IMC decoder
│   │   ├── compressed_decoder.v      # RV32C expander
│   │   ├── alu.v                     # Arithmetic logic unit
│   │   ├── regfile.v                 # 32x32 register file
│   │   ├── muldiv.v                  # M-extension multiply/divide
│   │   ├── branch_predictor.v        # 2-bit BHT + BTB
│   │   ├── hazard_unit.v             # Forwarding + stall logic
│   │   └── csr.v                     # Machine-mode CSRs
│   ├── cache/
│   │   ├── icache.v                  # 2-way I-cache
│   │   └── dcache.v                  # 2-way D-cache (write-through)
│   ├── bus/
│   │   ├── axi_interconnect.v        # 2M→2S bus arbiter
│   │   ├── axi_sram.v                # AXI SRAM slave
│   │   └── axi_periph_bridge.v       # AXI → peripheral bridge
│   ├── periph/
│   │   ├── gpio.v                    # GPIO with interrupts
│   │   ├── uart.v                    # UART TX/RX
│   │   └── timer.v                   # Timer/counter
│   └── brv32p_soc.v                  # SoC top-level
├── tb/tb_brv32p_soc.v                # Verilog testbench
├── cocotb/
│   ├── test_brv32p_soc.py            # CocoTB test suite
│   └── Makefile
├── firmware/
│   ├── firmware.hex
│   └── gen_firmware.py
└── doc/BRV32P_Design_Report.md
```

## Running Tests

### Verilog (Icarus Verilog 10.1+)
```bash
iverilog -g2005 -o sim_brv32p -I rtl/pkg -I rtl/core \
  rtl/core/*.v rtl/cache/*.v \
  rtl/bus/axi_interconnect.v rtl/bus/axi_sram.v \
  rtl/bus/axi_periph_bridge.v rtl/periph/*.v \
  rtl/brv32p_soc.v tb/tb_brv32p_soc.v
cp firmware/firmware.hex .
vvp sim_brv32p
```

### CocoTB
```bash
cd cocotb
cp ../firmware/firmware.hex .
make
```
